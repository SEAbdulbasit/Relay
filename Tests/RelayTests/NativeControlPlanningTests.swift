import AppKit
import Foundation
import Testing
@testable import Relay

@Suite @MainActor struct NativeControlPlanningTests {
    @Test func backgroundReadAndPointerPlanningPerformNoEditorContentReads() async throws {
        let rig = NextNativeControlRig(); rig.foreground = false
        let observation = try await rig.read()
        #expect(!observation.hasNavigationPreview && !observation.hasTextInsertionPreview)
        let source = try rig.session.source(from: observation)
        try rig.session.validateOriginalSource(source)
        #expect(throws: NativeControlSession.Failure.changedFocus) { try rig.session.validateForInput(source) }
        let frame = try await rig.frame(observation)
        _ = try await rig.session.prepareForReview(.click(image: frame.id, point: .init(x: 8, y: 8)),
            request: NextNativeControlRig.Request().admission, from: observation, frame: frame)
        #expect(rig.textReads == 0 && rig.labelReads == 0)
        #expect(rig.focusCaptures == 0 && rig.insertionCaptures == 0 && rig.commands.isEmpty)
    }

    @Test(arguments: [false, true])
    func readOnlyObservationCannotLazilyAdoptAnEditorForKeyOrText(_ literal: Bool) async throws {
        let rig = NextNativeControlRig(), observation = try await rig.read()
        await #expect(throws: NativeControlSession.Failure.unavailableFocus) {
            try await rig.session.prepareForReview(literal ? .typeUnsentText("literal") : .key(.left),
                request: NextNativeControlRig.Request().admission, from: observation)
        }
        #expect(rig.textReads == 0 && rig.labelReads == 0 && rig.focusCaptures == 0 && rig.insertionCaptures == 0)
    }

    @Test func missingPlanningAuthorizationRefusesBeforePrivateCapture() async throws {
        let rig = NextNativeControlRig(), original = try await rig.read()
        let source = try rig.session.source(from: original)
        rig.planningAuthorized = false
        await #expect(throws: NativeControlSession.Failure.unqualifiedEffect) {
            try await rig.session.refreshOriginalForInputPlanning(source, authorizeInputPlanning: { try rig.authorizePlanning() })
        }
        #expect(rig.captureCount == 1 && rig.textReads == 0 && rig.labelReads == 0)
        #expect(rig.focusCaptures == 0 && rig.insertionCaptures == 0)
    }

    @Test func backgroundInputPreviewCanBeReviewedWithoutActivatingTheWindow() async throws {
        let rig = NextNativeControlRig(); rig.foreground = false
        let observation = try await rig.plan()
        #expect(observation.hasNavigationPreview && observation.hasTextInsertionPreview)
        let request = NextNativeControlRig.Request()
        let proposal = try await rig.session.prepareForReview(.key(.left), request: request.admission, from: observation)
        #expect(proposal.context.focusedTarget?.label == "Actual editor")
        #expect(rig.commands.isEmpty && rig.textWrites == 0 && request.attempts == 0)
        await #expect(throws: NativeControlSession.Failure.changedFocus) { try await rig.session.execute(proposal) }
        #expect(rig.commands.isEmpty && rig.textWrites == 0 && rig.authorizer.consumeCount == 0)
        #expect(request.attempts == 1)

    }

    @Test(arguments: ["editor", "selection", "value", "style"])
    func compositeObservationRejectsDriftDuringTheFrameCapture(_ drift: String) async throws {
        let rig = NextNativeControlRig(), first = try await rig.read()
        let source = try rig.session.source(from: first)
        rig.captureHook = { count in if count == 2 { Self.change(drift, rig) } }
        await #expect(throws: (any Error).self) {
            try await rig.session.refreshOriginalForInputPlanning(source, authorizeInputPlanning: { try rig.authorizePlanning() })
        }
        #expect(rig.commands.isEmpty && rig.textWrites == 0 && rig.authorizer.consumeCount == 0)
        #expect(!rig.session.isCurrent(first))
    }

    @Test(arguments: ["editor", "selection", "value", "style"])
    func originalCompositePreviewRefusesDriftDuringModelPlanning(_ drift: String) async throws {
        let rig = NextNativeControlRig(), observation = try await rig.plan()
        let focusCaptures = rig.focusCaptures, insertionCaptures = rig.insertionCaptures
        Self.change(drift, rig)
        await #expect(throws: (any Error).self) {
            try await rig.session.prepareForReview(.typeUnsentText("café 🌍 — owned canvas"),
                request: NextNativeControlRig.Request().admission, from: observation)
        }
        #expect(rig.focusCaptures == focusCaptures && rig.insertionCaptures == insertionCaptures)
        #expect(rig.commands.isEmpty && rig.textWrites == 0 && rig.authorizer.consumeCount == 0)
    }

    @Test(arguments: ["editor", "selection", "value", "style"])
    func reviewCannotPublishAProposalAfterItsCompositeSourceChanges(_ drift: String) async throws {
        let rig = NextNativeControlRig(), observation = try await rig.plan()
        rig.authorizer.whileAuthorizing = { Self.change(drift, rig) }
        await #expect(throws: (any Error).self) {
            try await rig.session.prepareForReview(.key(.right), request: NextNativeControlRig.Request().admission, from: observation)
        }
        #expect(rig.commands.isEmpty && rig.textWrites == 0 && rig.authorizer.consumeCount == 0)
    }

    @Test func planningGrantRevokedDuringCaptureCannotPublishOrReadMorePrivateValues() async throws {
        let rig = NextNativeControlRig(), first = try await rig.read()
        let source = try rig.session.source(from: first)
        var readsAtRevocation = -1
        rig.captureHook = { count in if count == 2 { rig.planningAuthorized = false; readsAtRevocation = rig.textReads } }
        await #expect(throws: NativeControlSession.Failure.unqualifiedEffect) {
            try await rig.session.refreshOriginalForInputPlanning(source, authorizeInputPlanning: { try rig.authorizePlanning() })
        }
        #expect(readsAtRevocation >= 0 && rig.textReads == readsAtRevocation)
        #expect(rig.commands.isEmpty && rig.textWrites == 0)
    }

    @Test func unsupportedEditorHasNoKeyOrTextWrapperButRetainsReadObservation() async throws {
        let rig = NextNativeControlRig(); rig.focusAvailable = false; rig.insertionAvailable = false
        let observation = try await rig.plan()
        #expect(!observation.hasNavigationPreview && !observation.hasTextInsertionPreview)
        #expect(rig.session.isCurrent(observation) && rig.textReads == 0)
    }

    @Test func newReadRetiresTheOldPrivateEditorPreviewWithoutCapturingANewOne() async throws {
        let rig = NextNativeControlRig(), planned = try await rig.plan()
        let source = try rig.session.source(from: planned), reads = rig.textReads
        let current = try await rig.session.refreshOriginalForRead(source)
        #expect(!planned.hasNavigationPreview && !planned.hasTextInsertionPreview)
        #expect(!current.hasNavigationPreview && !current.hasTextInsertionPreview)
        #expect(rig.textReads == reads && rig.session.isCurrent(current))
        try rig.session.validateOriginalSource(source)
    }

    @Test func intentionalOwnClickMayBeFollowedByAFreshAuthorizedEditorPlanningObservation() async throws {
        let rig = NextNativeControlRig(), first = try await rig.read()
        let source = try rig.session.source(from: first), frame = try await rig.frame(first)
        rig.dispatchHook = { rig.editorVersion += 1; rig.field = "New actual editor"; rig.selection = .init(location: 0, length: rig.field.utf16.count) }
        let click = try await rig.session.prepareForReview(.click(image: frame.id, point: .init(x: 8, y: 8)),
            request: NextNativeControlRig.Request().admission, from: first, frame: frame)
        guard case .readback = try await rig.session.execute(click) else { Issue.record("Expected independent scoped pointer readback."); return }
        #expect(rig.commands.count == 1 && rig.textReads == 0 && rig.textWrites == 0)
        rig.dispatchHook = nil
        let next = try await rig.session.refreshOriginalForInputPlanning(source, authorizeInputPlanning: { try rig.authorizePlanning() })
        let text = "café 🌍 — owned canvas"
        let insertion = try await rig.session.prepareForReview(.typeUnsentText(text), request: NextNativeControlRig.Request().admission, from: next)
        guard case .textInserted(let caret, _, _) = try await rig.session.execute(insertion) else {
            Issue.record("The up-front AX route must verify the exact literal."); return
        }
        #expect(rig.field.utf16.elementsEqual(text.utf16) && caret == NSRange(location: text.utf16.count, length: 0))
        #expect(rig.textWrites == 1 && rig.commands.count == 1 && rig.authorizer.consumeCount == 2)
    }

    @Test func sourceLeaseSurvivesOwnReadEpochButCannotCrossStopOrSessionOwnership() async throws {
        let rig = NextNativeControlRig(), observation = try await rig.read()
        let source = try rig.session.source(from: observation)
        _ = try await rig.session.refreshOriginalForRead(source)
        #expect(!rig.session.isCurrent(observation)); try rig.session.validateOriginalSource(source)
        rig.session.stop()
        let oldCaptures = rig.captureCount
        await #expect(throws: NativeControlSession.Failure.stopped) { try await rig.session.refreshOriginalForRead(source) }
        let successor = NextNativeControlRig()
        await #expect(throws: NativeControlSession.Failure.wrongOwner) { try await successor.session.refreshOriginalForRead(source) }
        #expect(rig.captureCount == oldCaptures && successor.captureCount == 0)
        // A genuinely new task is separate authority; the controller does not ban
        // intentional app-scoped/new-task window selection forever.
        _ = try await successor.read()
        #expect(successor.captureCount == 1)
    }

    @Test func selectedLookalikeWindowCannotReplaceThePinnedOriginalAfterReadRefresh() async throws {
        let rig = NextNativeControlRig(), first = try await rig.read()
        let source = try rig.session.source(from: first), before = rig.captureCount
        rig.sourceVersion += 1
        await #expect(throws: TargetBoundNativeObservation.Failure.changedTarget) { try await rig.session.refreshOriginalForRead(source) }
        #expect(rig.captureCount == before)
    }

    @Test func inconsistentInitialNavigationAndInsertionEditorsCannotDowngradeToAMissingCapability() async throws {
        let rig = NextNativeControlRig(), first = try await rig.read()
        let source = try rig.session.source(from: first)
        rig.beforeInsertionCapture = { rig.editorVersion += 1 }
        await #expect(throws: NativeControlSession.Failure.changedFocus) {
            try await rig.session.refreshOriginalForInputPlanning(source, authorizeInputPlanning: { try rig.authorizePlanning() })
        }
        #expect(rig.captureCount == 1 && rig.commands.isEmpty && rig.textWrites == 0)
    }

    @Test func styleDriftInsideInitialAXCaptureIsNotDowngradedToNavigationOnly() async throws {
        let rig = NextNativeControlRig(), first = try await rig.read()
        let source = try rig.session.source(from: first)
        rig.fieldReadHook = { count in if count == 3 { Self.change("style", rig) } }
        await #expect(throws: NativeFocusedAXInsertion.Failure.changedSource) {
            try await rig.session.refreshOriginalForInputPlanning(source, authorizeInputPlanning: { try rig.authorizePlanning() })
        }
        #expect(rig.captureCount == 1 && rig.commands.isEmpty && rig.textWrites == 0)
    }

    @Test(arguments: [false, true])
    func keyAndTextPolicyCanRetainTheExactOriginalPlanningJPEG(_ text: Bool) async throws {
        let rig = NextNativeControlRig(), observation = try await rig.plan(), frame = try await rig.frame(observation)
        let proposal = try await rig.session.prepareForReview(text ? .typeUnsentText("literal") : .key(.left),
            request: NextNativeControlRig.Request().admission, from: observation, frame: frame)
        #expect(proposal.context.frame?.id == frame.id && proposal.context.frame?.jpeg == frame.jpeg)
        #expect(proposal.context.frame?.observationID == observation.snapshot.id)
        #expect(proposal.context.focusedTarget?.identifier == "editor" && rig.commands.isEmpty && rig.textWrites == 0)
    }

    @Test func anOlderPlanningJPEGCannotBeAttachedToANewerCompositeEditorPreview() async throws {
        let rig = NextNativeControlRig(), first = try await rig.plan(), oldFrame = try await rig.frame(first)
        let source = try rig.session.source(from: first)
        let current = try await rig.session.refreshOriginalForInputPlanning(source, authorizeInputPlanning: { try rig.authorizePlanning() })
        await #expect(throws: NativeControlSession.Failure.invalidImage) {
            try await rig.session.prepareForReview(.key(.left), request: NextNativeControlRig.Request().admission, from: current, frame: oldFrame)
        }
        #expect(rig.commands.isEmpty && rig.textWrites == 0 && rig.authorizer.authorizations == 0)
    }

    @Test func acceptedProposalNamespacesAllowProviderIDsToBeReusedButNeverReplayOneProposal() async throws {
        let rig = NextNativeControlRig(); rig.includeImage = false
        let first = try await rig.plan(), source = try rig.session.source(from: first)
        let request = NextNativeControlRig.Request("accepted-turn-one")
        let original = try await rig.session.prepareForReview(.key(.left), request: request.admission, from: first)
        _ = try await rig.session.execute(original)
        await #expect(throws: NativeControlSession.Failure.consumed) { try await rig.session.execute(original) }
        let next = try await rig.session.refreshOriginalForInputPlanning(source, authorizeInputPlanning: { try rig.authorizePlanning() })
        await #expect(throws: NativeControlSession.Failure.consumed) {
            try await rig.session.prepareForReview(.key(.left), request: request.admission, from: next)
        }
        let later = NextNativeControlRig.Request("accepted-turn-two")
        let proposal = try await rig.session.prepareForReview(.key(.left), request: later.admission, from: next)
        #expect(original.context.originalProviderCallID == proposal.context.originalProviderCallID)
        #expect(original.context.requestID != proposal.context.requestID)
        _ = try await rig.session.execute(proposal)
        #expect(request.attempts == 1 && later.attempts == 1 && rig.commands.count == 2)
        #expect(rig.requestIDs == ["accepted-turn-one", "accepted-turn-two"])
    }

    @Test func moreThan1024AcceptedProposalsDoNotCreateAnApplicationLifetimeRefusal() async throws {
        let rig = NextNativeControlRig(); rig.includeImage = false
        let first = try await rig.read(), source = try rig.session.source(from: first)
        for turn in 0..<1_025 {
            let observation = try await rig.session.refreshOriginalForInputPlanning(source,
                authorizeInputPlanning: { try rig.authorizePlanning() })
            let request = NextNativeControlRig.Request("accepted-turn-\(turn)")
            let proposal = try await rig.session.prepareForReview(.key(.left), request: request.admission, from: observation)
            _ = try await rig.session.execute(proposal)
            #expect(request.attempts == 1)
        }
        #expect(rig.commands.count == 1_025 && rig.authorizer.consumeCount == 1_025)
        #expect(Set(rig.requestIDs).count == 1_025 && rig.textWrites == 0)
    }

    @Test func requestRevocationAfterReviewBlocksAdmissionBeforeNativeOrAXInput() async throws {
        let rig = NextNativeControlRig(), observation = try await rig.plan(), request = NextNativeControlRig.Request()
        let proposal = try await rig.session.prepareForReview(.typeUnsentText("café 🌍"), request: request.admission, from: observation)
        request.valid = false
        await #expect(throws: NativeControlSession.Failure.unqualifiedEffect) { try await rig.session.execute(proposal) }
        #expect(request.attempts == 0 && rig.textWrites == 0 && rig.commands.isEmpty && rig.authorizer.consumeCount == 0)
    }

    @Test func stopAtTheLastNativeAdmissionRejectsInputEvenAfterPolicyConsumption() async throws {
        let rig = NextNativeControlRig(), observation = try await rig.plan()
        let proposal = try await rig.session.prepareForReview(.key(.left), request: NextNativeControlRig.Request().admission, from: observation)
        rig.beforeNativeAdmission = { rig.session.stop() }
        guard case .focusOnly(.alreadyFocused, _) = try await rig.session.execute(proposal) else {
            Issue.record("Stop refused input after a no-effect already-focused check."); return
        }
        #expect(rig.commands.isEmpty && rig.textWrites == 0 && rig.authorizer.consumeCount == 1)
    }

    @Test func expiredReservationDoesNotGainANewBudgetForFocusOrInput() async throws {
        let rig = NextNativeControlRig(), observation = try await rig.plan()
        let request = NextNativeControlRig.Request()
        let proposal = try await rig.session.prepareForReview(.key(.right), request: request.admission, from: observation)
        rig.reservationDuration = .zero
        await #expect(throws: NativeControlSession.Failure.staleObservation) { try await rig.session.execute(proposal) }
        #expect(rig.commands.isEmpty && rig.textWrites == 0 && rig.authorizer.consumeCount == 0 && request.attempts == 1)
    }

    private static func change(_ drift: String, _ rig: NextNativeControlRig) {
        switch drift {
        case "editor": rig.editorVersion += 1
        case "selection": rig.selection = .init(location: 1, length: 2)
        case "value": rig.field = "Externally changed actual field"
        default: rig.fieldStorage.addAttribute(NSAttributedString.Key("AXFont"), value: ["AXFontName": "Synthetic Bold", "AXFontSize": NSNumber(value: 19)], range: NSRange(location: 0, length: rig.fieldStorage.length))
        }
    }
}
