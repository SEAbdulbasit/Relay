import ApplicationServices
import Foundation
import Testing
@testable import Relay

/// Status predicates used by the actual reader. These do not mint a survey or
/// qualify any OS source; actual standard AppKit/controller acceptance is held.
@MainActor @Suite struct NativeStandardControlSurveyTests {
    @Test func protectedActualApplicationAncestorRefusesBeforeAnyWindowOrControlLabel() throws {
        var reads = 0
        let protectedCases: [[NativeStandardControlSurvey.OptionalFlag]] = [[.reported(true), .unreported], [.unreported, .reported(true)]]
        for flags in protectedCases {
            #expect(throws: NativeOrdinaryWindowPolicySource.Failure.protectedContext) {
                try NativeStandardControlSurvey.admitApplicationProtection(flags)
                reads += 1
            }
        }
        #expect(reads == 0)
        let unreported: [NativeStandardControlSurvey.OptionalFlag] = [.unreported, .unreported]
        try NativeStandardControlSurvey.admitApplicationProtection(unreported)
        #expect(unreported.allSatisfy { $0.value == nil })
        // This predicate is not a minted survey/window/editor capability.
    }
    @Test func supportedAbsenceIsNotFalseAndErrorsNeverBecomeAbsence() throws {
        let absent = try NativeStandardControlSurvey.optionalFlag(status: .attributeUnsupported, advertised: false, value: nil)
        #expect(absent == .unreported && absent.value == nil)
        let reported = try NativeStandardControlSurvey.optionalFlag(status: .success, advertised: true, value: kCFBooleanFalse)
        #expect(reported == .reported(false) && reported.value == false)
        for status in [AXError.noValue, .cannotComplete, .invalidUIElement, .failure] {
            #expect(throws: NativeOrdinaryWindowPolicySource.Failure.incomplete) {
                try NativeStandardControlSurvey.optionalFlag(status: status, advertised: false, value: nil)
            }
        }
        #expect(throws: NativeOrdinaryWindowPolicySource.Failure.incomplete) {
            try NativeStandardControlSurvey.optionalFlag(status: .attributeUnsupported, advertised: true, value: nil)
        }
        #expect(throws: NativeOrdinaryWindowPolicySource.Failure.incomplete) {
            try NativeStandardControlSurvey.optionalFlag(status: .success, advertised: true, value: "false" as CFString)
        }
    }
    @Test func actualLeafNoValueNeedsPositiveOriginalLivenessAndDoesNotHideReportedChildren() throws {
        for status in [AXError.noValue, .attributeUnsupported] {
            let leaf: [Int] = try NativeStandardControlSurvey.terminalChildren(role: "AXButton", status: status,
                value: nil, liveOriginalLeaf: true)
            #expect(leaf.isEmpty)
            for role in ["AXGroup", "AXWindow", "AXScrollArea", "AXUnknown"] {
                #expect(throws: NativeOrdinaryWindowPolicySource.Failure.incomplete) {
                    try NativeStandardControlSurvey.terminalChildren(role: role, status: status,
                        value: Optional<[Int]>.none, liveOriginalLeaf: true)
                }
            }
            #expect(throws: NativeOrdinaryWindowPolicySource.Failure.incomplete) {
                try NativeStandardControlSurvey.terminalChildren(role: "AXButton", status: status,
                    value: Optional<[Int]>.none, liveOriginalLeaf: false)
            }
        }
        let reported = try NativeStandardControlSurvey.terminalChildren(role: "AXTextField", status: .success,
            value: [1], liveOriginalLeaf: true)
        #expect(reported == [1])
    }
    @Test func standardEditableFieldAndTextareaRequireActualWriteability() throws {
        for (role, enabled) in [("AXTextField", NativeStandardControlSurvey.OptionalFlag.reported(true)),
                                ("AXTextArea", .unreported)] {
            try NativeStandardControlSurvey.admitEditorMetadata(role: role, subrole: "", protection: .unreported,
                hidden: .unreported, enabled: enabled, valueWritable: true, selectionWritable: true, selectedTextWritable: true)
            for writes in [(false, true, true), (true, false, true), (true, true, false)] {
                #expect(throws: NativeOrdinaryWindowPolicySource.Failure.incomplete) {
                    try NativeStandardControlSurvey.admitEditorMetadata(role: role, subrole: "", protection: .unreported,
                        hidden: .unreported, enabled: enabled, valueWritable: writes.0,
                        selectionWritable: writes.1, selectedTextWritable: writes.2)
                }
            }
        }
    }
    @Test func selectableDisabledHiddenSecureAndUnknownFieldsCannotQualify() throws {
        let refusals: [(String, String, NativeStandardControlSurvey.OptionalFlag, NativeStandardControlSurvey.OptionalFlag, NativeStandardControlSurvey.OptionalFlag)] = [
            ("AXTextArea", "", NativeStandardControlSurvey.OptionalFlag.unreported, .unreported, .reported(false)),
            ("AXTextField", "", .unreported, .unreported, .unreported),
            ("AXTextField", "AXSecureTextField", .unreported, .unreported, .reported(true)),
            ("AXTextField", "", .reported(true), .unreported, .reported(true)),
            ("AXTextField", "", .unreported, .reported(true), .reported(true)),
            ("AXUnknown", "", .unreported, .unreported, .reported(true))]
        for (role, subrole, protection, hidden, enabled) in refusals {
            #expect(throws: NativeOrdinaryWindowPolicySource.Failure.incomplete) {
                try NativeStandardControlSurvey.admitEditorMetadata(role: role, subrole: subrole, protection: protection,
                    hidden: hidden, enabled: enabled, valueWritable: true, selectionWritable: true, selectedTextWritable: true)
            }
        }
        // The actual hidden scrollbar is safe to retain as metadata; it is
        // neither an editor nor input permission, even with settable attrs.
        #expect(throws: NativeOrdinaryWindowPolicySource.Failure.incomplete) {
            try NativeStandardControlSurvey.admitEditorMetadata(role: "AXScrollBar", subrole: "", protection: .unreported,
                hidden: .reported(true), enabled: .reported(false), valueWritable: true, selectionWritable: true, selectedTextWritable: true)
        }
    }
    @Test func hiddenContainerDescendantLabelsStayUnreadAndAncestryFailureIsNotVisibility() throws {
        var hidden = [0: NativeStandardControlSurvey.OptionalFlag.unreported, 1: .reported(true), 2: .unreported]
        var parent = [2: 1, 1: 0], children = [0: [1], 1: [2], 2: [1]], reads = 0, active = true
        func access() -> NativeStandardControlSurvey.AncestryAccess<Int> {
            .init(originalWindow: 0, identical: ==, validate: { if !active { throw CancellationError() } },
                hidden: { node in try #require(hidden[node]) }, parent: { node in try #require(parent[node]) },
                reportedChildren: { node in try #require(children[node]) })
        }
        let skipped = try NativeStandardControlSurvey.readVisibleLabels(from: 2, access: access(), read: { reads += 1; return "HIDDEN_PRIVATE_LABEL" })
        #expect(skipped == nil && reads == 0)
        hidden[1] = .unreported
        let visible = try NativeStandardControlSurvey.readVisibleLabels(from: 2, access: access(), read: { reads += 1; return "Owned visible control" })
        #expect(visible == "Owned visible control" && reads == 1)
        children[1] = []
        #expect(throws: NativeOrdinaryWindowPolicySource.Failure.incomplete) {
            try NativeStandardControlSurvey.readVisibleLabels(from: 2, access: access(), read: { reads += 1; return "MISMATCHED_PRIVATE_LABEL" })
        }
        #expect(reads == 1)
        children[1] = [2]; parent[1] = 2
        #expect(throws: NativeOrdinaryWindowPolicySource.Failure.incomplete) {
            try NativeStandardControlSurvey.readVisibleLabels(from: 2, access: access(), read: { reads += 1; return "CYCLE_PRIVATE_LABEL" })
        }
        #expect(reads == 1)
        parent[1] = 0; active = false
        #expect(throws: CancellationError.self) {
            try NativeStandardControlSurvey.readVisibleLabels(from: 2, access: access(), read: { reads += 1; return "REVOKED_PRIVATE_LABEL" })
        }
        #expect(reads == 1)
    }
    @Test func ordinaryCoverageWithoutTheActualReaderCapabilityCannotAuthorizePrivatePlanning() {
        let application = DesktopApplicationIdentity(processID: 1, launchedAt: Date(timeIntervalSince1970: 1),
            bundleID: "test.inert", bundleURL: URL(fileURLWithPath: "/Inert.app"))
        let forged = NativeOrdinaryWindowPolicySource.Facts(sourceID: UUID(), application: application, context: .ordinary,
            coverage: .standardRoleSurvey, visibleDedicatedControls: [], visitedNodes: 3, digest: Data([1]))
        #expect(throws: NativeOrdinaryWindowPolicySource.Failure.incomplete) { try forged.admitPrivateEditorPlanning() }
    }
}

/// Tests the control-only capture boundary with inert source/transport seams.
/// No actual AX metadata reader, provider, image model, focus or input is used.
@MainActor @Suite struct NativeControlSourceCaptureTests {
    private func target(_ rig: NextNativeControlRig, boundSourceID: UUID? = nil) -> NativeControlSession.Target {
        var target = rig.target()
        target.policyTarget = {
            NativeOriginalPolicyTarget(sourceID: boundSourceID ?? rig.sourceID, application: rig.application,
                originalWindow: AXUIElementCreateApplication(rig.application.processID), validateOriginalSource: {})
        }
        return target
    }
    @Test func protectedSourceRefusesBeforeFirstCaptureOrEditorRead() async throws {
        let rig = NextNativeControlRig()
        let original = target(rig)
        await #expect(throws: NativeOrdinaryWindowPolicySource.Failure.protectedContext) {
            try await rig.session.observeForRead(target: original, authorizeSourceBeforeCapture: { _ in
                #expect(rig.captureCount == 0)
                throw NativeOrdinaryWindowPolicySource.Failure.protectedContext
            })
        }
        #expect(rig.captureCount == 0 && rig.labelReads == 0 && rig.textReads == 0 && rig.commands.isEmpty)
        rig.session.stop(); await rig.session.drain()
    }
    @Test func metadataRevokedDuringCaptureCannotPublishAnObservation() async throws {
        let rig = NextNativeControlRig(); var gates: [Int] = []
        let original = target(rig)
        await #expect(throws: NativeOrdinaryWindowPolicySource.Failure.changedContext) {
            try await rig.session.observeForRead(target: original, authorizeSourceBeforeCapture: { _ in
                gates.append(rig.captureCount)
                if rig.captureCount > 0 { throw NativeOrdinaryWindowPolicySource.Failure.changedContext }
            })
        }
        // Both the successful capture boundary and its refusal/error path
        // recheck privacy before any observation could be published.
        #expect(gates == [0, 1, 1])
        #expect(rig.captureCount == 1)
        #expect(rig.labelReads == 0 && rig.textReads == 0 && rig.commands.isEmpty)
        rig.session.stop(); await rig.session.drain()
    }
    @Test func missingOrForeignActualTargetCannotFallBackToGeneralRead() async throws {
        for wrong in [false, true] {
            let rig = NextNativeControlRig()
            let source = wrong ? target(rig, boundSourceID: UUID()) : rig.target()
            await #expect(throws: (any Error).self) {
                try await rig.session.observeForRead(target: source, authorizeSourceBeforeCapture: { _ in
                    Issue.record("Missing or foreign target reached admission")
                })
            }
            #expect(rig.captureCount == 0 && rig.textReads == 0)
            rig.session.stop(); await rig.session.drain()
        }
    }
    @Test func ordinaryBackgroundReadWithoutControlGatePreservesItsExistingBehavior() async throws {
        let rig = NextNativeControlRig(); rig.foreground = false
        let result = try await rig.session.observeForRead(target: rig.target())
        #expect(rig.session.isCurrent(result) && rig.captureCount == 1)
        #expect(rig.labelReads == 0 && rig.textReads == 0 && rig.commands.isEmpty)
        rig.session.stop(); await rig.session.drain()
    }
}
