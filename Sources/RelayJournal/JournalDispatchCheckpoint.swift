import Foundation

/// Durability adapter only. The existing action controller must still validate its own admission.
@MainActor public final class JournalDispatchCheckpoint {
    private let journal: ConversationJournal
    private var revision = 0
    private var active = true
    private var pending: [UUID: (JournalEvent, JournalScope)] = [:]
    private var inFlight = false
    public init(journal: ConversationJournal) { self.journal = journal }
    public func stop() { active = false; revision += 1 }
    public var pendingResultCount: Int { pending.count }
    public func execute(_ event: JournalEvent, expectedScope: JournalScope,
                        validate: @MainActor () throws -> Void,
                        admitAction: (@MainActor @Sendable () async throws -> Void)? = nil,
                        action: @MainActor () async throws -> JournalToolOutcome) async throws -> JournalRecord {
        guard case let .intent(intent) = event.payload else { throw JournalError.invalidEvent }
        guard active else { throw JournalError.dispatchRevoked }
        guard pending.isEmpty, !inFlight else { throw JournalError.pendingResult }
        inFlight = true; defer { inFlight = false }
        let expectedRevision = revision
        try Task.checkCancellation(); try validate()
        let committed = try await journal.commitIntent(event, expectedScope: expectedScope)
        guard case .inserted = committed else { throw JournalError.duplicateIntent }
        do {
            try Task.checkCancellation(); guard active, revision == expectedRevision else { throw JournalError.dispatchRevoked }; try validate()
            if let admitAction {
                // The immutable source proof belongs to this accepted reply.
                // Its await cannot bypass Stop or the exact current task guard.
                try await admitAction()
                try Task.checkCancellation(); guard active, revision == expectedRevision else { throw JournalError.dispatchRevoked }; try validate()
            }
        } catch {
            let result = try resultEvent(event, outcome: JournalToolOutcome(intent: intent, kind: .notDispatched))
            pending[intent.invocationID] = (result, expectedScope)
            _ = try await savePendingResult(invocationID: intent.invocationID)
            throw error
        }
        // The durable call identity is unique across settled and pending results. No
        // reusable ticket escapes this method, so no growing in-memory ID ledger is needed.
        let outcome: JournalToolOutcome
        do { outcome = try await action() }
        catch { outcome = JournalToolOutcome(intent: intent, kind: .effectUncertain) }
        guard outcome.invocationID == intent.invocationID, outcome.callDigest == intent.callDigest else {
            let uncertain = JournalToolOutcome(intent: intent, kind: .effectUncertain)
            pending[intent.invocationID] = (try resultEvent(event, outcome: uncertain), expectedScope)
            _ = try await savePendingResult(invocationID: intent.invocationID)
            throw JournalError.invalidEvent
        }
        pending[intent.invocationID] = (try resultEvent(event, outcome: outcome), expectedScope)
        return try await savePendingResult(invocationID: intent.invocationID)
    }
    private func resultEvent(_ intent: JournalEvent, outcome: JournalToolOutcome) throws -> JournalEvent {
        let milliseconds = Date().timeIntervalSince1970 * 1000
        guard milliseconds.isFinite, milliseconds >= Double(Int64.min), milliseconds < Double(Int64.max) else { throw JournalError.invalidEvent }
        return JournalEvent(id: try JournalOpaqueID("result:" + outcome.invocationID.uuidString), taskID: intent.taskID, attemptID: intent.attemptID, createdAtMilliseconds: Int64(milliseconds), payload: .result(outcome))
    }
    /// Storage-only retry: no action/validation closure is retained or accepted here.
    @discardableResult public func savePendingResult(invocationID: UUID) async throws -> JournalRecord {
        guard let (event, scope) = pending[invocationID] else { throw JournalError.invalidEvent }
        let record = try await journal.commitResult(event, expectedScope: scope).record
        pending.removeValue(forKey: invocationID)
        return record
    }
}
