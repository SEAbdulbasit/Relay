import ApplicationServices
import Foundation
import Testing
@testable import Relay

/// Inert source/FIFO/editor seams exercise the centralized guard. These tests
/// neither mint an actual OS survey nor qualify standard AppKit availability.
@MainActor @Suite struct NativeControlRetainedPrivacyTests {
    private func target(_ rig: NextNativeControlRig) -> NativeControlSession.Target {
        var target = rig.target()
        target.policyTarget = {
            .init(sourceID: rig.sourceID, application: rig.application,
                originalWindow: AXUIElementCreateApplication(rig.application.processID), validateOriginalSource: {})
        }
        return target
    }
    @Test func retainedControlSourceCannotReadOrPublishAfterItsPrivacyBoundaryChanges() async throws {
        let rig = NextNativeControlRig(); var protected = false
        let observation = try await rig.session.observeForRead(target: target(rig), authorizeSourceBeforeCapture: { _ in
            if protected { throw NativeOrdinaryWindowPolicySource.Failure.protectedContext }
        })
        let original = try rig.session.controlReadSource(from: observation), captures = rig.captureCount
        protected = true
        #expect(throws: NativeOrdinaryWindowPolicySource.Failure.protectedContext) { try rig.session.validateOriginalSource(original) }
        #expect(throws: NativeOrdinaryWindowPolicySource.Failure.protectedContext) { try rig.session.validatePlanningObservation(observation) }
        await #expect(throws: NativeOrdinaryWindowPolicySource.Failure.protectedContext) { try await rig.session.refreshOriginalForRead(original) }
        #expect(rig.captureCount == captures && rig.textReads == 0 && rig.commands.isEmpty)
        // Actual metadata inspection still uses the identity-only owner fence;
        // it must not recursively call the very policy it is trying to inspect.
        let metadata = try rig.session.policyTarget(from: original)
        try metadata.validateSource()
        rig.session.stop(); await rig.session.drain()
        #expect(throws: (any Error).self) { try metadata.validateSource() }
    }
    @Test func protectedSourceReplacesLateProviderTextWithClosedFenceFailure() async throws {
        let rig = NextNativeControlRig(); var protected = false, attempts = 0
        let original = target(rig), marker = "PRIVATE_LATE_PROVIDER_MARKER"
        let throwing = NativeControlSession.Target(sourceID: original.sourceID, application: original.application,
            window: original.window, validateOriginalSource: original.validateOriginalSource, validateForInput: original.validateForInput,
            capture: { _ in attempts += 1; protected = true; throw RelayError.message(marker) },
            isCurrent: original.isCurrent, captureFocusForReview: original.captureFocusForReview,
            restoreReviewedOriginalFocus: original.restoreReviewedOriginalFocus,
            captureInsertionForReview: original.captureInsertionForReview, policyTarget: original.policyTarget)
        do {
            _ = try await rig.session.observeForRead(target: throwing, authorizeSourceBeforeCapture: { _ in
                if protected { throw NativeOrdinaryWindowPolicySource.Failure.protectedContext }
            })
            Issue.record("A protected late provider error unexpectedly returned an observation.")
        } catch {
            #expect(error as? NativeOrdinaryWindowPolicySource.Failure == .protectedContext)
            #expect(Data(error.localizedDescription.utf8).range(of: Data(marker.utf8)) == nil)
        }
        #expect(attempts == 1 && rig.textReads == 0 && rig.textWrites == 0 && rig.commands.isEmpty)
        rig.session.stop(); await rig.session.drain()
    }
    @Test func generalReadSourceDoesNotBecomeAnImageFreeControlGoalCapability() async throws {
        let rig = NextNativeControlRig(), observation = try await rig.read()
        #expect(throws: NativeControlSession.Failure.unqualifiedEffect) { try rig.session.controlReadSource(from: observation) }
        let source = try rig.session.source(from: observation)
        _ = try await rig.session.refreshOriginalForRead(source)
        #expect(rig.captureCount == 2 && rig.textReads == 0)
        rig.session.stop(); await rig.session.drain()
    }
    @Test func protectedContextBeforeInputBlocksReservedCaptureAndDispatch() async throws {
        let rig = NextNativeControlRig(); var protected = false
        let first = try await rig.session.observeForRead(target: target(rig), authorizeSourceBeforeCapture: { _ in
            if protected { throw NativeOrdinaryWindowPolicySource.Failure.protectedContext }
        })
        let original = try rig.session.controlReadSource(from: first)
        let plan = try await rig.session.refreshOriginalForInputPlanning(original, authorizeInputPlanning: {})
        let frame = try await rig.frame(plan), request = NextNativeControlRig.Request()
        let proposal = try await rig.session.prepareForReview(.typeUnsentText("Exact café 🌍"), request: request.admission, from: plan, frame: frame)
        let captures = rig.captureCount, privateReads = rig.textReads
        protected = true
        await #expect(throws: (any Error).self) { try await rig.session.execute(proposal) }
        #expect(rig.captureCount == captures && rig.textReads == privateReads && rig.textWrites == 0 && rig.commands.isEmpty)
        rig.session.stop(); await rig.session.drain()
    }
    @Test func protectionAfterOneActualInertWritePreservesUncertaintyAndPreventsPrivateReadbackOrReplay() async throws {
        let rig = NextNativeControlRig(); var protected = false, readsAtWrite = 0, capturesAtWrite = 0
        let first = try await rig.session.observeForRead(target: target(rig), authorizeSourceBeforeCapture: { _ in
            if protected { throw NativeOrdinaryWindowPolicySource.Failure.protectedContext }
        })
        let original = try rig.session.controlReadSource(from: first)
        let plan = try await rig.session.refreshOriginalForInputPlanning(original, authorizeInputPlanning: {})
        let frame = try await rig.frame(plan), request = NextNativeControlRig.Request()
        let proposal = try await rig.session.prepareForReview(.typeUnsentText("Exact cafe\u{301} 🌍"), request: request.admission, from: plan, frame: frame)
        rig.afterAXWrite = { protected = true; readsAtWrite = rig.textReads; capturesAtWrite = rig.captureCount }
        let actual = try await rig.session.execute(proposal)
        guard case .uncertain = actual else { Issue.record("An attempted write followed by protected readback must remain uncertain."); rig.session.stop(); await rig.session.drain(); return }
        #expect(rig.textWrites == 1 && rig.commands.isEmpty)
        #expect(rig.textReads == readsAtWrite && rig.captureCount == capturesAtWrite)
        await #expect(throws: (any Error).self) { try await rig.session.execute(proposal) }
        #expect(rig.textWrites == 1 && request.attempts == 1)
        rig.session.stop(); await rig.session.drain()
    }
}
