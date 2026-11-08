import Foundation

/// Process-only distribution of actual, settled file-result source proofs.
/// The receipt OBJECT is the key. Digests only check its exact namespace; a
/// body/path/history/hash lookup can never register or recover an entry.
@MainActor final class FileReadResultSources {
    private struct Entry {
        let receipt: FileExtractionReceipt
        let settlement: AssistantConversationHistory.FileReadSettlement
        let context: MultiAgentContinuation.Context
        let proof: ModelInputSourceProof
    }
    private var epoch = UUID()
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var order: [ObjectIdentifier] = []
    private let capacity: Int
    var retainedCount: Int { entries.count }
    init(capacity: Int = 32) { self.capacity = min(32, max(1, capacity)) }
    func reset() { epoch = UUID(); entries.removeAll(); order.removeAll() }

    /// The token can only originate after History's real result-save return.
    /// Registering the same actual settlement is idempotent, never a second
    /// consume. An evicted receipt still contains its burned consume bit.
    @discardableResult
    func registerSettled(call: ToolCall, result: ToolResult, run: AssistantConversationHistory.Run,
                         proposalID: UUID, context: MultiAgentContinuation.Context,
                         settlement: AssistantConversationHistory.FileReadSettlement) throws -> ModelInputSourceProof {
        try Task.checkCancellation()
        guard let receipt = result.fileExtractionReceipt,
              settlement.matches(call: call, result: result, run: run, proposalID: proposalID) else {
            throw FileExtractionWorker.Failure.unavailable
        }
        let key = ObjectIdentifier(receipt)
        if let old = entries[key] {
            guard old.receipt === receipt, old.settlement === settlement, old.context == context else {
                throw FileExtractionWorker.Failure.unavailable
            }
            return old.proof
        }
        let proof = try receipt.consume(call: call, result: result, run: run, proposalID: proposalID, context: context)
        entries[key] = Entry(receipt: receipt, settlement: settlement, context: context, proof: proof)
        order.append(key)
        while order.count > capacity { entries.removeValue(forKey: order.removeFirst()) }
        return proof
    }

    /// Every inclusion validates the retained flat proof again. Retirement,
    /// eviction or Stop during its IO await also refuses the old projection.
    func sourceProof(call: ToolCall, result: ToolResult, run: AssistantConversationHistory.Run,
                     proposalID: UUID, context: MultiAgentContinuation.Context) async throws -> ModelInputSourceProof {
        try Task.checkCancellation()
        guard let receipt = result.fileExtractionReceipt else { throw FileExtractionWorker.Failure.unavailable }
        let key = ObjectIdentifier(receipt), expected = epoch
        guard let entry = entries[key], entry.receipt === receipt, entry.context == context,
              entry.settlement.matches(call: call, result: result, run: run, proposalID: proposalID) else {
            throw FileExtractionWorker.Failure.unavailable
        }
        try await entry.proof.validate()
        try Task.checkCancellation()
        guard epoch == expected, let retained = entries[key], retained.receipt === receipt,
              retained.settlement === entry.settlement, retained.context == context else {
            throw FileExtractionWorker.Failure.unavailable
        }
        return entry.proof
    }
}
