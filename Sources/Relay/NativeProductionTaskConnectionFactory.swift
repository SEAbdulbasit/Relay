import AppKit
import Foundation

/// Source-only positive production adapter. This successor is not registered in
/// the active SDK. Its controller policyTarget binding and full factory/Store
/// tests still require qualification before any catalog or runtime cutover.
@MainActor final class NativeProductionTaskConnectionFactory {
    private let scope: NativeVisualTaskScope
    private let authority: NativeLocalTaskInputAuthority
    /// Finite trusted OS/client boundary. The default is the real signed native
    /// client and exact running-process resolver; tests inject only inert IO.
    struct Platform {
        struct Opened {
            let controller: NativeControlSession
            let close: @MainActor () async -> Void
        }
        let open: @MainActor (NativeOrdinaryVisualPolicy, @escaping @MainActor () -> Bool) async throws -> Opened
        let observeRead: @MainActor (NativeControlSession, NativeWindowTaskAdapter.ApplicationAdmission) async throws -> NativeControlSession.Observation
        static var production: Self {
            .init(open: { policy, current in
                let runtime = try OwnedNativeComputerUseClient.Runtime.discover()
                let client = try await OwnedNativeComputerUseClient.open(runtime: runtime)
                return Opened(controller: NativeControlSession(client: client, sessionIsActive: current,
                    authorizer: policy), close: { await client.close() })
            }, observeRead: { controller, admission in
                try admission.validate()
                guard let application = NSRunningApplication(processIdentifier: admission.application.processID),
                      DesktopApplicationTarget.matches(admission.application, application: application) else {
                    throw NativeVisualTaskFailure.staleTask
                }
                let observation = try await controller.observeForRead(application: application)
                try admission.validate()
                return observation
            })
        }
    }
    private let platform: Platform
    private var policyTargets: [UUID: NativeOriginalPolicyTarget] = [:]
    private var originals: [UUID: NativeControlSession.OriginalSource] = [:]
    private var closed = false

    init(scope: NativeVisualTaskScope, inputAuthority: NativeLocalTaskInputAuthority,
         platform: Platform = .production) throws {
        guard inputAuthority.scope === scope else { throw NativeVisualTaskFailure.staleTask }
        self.scope = scope; self.authority = inputAuthority; self.platform = platform
        try scope.validate(); try authority.validate()
    }

    func policyTarget(_ sourceID: UUID) throws -> NativeOriginalPolicyTarget {
        try validate()
        guard let target = policyTargets[sourceID] else { throw NativeVisualTaskFailure.staleProposal }
        try target.validateSource(); return target
    }

    func open(policy: NativeOrdinaryVisualPolicy) async throws -> NativeVisualTaskConnection {
        try validate()
        // A pinned source from a previous owner cannot be imported by creating
        // another controller or selecting a new/lookalike app window.
        if case .pinned = authority.windowRequirement {
            throw NativeVisualTaskFailure.unavailableDependency("a transferable original-window source for this continuation")
        }
        let opened = try await platform.open(policy, { [weak self] in
            guard let self else { return false }
            return (try? self.validate()) != nil
        })
        let controller = opened.controller
        do { try validate() }
        catch { controller.stop(); await controller.drain(); await opened.close(); throw error }
        do {
            try validate()
            return NativeVisualTaskConnection(controller: controller,
                observeRead: { [self] admission in
                    try validate(); try admission.validate()
                    let originalAdmission = try scope.admitRead(admission.application.bundleID)
                    guard originalAdmission.application == admission.application else {
                        throw NativeVisualTaskFailure.staleTask
                    }
                    try originalAdmission.validate()
                    let observation = try await platform.observeRead(controller, originalAdmission)
                    try validate(); try admission.validate()
                    guard observation.snapshot.application == admission.application else { throw NativeVisualTaskFailure.staleTask }
                    return try retain(observation, controller: controller)
                }, refreshOriginal: { [self] previous in
                    let original = try source(previous, controller: controller)
                    let observation = try await controller.refreshOriginalForRead(original)
                    try validate(); try previous.validateOriginalSource()
                    return try retain(observation, controller: controller)
                }, refreshForInputPlanning: { [self] previous in
                    let original = try source(previous, controller: controller)
                    let target = try policyTarget(previous.sourceID)
                    // Metadata/privacy precedes all focused labels/content.
                    // This callback is an existing positive live task grant;
                    // a model offering key/text wrappers cannot manufacture it.
                    let metadata = try authority.inspect(target)
                    switch metadata.context {
                    case .protected: throw NativeOrdinaryWindowPolicySource.Failure.protectedContext
                    case .dedicated: throw NativeOrdinaryWindowPolicySource.Failure.dedicatedContext
                    case .ordinary, .modalReviewRequired: break
                    }
                    let modal: Bool
                    if case .modalReviewRequired = metadata.context { modal = true } else { modal = false }
                    if metadata.coverage != .complete || modal {
                        // An unknown modal does not acquire field contents.
                        // Pointer planning may still use existing read scope;
                        // actual input requires the exact local review.
                        let observation = try await controller.refreshOriginalForRead(original)
                        try validate()
                        let current = try authority.inspect(target)
                        guard current.digest == metadata.digest else { throw NativeOrdinaryWindowPolicySource.Failure.changedContext }
                        return try retain(observation, controller: controller)
                    }
                    let grant = try authority.privateEditorPlanningGrant(for: target)
                    let observation = try await controller.refreshOriginalForInputPlanning(original,
                        authorizeInputPlanning: grant)
                    try validate(); try grant()
                    try controller.validatePlanningObservation(observation)
                    return try retain(observation, controller: controller)
                }, prepareForReview: { [self] action, identity, source, frame in
                    try validate(); try source.validateOriginalSource()
                    try controller.validatePlanningObservation(source.observation)
                    let request = try identity.admission(scope: scope)
                    let prepared = try await controller.prepareForReview(action, request: request,
                        from: source.observation, frame: frame)
                    try validate(); try source.validateOriginalSource()
                    return prepared
                }, executeAdmitted: { proposal in
                    // execute retains late partial focus/input facts for the
                    // ORIGINAL run's checkpoint. Owner fencing occurs afterward.
                    do { return .controller(try await controller.execute(proposal)) }
                    catch {
                        // A thrown execute is not evidence that no focus or
                        // gesture occurred. Retain uncertainty/no replay in the
                        // original checkpoint before replacement-run fencing.
                        return .uncertain(NativeVisualStepOutcome.bounded(error.localizedDescription))
                    }
                }, closeOwnedClient: { [self] in
                    closed = true; policyTargets.removeAll(); originals.removeAll()
                    await opened.close()
                })
        } catch {
            controller.stop(); await controller.drain(); await opened.close(); throw error
        }
    }

    private func retain(_ observation: NativeControlSession.Observation,
                        controller: NativeControlSession) throws -> NativeVisualTaskSource {
        try validate()
        let original = try controller.source(from: observation)
        try controller.validateOriginalSource(original)
        let target = try controller.policyTarget(from: original)
        guard target.sourceID == original.id, target.application == observation.snapshot.application else { throw NativeVisualTaskFailure.staleProposal }
        try target.validateSource(); try validate()
        originals[original.id] = original; policyTargets[original.id] = target
        return .init(observation: observation, sourceID: original.id,
            validateOriginalSource: { [self] in try validate(); try controller.validateOriginalSource(original) },
            validatePlanningObservation: {
                // This validates an already captured image/preview, not the
                // separate selected-window fence before the controller's RPC.
                try controller.validatePlanningObservation(observation)
            }, validateForInput: { [self] in try validate(); try controller.validateForInput(original) })
    }

    private func source(_ previous: NativeVisualTaskSource,
                        controller: NativeControlSession) throws -> NativeControlSession.OriginalSource {
        try validate(); try previous.validateOriginalSource()
        guard let original = originals[previous.sourceID], original.id == previous.sourceID else { throw NativeVisualTaskFailure.staleProposal }
        try controller.validateOriginalSource(original)
        return original
    }
    private func validate() throws {
        try scope.validate()
        guard !closed else { throw NativeVisualTaskFailure.stopped }
    }
}
