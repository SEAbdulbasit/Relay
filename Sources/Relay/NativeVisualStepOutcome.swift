import Foundation
import RelayJournal

/// Focus-bearing successor for the actual next controller Outcome. Facts remain
/// memory-only: images/raw native bodies never enter history, Activity or journal.
@MainActor enum NativeVisualStepOutcome {
    case controller(NativeControlSession.Outcome)
    case focusOnly(NativeReviewedFocusOutcome, reason: String)
    case uncertain(String)

    var journalKind: JournalOutcomeKind {
        switch self {
        case .controller(let outcome):
            switch outcome {
            case .textInserted(_, _, let focus):
                return Self.focusContradictsInput(focus) ? .effectUncertain : .returnedVerified
            case .textUnchanged(_, let focus):
                // Even with no text write, activation/raise may be a real effect.
                return Self.focusOnlyKind(focus)
            case .readback(_, _, let focus):
                return Self.focusContradictsInput(focus) ? .effectUncertain : .returnedUnverified
            case .uncertain: return .effectUncertain
            case .focusOnly(let focus, _): return Self.focusOnlyKind(focus)
            }
        case .focusOnly(let focus, _): return Self.focusOnlyKind(focus)
        case .uncertain: return .effectUncertain
        }
    }
    var toolResult: ToolResult {
        switch self {
        case .controller(let outcome):
            switch outcome {
            case .textInserted(_, _, let focus):
                return ToolResult(summary: "Entered the unsent text in the original focused editor.",
                    evidence: "Exact AX text, unchanged surrounding text/style and resulting caret were verified, with original-target readback. No submission key was represented. " + Self.focusFact(focus),
                    verified: !Self.focusContradictsInput(focus))
            case .textUnchanged(_, let focus):
                return ToolResult(summary: "The original editor already matched; no text write was needed.",
                    evidence: "The qualified original-focused AX route returned unchanged. No replacement editor or keyboard fallback was used. " + Self.focusFact(focus),
                    verified: Self.focusHasNoEffect(focus))
            case .readback(_, _, let focus):
                return ToolResult(summary: "The native input request returned with original-target readback.",
                    evidence: "This establishes the provider receipt and scoped readback, not independent semantic success. Inspect the requested state before claiming completion or repeating input. " + Self.focusFact(focus),
                    verified: false)
            case .uncertain(_, _, let focus):
                return ToolResult(summary: "The native operation's effect is uncertain.",
                    evidence: "The original input may have been admitted. No replay is authorized by this result. Inspect only the retained original source when available. " + Self.focusFact(focus), verified: false)
            case .focusOnly(let focus, let reason): return Self.focusResult(focus, reason: reason)
            }
        case .focusOnly(let focus, let reason): return Self.focusResult(focus, reason: reason)
        case .uncertain(let reason):
            return ToolResult(summary: "Native execution returned an uncertain effect.",
                evidence: "Do not repeat the operation blindly. " + Self.bounded(reason), verified: false)
        }
    }
    private static func focusOnlyKind(_ focus: NativeReviewedFocusOutcome) -> JournalOutcomeKind {
        switch focus {
        case .restored: .returnedUnverified
        case .uncertain: .effectUncertain
        case .notRequested, .alreadyFocused, .refused: .notDispatched
        }
    }
    private static func focusContradictsInput(_ focus: NativeReviewedFocusOutcome) -> Bool {
        switch focus { case .uncertain, .refused: true; case .notRequested, .alreadyFocused, .restored: false }
    }
    private static func focusHasNoEffect(_ focus: NativeReviewedFocusOutcome) -> Bool {
        switch focus { case .notRequested, .alreadyFocused: true; case .restored, .uncertain, .refused: false }
    }
    private static func focusFact(_ focus: NativeReviewedFocusOutcome) -> String {
        switch focus {
        case .notRequested: "No original-window focus restoration was requested."
        case .alreadyFocused: "The original window was already focused; no activation is implied."
        case .restored: "The retained original window was brought forward during this operation."
        case .refused(let reason): "Original-window focus was refused. " + bounded(reason)
        case .uncertain(let reason): "The original-window focus phase remains uncertain. " + bounded(reason)
        }
    }
    private static func focusResult(_ focus: NativeReviewedFocusOutcome, reason: String) -> ToolResult {
        let text: String
        switch focus {
        case .uncertain: text = "Original-window focus is uncertain; the gesture was not admitted."
        case .restored: text = "Brought the original window forward; the later gesture was refused."
        case .alreadyFocused: text = "The original window was already focused; the gesture was refused."
        case .refused: text = "Original-window focus was refused; no gesture was admitted."
        case .notRequested: text = "No focus restoration or gesture was admitted."
        }
        return ToolResult(summary: text, evidence: focusFact(focus) + " No gesture replay was sent. " + bounded(reason), verified: false)
    }
    static func bounded(_ text: String) -> String { NativeProviderFailureText.textDetail(text, maximumBytes: 768) }
}

/// Created only around a stage known to precede gesture dispatch. Do not wrap
/// unknown execution failures or a changed-focus partial effect in this type.
nonisolated struct NativeVisualNoGesture: LocalizedError {
    let reason: String
    var errorDescription: String? { "No gesture was dispatched. " + reason }
}
