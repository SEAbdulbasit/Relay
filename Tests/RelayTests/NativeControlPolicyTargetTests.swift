import ApplicationServices
import Foundation
import Testing
@testable import Relay

/// Only local opaque AX references are created; no AX metadata query occurs.
@Suite @MainActor struct NativeControlPolicyTargetTests {
    @Test func originalPolicyBindingSurvivesOwnImageEpochWithoutCapturingAnEditor() async throws {
        let rig = NextNativeControlRig()
        var target = rig.target(), bindings = 0, validations = 0
        target.policyTarget = {
            bindings += 1
            return NativeOriginalPolicyTarget(sourceID: rig.sourceID, application: rig.application,
                originalWindow: AXUIElementCreateApplication(rig.application.processID), validateOriginalSource: { validations += 1 })
        }
        let first = try await rig.session.observeForRead(target: target), source = try rig.session.source(from: first)
        _ = try await rig.session.refreshOriginalForRead(source)
        let captures = rig.captureCount, binding = try rig.session.policyTarget(from: source)
        #expect(binding.sourceID == source.id && binding.application == rig.application)
        #expect(bindings == 1 && validations == 1 && rig.captureCount == captures)
        #expect(rig.textReads == 0 && rig.labelReads == 0 && rig.textWrites == 0 && rig.commands.isEmpty)
    }
    @Test func retainedMetadataReaderCannotOutliveItsControllerStop() async throws {
        let rig = NextNativeControlRig(); var target = rig.target(), validations = 0
        target.policyTarget = {
            NativeOriginalPolicyTarget(sourceID: rig.sourceID, application: rig.application,
                originalWindow: AXUIElementCreateApplication(rig.application.processID), validateOriginalSource: { validations += 1 })
        }
        let first = try await rig.session.observeForRead(target: target), source = try rig.session.source(from: first)
        let reader = try rig.session.policyTarget(from: source), before = validations
        rig.session.stop()
        #expect(throws: NativeControlSession.Failure.stopped) { try reader.validateSource() }
        #expect(validations == before && rig.textReads == 0)
    }
    @Test func syntheticTargetWithoutActualBindingRefusesRatherThanReconstructingAWindow() async throws {
        let rig = NextNativeControlRig(), first = try await rig.read(), source = try rig.session.source(from: first)
        #expect(throws: NativeControlSession.Failure.unqualifiedEffect) { try rig.session.policyTarget(from: source) }
        #expect(rig.captureCount == 1 && rig.textReads == 0)
    }
    @Test(arguments: ["stop", "foreign", "changed-source"])
    func invalidSourceNeverCallsTheActualWindowBinder(_ cause: String) async throws {
        let rig = NextNativeControlRig(); var target = rig.target(), bindings = 0
        target.policyTarget = { bindings += 1; throw NativeControlSession.Failure.unqualifiedEffect }
        let first = try await rig.session.observeForRead(target: target), source = try rig.session.source(from: first)
        if cause == "stop" { rig.session.stop() }
        if cause == "changed-source" { rig.sourceVersion += 1 }
        let successor = cause == "foreign" ? NextNativeControlRig() : rig
        #expect(throws: (any Error).self) { try successor.session.policyTarget(from: source) }
        #expect(bindings == 0 && successor.textReads == 0)
    }
    @Test(arguments: [false, true])
    func mismatchedSourceOrApplicationRefusesBeforeTheReturnedReaderRuns(_ wrongApplication: Bool) async throws {
        let rig = NextNativeControlRig(); var target = rig.target(), validations = 0
        let other = DesktopApplicationIdentity(processID: 9_999, launchedAt: Date(timeIntervalSince1970: 5),
            bundleID: "test.other", bundleURL: URL(fileURLWithPath: "/Applications/Other.app"))
        target.policyTarget = {
            NativeOriginalPolicyTarget(sourceID: wrongApplication ? rig.sourceID : UUID(),
                application: wrongApplication ? other : rig.application,
                originalWindow: AXUIElementCreateApplication(rig.application.processID), validateOriginalSource: { validations += 1 })
        }
        let first = try await rig.session.observeForRead(target: target), source = try rig.session.source(from: first)
        #expect(throws: NativeControlSession.Failure.wrongOwner) { try rig.session.policyTarget(from: source) }
        #expect(validations == 0 && rig.textReads == 0)
    }
    @Test func sourceRevokedByConstructionCannotPublishAReader() async throws {
        let rig = NextNativeControlRig(); var target = rig.target(), validations = 0
        target.policyTarget = {
            rig.sourceVersion += 1
            return NativeOriginalPolicyTarget(sourceID: rig.sourceID, application: rig.application,
                originalWindow: AXUIElementCreateApplication(rig.application.processID), validateOriginalSource: { validations += 1 })
        }
        let first = try await rig.session.observeForRead(target: target), source = try rig.session.source(from: first)
        #expect(throws: TargetBoundNativeObservation.Failure.changedTarget) { try rig.session.policyTarget(from: source) }
        #expect(validations == 0 && rig.textReads == 0)
    }
}
