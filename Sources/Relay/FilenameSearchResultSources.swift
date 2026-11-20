import Foundation

/// Only actual receipt OBJECTS and actual successful History tokens register.
/// Namespace/result digests check binding; they cannot create source authority.
@MainActor final class FilenameSearchResultSources {
    private struct Entry {
        let receipt: FilenameSearchReceipt
        let settlement: AssistantConversationHistory.FilenameSearchSettlement
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
        settlement: AssistantConversationHistory.FilenameSearchSettlement) throws -> ModelInputSourceProof {
        try Task.checkCancellation()
        guard let receipt = result.filenameSearchReceipt,
              settlement.matches(call: call, result: result, run: run, proposalID: proposalID) else {
            throw FilenameSearchWorker.Failure.unavailable
        }
        let key = ObjectIdentifier(receipt)
        if let prior = entries[key] {
            guard prior.receipt === receipt, prior.settlement === settlement, prior.context == context else {
                throw FilenameSearchWorker.Failure.unavailable
            }
            return prior.proof
        }
        let proof = try receipt.consume(call: call, result: result, run: run, proposalID: proposalID,
            context: context, settlement: settlement)
        entries[key] = Entry(receipt: receipt, settlement: settlement, context: context, proof: proof)
        order.append(key)
        while order.count > capacity { entries.removeValue(forKey: order.removeFirst()) }
        return proof
    }
    func sourceProof(call: ToolCall, result: ToolResult, run: AssistantConversationHistory.Run,
                     proposalID: UUID, context: MultiAgentContinuation.Context) async throws -> ModelInputSourceProof {
        try Task.checkCancellation()
        guard let receipt = result.filenameSearchReceipt else { throw FilenameSearchWorker.Failure.unavailable }
        let key = ObjectIdentifier(receipt), expected = epoch
        guard let entry = entries[key], entry.receipt === receipt, entry.context == context,
              entry.settlement.matches(call: call, result: result, run: run, proposalID: proposalID) else {
            throw FilenameSearchWorker.Failure.unavailable
        }
        try await entry.proof.validate(); try Task.checkCancellation()
        guard epoch == expected, let retained = entries[key], retained.receipt === receipt,
              retained.settlement === entry.settlement, retained.context == context else {
            throw FilenameSearchWorker.Failure.unavailable
        }
        return entry.proof
    }
}
