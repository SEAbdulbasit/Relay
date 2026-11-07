import Foundation

public struct JournalProjection: Sendable, Equatable {
    public private(set) var scope: JournalScope?
    public private(set) var lastSequence: Int64 = 0
    public private(set) var messages: [JournalEvent] = []
    public private(set) var taskOutcomes: [UUID: JournalTaskOutcome] = [:]
    private var applied: [Int64: Data] = [:]
    private var eventIDs: [JournalOpaqueID: Data] = [:]
    public init() {}
    /// A bounded projection, not an action queue or a substitute for paged history reads.
    public mutating func apply(_ records: [JournalRecord]) throws {
        // Reject atomically: a bad later record cannot leave a partly changed visible projection.
        var candidate = self
        for record in records { try candidate.applyOne(record) }
        self = candidate
    }
    private mutating func applyOne(_ record: JournalRecord) throws {
        if let scope { guard scope == record.scope else { throw JournalError.wrongGeneration } }
        else { scope = record.scope }
        guard record.sequence > 0, try journalDigest(journalEncoded(record.event)) == record.digest else { throw JournalError.corrupt }
        if let original = applied[record.sequence] {
            guard original == record.digest else { throw JournalError.conflictingID }; return
        }
        guard record.sequence > lastSequence, applied.count < 100_000, eventIDs[record.event.id] == nil else { throw JournalError.invalidTransition }
        applied[record.sequence] = record.digest; eventIDs[record.event.id] = record.digest; lastSequence = record.sequence
        switch record.event.payload {
        case .user, .assistant, .question, .answer: messages.append(record.event)
        case let .finished(outcome):
            guard taskOutcomes[record.event.taskID] == nil else { throw JournalError.invalidTransition }
            taskOutcomes[record.event.taskID] = outcome
        default: break
        }
    }
}
