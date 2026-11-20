import AppKit
import SwiftUI

/// Pure geometry and hit-region contract for the notchless idle Sidekick handle.
///
/// The handle renders a `72×6` resting capsule (`84×9` when hovered) centered
/// inside an `84×18` interactive hit target within a `96×24` transparent canvas
/// placed at `SidekickPanelLayout.topEdge` (`visibleTop - 4`).
nonisolated struct SidekickRestingHandleLayout: Equatable, Sendable {
    static let canvasSize = CGSize(width: 96, height: 24)
    static let hitSize = CGSize(width: 84, height: 18)
    static let restingVisibleSize = CGSize(width: 72, height: 6)
    static let hoverVisibleSize = CGSize(width: 84, height: 9)
    static let activeCompactSize = CGSize(width: 210, height: 34)

    static let horizontalHitMargin: CGFloat = (canvasSize.width - hitSize.width) / 2
    static let verticalHitMargin: CGFloat = (canvasSize.height - hitSize.height) / 2

    static func visibleSize(hovered: Bool) -> CGSize {
        hovered ? hoverVisibleSize : restingVisibleSize
    }

    /// Central `84×18` interactive hit region inside a `96×24` handle canvas frame.
    static func hitRect(in canvasFrame: CGRect) -> CGRect {
        guard canvasFrame.width.isFinite, canvasFrame.height.isFinite,
              canvasFrame.width > 0, canvasFrame.height > 0 else { return .null }
        let width = min(hitSize.width, canvasFrame.width)
        let height = min(hitSize.height, canvasFrame.height)
        return CGRect(x: canvasFrame.midX - width / 2, y: canvasFrame.midY - height / 2,
                      width: width, height: height)
    }

    /// Top-centered `96×24` handle canvas within an arbitrary hosting view bounds.
    static func topCenteredCanvasRect(in containerBounds: CGRect, isFlipped: Bool = true) -> CGRect {
        let width = min(canvasSize.width, containerBounds.width)
        let height = min(canvasSize.height, containerBounds.height)
        let x = containerBounds.midX - width / 2
        let y = isFlipped ? containerBounds.minY : (containerBounds.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Central `84×18` interactive hit region in a hosting view's local `bounds` coordinates.
    static func localHitRect(in containerBounds: CGRect, isFlipped: Bool = true) -> CGRect {
        hitRect(in: topCenteredCanvasRect(in: containerBounds, isFlipped: isFlipped))
    }

    static func acceptsPointer(_ pointer: CGPoint, inCanvas canvasFrame: CGRect) -> Bool {
        guard [pointer.x, pointer.y].allSatisfy(\.isFinite) else { return false }
        return hitRect(in: canvasFrame).contains(pointer)
    }

    /// Guards pointer-initiated button/gesture activations to the central hit target
    /// while preserving keyboard and accessibility (`AXPress`) activation when `event`
    /// is nil or non-pointer.
    @MainActor
    static func currentEventAllowsHandleActivation(
        acceptsPointer: Bool,
        event: NSEvent? = NSApp.currentEvent
    ) -> Bool {
        guard let event else { return true }
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged,
             .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            return acceptsPointer
        default:
            return true
        }
    }
}

/// App-owned closed compact status cue shared between the main Sidekick panel
/// and secondary display handles without copying message or transcript body text.
nonisolated struct SidekickCompactCue: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case idle
        case pendingReview
        case voiceRecording
        case voiceFinishing
        case dictationReview
        case working(preparingModel: Bool)
        case resultReady
    }

    let kind: Kind
    let ownsDictation: Bool
    let hasResult: Bool

    static let idle = Self(kind: .idle, ownsDictation: false, hasResult: false)

    init(kind: Kind, ownsDictation: Bool = false, hasResult: Bool = false) {
        self.kind = kind
        self.ownsDictation = ownsDictation || kind == .dictationReview
        self.hasResult = hasResult || kind == .resultReady
    }

    @MainActor
    init(store: AssistantStore, ownsDictation: Bool, hasResult: Bool) {
        self.ownsDictation = ownsDictation
        self.hasResult = hasResult
        if store.pendingReview != nil {
            self.kind = .pendingReview
        } else if store.voice.isRecording {
            self.kind = .voiceRecording
        } else if store.voice.isBusy {
            self.kind = .voiceFinishing
        } else if store.isRunning {
            self.kind = .working(preparingModel: store.isPreparingModel)
        } else if ownsDictation {
            self.kind = .dictationReview
        } else if hasResult {
            self.kind = .resultReady
        } else {
            self.kind = .idle
        }
    }

    var isIdle: Bool { kind == .idle }
    var isActive: Bool { !isIdle }

    var title: String {
        switch kind {
        case .idle: "Relay Sidekick"
        case .pendingReview: "Review pending"
        case .voiceRecording: "Microphone on"
        case .voiceFinishing: "Finishing speech…"
        case .dictationReview: "Review dictation"
        case .working: "Relay is working"
        case .resultReady: "Result ready"
        }
    }

    var hardwareStatusLabel: String {
        switch kind {
        case .pendingReview: "Review"
        case .voiceRecording, .voiceFinishing, .dictationReview: "Dictation"
        case .working(let preparingModel): preparingModel ? "Starting" : "Working"
        case .resultReady: "All set"
        case .idle: "Sidekick"
        }
    }

    var showsMicrophoneIcon: Bool {
        kind == .voiceRecording
    }

    @MainActor
    var indicatorColor: Color {
        switch kind {
        case .voiceRecording: RelayColors.accentCoral
        case .pendingReview: RelayColors.accentAmber
        default: RelayColors.accentBlue
        }
    }

    func compactSurfaceSize(onNotchedDisplay: Bool) -> CGSize {
        if !onNotchedDisplay && isIdle {
            return SidekickRestingHandleLayout.canvasSize
        }
        return SidekickRestingHandleLayout.activeCompactSize
    }
}

/// Frosted obsidian resting handle capsule for notchless displays.
/// Performs no wallpaper/screen sampling and runs no timers or decorative animations in idle.
struct SidekickRestingHandleSurface: View {
    let hovered: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var size: CGSize {
        SidekickRestingHandleLayout.visibleSize(hovered: hovered)
    }

    var body: some View {
        let shape = Capsule(style: .continuous)
        shape
            .fill(Color.black.opacity(reduceTransparency ? 0.86 : 0.42))
            .overlay {
                LinearGradient(
                    colors: [
                        .white.opacity(hovered ? 0.28 : 0.18),
                        .white.opacity(0.05)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(
                    .white.opacity(hovered ? 0.34 : 0.24),
                    lineWidth: 0.5
                )
            }
            .frame(width: size.width, height: size.height)
            .shadow(
                color: .black.opacity(reduceTransparency ? 0 : (hovered ? 0.32 : 0.20)),
                radius: hovered ? 5 : 2.5,
                y: 1
            )
            .animation(
                reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.26, dampingFraction: 0.84),
                value: hovered
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

}

/// Transparent `96×24` canvas hosting the central `84×18` button and `72×6` / `84×9` visible handle.
struct SidekickRestingHandleButton: View {
    let hovered: Bool
    let accessibilityLabel: String
    let accessibilityIdentifier: String
    let action: () -> Void

    var body: some View {
        ZStack {
            Color.clear
                .frame(
                    width: SidekickRestingHandleLayout.canvasSize.width,
                    height: SidekickRestingHandleLayout.canvasSize.height
                )
                .allowsHitTesting(false)

            Button(action: action) {
                ZStack {
                    Color.clear
                    SidekickRestingHandleSurface(hovered: hovered)
                }
                .frame(
                    width: SidekickRestingHandleLayout.hitSize.width,
                    height: SidekickRestingHandleLayout.hitSize.height
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(
                width: SidekickRestingHandleLayout.hitSize.width,
                height: SidekickRestingHandleLayout.hitSize.height
            )
            .accessibilityLabel(accessibilityLabel)
            .accessibilityIdentifier(accessibilityIdentifier)
        }
        .frame(
            width: SidekickRestingHandleLayout.canvasSize.width,
            height: SidekickRestingHandleLayout.canvasSize.height
        )
    }
}

/// View-layer hit-test gate paired with window-level `ignoresMouseEvents` pointer gating.
///
/// Returning `nil` from `NSView.hitTest(_:)` prevents AppKit subview hit routing in the
/// transparent outer margins, while `NotchOverlayController`'s 30 Hz pointer poll sets
/// `panel.ignoresMouseEvents` for WindowServer click routing.
@MainActor
final class SidekickHitGatedHostingView<Content: View>: NSHostingView<Content> {
    var gatesToRestingHandleHitRect = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        if gatesToRestingHandleHitRect {
            let localPoint = superview == nil ? point : convert(point, from: superview)
            let allowed = SidekickRestingHandleLayout.localHitRect(in: bounds, isFlipped: isFlipped)
            guard allowed.contains(localPoint) else { return nil }
        }
        return super.hitTest(point)
    }
}
