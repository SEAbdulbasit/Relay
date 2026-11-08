import Foundation

/// Concrete ordinary-step loop. No static fixture/app allowlist, raw native
/// catalog, hidden keyboard fallback, automatic mutation retry or turn cap.
/// Store supplies the acknowledged scope, journal and one accepted-reply mint.
@MainActor final class NativeWindowControlTaskLoop {
    typealias AcceptReply = @MainActor (NativeWindowControlPlanningPhase.Operation) throws -> NativeVisualProposalIdentity
    private let owner: NativeComputerTaskSession
    private let journal: NativeVisualTaskJournal
    private let complete: NativeWindowControlPlanningPhase.Complete
    private let completeBound: NativeWindowControlPlanningPhase.BoundComplete?
    private let acceptReply: AcceptReply
    private let planningAdmission: NativeVisualPlanningAdmission

    init(owner: NativeComputerTaskSession, journal: NativeVisualTaskJournal,
         complete: @escaping NativeWindowControlPlanningPhase.Complete, acceptReply: @escaping AcceptReply,
         planningAdmission: NativeVisualPlanningAdmission,
         completeBound: NativeWindowControlPlanningPhase.BoundComplete? = nil) {
        self.owner = owner; self.journal = journal; self.complete = complete; self.acceptReply = acceptReply
        self.planningAdmission = planningAdmission; self.completeBound = completeBound
    }

    func control(_ outer: NativeVisualProposalIdentity) async throws -> ToolResult {
        try await controlWithSource(outer).result
    }

    func controlWithSource(_ outer: NativeVisualProposalIdentity, inputProof: ModelInputSourceProof? = nil) async throws -> NativeSourcedToolResult {
        let scope = owner.scope
        try outer.validate(scope: scope, call: outer.call)
        let request = try NativeWindowControlTools.requestedStep(outer.call)
        // Admission precedes connection/capture; the selector is never authority.
        let admission = try scope.admitRead(request.bundleID)
        var sourceFence: @MainActor () throws -> Void = {}
        return try await owner.withOperation(validateSource: { try sourceFence() }) { [self] connection in
            defer { owner.policy.retire() }
            var anchor = outer
            var retained: NativeVisualTaskSource?
            var round: UInt64 = 0
            while true {
                try scope.validate(); try planningAdmission.validate()
                let previous = retained
                try planningAdmission.admit(.init(ordinal: round, previousSourceID: previous?.sourceID,
                    previousObservationID: previous?.observation.snapshot.id))
                let next = round.addingReportingOverflow(1)
                guard !next.overflow else { throw NativeVisualTaskFailure.staleTask }
                round = next.partialValue
                let prepared = try await journal.prepare(anchor: anchor, actualOriginalRead: previous != nil, inputProof: inputProof) { [self] in
                    try planningAdmission.validate()
                    let readSource: NativeVisualTaskSource
                    if let previous {
                        try previous.validateOriginalSource()
                        readSource = try await connection.refreshOriginal(previous)
                    } else {
                        try admission.validate()
                        readSource = try await connection.observeRead(admission)
                    }
                    try scope.validate(); try planningAdmission.validate(); try readSource.validateOriginalSource()
                    let source = try await connection.refreshForInputPlanning(readSource)
                    guard source.sourceID == readSource.sourceID,
                          source.observation.snapshot.application == readSource.observation.snapshot.application,
                          source.observation.snapshot.window.matchesExactly(readSource.observation.snapshot.window) else {
                        throw NativeVisualTaskFailure.staleProposal
                    }
                    sourceFence = source.validateOriginalSource
                    try scope.validate(); try planningAdmission.validate(); try source.validateOriginalSource()
                    try source.validatePlanningObservation()
                    let operation = try await NativeWindowControlPlanningPhase.plan(taskID: scope.logicalTaskID,
                        runRevision: scope.runRevision, originalObjective: scope.originalObjective,
                        requestedStep: request.instruction, observation: source.observation, session: connection.controller,
                        taskIsCurrent: { [self] in do { try scope.validate(); try planningAdmission.validate(); return true } catch { return false } },
                        inputProof: inputProof, completeBound: completeBound, complete: complete)
                    try scope.validate(); try source.validateOriginalSource()
                    // This synchronous callback mints once only after a current,
                    // finite accepted reply. It is not rerun by a storage retry.
                    let identity = try acceptReply(operation)
                    try identity.validate(scope: scope, call: operation.call)
                    switch operation.proposal {
                    case .observeOriginal, .report:
                        return NativeVisualPreparedStep(source: source, operation: operation, identity: identity,
                            preparedAction: nil)
                    case .input(let action, _):
                        try owner.policy.begin(.init(scope: scope, identity: identity, operation: operation, sourceID: source.sourceID,
                            validateOriginalSource: source.validateOriginalSource))
                        let frame: NativeVisionFrame? = operation.frame
                        // Source-only preparation/review. The required positive
                        // adapter must defer every focus/input effect to execute.
                        let ticket = try await connection.prepareForReview(action, identity, source, frame)
                        try scope.validate(); try source.validateOriginalSource()
                        return NativeVisualPreparedStep(source: source, operation: operation, identity: identity,
                            preparedAction: ticket)
                    }
                }
                switch prepared.operation.proposal {
                case .observeOriginal:
                    anchor = prepared.identity; retained = prepared.source
                    // An explicit model read gets a new accepted namespace and
                    // refreshes only this retained source. No gesture is replayed.
                    continue
                case .report(let report):
                    // Preparation/read has already settled. This callback has
                    // no policy, focus, controller-input or native effect path.
                    let validateReport: @MainActor () throws -> Void = { [self] in
                        try scope.validate(); try planningAdmission.validate()
                        try prepared.source.validateOriginalSource(); try prepared.source.validatePlanningObservation()
                        try connection.controller.validatePlanningObservation(prepared.operation.observation)
                    }
                    sourceFence = validateReport
                    let result = try await journal.report(identity: prepared.identity, report: report,
                        observationID: prepared.operation.observation.snapshot.id, imageID: prepared.operation.frame.id,
                        inputProof: prepared.operation.inputProof, validateCurrent: validateReport)
                    return NativeSourcedToolResult(result: result, source: Self.readbackSource(prepared.source, scope: scope))
                case .input:
                    guard let ticket = prepared.preparedAction else { throw NativeVisualTaskFailure.staleProposal }
                    let fact = try await journal.effect(identity: prepared.identity, inputProof: prepared.operation.inputProof) {
                        // The controller's admitted execute calls the retained
                        // request's shared one-attempt callback exactly once.
                        // Do not perform a post-effect scope check here. A late
                        // actual/partial outcome belongs in this original run's
                        // checkpoint before owner fencing returns cancellation.
                        return await connection.executeAdmitted(ticket)
                    }
                    return NativeSourcedToolResult(result: fact.toolResult, source: Self.readbackSource(prepared.source, scope: scope))
                }
            }
        }
    }
    private static func readbackSource(_ source: NativeVisualTaskSource, scope: NativeVisualTaskScope) -> NativeCurrentReadbackSource {
        let validateOriginal = source.validateOriginalSource
        return NativeCurrentReadbackSource(sourceID: source.sourceID,
            application: source.observation.snapshot.application, validateOriginalSource: {
                try scope.validate(); try validateOriginal(); try scope.validate()
            })
    }

}
