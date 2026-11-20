import CryptoKit
import Foundation

/// Required live scope, minted by the accepted-proposal caller. This carries no
/// model text, restored authority, dispatch action or permissive default fence.
@MainActor struct FilenameSearchExecutionScope {
    fileprivate struct Namespace: Equatable {
        let run: UUID, attempt: UUID, proposal: UUID, provider: Data, callDigest: String
    }
    fileprivate struct Fence {
        let context: MultiAgentContinuation.Context, grantDigest: Data
        let currentContext: @MainActor @Sendable () -> MultiAgentContinuation.Context?
        let grants: @MainActor @Sendable () -> [ScopeGrant]
        let isCurrent: @MainActor @Sendable () -> Bool
        func check() throws {
            try Task.checkCancellation()
            let currentGrants = try? FilenameSearchTraversal.grantDigest(grants())
            guard isCurrent(), currentContext() == context,
                  currentGrants == grantDigest else { throw FilenameSearchWorker.Failure.unavailable }
        }
        var sourceScopeID: Data {
            get throws {
                let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
                return FilenameSearchTraversal.frame([Data(context.logicalTaskID.uuidString.utf8),
                    Data(context.scopeID.uuidString.utf8), Data(String(context.sourceRevision).utf8),
                    Data(SHA256.hash(data: try encoder.encode(context.configuration))), grantDigest])
            }
        }
    }
    fileprivate let namespace: Namespace, fence: Fence
    init(run: AssistantConversationHistory.Run, proposalID: UUID, call: ToolCall,
         context: MultiAgentContinuation.Context,
         currentContext: @escaping @MainActor @Sendable () -> MultiAgentContinuation.Context?,
         grants: @escaping @MainActor @Sendable () -> [ScopeGrant],
         isCurrent: @escaping @MainActor @Sendable () -> Bool) throws {
        guard call.name == "search_files", !call.id.isEmpty, call.id.utf8.count <= 4_096,
              run.relation.logicalTaskID == context.logicalTaskID else { throw FilenameSearchWorker.Failure.unavailable }
        try ToolPolicy.validate(call, against: MacTools.definitions)
        namespace = Namespace(run: run.taskID, attempt: run.attemptID, proposal: proposalID,
            provider: Data(call.id.utf8), callDigest: ToolPolicy.fingerprint(call))
        guard let grantDigest = try? FilenameSearchTraversal.grantDigest(grants()) else { throw FilenameSearchWorker.Failure.unavailable }
        fence = Fence(context: context, grantDigest: grantDigest,
            currentContext: currentContext, grants: grants, isCurrent: isCurrent)
        try check(call)
    }
    var executionContext: MultiAgentContinuation.Context { fence.context }
    func validateCurrent(call: ToolCall) throws { try check(call) }
    fileprivate func check(_ call: ToolCall) throws {
        try fence.check()
        guard call.name == "search_files", Data(call.id.utf8) == namespace.provider,
              ToolPolicy.fingerprint(call) == namespace.callDigest else { throw FilenameSearchWorker.Failure.unavailable }
    }
}

/// This file's actual producer is the only constructor. Validation is data-only:
/// it creates no flat proof or executable capability before durable settlement.
/// A separate saved-result token/distribution adapter is deliberately required.
@MainActor final class FilenameSearchReceipt {
    private let scope: FilenameSearchExecutionScope
    private let snapshot: FilenameSearchTraversal.Snapshot
    private let resultDigest: Data
    private let worker: FilenameSearchWorker
    private var consumed = false
    fileprivate init(scope: FilenameSearchExecutionScope, snapshot: FilenameSearchTraversal.Snapshot,
                     result: ToolResult, worker: FilenameSearchWorker) throws {
        try scope.fence.check()
        self.scope = scope; self.snapshot = snapshot; self.worker = worker
        resultDigest = Self.digest(result)
    }
    /// Stable within the logical task/query/actual scope; accepted proposal IDs
    /// do not create a growing source dependency for repeating the same query.
    var sourceIdentity: Data {
        get throws { Data(SHA256.hash(data: FilenameSearchTraversal.frame([try scope.fence.sourceScopeID, snapshot.sourceID]))) }
    }
    func validateProducedResult(call: ToolCall, result: ToolResult, run: AssistantConversationHistory.Run,
                                proposalID: UUID, context: MultiAgentContinuation.Context) async throws {
        try scope.check(call)
        guard result.filenameSearchReceipt === self, scope.namespace.run == run.taskID, scope.namespace.attempt == run.attemptID,
              scope.namespace.proposal == proposalID, context == scope.fence.context,
              Self.digest(result) == resultDigest else { throw FilenameSearchWorker.Failure.unavailable }
        do {
            try await worker.validate(snapshot, grants: scope.fence.grants())
            try scope.check(call)
        } catch {
            // No private filename/path/error text can escape after revocation,
            // including an error or timeout returned by the physical producer.
            try scope.check(call)
            if error is CancellationError { throw CancellationError() }
            throw FilenameSearchWorker.Failure.unavailable
        }
    }
    /// Only the exact actual saved search token may distribute this receipt.
    /// Eviction/reset never clears consumed; no history/body lookup can mint it.
    func consume(call: ToolCall, result: ToolResult, run: AssistantConversationHistory.Run,
                 proposalID: UUID, context: MultiAgentContinuation.Context,
                 settlement: AssistantConversationHistory.FilenameSearchSettlement) throws -> ModelInputSourceProof {
        try scope.check(call)
        guard !consumed, result.filenameSearchReceipt === self,
              settlement.matches(call: call, result: result, run: run, proposalID: proposalID),
              scope.namespace.run == run.taskID, scope.namespace.attempt == run.attemptID,
              scope.namespace.proposal == proposalID, context == scope.fence.context,
              Self.digest(result) == resultDigest else { throw FilenameSearchWorker.Failure.unavailable }
        consumed = true
        let fence = scope.fence, snapshot = snapshot, worker = worker
        let identity = ModelInputSourceProof.Identity(owner: scope.namespace.run,
            sourceID: try sourceIdentity, purpose: "relay.actual-filename-query.metadata.v1")
        return .source(identity: identity) {
            try fence.check()
            do {
                try await worker.validate(snapshot, grants: fence.grants())
                try fence.check()
            } catch {
                try fence.check()
                if error is CancellationError { throw CancellationError() }
                throw FilenameSearchWorker.Failure.unavailable
            }
        }
    }
    nonisolated static func digest(_ result: ToolResult) -> Data {
        Data(SHA256.hash(data: FilenameSearchTraversal.frame([Data("relay.filename-query.result.v1".utf8),
            Data(result.summary.utf8), Data(result.evidence.utf8), Data([result.verified ? 1 : 0]),
            Data([result.artifactPath == nil ? 0 : 1]), Data((result.artifactPath ?? "").utf8)])))
    }
}

/// Exactly one physical metadata traversal per worker. Cancellation/timeout can
/// release its waiter, never its still-running physical IO slot or descriptors.
@MainActor final class FilenameSearchWorker {
    static let shared = FilenameSearchWorker()
    struct ProducedResult { let result: ToolResult, receipt: FilenameSearchReceipt }
    nonisolated enum Failure: LocalizedError, Equatable {
        case busy, timedOut, unavailable
        var errorDescription: String? {
            switch self {
            case .busy: "A filename search is still settling. No additional traversal was queued."
            case .timedOut: "The bounded filename search timed out. Its late output will not be used."
            case .unavailable: "The filename query could not be rechecked for the current selected scope and task. Its result cannot be reused."
            }
        }
    }
    private nonisolated enum Resolution: Sendable {
        case value(FilenameSearchTraversal.Snapshot), failed(Failure), cancelled
    }
    private nonisolated final class Delivery: @unchecked Sendable {
        private let lock = NSLock()
        private var completed: Resolution?, continuation: CheckedContinuation<FilenameSearchTraversal.Snapshot, any Error>?
        private var kernelDone = false
        var pending: Bool { lock.withLock { completed == nil } }
        var isKernelDone: Bool { lock.withLock { kernelDone } }
        @discardableResult func completeFromKernel(_ result: Resolution) -> Bool {
            lock.withLock { kernelDone = true }
            return complete(result)
        }
        func install(_ continuation: CheckedContinuation<FilenameSearchTraversal.Snapshot, any Error>) {
            let result = lock.withLock { () -> Resolution? in
                if let completed { return completed }; self.continuation = continuation; return nil
            }
            if let result { Self.resume(continuation, result) }
        }
        @discardableResult func complete(_ result: Resolution) -> Bool {
            let delivery = lock.withLock { () -> (Bool, CheckedContinuation<FilenameSearchTraversal.Snapshot, any Error>?) in
                guard completed == nil else { return (false, nil) }
                completed = result; let old = continuation; continuation = nil; return (true, old)
            }
            if let old = delivery.1 { Self.resume(old, result) }; return delivery.0
        }
        private static func resume(_ waiter: CheckedContinuation<FilenameSearchTraversal.Snapshot, any Error>, _ result: Resolution) {
            switch result {
            case .value(let value): waiter.resume(returning: value)
            case .failed(let failure): waiter.resume(throwing: failure)
            case .cancelled: waiter.resume(throwing: CancellationError())
            }
        }
    }
    #if DEBUG
    private nonisolated static let processStart = ContinuousClock.now
    private nonisolated final class Hook: @unchecked Sendable {
        private let lock = NSLock(); private var value: (@Sendable () -> Void)?
        var hasCallback: Bool { lock.withLock { value != nil } }
        func set(_ value: @escaping @Sendable () -> Void) { lock.withLock { self.value = value } }
        func take() -> (@Sendable () -> Void)? { lock.withLock { let old = value; value = nil; return old } }
    }
    private let hook = Hook()
    /// May delay only completion of the real metadata attempt (including its
    /// typed failure); cannot replace data, errors or proof.
    func pauseAfterNextTraversal(_ value: @escaping @Sendable () -> Void) { hook.set(value) }
    #endif
    private struct Active { let id: UUID, physical: Task<Void, Never>, expiry: Task<Void, Never> }
    private var active: Active?
    private let timeout: Duration
    var activeCount: Int { active == nil ? 0 : 1 }
    init(timeout: Duration = .seconds(10)) { self.timeout = min(.seconds(10), max(.milliseconds(1), timeout)) }
    func drain() async { if let active { await active.physical.value } }

    func search(call: ToolCall, scope: FilenameSearchExecutionScope) async throws -> ProducedResult {
        try scope.check(call)
        guard let query = call.arguments["query"]?.string else { throw Failure.unavailable }
        do {
            let snapshot = try await capture(query: query, grants: scope.fence.grants())
            try scope.check(call)
            var result = Self.result(snapshot)
            let receipt = try FilenameSearchReceipt(scope: scope, snapshot: snapshot, result: result, worker: self)
            result.filenameSearchReceipt = receipt
            return ProducedResult(result: result, receipt: receipt)
        } catch {
            try scope.check(call)
            if error is CancellationError { throw CancellationError() }
            if let error = error as? Failure { throw error }
            throw Failure.unavailable
        }
    }
    /// Shared by ScopedFileOperations.search. No receipt is minted for callers
    /// lacking the required accepted-proposal/source fence.
    func capture(query: String, grants: [ScopeGrant]) async throws -> FilenameSearchTraversal.Snapshot {
        try Task.checkCancellation()
        guard active == nil else { throw Failure.busy }
        let id = UUID(), delivery = Delivery(), deadline = ContinuousClock.now.advanced(by: timeout)
        #if DEBUG
        let after: @Sendable () async -> Void = { [hook] in
            guard let callback = hook.take() else { return }
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInteractive).async {
                    callback()
                    continuation.resume()
                }
            }
        }
        #else
        let after: @Sendable () async -> Void = {}
        #endif
        let physical = Task.detached(priority: .userInitiated) { [weak self] in
            let result = await Self.kernel(query: query, grants: grants, deadline: deadline,
                delivery: delivery, after: after)
            if !delivery.completeFromKernel(result) {
                await self?.finished(id)
            }
        }
        let expiry = Task.detached(priority: .userInitiated) {
            do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            if delivery.complete(.failed(.timedOut)) { physical.cancel() }
        }
        active = Active(id: id, physical: physical, expiry: expiry)
        return try await withTaskCancellationHandler {
            defer {
                expiry.cancel()
                if delivery.isKernelDone { finished(id) }
            }
            let value = try await Self.awaitDelivery(delivery)
            try Task.checkCancellation()
            return value
        } onCancel: {
            delivery.complete(.cancelled)
            physical.cancel()
            expiry.cancel()
        }
    }
    @concurrent
    private static func awaitDelivery(_ delivery: Delivery) async throws -> FilenameSearchTraversal.Snapshot {
        try await withCheckedThrowingContinuation { continuation in
            delivery.install(continuation)
        }
    }
    fileprivate func validate(_ snapshot: FilenameSearchTraversal.Snapshot, grants: [ScopeGrant]) async throws {
        let current = try await capture(query: snapshot.query, grants: grants)
        guard current == snapshot else { throw Failure.unavailable }
    }
    private func finished(_ id: UUID) {
        guard let active, active.id == id else { return }
        active.expiry.cancel()
        self.active = nil
    }
    @concurrent private static func kernel(query: String, grants: [ScopeGrant], deadline: ContinuousClock.Instant,
                                           delivery: Delivery, after: @escaping @Sendable () async -> Void) async -> Resolution {
        let resolution: Resolution
        do {
            resolution = .value(try await FilenameSearchTraversal.capture(query: query, grants: grants,
                deadline: deadline, stillPending: { delivery.pending }))
        } catch is CancellationError { resolution = .cancelled }
        catch FilenameSearchTraversal.Failure.timedOut { resolution = .failed(.timedOut) }
        catch { resolution = .failed(.unavailable) }
        await after()
        return resolution
    }
    private static func result(_ value: FilenameSearchTraversal.Snapshot) -> ToolResult {
        let rows = value.matches.map { "\($0.path) [\($0.bytes) bytes]" }.joined(separator: "\n")
        return ToolResult(summary: rows.isEmpty ? "No filename matches returned in selected scope." : rows,
            evidence: "Enumerated \(value.visitedEntries) bounded entries; excluded \(value.skippedSymlinks) symlinks. "
                + (value.truncated ? "Search was bounded or incomplete; more matches may exist. Limits: " + value.limits.map(\.rawValue).joined(separator: ", ") + "." : "Within the qualified traversal limits.")
                + " Filename/size metadata only; file contents were not read.", verified: true)
    }
}
