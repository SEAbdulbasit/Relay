import AppKit
import Foundation

/// Composes one retained-window controller with live application and task policy.
@MainActor final class NativeProductionTaskConnectionFactory {
    private let scope: NativeVisualTaskScope
    private let authority: NativeLocalTaskInputAuthority
    private let validateAvailability: @MainActor () throws -> Void
    /// Finite trusted OS/client boundary. The default is the real signed native
    /// client and exact running-process resolver; tests inject only inert IO.
    struct Platform {
        struct Opened {
            let controller: NativeControlSession
            let close: @MainActor () async -> Void
        }
        let open: @MainActor (NativeOrdinaryVisualPolicy, @escaping @MainActor () -> Bool) async throws -> Opened
        let observeRead: @MainActor (NativeControlSession, NativeWindowTaskAdapter.ApplicationAdmission) async throws -> NativeControlSession.Observation
        var observeControl: (@MainActor (NativeControlSession, NativeWindowTaskAdapter.ApplicationAdmission,
            @escaping @MainActor (NativeOriginalPolicyTarget) throws -> Void) async throws -> NativeControlSession.Observation)? = nil
        static var production: Self { production(readAudit: nil, processStarted: nil) }
        static func production(readAudit: NativeReadAudit?,
                               processStarted: (@Sendable (OwnedNativeComputerUseClient.ProcessStarted) throws -> Void)?) -> Self {
            .init(open: { policy, current in
                let runtime = try OwnedNativeComputerUseClient.Runtime.discover()
                let client = try await OwnedNativeComputerUseClient.open(runtime: runtime, readAudit: readAudit, processStarted: processStarted)
                return Opened(controller: NativeControlSession(client: client, sessionIsActive: current,
                    authorizer: policy, readAudit: readAudit), close: { await client.close() })
            }, observeRead: { controller, admission in
                try admission.validate()
                guard let application = NSRunningApplication(processIdentifier: admission.application.processID),
                      DesktopApplicationTarget.matches(admission.application, application: application) else {
                    throw NativeVisualTaskFailure.staleTask
                }
                let observation = try await controller.observeForRead(application: application)
                try admission.validate()
                return observation
            }, observeControl: { controller, admission, authorize in
                try admission.validate()
                guard let application = NSRunningApplication(processIdentifier: admission.application.processID),
                      DesktopApplicationTarget.matches(admission.application, application: application) else {
                    throw NativeVisualTaskFailure.staleTask
                }
                let observation = try await controller.observeForRead(application: application,
                    authorizeSourceBeforeCapture: authorize)
                try admission.validate()
                return observation
            })
        }
    }
    private let platform: Platform
    private var policyTargets: [UUID: NativeOriginalPolicyTarget] = [:]
    private var originals: [UUID: NativeControlSession.OriginalSource] = [:]
    private let initialMetadata: NativeInitialMetadataOwners<NativeOriginalPolicyTarget>
    private var closed = false

    init(scope: NativeVisualTaskScope, inputAuthority: NativeLocalTaskInputAuthority,
         platform: Platform? = nil, readAudit: NativeReadAudit? = nil,
         processStarted: (@Sendable (OwnedNativeComputerUseClient.ProcessStarted) throws -> Void)? = nil,
         validateAvailability: @escaping @MainActor () throws -> Void = {}) throws {
        guard inputAuthority.scope === scope else { throw NativeVisualTaskFailure.staleTask }
        self.scope = scope; self.authority = inputAuthority; self.platform = platform ?? .production(readAudit: readAudit, processStarted: processStarted)
        self.validateAvailability = validateAvailability
        initialMetadata = NativeInitialMetadataOwners(owner: scope)
        try scope.validate(); try authority.validate()
    }

    func policyTarget(_ sourceID: UUID) throws -> NativeOriginalPolicyTarget {
        try validate()
        guard let target = policyTargets[sourceID] else { throw NativeVisualTaskFailure.staleProposal }
        try target.validateSource(); return target
    }

    /// Dedicated metadata preparation, not general control availability. A real
    /// Store saved-message bridge is required before a purpose can exist.
    func prepareInitialExactUnsent(using observer: TargetBoundNativeObservation) throws -> TargetBoundNativeObservation.Request {
        try validate(); try authority.validate()
        guard case .initialExactUnsent(let purpose) = authority.windowRequirement else {
            throw NativeExactUnsentFailure.wrongTask
        }
        try purpose.validateCurrent(scope: scope)
        let request = try observer.prepareInitialExactUnsent(purpose)
        try purpose.validateCurrent(scope: scope); try authority.validate(); try validate()
        return request
    }

    func open(policy: NativeOrdinaryVisualPolicy) async throws -> NativeVisualTaskConnection {
        guard scope.executionKind == .inference else { throw NativeExactUnsentFailure.directAdapterUnavailable }
        try validate()
        // A pinned source from a previous owner cannot be imported by creating
        // another controller or selecting a new/lookalike app window.
        if case .pinned = authority.windowRequirement {
            throw NativeVisualTaskFailure.unavailableDependency("a transferable original-window source for this continuation")
        }
        // This purpose must never fall through into an app-scoped model/read/
        // mutation route before the closed direct adapter is implemented.
        if case .initialExactUnsent = authority.windowRequirement { throw NativeExactUnsentFailure.directAdapterUnavailable }
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
                }, refreshForInputPlanning: { [self] previous, includesTextInsertion in
                    let original = try source(previous, controller: controller)
                    let target = try policyTarget(previous.sourceID)
                    // Metadata/privacy precedes all focused labels/content.
                    // This callback is an existing positive live task grant;
                    // a model offering key/text wrappers cannot manufacture it.
                    let grant = try authority.privateEditorPlanningGrant(for: target)
                    let observation = try await controller.refreshOriginalForInputPlanning(original, includesTextInsertion: includesTextInsertion,
                        authorizeInputPlanning: grant)
                    try validate(); try grant()
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
                    initialMetadata.revoke()
                    await opened.close()
                }, observeForControl: { [self] admission in
                    try validate(); try authority.admit(admission)
                    guard let observeControl = platform.observeControl else {
                        throw NativeVisualTaskFailure.unavailableDependency("pre-capture original-window control policy")
                    }
                    let observation = try await observeControl(controller, admission, { [self] target in
                        let facts = try inspectInitialControlReadPrivacy(target)
                        try facts.admitControlReadCapture()
                    })
                    try validate(); try admission.validate()
                    guard observation.snapshot.application == admission.application else { throw NativeVisualTaskFailure.staleTask }
                    return try retain(observation, controller: controller)
                }, refreshOriginalForControl: { [self] previous in
                    let original = try source(previous, controller: controller)
                    let target = try policyTarget(previous.sourceID)
                    let before = try inspectControlReadPrivacy(target)
                    try before.admitControlReadCapture()
                    let observation = try await controller.refreshOriginalForRead(original)
                    try validate(); try previous.validateOriginalSource()
                    let after = try inspectControlReadPrivacy(target)
                    try after.admitControlReadCapture()
                    guard before.digest == after.digest else { throw NativeOrdinaryWindowPolicySource.Failure.changedContext }
                    return try retain(observation, controller: controller)
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

    /// Reuses only actual task/read authority for control-derived capture.
    /// Input planning/dispatch continue to require their independent input grant.
    private func inspectControlReadPrivacy(_ target: NativeOriginalPolicyTarget) throws -> NativeOrdinaryWindowPolicySource.Facts {
        try validate(); try target.validateSource()
        return try target.inspectMetadata(authorizeMetadata: { [self] in
            // NativeOriginalPolicyTarget's metadata fence brackets this callback
            // with the exact original-source validation before and after it.
            try authorizeControlReadMetadataScope(target.application)
        }, metadataScope: .controlRead(self, application: target.application))
    }

    /// Only this first control pre-capture callback can acquire a stable pair.
    /// The retained success/error callback re-enters through the spent owner
    /// and uses strict inspection, even after image/wrapper/source-ID changes.
    private func inspectInitialControlReadPrivacy(_ target: NativeOriginalPolicyTarget) throws -> NativeOrdinaryWindowPolicySource.Facts {
        try initialMetadata.withSource(target, sourceID: target.sourceID, owner: scope,
            sameOriginalWindow: { $0.sharesOriginalWindow(with: $1) }, validate: { [self] in
                try validate(); try target.validateSource()
            }, initial: { [self] acquisition, validateOwner in
                try target.inspectInitialMetadata(using: acquisition, validateInitialOwnership: validateOwner,
                    authorizeMetadata: { [self] in try authorizeControlReadMetadataScope(target.application) },
                    metadataScope: .controlRead(self, application: target.application))
            }, strict: { [self] in try inspectControlReadPrivacy(target) })
    }

    /// Scope only, used solely inside the retained policy target's metadata
    /// bracket. No full-window/source/privacy validator is replaced or cached.
    func authorizeControlReadMetadataScope(_ identity: DesktopApplicationIdentity) throws {
        try validate()
        let application = try scope.admitRead(identity.bundleID)
        guard application.application == identity else { throw NativeVisualTaskFailure.staleTask }
        try application.validate(); try validate()
    }

    /// Only the typed metadata factory uses these. The actual scope stays here;
    /// callers cannot pair this owner with a different task's scope.
    func bindControlReadMetadataApplication(_ identity: DesktopApplicationIdentity) throws -> NativeWindowTaskAdapter.ApplicationAdmission {
        try validate()
        let application = try scope.admitRead(identity.bundleID)
        guard application.application == identity else { throw NativeVisualTaskFailure.staleTask }
        try application.validate(); try validate()
        return application
    }
    func validateControlReadMetadataOwner() throws { try validate() }

    private func source(_ previous: NativeVisualTaskSource,
                        controller: NativeControlSession) throws -> NativeControlSession.OriginalSource {
        try validate(); try previous.validateOriginalSource()
        guard let original = originals[previous.sourceID], original.id == previous.sourceID else { throw NativeVisualTaskFailure.staleProposal }
        try controller.validateOriginalSource(original)
        return original
    }
    private func validate() throws {
        try scope.validate()
        try validateAvailability()
        guard !closed else { throw NativeVisualTaskFailure.stopped }
    }
}
