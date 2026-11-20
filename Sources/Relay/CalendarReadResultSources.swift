import Foundation

/// Saved object capabilities only. Body/digest lookup, restored results and
/// another read type's token cannot create calendar admission.
@MainActor final class CalendarReadResultSources {
    private struct Entry {
        let receipt: CalendarReadReceipt
        let settlement: AssistantConversationHistory.CalendarReadSettlement
        let context: MultiAgentContinuation.Context
        let proof: ModelInputSourceProof
    }
    private var epoch = UUID(), entries: [ObjectIdentifier: Entry] = [:], order: [ObjectIdentifier] = []
    private let capacity: Int
    var retainedCount: Int { entries.count }
    init(capacity: Int = 32) { self.capacity = min(32, max(1, capacity)) }
    func reset() { epoch = UUID(); entries.removeAll(); order.removeAll() }
    @discardableResult func registerSettled(call: ToolCall, result: ToolResult,
        run: AssistantConversationHistory.Run, proposalID: UUID, context: MultiAgentContinuation.Context,
        settlement: AssistantConversationHistory.CalendarReadSettlement) throws -> ModelInputSourceProof {
        try Task.checkCancellation()
        guard let receipt = result.calendarReadReceipt,
              settlement.matches(call: call, result: result, run: run, proposalID: proposalID) else { throw CalendarReadFailure.unavailable }
        let key = ObjectIdentifier(receipt)
        if let prior = entries[key] {
            guard prior.receipt === receipt, prior.settlement === settlement, prior.context == context else { throw CalendarReadFailure.unavailable }
            return prior.proof
        }
        let proof = try receipt.consume(call: call, result: result, run: run, proposalID: proposalID,
            context: context, settlement: settlement)
        entries[key] = Entry(receipt: receipt, settlement: settlement, context: context, proof: proof)
        order.append(key)
        while order.count > capacity { entries.removeValue(forKey: order.removeFirst()) }
        return proof
    }
    /// Must follow the last awaited incoming-source check and precede first
    /// body publication. It cannot query the SDK or reconstruct a receipt.
    func validatePublication(call: ToolCall, result: ToolResult, run: AssistantConversationHistory.Run,
                             proposalID: UUID, context: MultiAgentContinuation.Context) throws {
        try Task.checkCancellation()
        guard let receipt = result.calendarReadReceipt, let entry = entries[ObjectIdentifier(receipt)],
              entry.receipt === receipt, entry.context == context,
              entry.settlement.matches(call: call, result: result, run: run, proposalID: proposalID) else { throw CalendarReadFailure.unavailable }
        try receipt.validateCurrent(call: call, result: result, run: run, proposalID: proposalID, context: context)
        try entry.proof.validateFinalMetadata()
    }
    func sourceProof(call: ToolCall, result: ToolResult, run: AssistantConversationHistory.Run,
                     proposalID: UUID, context: MultiAgentContinuation.Context) async throws -> ModelInputSourceProof {
        try Task.checkCancellation()
        guard let receipt = result.calendarReadReceipt else { throw CalendarReadFailure.unavailable }
        let key = ObjectIdentifier(receipt), expected = epoch
        guard let entry = entries[key], entry.receipt === receipt, entry.context == context,
              entry.settlement.matches(call: call, result: result, run: run, proposalID: proposalID) else { throw CalendarReadFailure.unavailable }
        try await entry.proof.validate(); try Task.checkCancellation()
        guard epoch == expected, let retained = entries[key], retained.receipt === receipt,
              retained.settlement === entry.settlement, retained.context == context else { throw CalendarReadFailure.unavailable }
        return entry.proof
    }
}
