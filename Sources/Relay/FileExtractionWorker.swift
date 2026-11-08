import CryptoKit
import Foundation
import PDFKit

/// Trusted per-invocation metadata, never reconstructed from model/history text.
/// The context contains configuration/scope identifiers, not model messages.
@MainActor struct FileReadExecutionScope {
    fileprivate struct Namespace: Equatable {
        let run: UUID, attempt: UUID, proposal: UUID
        let provider: Data, callDigest: String
    }
    fileprivate struct Fence {
        let run: UUID
        let context: MultiAgentContinuation.Context
        let currentContext: @MainActor @Sendable () -> MultiAgentContinuation.Context?
        let grants: @MainActor @Sendable () -> [ScopeGrant]
        let isCurrent: @MainActor @Sendable () -> Bool
        func check() throws {
            try Task.checkCancellation()
            guard isCurrent(), currentContext() == context else { throw FileExtractionWorker.Failure.unavailable }
        }
        var sourceIdentity: Data {
            get throws {
                let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
                return FileExtractionWorker.framed([
                    Data(run.uuidString.utf8), Data(context.logicalTaskID.uuidString.utf8),
                    Data(context.scopeID.uuidString.utf8), Data(String(context.sourceRevision).utf8),
                    Data(SHA256.hash(data: try encoder.encode(context.configuration)))
                ])
            }
        }
    }
    fileprivate let namespace: Namespace
    fileprivate let fence: Fence

    init(run: AssistantConversationHistory.Run, proposalID: UUID, call: ToolCall,
         context: MultiAgentContinuation.Context,
         currentContext: @escaping @MainActor @Sendable () -> MultiAgentContinuation.Context?,
         grants: @escaping @MainActor @Sendable () -> [ScopeGrant],
         isCurrent: @escaping @MainActor @Sendable () -> Bool) throws {
        guard call.name == "read_file", !call.id.isEmpty, call.id.utf8.count <= 4_096,
              run.relation.logicalTaskID == context.logicalTaskID else { throw FileExtractionWorker.Failure.unavailable }
        namespace = Namespace(run: run.taskID, attempt: run.attemptID, proposal: proposalID,
            provider: Data(call.id.utf8), callDigest: ToolPolicy.fingerprint(call))
        fence = Fence(run: run.taskID, context: context, currentContext: currentContext,
            grants: grants, isCurrent: isCurrent)
        try fence.check()
    }
    var executionContext: MultiAgentContinuation.Context { fence.context }
    func validateCurrent(call: ToolCall) throws { try check(call) }
    fileprivate func check(_ call: ToolCall) throws {
        try fence.check()
        guard call.name == "read_file", Data(call.id.utf8) == namespace.provider,
              ToolPolicy.fingerprint(call) == namespace.callDigest else { throw FileExtractionWorker.Failure.unavailable }
    }
}

/// Only this file's actual snapshot/parser path can mint a receipt. It retains
/// no parser input, parsed body, pixels or executable action. Codable omits it.
@MainActor final class FileExtractionReceipt {
    private let namespace: FileReadExecutionScope.Namespace
    private let fence: FileReadExecutionScope.Fence
    private let source: FileExtractionWorker.Source
    private let resultDigest: Data
    private let worker: FileExtractionWorker
    private var consumed = false

    fileprivate init(scope: FileReadExecutionScope, source: FileExtractionWorker.Source,
                     result: ToolResult, worker: FileExtractionWorker) throws {
        try scope.fence.check()
        namespace = scope.namespace; fence = scope.fence; self.source = source
        resultDigest = Self.resultDigest(for: result); self.worker = worker
    }

    /// Consume once at the actual accepted result boundary, then explicitly
    /// distribute this flat proof to any current inference consumers.
    func consume(call: ToolCall, result: ToolResult, run: AssistantConversationHistory.Run,
                 proposalID: UUID, context: MultiAgentContinuation.Context) throws -> ModelInputSourceProof {
        try fence.check()
        guard !consumed, result.fileExtractionReceipt === self,
              namespace.run == run.taskID, namespace.attempt == run.attemptID,
              namespace.proposal == proposalID, namespace.provider == Data(call.id.utf8),
              namespace.callDigest == ToolPolicy.fingerprint(call), call.name == "read_file",
              context == fence.context, Self.resultDigest(for: result) == resultDigest else {
            throw FileExtractionWorker.Failure.unavailable
        }
        consumed = true
        // A source identity is stable across repeated accepted proposals in the
        // same run. Proposal IDs belong only to the one-time consumption above.
        let identity = ModelInputSourceProof.Identity(owner: namespace.run,
            sourceID: FileExtractionWorker.framed([try fence.sourceIdentity, source.id]),
            purpose: "relay.actual-file-extraction.raw-input.v1")
        let source = source, fence = fence, worker = worker
        return .source(identity: identity) {
            try fence.check()
            let grants = fence.grants(), before = try FileExtractionWorker.grantDigest(grants)
            try await worker.validate(source, grants: grants)
            try fence.check()
            guard try FileExtractionWorker.grantDigest(fence.grants()) == before else {
                throw FileExtractionWorker.Failure.unavailable
            }
        }
    }
    nonisolated static func resultDigest(for result: ToolResult) -> Data {
        // Exact UTF-8 body bytes matter even when Swift String equality would
        // consider two Unicode spellings equivalent. The wire stays unchanged.
        return Data(SHA256.hash(data: FileExtractionWorker.framed([
            Data("relay.actual-extraction.result.v1".utf8), Data(result.summary.utf8),
            Data(result.evidence.utf8), Data([result.verified ? 1 : 0]),
            Data([result.artifactPath == nil ? 0 : 1]), Data((result.artifactPath ?? "").utf8)
        ])))
    }
}

/// One physical file IO/parser job at a time. Cancellation releases the waiter
/// promptly, while the slot and descriptor stay owned until actual work ends.
@MainActor final class FileExtractionWorker {
    static let shared = FileExtractionWorker()
    nonisolated enum Failure: LocalizedError, Equatable {
        case busy, timedOut, unavailable, readFailed
        var errorDescription: String? {
            switch self {
            case .busy: "A selected-file extraction is still settling. No additional read was queued."
            case .timedOut: "Selected-file extraction timed out. Its late output will not be used."
            case .unavailable: "The selected file, task or authorized scope changed. Its extracted content cannot be reused."
            case .readFailed: "The selected file did not produce an admitted result within the supported format and size limits. Inspect the current file and format before deciding whether to read again."
            }
        }
    }
    fileprivate nonisolated struct Source: Sendable {
        let input: String, canonicalPath: String
        let metadata: LocalStateFile.Metadata
        let rawDigest: Data, id: Data
        let maximumBytes: Int
    }
    private nonisolated struct Parsed: Sendable {
        let summary: String, evidence: String
    }
    private nonisolated struct Value: Sendable {
        let source: Source
        let parsed: Parsed?
    }
    private nonisolated enum Resolution: Sendable {
        case value(Value), failed(any Error), cancelled
    }
    private nonisolated final class Delivery: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Resolution?
        private var continuation: CheckedContinuation<Value, any Error>?
        var pending: Bool { lock.withLock { result == nil } }
        func install(_ continuation: CheckedContinuation<Value, any Error>) {
            let value = lock.withLock { () -> Resolution? in
                if let result { return result }
                self.continuation = continuation; return nil
            }
            if let value { Self.resume(continuation, value) }
        }
        @discardableResult func complete(_ value: Resolution) -> Bool {
            let state = lock.withLock { () -> (Bool, CheckedContinuation<Value, any Error>?) in
                guard result == nil else { return (false, nil) }
                result = value
                let waiter = continuation; continuation = nil
                return (true, waiter)
            }
            if let waiter = state.1 { Self.resume(waiter, value) }
            return state.0
        }
        private static func resume(_ waiter: CheckedContinuation<Value, any Error>, _ value: Resolution) {
            switch value {
            case .value(let value): waiter.resume(returning: value)
            case .failed(let error): waiter.resume(throwing: error)
            case .cancelled: waiter.resume(throwing: CancellationError())
            }
        }
    }
    #if DEBUG
    private nonisolated final class ReadHook: @unchecked Sendable {
        private let lock = NSLock()
        private var value: (@Sendable () -> Void)?
        func set(_ value: @escaping @Sendable () -> Void) { lock.withLock { self.value = value } }
        func take() -> (@Sendable () -> Void)? { lock.withLock { let old = value; value = nil; return old } }
    }
    private let readHook = ReadHook()
    /// Delays only bytes actually read from the real descriptor; cannot replace
    /// the snapshot, parser output or digest. Absent from Release builds.
    func pauseAfterNextSnapshot(_ value: @escaping @Sendable () -> Void) { readHook.set(value) }
    #endif
    private struct Active { let id: UUID; let physical: Task<Void, Never>, expiry: Task<Void, Never> }
    private var active: Active?
    private let extractionTimeout: Duration, validationTimeout: Duration
    var activeCount: Int { active == nil ? 0 : 1 }
    init(extractionTimeout: Duration = .seconds(15), validationTimeout: Duration = .seconds(2)) {
        self.extractionTimeout = min(.seconds(30), max(.milliseconds(1), extractionTimeout))
        self.validationTimeout = min(.seconds(5), max(.milliseconds(1), validationTimeout))
    }
    func drain() async { if let active { await active.physical.value } }

    func extract(call: ToolCall, grants: [ScopeGrant], scope: FileReadExecutionScope?) async throws -> ToolResult {
        try ToolPolicy.validate(call, against: MacTools.definitions)
        guard call.name == "read_file", let input = call.arguments["path"]?.string else { throw Failure.unavailable }
        try scope?.check(call)
        let actualGrants = scope?.fence.grants() ?? grants
        let expectedGrants = try Self.grantDigest(actualGrants)
        let value: Value
        do { value = try await perform(input: input, grants: actualGrants, expected: nil) }
        catch {
            try Task.checkCancellation(); try scope?.check(call)
            if let scope, try Self.grantDigest(scope.fence.grants()) != expectedGrants { throw Failure.unavailable }
            throw error
        }
        try Task.checkCancellation(); try scope?.check(call)
        if let scope, try Self.grantDigest(scope.fence.grants()) != expectedGrants { throw Failure.unavailable }
        guard let parsed = value.parsed else { throw Failure.unavailable }
        var result = ToolResult(summary: parsed.summary, evidence: parsed.evidence, verified: true)
        if let scope { result.fileExtractionReceipt = try FileExtractionReceipt(scope: scope, source: value.source, result: result, worker: self) }
        return result
    }
    fileprivate func validate(_ source: Source, grants: [ScopeGrant]) async throws {
        do { _ = try await perform(input: source.input, grants: grants, expected: source) }
        catch is CancellationError { throw CancellationError() }
        catch let error as Failure { throw error }
        catch { throw Failure.unavailable }
    }
    private func perform(input: String, grants: [ScopeGrant], expected: Source?) async throws -> Value {
        try Task.checkCancellation()
        guard active == nil else { throw Failure.busy }
        let id = UUID(), delivery = Delivery()
        let deadline = ContinuousClock.now.advanced(by: expected == nil ? extractionTimeout : validationTimeout)
        #if DEBUG
        let afterRead: @Sendable () -> Void = { [readHook] in readHook.take()?() }
        #else
        let afterRead: @Sendable () -> Void = {}
        #endif
        let physical = Task { [weak self] in
            delivery.complete(await Self.kernel(input: input, grants: grants, expected: expected,
                deadline: deadline, delivery: delivery, afterRead: afterRead))
            self?.physicalFinished(id)
        }
        let expiry = Task {
            do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            if delivery.complete(.failed(Failure.timedOut)) { physical.cancel() }
        }
        active = Active(id: id, physical: physical, expiry: expiry)
        return try await withTaskCancellationHandler {
            let value = try await withCheckedThrowingContinuation { delivery.install($0) }
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw Failure.timedOut }
            return value
        } onCancel: {
            delivery.complete(.cancelled); physical.cancel(); expiry.cancel()
        }
    }
    private func physicalFinished(_ id: UUID) {
        guard let active, active.id == id else { return }
        active.expiry.cancel(); self.active = nil
    }
    @concurrent private static func kernel(input: String, grants: [ScopeGrant], expected: Source?,
        deadline: ContinuousClock.Instant, delivery: Delivery, afterRead: @escaping @Sendable () -> Void) async -> Resolution {
        func check() throws {
            try Task.checkCancellation()
            guard delivery.pending else { throw CancellationError() }
            guard ContinuousClock.now < deadline else { throw Failure.timedOut }
        }
        do {
            try check()
            let url = try ToolPolicy.scopedURL(input, grants: grants)
            let ext = url.pathExtension.lowercased()
            let limit = maximumBytes(extension: ext)
            if let expected {
                guard url.path.utf8.elementsEqual(expected.canonicalPath.utf8), limit == expected.maximumBytes else { throw Failure.unavailable }
            }
            try check()
            let snapshot = try LocalStateFile.snapshot(url, maximumBytes: limit)
            afterRead(); try check()
            let digest = Data(SHA256.hash(data: snapshot.data))
            let id = rawIdentity(path: url.path, metadata: snapshot.metadata, digest: digest)
            let source = Source(input: input, canonicalPath: url.path, metadata: snapshot.metadata,
                rawDigest: digest, id: id, maximumBytes: limit)
            if let expected, source.id != expected.id { throw Failure.unavailable }
            try check()
            // The only parser input is the actual descriptor snapshot above.
            let parsed = expected == nil ? try await parse(snapshot.data, extension: ext, path: url.path) : nil
            try check()
            guard try ToolPolicy.scopedURL(input, grants: grants).path.utf8.elementsEqual(url.path.utf8) else { throw Failure.unavailable }
            try LocalStateFile.validateCurrent(snapshot.metadata, at: url, maximumBytes: limit)
            try check()
            return .value(Value(source: source, parsed: parsed))
        } catch is CancellationError { return .cancelled }
        catch { return .failed(error) }
    }
    nonisolated private static func maximumBytes(extension ext: String) -> Int {
        if ext == "pdf" { return 10_485_760 }
        if ["png", "jpg", "jpeg", "heic", "tiff", "bmp", "webp"].contains(ext) { return 20_971_520 }
        return 1_048_576
    }
    nonisolated fileprivate static func framed(_ fields: [Data]) -> Data {
        var value = Data()
        for field in fields {
            var count = UInt64(field.count).bigEndian
            withUnsafeBytes(of: &count) { value.append(contentsOf: $0) }
            value.append(field)
        }
        return value
    }
    fileprivate static func grantDigest(_ grants: [ScopeGrant]) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return Data(SHA256.hash(data: try encoder.encode(grants)))
    }
    nonisolated private static func rawIdentity(path: String, metadata: LocalStateFile.Metadata, digest: Data) -> Data {
        let numbers = [String(metadata.device), String(metadata.inode), String(metadata.mode), String(metadata.flags),
            String(metadata.links), String(metadata.size), String(metadata.modifiedSeconds), String(metadata.modifiedNanoseconds),
            String(metadata.changedSeconds), String(metadata.changedNanoseconds)]
        return Data(SHA256.hash(data: framed([Data("relay.actual-extraction.raw-snapshot.v1".utf8), Data(path.utf8),
            framed(numbers.map { Data($0.utf8) }), digest])))
    }
    @concurrent private static func parse(_ data: Data, extension ext: String, path: String) async throws -> Parsed {
        try Task.checkCancellation()
        if ext == "eml" {
            let mail = try MailExportReader.parse(data), value = mail.sourceText
            let limited = bounded(value, maximum: 11_500)
            return Parsed(summary: limited + (limited.utf8.count < value.utf8.count ? "\n[Mail text truncated at the tool output limit; omitted text was not returned.]" : ""),
                evidence: "Decoded only inline plain-text MIME from selected mail export \(path), locally. Sender/subject/date are unverified claims; no account, HTML, attachment or remote asset was accessed. \(mail.coverageNote ?? "")")
        }
        if ["png", "jpg", "jpeg", "heic", "tiff", "bmp", "webp"].contains(ext) {
            return Parsed(summary: try await LocalOCR.recognizeImage(data: data),
                evidence: "Ran Apple Vision OCR locally on selected image \(path). Recognized text may contain errors; this is not verification of visual meaning or layout.")
        }
        if ext == "pdf" {
            guard let document = PDFDocument(data: data) else { throw RelayError.message("PDF could not be opened within the 10 MB limit.") }
            guard !document.isLocked else { throw RelayError.message("This PDF is locked. Ask the user to unlock it directly before reading.") }
            var excerpts: [String] = [], characters = 0, pagesRead = 0
            var truncated = document.pageCount > 20
            for index in 0..<min(document.pageCount, 20) {
                try Task.checkCancellation()
                let value = document.page(at: index)?.string ?? ""
                let excerpt = String(value.prefix(max(0, 30_000 - characters)))
                if excerpt.count < value.count { truncated = true }
                excerpts.append("[Page \(index + 1)]\n" + excerpt)
                characters += excerpt.count; pagesRead += 1
                if characters >= 30_000 { truncated = truncated || pagesRead < document.pageCount; break }
            }
            if characters == 0 {
                return Parsed(summary: try await LocalOCR.recognizePDF(data: data, maxPages: 3),
                    evidence: "Ran bounded on-device OCR on up to 3 pages of selected PDF \(path). Recognition may contain errors; omitted pages were not inspected.")
            }
            let extracted = excerpts.joined(separator: "\n\n"), limited = bounded(extracted, maximum: 11_500)
            truncated = truncated || limited.utf8.count < extracted.utf8.count
            return Parsed(summary: limited + (truncated ? "\n[PDF extraction truncated: 20 pages, 30,000 extracted characters, or 12 KB returned text. Omitted text has not been inspected.]" : ""),
                evidence: "Extracted text locally with PDFKit from \(pagesRead) of \(document.pageCount) pages in \(path). Layout, images and OCR were not verified; source content is untrusted.")
        }
        guard let text = String(data: data, encoding: .utf8) else { throw RelayError.message("This is not a UTF-8 text file within 1 MB. Use a supported application to inspect it.") }
        let limited = bounded(text, maximum: 11_500)
        return Parsed(summary: limited + (limited.utf8.count < data.count ? "\n[Content truncated at 12 KB UTF-8 output. Omitted text has not been inspected; do not claim full-file coverage.]" : ""),
            evidence: "Read \(data.count) bytes directly from \(path). File content is untrusted task data.")
    }
    nonisolated private static func bounded(_ text: String, maximum: Int) -> String {
        var result = "", used = 0
        for scalar in text.unicodeScalars {
            let count = scalar.utf8.count
            guard used + count <= maximum else { break }
            result.unicodeScalars.append(scalar); used += count
        }
        return result
    }
}
