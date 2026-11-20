import ApplicationServices
import Foundation
import Testing
@testable import Relay

/// Actual metadata bracket/scope methods with inert source callbacks. This does
/// not mint a survey or qualify any OS target, timing or private disclosure.
@MainActor @Suite struct NativeMetadataAuthorizationTests {
    @Test func bracketedScopeChecksHalveFullSourceWorkWithoutRemovingQueryBoundaryChecks() throws {
        let rig = try Rig()
        let independent = rig.target.metadataValidation { try rig.authority.authorizeMetadata(rig.target) }
        for _ in 0..<40 { try independent(); try independent() }
        let before = rig.state.sourceChecks
        rig.state.sourceChecks = 0
        let actual = rig.target.metadataValidation { try rig.authority.authorizeMetadataScope(rig.application) }
        for _ in 0..<40 { try actual(); try actual() }
        #expect(before == 320 && rig.state.sourceChecks == 160)
        #expect(rig.state.sourceChecks * 2 == before)
        // This is a per-query reduction, not a claim that a full survey now
        // finishes within750ms or avoids all thousands of technical AX reads.
    }

    @Test func scopeChangeDuringAuthorizationPreventsTheMetadataQuery() throws {
        let rig = try Rig()
        var queries = 0
        let check = rig.target.metadataValidation {
            try rig.authority.authorizeMetadataScope(rig.application)
            rig.state.sourceValid = false
        }
        #expect(throws: NativeOrdinaryWindowPolicySource.Failure.changedContext) {
            try check(); queries += 1
        }
        #expect(queries == 0 && rig.state.sourceChecks == 2)
    }

    @Test func sourceDriftAfterAQueryPreventsItsPublicationAndAnyPrivateFollowup() throws {
        let rig = try Rig()
        var queries = 0, published = 0, privateFollowups = 0
        let check = rig.target.metadataValidation { try rig.authority.authorizeMetadataScope(rig.application) }
        #expect(throws: NativeOrdinaryWindowPolicySource.Failure.changedContext) {
            try check(); queries += 1; rig.state.sourceValid = false
            try check(); published += 1; privateFollowups += 1
        }
        #expect(queries == 1 && published == 0 && privateFollowups == 0)
    }

    @Test func independentAuthorizationKeepsItsStrongSourceChecksAndCurrentInputGrant() throws {
        let rig = try Rig()
        try rig.authority.authorizeMetadata(rig.target)
        #expect(rig.state.sourceChecks == 2)
        rig.state.sourceValid = false
        #expect(throws: NativeOrdinaryWindowPolicySource.Failure.changedContext) {
            try rig.authority.authorizeMetadata(rig.target)
        }
        rig.state.sourceValid = true; rig.state.inputGrant = false
        #expect(throws: CancellationError.self) { try rig.authority.authorizeMetadataScope(rig.application) }
    }

    @Test func factoryReadScopeRefusesForeignApplicationAndStoppedOwnerWithoutOpeningAnything() throws {
        let rig = try Rig()
        let factory = try NativeProductionTaskConnectionFactory(scope: rig.scope, inputAuthority: rig.authority)
        try factory.authorizeControlReadMetadataScope(rig.application)
        #expect(rig.state.sourceChecks == 0)
        let foreign = DesktopApplicationIdentity(processID: 43, launchedAt: rig.application.launchedAt,
            bundleID: "test.metadata.foreign", bundleURL: URL(fileURLWithPath: "/Foreign.app"))
        #expect(throws: (any Error).self) { try factory.authorizeControlReadMetadataScope(foreign) }
        rig.state.active = false
        #expect(throws: (any Error).self) { try factory.authorizeControlReadMetadataScope(rig.application) }
    }

    @Test func typedProtectedRefusalCannotBeConfusedWithDeadlineUnavailableOrOpaqueFailure() throws {
        let samples = Samples(), audit = NativeReadAudit { samples.record($0) }
        #expect(throws: NativeOrdinaryWindowPolicySource.Failure.protectedContext) {
            try NativeReadAudit.inspectPolicy(audit) { throw NativeOrdinaryWindowPolicySource.Failure.protectedContext }
        }
        #expect(samples.stages == [.policyProtectedRefusal])
        samples.clear()
        let deadline = ContinuousClock.now
        #expect(throws: NativeOrdinaryWindowPolicySource.Failure.incomplete) {
            try NativeReadAudit.inspectPolicy(audit) {
                try NativeStandardControlSurvey.requireMetadataDeadline(deadline, now: deadline, readAudit: audit)
            }
        }
        #expect(samples.stages == [.policyDeadlineRefusal, .policyIncompleteRefusal])
        samples.clear()
        #expect(throws: NativeOrdinaryWindowPolicySource.Failure.unavailable) {
            try NativeReadAudit.inspectPolicy(audit) { throw NativeOrdinaryWindowPolicySource.Failure.unavailable }
        }
        #expect(samples.stages == [.policyUnavailableRefusal])
        samples.clear()
        #expect(throws: SyntheticFailure.privateMarker) {
            try NativeReadAudit.inspectPolicy(audit) { throw SyntheticFailure.privateMarker }
        }
        #expect(samples.stages == [.policyOtherRefusal])
        // Nil diagnostics preserve the exact original typed error as well.
        #expect(throws: NativeOrdinaryWindowPolicySource.Failure.protectedContext) {
            try NativeReadAudit.inspectPolicy(nil) { throw NativeOrdinaryWindowPolicySource.Failure.protectedContext }
        }
    }

    private enum SyntheticFailure: Error, Equatable { case privateMarker }
    @MainActor private final class State {
        var active = true, inputGrant = true, sourceValid = true
        var sourceChecks = 0
    }
    @MainActor private final class Rig {
        let state: State, application: DesktopApplicationIdentity
        let scope: NativeVisualTaskScope
        let authority: NativeLocalTaskInputAuthority
        let target: NativeOriginalPolicyTarget
        init() throws {
            let state = State(), task = UUID()
            let application = DesktopApplicationIdentity(processID: 42, launchedAt: Date(timeIntervalSince1970: 1),
                bundleID: "test.metadata.original", bundleURL: URL(fileURLWithPath: "/Original.app"))
            let run = try AssistantConversationHistory.Run(logicalTaskID: task, cause: .newRequest)
            let read = NativeLocalTaskReadAuthority.localUserInvocation(taskID: task,
                taskIsCurrent: { state.active }, resolve: { bundle in
                    guard state.active, bundle == application.bundleID else { throw CancellationError() }
                    return .init(application: application, validate: { guard state.active else { throw CancellationError() } })
                })
            let scope = try NativeVisualTaskScope(logicalTaskID: task, runRevision: 1, run: run,
                originalObjective: "Inspect one admitted synthetic metadata source.",
                inferenceIdentity: .embedded(path: "/inert/not-loaded.litertlm", compute: "cpu"), readAuthority: read,
                validateAcknowledgedStoreRun: { guard state.active else { throw CancellationError() } })
            self.state = state; self.application = application; self.scope = scope
            authority = try .localUserInvocation(scope: scope, windowRequirement: .appScoped,
                validateAcknowledgedInputGrant: { guard state.inputGrant else { throw CancellationError() } })
            target = NativeOriginalPolicyTarget(sourceID: UUID(), application: application,
                originalWindow: AXUIElementCreateApplication(application.processID), validateOriginalSource: {
                    state.sourceChecks += 1
                    guard state.active else { throw CancellationError() }
                    guard state.sourceValid else { throw NativeOrdinaryWindowPolicySource.Failure.changedContext }
                })
        }
    }
    nonisolated private final class Samples: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [NativeReadAudit.Sample] = []
        func record(_ value: NativeReadAudit.Sample) { lock.lock(); defer { lock.unlock() }; values.append(value) }
        var stages: [NativeReadAudit.Stage] { lock.lock(); defer { lock.unlock() }; return values.map(\.stage) }
        func clear() { lock.lock(); defer { lock.unlock() }; values.removeAll() }
    }
}
