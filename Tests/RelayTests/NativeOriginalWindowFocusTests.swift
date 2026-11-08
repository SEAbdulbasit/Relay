import Foundation
import Testing
@testable import Relay

/// No NSRunningApplication, AX process, native provider or physical input is
/// used. These tests exercise the same finite restoration state machine.
@MainActor @Suite(.serialized) struct NativeOriginalWindowFocusTests {
    @Test func alreadyFocusedPerformsNoEffectAndDoesNotConsumeFocusReview() async {
        let rig = Rig(); rig.focused = true
        let outcome = await rig.restore()
        guard case .alreadyFocused = outcome else { Issue.record("Expected original focus proof"); return }
        #expect(rig.effects.isEmpty && rig.consumptions == 0 && rig.inputChecks == 1)
    }
    @Test func originalOnlyActivationRaiseAndSelectionShareOneReview() async {
        let rig = Rig()
        let outcome = await rig.restore()
        guard case .restored = outcome else { Issue.record("Expected retained original focus restoration"); return }
        #expect(rig.effects == ["activate-original", "raise-original", "select-original"])
        #expect(rig.consumptions == 1 && rig.inputChecks == 1)
    }
    @Test func aRaiseOnlyBindingCanProveFocusWithoutAWritableFocusedWindowAttribute() async {
        let rig = Rig(); rig.usesSelectionStage = false; rig.raiseActuallyFocuses = true
        let outcome = await rig.restore()
        guard case .restored = outcome else { Issue.record("AXRaise may establish the exact original focus"); return }
        #expect(rig.effects == ["activate-original", "raise-original"] && rig.inputChecks == 1)
    }
    @Test func foregroundProcessWithDifferentSelectedWindowDoesNotReactivateOrReplaceIt() async {
        let rig = Rig(); rig.foreground = true
        let outcome = await rig.restore()
        guard case .restored = outcome else { Issue.record("Expected original window focus"); return }
        #expect(rig.effects == ["raise-original", "select-original"] && rig.consumptions == 1)
    }
    @Test(arguments: ["source", "review", "stop", "client-close", "deadline", "unsupported"])
    func preEffectRefusalDispatchesNothing(_ boundary: String) async {
        let rig = Rig()
        switch boundary {
        case "source": rig.sourceValid = false
        case "review": rig.reviewValid = false
        case "stop": rig.active = false
        case "client-close": rig.gate.revoke()
        case "deadline": rig.now = rig.deadline
        default: rig.qualified = false
        }
        let outcome = await rig.restore()
        guard case .refused = outcome else { Issue.record("Expected pre-effect refusal at \(boundary)"); return }
        #expect(rig.effects.isEmpty && rig.consumptions == 0)
    }
    @Test(arguments: ["source", "review", "stop", "client-close", "deadline", "activation-error"])
    func refusalAfterActivationPreservesItsPartialEffectAndSendsNoRaise(_ boundary: String) async {
        let rig = Rig()
        rig.afterEffect = { name in
            guard name == "activate-original" else { return }
            switch boundary {
            case "source": rig.sourceValid = false
            case "review": rig.reviewValid = false
            case "stop": rig.active = false
            case "client-close": rig.gate.revoke()
            case "deadline": rig.now = rig.deadline
            default: rig.activationFails = true
            }
        }
        let outcome = await rig.restore()
        guard case .uncertain = outcome else { Issue.record("Attempted activation must remain uncertain"); return }
        #expect(rig.effects == ["activate-original"] && rig.consumptions == 1)
    }
    @Test func stopDuringTheWaitingHopKeepsFocusEffectsAndNeverAdmitsInput() async {
        let rig = Rig(); rig.selectionActuallyFocuses = false
        rig.onPause = { rig.active = false }
        let outcome = await rig.restore()
        guard case .uncertain = outcome else { Issue.record("Expected focus-only uncertainty"); return }
        #expect(rig.effects == ["activate-original", "raise-original", "select-original"])
        #expect(rig.pauseCount == 1 && rig.inputChecks == 0)
    }
    @Test func wrongOriginalFocusedEditorAfterSelectionRefusesWithoutSelectingAnotherEditor() async {
        let rig = Rig(); rig.inputValid = false
        let outcome = await rig.restore()
        guard case .uncertain = outcome else { Issue.record("Window focus cannot invent editor focus"); return }
        #expect(rig.effects == ["activate-original", "raise-original", "select-original"])
        #expect(rig.inputChecks == 1)
    }
    @Test func anExpiredReservationIsNotRenewedWhileWaiting() async {
        let rig = Rig(); rig.selectionActuallyFocuses = false
        rig.onPause = { rig.now = rig.deadline }
        let outcome = await rig.restore()
        guard case .uncertain = outcome else { Issue.record("The original deadline must be retained"); return }
        #expect(rig.pauseCount == 1 && rig.effects.count == 3)
    }
    @Test func cancellationDuringFinalSourceReviewCheckAdmitsNoFocusStage() async {
        let rig = Rig(); rig.cancelAfterReviewConsumption = true
        let operation = Task { await rig.restore() }
        let outcome = await operation.value
        guard case .refused = outcome else { Issue.record("Cancellation before focus admission must refuse"); return }
        #expect(rig.effects.isEmpty && rig.consumptions == 1)
    }
    @Test func anotherSourceCannotConsumeReviewOrRunAnyFocusIO() async {
        let rig = Rig(); rig.reviewSourceID = UUID()
        let outcome = await rig.restore()
        guard case .refused = outcome else { Issue.record("A different source token must refuse"); return }
        #expect(rig.effects.isEmpty && rig.consumptions == 0 && rig.sourceChecks == 0)
    }
    @Test func aConsumedReviewCannotRepeatAnyFocusStage() async {
        let rig = Rig()
        _ = await rig.restore()
        rig.foreground = false; rig.focused = false
        let outcome = await rig.restore()
        guard case .refused = outcome else { Issue.record("Expected once-only focus refusal"); return }
        #expect(rig.effects.count == 3 && rig.consumptions == 1)
    }

    @MainActor private final class Rig {
        enum Failure: Error { case changed, unsupported, activation }
        var now = ContinuousClock.now
        lazy var deadline = now.advanced(by: .seconds(1))
        let gate = NativeInputRevocation()
        let sourceID = UUID()
        lazy var reviewSourceID = sourceID
        var sourceChecks = 0
        var sourceValid = true, reviewValid = true, active = true, qualified = true
        var foreground = false, focused = false, inputValid = true
        var activationFails = false, selectionActuallyFocuses = true
        var usesSelectionStage = true, raiseActuallyFocuses = false
        var consumed = false, consumptions = 0, inputChecks = 0, pauseCount = 0
        var cancelAfterReviewConsumption = false
        var effects: [String] = []
        var afterEffect: ((String) -> Void)?, onPause: (() -> Void)?
        lazy var helper = NativeOriginalWindowFocus(sourceID: sourceID, io: .init(
            validateOriginalSource: { [self] in sourceChecks += 1; guard sourceValid else { throw Failure.changed } },
            validateForInput: { [self] in inputChecks += 1; guard inputValid else { throw Failure.changed } },
            sessionIsActive: { [self] in active },
            isOriginalApplicationForeground: { [self] in foreground },
            isOriginalInputFocused: { [self] _ in focused },
            qualifyFocusOperations: { [self] _ in guard qualified else { throw Failure.unsupported } },
            activateOriginal: { [self] _ in
                effects.append("activate-original"); afterEffect?("activate-original")
                if activationFails { throw Failure.activation }; foreground = true
            }, raiseOriginal: { [self] _ in
                effects.append("raise-original"); afterEffect?("raise-original")
                if raiseActuallyFocuses { focused = true }
            }, selectOriginal: selectionOperation, now: { [self] in now }, pause: { [self] _ in pauseCount += 1; onPause?() }))
        var selectionOperation: (@MainActor (ContinuousClock.Instant) throws -> Void)? {
            guard usesSelectionStage else { return nil }
            return { [self] _ in
                effects.append("select-original"); afterEffect?("select-original")
                focused = selectionActuallyFocuses
            }
        }
        func restore() async -> NativeReviewedFocusOutcome {
            await helper.restore(review: .init(sourceID: reviewSourceID, validateOriginalScope: { [self] in
                guard reviewValid else { throw Failure.changed }
                if consumed, cancelAfterReviewConsumption { withUnsafeCurrentTask { $0?.cancel() } }
            }, admitOriginalFocusOnce: { [self] in
                guard !consumed else { throw Failure.changed }
                consumed = true; consumptions += 1
            }), gate: gate, notAfter: deadline)
        }
    }
}
