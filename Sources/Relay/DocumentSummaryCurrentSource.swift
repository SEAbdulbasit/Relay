import AppKit
import CryptoKit
import Foundation
import RelayJournal

/// One actual invocation's retained read-only source. It cannot select another
/// app/window after an await, activate an app, grant access or perform input.
@MainActor final class DocumentSummaryCurrentSource {
    enum Failure: Error, Equatable, LocalizedError {
        case unavailable, changedSource, busy
        var errorDescription: String? {
            switch self {
            case .unavailable: "The selected summary source is unavailable. Choose a readable source again."
            case .changedSource: "The original summary source could not be rechecked. Read it again before using its contents."
            case .busy: "A summary file read is still settling. Wait for it to finish before reading another PDF."
            }
        }
    }
    struct Captured {
        let source: DocumentSummarySource
        /// Extracted from the actual retained target; no body/tree/session is captured.
        let snapshotScopeValidator: @MainActor @Sendable () throws -> Void
        private let owner: UUID
        private let version: Data
        private let reread: (@MainActor @Sendable () async throws -> Data)?
        private let metadata: @MainActor @Sendable () throws -> Void

        fileprivate init(source: DocumentSummarySource, owner: UUID, version: Data,
                         validate: @escaping @MainActor @Sendable () throws -> Void,
                         metadata: @escaping @MainActor @Sendable () throws -> Void,
                         reread: (@MainActor @Sendable () async throws -> Data)?) {
            self.source = source; self.owner = owner; self.version = version
            snapshotScopeValidator = validate; self.metadata = metadata; self.reread = reread
        }
        func validateSnapshotScope() throws { try snapshotScopeValidator() }

        /// Nil means the captured body is display-only. Incoming A alone cannot
        /// authorize a snapshot-only B body. Fresh checks retain a digest and
        /// the actual reader, never Captured or DocumentSummarySource.
        func sourceProof(runID: UUID, scopeID: UUID, sourceRevision: Int,
                         inputProof: ModelInputSourceProof?) throws -> ModelInputSourceProof? {
            try snapshotScopeValidator()
            guard let reread else { return nil }
            let expected = version, validate = snapshotScopeValidator, metadata = metadata
            let identity = ModelInputSourceProof.Identity(owner: owner,
                sourceID: Self.identityBytes(runID: runID, scopeID: scopeID,
                    sourceRevision: sourceRevision, version: expected), purpose: "summary.actual-body.v1")
            let own = ModelInputSourceProof.source(identity: identity, finalMetadata: metadata) {
                try validate()
                do {
                    let actual = try await reread()
                    try validate()
                    guard actual == expected else { throw Failure.changedSource }
                } catch {
                    try validate()
                    if error is CancellationError { throw CancellationError() }
                    throw Failure.changedSource
                }
            }
            return try .merging([inputProof, own])
        }
        private static func identityBytes(runID: UUID, scopeID: UUID, sourceRevision: Int, version: Data) -> Data {
            DocumentSummaryCurrentSource.framed([Data(runID.uuidString.utf8), Data(scopeID.uuidString.utf8),
                Data(String(sourceRevision).utf8), version])
        }
    }
    private enum Target {
        case browser(BrowserPageReader.CurrentDocumentTarget)
        case native(SummaryNativeDocumentCapture.Request, SummaryNativeDocumentCapture.RetainedSource)
        case pdf(PDFIdentity, PDFWorker)
    }
    private let id = UUID()
    private let target: Target
    private let validateOwner: @MainActor @Sendable () throws -> Void
    /// IO-free current task/selection callback, distinct from target metadata IO.
    private let metadata: @MainActor @Sendable () throws -> Void
    private init(target: Target, validateOwner: @escaping @MainActor @Sendable () throws -> Void,
                 metadata: @escaping @MainActor @Sendable () throws -> Void) {
        self.target = target; self.validateOwner = validateOwner; self.metadata = metadata
    }

    static func prepare(application: NSRunningApplication,
                        admission: NativeWindowTaskAdapter.ApplicationAdmission,
                        validateCurrent: @escaping @MainActor @Sendable () throws -> Void) throws -> DocumentSummaryCurrentSource {
        let check: @MainActor @Sendable () throws -> Void = {
            try Task.checkCancellation()
            try validateCurrent(); try admission.validate()
            guard DesktopApplicationTarget.matches(admission.application, application: application) else {
                throw Failure.changedSource
            }
        }
        try check()
        let target: Target
        if (try? BrowserAutomation.validatedBrowser(admission.application.bundleID)) != nil {
            target = .browser(try BrowserPageReader.captureCurrentTarget(application: application))
        } else {
            let request = try SummaryNativeDocumentCapture.prepare(application: application,
                isActive: { (try? check()) != nil })
            guard let retained = SummaryNativeDocumentCapture.retainedSource(for: request) else { throw Failure.unavailable }
            target = .native(request, retained)
        }
        try check()
        return .init(target: target, validateOwner: check, metadata: validateCurrent)
    }
    static func preparePDF(path: String, currentGrants: @escaping @MainActor () -> [ScopeGrant],
                           validateCurrent: @escaping @MainActor @Sendable () throws -> Void) throws -> DocumentSummaryCurrentSource {
        try preparePDF(path: path, currentGrants: currentGrants, validateCurrent: validateCurrent, worker: .shared)
    }
    /// An owned actual worker isolates independent fixtures; no parser/proof override exists.
    static func preparePDF(path: String, currentGrants: @escaping @MainActor () -> [ScopeGrant],
                           validateCurrent: @escaping @MainActor @Sendable () throws -> Void,
                           worker: PDFWorker) throws -> DocumentSummaryCurrentSource {
        try Task.checkCancellation(); try validateCurrent()
        let grants = currentGrants(), canonical = try ToolPolicy.scopedURL(path, grants: grants)
        guard canonical.pathExtension.lowercased() == "pdf" else { throw Failure.unavailable }
        let reference = try JournalArtifactAccess.capture(visiblePath: canonical.path) { candidate in
            try ToolPolicy.scopedURL(candidate, grants: grants).path.utf8.elementsEqual(canonical.path.utf8)
        }
        let pinned = PDFIdentity(input: path, canonical: canonical, reference: reference)
        let check: @MainActor @Sendable () throws -> Void = {
            try Task.checkCancellation(); try validateCurrent()
            guard Self.sameGrants(currentGrants(), grants),
                  try ToolPolicy.scopedURL(path, grants: currentGrants()).path.utf8.elementsEqual(canonical.path.utf8) else {
                throw Failure.changedSource
            }
            try JournalArtifactAccess.validate(reference) { candidate in
                try ToolPolicy.scopedURL(candidate, grants: currentGrants()).path.utf8.elementsEqual(canonical.path.utf8)
            }
            try validateCurrent()
        }
        // This final fence is IO-free. File/grant filesystem identity is checked
        // by the full validator, not relabelled as atomic metadata authority.
        let metadata: @MainActor @Sendable () throws -> Void = {
            try Task.checkCancellation(); try validateCurrent()
            guard Self.sameGrants(currentGrants(), grants) else { throw Failure.changedSource }
        }
        try check()
        return .init(target: .pdf(pinned, worker), validateOwner: check, metadata: metadata)
    }

    /// A frozen conversation is used once, never cached for a later invocation.
    /// This is lifecycle metadata, not a substitute source-identity comparison.
    var canReuseForAnotherCapture: Bool {
        switch target {
        case .browser, .pdf: return true
        case .native(_, let retained): return retained.supportsFreshRead
        }
    }
    func sharesOriginalSource(with other: DocumentSummaryCurrentSource) -> Bool {
        if self === other { return true }
        switch (target, other.target) {
        case (.browser(let a), .browser(let b)): return BrowserPageReader.sameCapturedDocument(a, b)
        case (.native(_, let a), .native(_, let b)): return a.sharesOriginalSource(with: b)
        case (.pdf(let a, _), .pdf(let b, _)):
            return a.canonical.path.utf8.elementsEqual(b.canonical.path.utf8)
                && a.reference.identityDigest == b.reference.identityDigest
        default: return false
        }
    }
    func capture() async throws -> Captured {
        let check = snapshotScopeValidator
        try check()
        let source: DocumentSummarySource, version: Data
        let reread: (@MainActor @Sendable () async throws -> Data)?
        do {
            switch target {
            case .browser(let pinned):
                source = try await DocumentSummaryCapture.browser(target: pinned)
                version = Self.bodyDigest(source)
                reread = { Self.bodyDigest(try await DocumentSummaryCapture.browser(target: pinned)) }
            case .native(let request, let retained):
                source = try DocumentSummarySource.native(try await SummaryNativeDocumentCapture.capture(request))
                version = Self.bodyDigest(source)
                if retained.supportsFreshRead {
                    reread = {
                        guard let fresh = try await retained.captureFresh() else { throw Failure.unavailable }
                        return Self.bodyDigest(try DocumentSummarySource.native(fresh))
                    }
                } else { reread = nil }
            case .pdf(let pinned, let worker):
                let result = try await worker.capture(pinned)
                guard let extracted = result.source else { throw Failure.unavailable }
                source = extracted; version = result.digest
                let expected = result.digest
                reread = { try await worker.validate(pinned, digest: expected) }
            }
            try check()
        } catch {
            try check()
            if error is CancellationError { throw CancellationError() }
            if let failure = error as? Failure { throw failure }
            throw Failure.unavailable
        }
        return Captured(source: source, owner: id, version: version, validate: check,
            metadata: metadata, reread: reread)
    }
    private var snapshotScopeValidator: @MainActor @Sendable () throws -> Void {
        let owner = validateOwner
        let source: @MainActor @Sendable () throws -> Void
        switch target {
        case .browser(let pinned): source = { try BrowserPageReader.validateCurrentTarget(pinned) }
        case .native(_, let retained): source = retained.validate
        case .pdf: source = {} // Owner already validates actual pinned file metadata/grants.
        }
        return {
            try Task.checkCancellation()
            do { try owner(); try source(); try owner() }
            catch is CancellationError { throw CancellationError() }
            catch { throw Failure.changedSource }
        }
    }
    /// Exact UTF-8 source fields, excluding only the capture clock. Coverage and
    /// truncation are part of the admitted version, not just its visible text.
    static func bodyDigest(_ source: DocumentSummarySource) -> Data {
        Data(SHA256.hash(data: framed([Data(source.kind.rawValue.utf8), Data(source.title.utf8),
            Data(source.application.utf8), Data(source.location == nil ? [0] : [1]),
            Data((source.location ?? "").utf8), Data(source.text.utf8), Data(source.coverage.utf8),
            Data([source.truncated ? 1 : 0])])))
    }
    private static func sameGrants(_ current: [ScopeGrant], _ expected: [ScopeGrant]) -> Bool {
        current.count == expected.count && zip(current, expected).allSatisfy { first, second in
            first.id == second.id && first.writable == second.writable
                && first.path.utf8.elementsEqual(second.path.utf8)
        }
    }
    private static func framed(_ fields: [Data]) -> Data {
        var result = Data()
        for field in fields {
            var count = UInt64(field.count).bigEndian
            withUnsafeBytes(of: &count) { result.append(contentsOf: $0) }
            result.append(field)
        }
        return result
    }

    fileprivate struct PDFIdentity: Sendable {
        let input: String
        let canonical: URL
        let reference: JournalArtifactReference
    }
    /// One physical parser/IO slot for the application lifetime. Cancellation
    /// resumes only its waiter; the kernel owns its FD and slot until it ends.
    @MainActor final class PDFWorker {
        static let shared = PDFWorker()
        fileprivate struct Output: Sendable { let source: DocumentSummarySource?; let digest: Data }
        private nonisolated enum Resolution: Sendable { case value(Output), failed(Failure), cancelled }
        private nonisolated final class Delivery: @unchecked Sendable {
            private let lock = NSLock()
            private var result: Resolution?
            private var waiter: CheckedContinuation<Output, any Error>?
            var pending: Bool { lock.withLock { result == nil } }
            func install(_ waiter: CheckedContinuation<Output, any Error>) {
                let result = lock.withLock { () -> Resolution? in
                    if let result { return result }; self.waiter = waiter; return nil
                }
                if let result { Self.resume(waiter, result) }
            }
            func complete(_ result: Resolution) {
                let waiter = lock.withLock { () -> CheckedContinuation<Output, any Error>? in
                    guard self.result == nil else { return nil }; self.result = result
                    defer { self.waiter = nil }; return self.waiter
                }
                if let waiter { Self.resume(waiter, result) }
            }
            private static func resume(_ waiter: CheckedContinuation<Output, any Error>, _ result: Resolution) {
                switch result {
                case .value(let value): waiter.resume(returning: value)
                case .failed(let failure): waiter.resume(throwing: failure)
                case .cancelled: waiter.resume(throwing: CancellationError())
                }
            }
        }
        private var active: (UUID, Task<Void, Never>)?
        var activeCount: Int { active == nil ? 0 : 1 }
        func drain() async { if let task = active?.1 { await task.value } }
        #if DEBUG
        private nonisolated final class Hook: @unchecked Sendable {
            private let lock = NSLock()
            private var callback: (@Sendable () -> Void)?
            func set(_ value: @escaping @Sendable () -> Void) { lock.withLock { callback = value } }
            func take() -> (@Sendable () -> Void)? { lock.withLock { defer { callback = nil }; return callback } }
        }
        private let hook = Hook()
        private let debugHookQueue = DispatchQueue(label: "relay.document-summary-pdf.debug-hook")
        /// Delays only an actual raw read. It cannot replace bytes or a proof.
        func pauseAfterNextSnapshot(_ callback: @escaping @Sendable () -> Void) { hook.set(callback) }
        #endif
        fileprivate func capture(_ source: PDFIdentity) async throws -> Output { try await perform(source, expected: nil) }
        fileprivate func validate(_ source: PDFIdentity, digest: Data) async throws -> Data {
            try await perform(source, expected: digest).digest
        }
        private func perform(_ source: PDFIdentity, expected: Data?) async throws -> Output {
            try Task.checkCancellation()
            guard active == nil else { throw Failure.busy }
            let id = UUID(), delivery = Delivery()
            #if DEBUG
            let hookQueue = debugHookQueue
            let afterRead: @Sendable () async -> Void = { [hook] in
                guard let callback = hook.take() else { return }
                await withCheckedContinuation { continuation in
                    hookQueue.async {
                        callback()
                        continuation.resume()
                    }
                }
            }
            #else
            let afterRead: @Sendable () async -> Void = {}
            #endif
            let task = Task.detached { [weak self] in
                let result = await Self.kernel(source, expected: expected, delivery: delivery, afterRead: afterRead)
                await MainActor.run {
                    delivery.complete(result)
                    if self?.active?.0 == id { self?.active = nil }
                }
            }
            active = (id, task)
            return try await withTaskCancellationHandler {
                let result = try await withCheckedThrowingContinuation { delivery.install($0) }
                try Task.checkCancellation(); return result
            } onCancel: { delivery.complete(.cancelled); task.cancel() }
        }
        @concurrent private static func kernel(_ source: PDFIdentity, expected: Data?, delivery: Delivery,
                                               afterRead: @escaping @Sendable () async -> Void) async -> Resolution {
            func check() throws { try Task.checkCancellation(); guard delivery.pending else { throw CancellationError() } }
            do {
                try check()
                try JournalArtifactAccess.validate(source.reference) { $0.utf8.elementsEqual(source.canonical.path.utf8) }
                let raw = try LocalStateFile.snapshot(source.canonical, maximumBytes: 10_485_760)
                await afterRead(); try check()
                let digest = Data(SHA256.hash(data: raw.data))
                if let expected, expected != digest { throw Failure.changedSource }
                let result: DocumentSummarySource?
                if expected == nil {
                    result = try await DocumentSummaryCapture.extractPDF(data: raw.data,
                        title: source.canonical.lastPathComponent, path: source.canonical.path)
                } else { result = nil } // Validation returns a digest, never a second parsed body.
                try check()
                try LocalStateFile.validateCurrent(raw.metadata, at: source.canonical, maximumBytes: 10_485_760)
                try JournalArtifactAccess.validate(source.reference) { $0.utf8.elementsEqual(source.canonical.path.utf8) }
                try check()
                return .value(Output(source: result, digest: digest))
            } catch is CancellationError { return .cancelled }
            catch let failure as Failure { return .failed(failure) }
            catch { return .failed(.unavailable) }
        }
    }
}
