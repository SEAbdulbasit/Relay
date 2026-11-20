import Foundation
import Testing
@testable import Relay

/// Actual task/read/input/Factory owners with inert application resolution.
/// No positive AX binding, SDK call, policy Facts, private read or input is made.
@MainActor @Suite struct NativeMetadataScopeBindingTests {
    @Test func actualOpaqueScopeAuditCountsOneAttemptAndCannotSelectASealedRoute() throws {
        let rig = try Rig(), samples = AuditSamples(), binding = rig.input.metadataScopeBinding(for: rig.application)
        let audit = NativeReadAudit { samples.record($0) }
        var escaped: NativeMetadataScopeBinding.Authorization?
        let value = try binding.withAuthorization(readAudit: audit) { authorization in
            escaped = authorization
            try authorization.check()
            #expect(!authorization.canShareCurrentProcessQuery)
            let before = rig.state.admissionChecks
            for _ in 0..<1_100 { try authorization.check() }
            #expect(rig.state.admissionChecks == before + 1_100)
            #expect(!authorization.canShareCurrentProcessQuery)
            return 42
        }
        #expect(value == 42 && rig.state.resolutions == 1)
        #expect(samples.snapshot().map(\.stage) == [.policyMetadataOpaqueScope])
        #expect(samples.snapshot().allSatisfy { $0.metadata == nil && $0.elapsed >= .zero })
        let actual = try #require(escaped), before = rig.state.admissionChecks
        #expect(throws: NativeMetadataPhase.Failure.expired) { try actual.check() }
        #expect(rig.state.admissionChecks == before)
        try binding.withAuthorization { try $0.check() }
        #expect(rig.state.resolutions == 2 && samples.snapshot().count == 1)
    }

    @Test func actualOpaqueScopeAuditRecordsBodyAndBindingFailuresWithoutReplacingThem() throws {
        let rig = try Rig(), samples = AuditSamples(), binding = rig.input.metadataScopeBinding(for: rig.application)
        let audit = NativeReadAudit { samples.record($0) }
        #expect(throws: Refusal.body) {
            try binding.withAuthorization(readAudit: audit) { authorization in
                try authorization.check(); throw Refusal.body
            }
        }
        rig.state.resolutionFails = true
        #expect(throws: Refusal.resolution) {
            try binding.withAuthorization(readAudit: audit) { try $0.check() }
        }
        #expect(rig.state.resolutions == 2)
        #expect(samples.snapshot().map(\.stage) == [.policyMetadataOpaqueScope, .policyMetadataOpaqueScope])
    }

    @Test func onePhaseSelectsOnceButValidatesItsOriginalAdmissionAtEveryCheck() throws {
        let rig = try Rig(), binding = rig.input.metadataScopeBinding(for: rig.application)
        try binding.withAuthorization { authorization in
            try authorization.check()
            let before = rig.state.admissionChecks
            for _ in 0..<1_100 { try authorization.check() }
            #expect(rig.state.resolutions == 1 && rig.state.admissionChecks == before + 1_100)
        }
        try binding.withAuthorization { try $0.check() }
        #expect(rig.state.resolutions == 2)
    }

    @Test func restrictedAdmissionIsLiveAndNeverFallsBackToTheUnrestrictedResolver() throws {
        let rig = try Rig(restricted: true), binding = rig.input.metadataScopeBinding(for: rig.application)
        try binding.withAuthorization { authorization in
            try authorization.check()
            let before = rig.state.admissionChecks
            rig.state.restrictionCurrent = false
            #expect(throws: Refusal.restriction) { try authorization.check() }
            #expect(rig.state.admissionChecks == before + 1 && rig.state.resolutions == 0)
        }
        #expect(rig.state.resolutions == 0)
    }

    @Test(arguments: [Revocation.task, .scope, .budget, .input])
    func liveTaskScopeBudgetAndInputRevocationRefuseBeforeAnotherMetadataQuery(_ change: Revocation) throws {
        let rig = try Rig(), binding = rig.input.metadataScopeBinding(for: rig.application)
        var queries = 0
        try binding.withAuthorization { authorization in
            try authorization.check(); queries += 1
            switch change {
            case .task: rig.state.readTaskCurrent = false
            case .scope: rig.scope.stop()
            case .budget: rig.state.budgetCurrent = false
            case .input: rig.state.inputCurrent = false
            }
            #expect(throws: (any Error).self) { try authorization.check(); queries += 1 }
        }
        #expect(queries == 1 && rig.state.resolutions == 1)
    }

    @Test func applicationMismatchCannotSelectAReplacementDuringErrorExit() throws {
        let rig = try Rig(), binding = rig.input.metadataScopeBinding(for: rig.application)
        rig.state.foreignResult = true
        var boundaries = 0, queries = 0
        #expect(throws: NativeVisualTaskFailure.staleTask) {
            try binding.withAuthorization { authorization in
                try NativeMetadataPhase.run(deadline: .now.advanced(by: .milliseconds(750)), boundary: {
                    boundaries += 1; try authorization.check()
                }, query: { try authorization.check() }) { phase in
                    try phase.check(); queries += 1
                }
            }
        }
        #expect(boundaries == 2 && queries == 0 && rig.state.resolutions == 1)
    }

    @Test func firstResolutionFailureStaysSpentUntilTheLexicalPhaseEnds() throws {
        let rig = try Rig(), binding = rig.input.metadataScopeBinding(for: rig.application)
        rig.state.resolutionFails = true
        var boundaries = 0
        #expect(throws: Refusal.resolution) {
            try binding.withAuthorization { authorization in
                try NativeMetadataPhase.run(deadline: .now.advanced(by: .milliseconds(750)), boundary: {
                    boundaries += 1
                    // The failure clears before the exit; that must not cause
                    // another resolution or make the failed entry executable.
                    defer { rig.state.resolutionFails = false }
                    try authorization.check()
                }, query: { try authorization.check() }) { _ in
                    Issue.record("Failed metadata entry ran its body")
                }
            }
        }
        #expect(boundaries == 2 && rig.state.resolutions == 1)
        try binding.withAuthorization { try $0.check() }
        #expect(rig.state.resolutions == 2)
    }

    @Test func reentryDuringResolutionCannotBeCaughtAndRemintedIntoSuccess() throws {
        let rig = try Rig(), binding = rig.input.metadataScopeBinding(for: rig.application)
        try binding.withAuthorization { authorization in
            rig.state.duringResolve = {
                #expect(throws: NativeVisualTaskFailure.staleTask) { try authorization.check() }
            }
            defer { rig.state.duringResolve = nil }
            #expect(throws: NativeVisualTaskFailure.staleTask) { try authorization.check() }
            #expect(throws: NativeVisualTaskFailure.staleTask) { try authorization.check() }
        }
        #expect(rig.state.resolutions == 1)
    }

    @Test func caughtReentryInsideRetainedAdmissionCannotReturnAValidQuery() throws {
        let rig = try Rig(), binding = rig.input.metadataScopeBinding(for: rig.application)
        try binding.withAuthorization { authorization in
            try authorization.check()
            rig.state.duringAdmission = {
                #expect(throws: NativeVisualTaskFailure.staleTask) { try authorization.check() }
            }
            defer { rig.state.duringAdmission = nil }
            #expect(throws: NativeVisualTaskFailure.staleTask) { try authorization.check() }
            #expect(throws: NativeVisualTaskFailure.staleTask) { try authorization.check() }
        }
        #expect(rig.state.resolutions == 1)
    }

    @Test(arguments: [Exit.success, .bodyFailure, .entryFailure, .stop, .deadline])
    func allExitsRetireEscapedAuthorizationBeforeAnyFurtherOwnerWork(_ exit: Exit) throws {
        let rig = try Rig(), binding = rig.input.metadataScopeBinding(for: rig.application)
        var escaped: NativeMetadataScopeBinding.Authorization?
        let start = ContinuousClock.now
        var now = start
        do {
            try binding.withAuthorization { authorization in
                escaped = authorization
                if exit == .entryFailure { rig.state.resolutionFails = true }
                try NativeMetadataPhase.run(deadline: start.advanced(by: .milliseconds(750)), boundary: {
                    try authorization.check()
                }, query: { try authorization.check() }, now: { now }) { phase in
                    try phase.check()
                    switch exit {
                    case .success, .entryFailure: break
                    case .bodyFailure: throw Refusal.body
                    case .stop: rig.scope.stop(); try phase.check()
                    case .deadline: now = start.advanced(by: .milliseconds(750))
                    }
                }
            }
            #expect(exit == .success)
        } catch {
            switch exit {
            case .success: Issue.record("Unchanged metadata phase unexpectedly failed")
            case .bodyFailure: #expect(error as? Refusal == .body)
            case .entryFailure: #expect(error as? Refusal == .resolution)
            case .stop: #expect(error as? NativeVisualTaskFailure == .stopped)
            case .deadline: #expect(error as? NativeOrdinaryWindowPolicySource.Failure == .incomplete)
            }
        }
        let authorization = try #require(escaped)
        let before = rig.state.admissionChecks, scopes = rig.state.scopeChecks
        #expect(throws: NativeMetadataPhase.Failure.expired) { try authorization.check() }
        #expect(rig.state.admissionChecks == before && rig.state.scopeChecks == scopes)
    }

    @Test func scheduledTaskCannotUseAnAuthorizationAfterItsSynchronousBody() async throws {
        let rig = try Rig(), binding = rig.input.metadataScopeBinding(for: rig.application)
        let delayed = try binding.withAuthorization { authorization in
            try authorization.check()
            return Task { @MainActor in
                #expect(throws: NativeMetadataPhase.Failure.expired) { try authorization.check() }
            }
        }
        await delayed.value
        #expect(rig.state.resolutions == 1)
    }

    @Test func losingTheOriginalInputOwnerDoesNotAdoptAnotherTaskOrKeepItAlive() throws {
        let rig = try Rig()
        var owner: NativeLocalTaskInputAuthority? = try .localUserInvocation(scope: rig.scope,
            windowRequirement: .appScoped, validateAcknowledgedInputGrant: { try rig.state.checkInput() })
        weak var weakOwner = owner
        let binding = try #require(owner).metadataScopeBinding(for: rig.application)
        try binding.withAuthorization { authorization in
            try authorization.check(); owner = nil
            #expect(weakOwner == nil)
            #expect(throws: NativeVisualTaskFailure.stopped) { try authorization.check() }
        }
        #expect(rig.state.resolutions == 1)
    }

    @Test func readOnlyFactoryKeepsItsIndependentReadContractAndWeakOwner() throws {
        let rig = try Rig()
        var factory: NativeProductionTaskConnectionFactory? = try .init(scope: rig.scope, inputAuthority: rig.input)
        weak var weakFactory = factory
        let binding = NativeMetadataScopeBinding.controlRead(try #require(factory), application: rig.application)
        rig.state.inputCurrent = false
        try binding.withAuthorization { authorization in
            try authorization.check()
            #expect(rig.state.resolutions == 1)
            factory = nil
            #expect(weakFactory == nil)
            #expect(throws: NativeVisualTaskFailure.stopped) { try authorization.check() }
        }
        #expect(throws: Refusal.input) { try rig.input.authorizeMetadataScope(rig.application) }
    }

    @Test func closedActualFactoryRefusesBeforeAnotherResolutionWithoutOpeningOrReadingAnApp() async throws {
        let rig = try Rig(), canvas = NextNativeControlRig()
        var opens = 0, closes = 0
        let platform = NativeProductionTaskConnectionFactory.Platform(open: { _, _ in
            opens += 1
            return .init(controller: canvas.session, close: { closes += 1 })
        }, observeRead: { _, _ in throw Refusal.body })
        let factory = try NativeProductionTaskConnectionFactory(scope: rig.scope, inputAuthority: rig.input, platform: platform)
        let policy = NativeOrdinaryVisualPolicy(inspect: { _, _ in throw Refusal.body }, review: { _, _, _ in
            Issue.record("Metadata owner test requested input review"); return false
        })
        let connection = try await factory.open(policy: policy)
        let binding = NativeMetadataScopeBinding.controlRead(factory, application: rig.application)
        try binding.withAuthorization { try $0.check() }
        connection.stop(); await connection.drain()
        #expect(throws: NativeVisualTaskFailure.stopped) { try binding.withAuthorization { try $0.check() } }
        #expect(opens == 1 && closes == 1 && rig.state.resolutions == 1)
        #expect(canvas.captureCount == 0 && canvas.textReads == 0 && canvas.commands.isEmpty)
    }

    @Test func canceledPhaseStillRunsItsExitButNeverReselectsAnApplication() async throws {
        let rig = try Rig(), binding = rig.input.metadataScopeBinding(for: rig.application)
        var boundaries = 0, queries = 0
        let child = Task { @MainActor in
            do {
                try binding.withAuthorization { authorization in
                    try NativeMetadataPhase.run(deadline: .now.advanced(by: .milliseconds(750)), boundary: {
                        boundaries += 1; try authorization.check()
                    }, query: { try authorization.check() }) { phase in
                        try phase.check(); queries += 1
                        withUnsafeCurrentTask { $0?.cancel() }
                        try phase.check(); queries += 1
                    }
                }
                Issue.record("Canceled metadata phase succeeded")
            } catch is CancellationError { }
            catch { Issue.record("Unexpected cancellation outcome") }
        }
        await child.value
        #expect(boundaries == 2 && queries == 1 && rig.state.resolutions == 1)
    }

    @Test func strongSourceErrorOverridesBodyFailureWithoutRenewingScopeAndBoundaryTimeCounts() throws {
        let rig = try Rig(), binding = rig.input.metadataScopeBinding(for: rig.application)
        var sourceCurrent = true, boundaries = 0, published = 0
        #expect(throws: Refusal.source) {
            try binding.withAuthorization { authorization in
                try NativeMetadataPhase.run(deadline: .now.advanced(by: .milliseconds(750)), boundary: {
                    boundaries += 1
                    guard sourceCurrent else { throw Refusal.source }
                    try authorization.check()
                }, query: { try authorization.check() }) { phase in
                    try phase.check(); sourceCurrent = false; throw Refusal.body
                }
            }
            published += 1
        }
        #expect(boundaries == 2 && published == 0 && rig.state.resolutions == 1)
        let start = ContinuousClock.now
        var now = start
        rig.state.duringResolve = { now = start.advanced(by: .milliseconds(751)) }
        defer { rig.state.duringResolve = nil }
        #expect(throws: NativeOrdinaryWindowPolicySource.Failure.incomplete) {
            try binding.withAuthorization { authorization in
                try NativeMetadataPhase.run(deadline: start.advanced(by: .milliseconds(750)), boundary: {
                    try authorization.check()
                }, query: { try authorization.check() }, now: { now }) { _ in
                    Issue.record("Binding work escaped the unchanged metadata deadline")
                }
            }
        }
        #expect(rig.state.resolutions == 2)
    }

    enum Revocation: Sendable { case task, scope, budget, input }
    enum Exit: Sendable, Equatable { case success, bodyFailure, entryFailure, stop, deadline }
    nonisolated private final class AuditSamples: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [NativeReadAudit.Sample] = []
        func record(_ value: NativeReadAudit.Sample) { lock.withLock { values.append(value) } }
        func snapshot() -> [NativeReadAudit.Sample] { lock.withLock { values } }
    }
    private enum Refusal: Error, Equatable { case restriction, resolution, budget, input, body, source }
    @MainActor private final class State {
        var readTaskCurrent = true, budgetCurrent = true, inputCurrent = true, restrictionCurrent = true
        var resolutionFails = false, foreignResult = false
        var resolutions = 0, admissionChecks = 0, scopeChecks = 0
        var duringResolve: (@MainActor () throws -> Void)?
        var duringAdmission: (@MainActor () throws -> Void)?
        func checkAdmission() throws {
            admissionChecks += 1
            guard restrictionCurrent else { throw Refusal.restriction }
            try duringAdmission?()
        }
        func checkInput() throws { guard inputCurrent else { throw Refusal.input } }
    }
    @MainActor private final class Rig {
        let state: State, application: DesktopApplicationIdentity
        let scope: NativeVisualTaskScope, input: NativeLocalTaskInputAuthority
        init(restricted: Bool = false) throws {
            let state = State(), task = UUID()
            let application = DesktopApplicationIdentity(processID: 42, launchedAt: Date(timeIntervalSince1970: 1),
                bundleID: "test.phase.admission", bundleURL: URL(fileURLWithPath: "/Owned Phase.app"))
            let admission = NativeWindowTaskAdapter.ApplicationAdmission(application: application, validate: state.checkAdmission)
            let read = NativeLocalTaskReadAuthority.localUserInvocation(taskID: task,
                taskIsCurrent: { state.readTaskCurrent }, restrictions: restricted ? [admission] : nil, resolve: { bundle in
                    state.resolutions += 1
                    guard bundle == application.bundleID, !state.resolutionFails else { throw Refusal.resolution }
                    try state.duringResolve?()
                    if state.foreignResult {
                        return .init(application: .init(processID: 99, launchedAt: application.launchedAt,
                            bundleID: application.bundleID, bundleURL: application.bundleURL), validate: state.checkAdmission)
                    }
                    return admission
                })
            let run = try AssistantConversationHistory.Run(logicalTaskID: task, cause: .newRequest)
            let scope = try NativeVisualTaskScope(logicalTaskID: task, runRevision: 1, run: run,
                originalObjective: "Inspect actual admission metadata with inert resolution only.",
                inferenceIdentity: .embedded(path: "/inert/not-loaded.litertlm", compute: "cpu"), readAuthority: read,
                validateAcknowledgedStoreRun: {
                    state.scopeChecks += 1
                    guard state.budgetCurrent else { throw Refusal.budget }
                })
            self.state = state; self.application = application; self.scope = scope
            input = try .localUserInvocation(scope: scope, windowRequirement: .appScoped,
                validateAcknowledgedInputGrant: state.checkInput)
        }
    }
}
