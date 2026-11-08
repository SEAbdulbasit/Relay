import Foundation

/// One ordinary local task's read/control service. The shared qualified owner
/// supplies both phases; until that owner qualifies the existing read-only
/// implementation remains available and the action tool remains unadvertised.
@MainActor final class NativeComputerTaskService {
    let reader: NativeWindowReadService
    private let owner: NativeComputerTaskSession
    private let loop: NativeWindowControlTaskLoop
    private let scope: NativeVisualTaskScope
    private let readbacks: NativeCurrentReadbackReceipts

    init(scope: NativeVisualTaskScope, history: AssistantConversationHistory,
         factory: NativeVisualTaskConnectionFactory,
         inspect: @escaping NativeOrdinaryVisualPolicy.Inspect,
         review: @escaping NativeOrdinaryVisualPolicy.Review,
         complete: @escaping NativeWindowControlPlanningPhase.Complete,
         completeRead: @escaping NativeWindowReadService.Complete,
         fallbackReadBackend: @escaping NativeWindowReadService.MakeBackend,
         unsavedFact: @escaping @MainActor (ToolResult) -> Void,
         planningAdmission: NativeVisualPlanningAdmission,
         completeBound: NativeWindowControlPlanningPhase.BoundComplete? = nil) {
        self.scope = scope
        readbacks = NativeCurrentReadbackReceipts(scope: scope)
        let policy = NativeOrdinaryVisualPolicy(inspect: inspect, review: review)
        let owner = NativeComputerTaskSession(scope: scope, factory: factory, policy: policy)
        self.owner = owner
        let journal = NativeVisualTaskJournal(history: history, scope: scope, unsavedFact: unsavedFact)
        loop = NativeWindowControlTaskLoop(owner: owner, journal: journal, complete: complete, acceptReply: { operation in
            try scope.validate()
            // Exactly one mint for this accepted finite reply, after decoding and
            // source/provider checks. Storage retry never invokes this callback.
            return try NativeVisualProposalIdentity(scope: scope, acceptedReplyID: UUID(), call: operation.call)
        }, planningAdmission: planningAdmission, completeBound: completeBound)
        let ownership = NativeWindowTaskAdapter.Ownership(taskID: scope.logicalTaskID,
            isCurrent: { do { try scope.validate(); return true } catch { return false } },
            admitApplication: { try scope.admitRead($0) })
        reader = NativeWindowReadService(ownership: ownership, makeBackend: { ownership in
            if owner.readIsAvailable { return try await owner.makeReadBackend() }
            // This branch cannot coexist with an advertised control tool: all
            // control dependencies include the shared read/provenance proofs.
            guard !owner.controlIsAvailable else { throw NativeVisualTaskFailure.staleTask }
            return try await fallbackReadBackend(ownership)
        }, complete: completeRead)
    }

    var definitions: [ToolDefinition] {
        [NativeWindowReadTool.definition] + (owner.controlIsAvailable ? [NativeWindowControlTools.outerDefinition] : [])
    }
    var isBusy: Bool { reader.isBusy || owner.isBusy }
    var controlIsAvailable: Bool { owner.controlIsAvailable }

    /// Call this directly from the Store's accepted-proposal handler, rather
    /// than inside another history.perform. The loop owns sequential planning
    /// and physical-effect checkpoints and returns one outer protocol result.
    func control(_ call: ToolCall, acceptedProposalID: UUID, inputProof: ModelInputSourceProof? = nil) async throws -> ToolResult {
        try scope.validate()
        guard owner.controlIsAvailable else { throw NativeVisualTaskFailure.unavailableDependency("the qualified shared native task owner") }
        try ToolPolicy.validate(call, against: [NativeWindowControlTools.outerDefinition])
        let identity = try NativeVisualProposalIdentity(scope: scope, acceptedReplyID: acceptedProposalID, call: call)
        let returned = try await loop.controlWithSource(identity, inputProof: inputProof)
        try scope.validate()
        try readbacks.record(returned, call: call, acceptedProposalID: acceptedProposalID, inputProof: inputProof)
        return returned.result
    }

    func read(_ call: ToolCall, acceptedProposalID: UUID, objective: String, inputProof: ModelInputSourceProof? = nil) async throws -> ToolResult {
        try scope.validate()
        let returned = try await reader.readWithSource(call, objective: objective, inputProof: inputProof)
        try scope.validate()
        try readbacks.record(returned, call: call, acceptedProposalID: acceptedProposalID, inputProof: inputProof)
        return returned.result
    }

    /// Exact current result/source only. This neither consults historical
    /// receipts nor clears their sticky unsupported-source barrier.
    func admitReadback(_ call: ToolCall, acceptedProposalID: UUID, result: ToolResult) async throws -> @MainActor @Sendable () async throws -> Void {
        try scope.validate()
        let check = try readbacks.admission(call: call, acceptedProposalID: acceptedProposalID, result: result)
        try await check(); try scope.validate()
        return check
    }
    func admitReadbackSourceProof(_ call: ToolCall, acceptedProposalID: UUID, result: ToolResult) async throws -> ModelInputSourceProof {
        try scope.validate()
        let proof = try readbacks.sourceProof(call: call, acceptedProposalID: acceptedProposalID, result: result)
        try await proof.validate(); try scope.validate()
        return proof
    }
    func stop() { readbacks.stop(); owner.stop(); reader.stop() }
    func drain() async { await reader.drain(); await owner.drain() }
}
