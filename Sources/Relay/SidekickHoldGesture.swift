import AppKit

nonisolated enum SidekickVoiceCommitPolicy {
    static func maySubmit(final: Bool, edited: Bool, localProvider: Bool, optedIn: Bool,
                          sameOrigin: Bool, promptUnchangedAndEmpty: Bool, cancelled: Bool) -> Bool {
        final && !edited && localProvider && optedIn && sameOrigin && promptUnchangedAndEmpty && !cancelled
    }
}

/// Native tracking survives a recording's content changes. Moving away cancels
/// the gesture rather than committing a voice task at an unexpected pointer-up.
@MainActor
final class SidekickHoldGesture: NSObject, NSGestureRecognizerDelegate {
    private let shouldBegin: @MainActor () -> Bool
    private let begin: @MainActor () -> Bool
    private let end: @MainActor (Bool) -> Void
    private let attached: @MainActor (NSView) -> Bool
    private let recognizer = NSPressGestureRecognizer()
    private weak var installedView: NSView?
    private var accepted = false
    private var armed = false
    private var detached = false
    private var revision: UInt64 = 0
    private var origin = CGPoint.zero

    init(view: NSView, shouldBegin: @escaping @MainActor () -> Bool,
         begin: @escaping @MainActor () -> Bool, end: @escaping @MainActor (Bool) -> Void,
         attached: @escaping @MainActor (NSView) -> Bool = { $0.window?.isVisible == true }) {
        self.shouldBegin = shouldBegin
        self.begin = begin
        self.end = end
        self.attached = attached
        installedView = view
        super.init()
        recognizer.target = self
        recognizer.action = #selector(changed(_:))
        recognizer.minimumPressDuration = 0.35
        recognizer.allowableMovement = 16
        recognizer.buttonMask = 1
        recognizer.delaysPrimaryMouseButtonEvents = true
        recognizer.delegate = self
        view.addGestureRecognizer(recognizer)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: NSGestureRecognizer) -> Bool {
        guard gestureRecognizer === recognizer, isAttached, !accepted, shouldBegin() else {
            cancel()
            return false
        }
        armed = true
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        // Reject before press tracking starts so ordinary composer clicks and
        // an opted-out handle do not wait for the hold-duration timer.
        gestureRecognizer === recognizer && isAttached && shouldBegin()
    }

    /// Cancel this press cycle. A later genuine delegate begin can arm a new one.
    func cancel() {
        finish(cancelled: true)
        guard !detached else { return }
        recognizer.isEnabled = false
        recognizer.isEnabled = true
    }

    /// Call before replacing a host or closing its panel. No late callback from
    /// this recognizer may start dictation after its owner releases the UI.
    func detach() {
        guard !detached else { return }
        detached = true
        recognizer.target = nil
        recognizer.delegate = nil
        recognizer.isEnabled = false
        recognizer.view?.removeGestureRecognizer(recognizer)
        installedView = nil
        finish(cancelled: true)
    }

    private var isAttached: Bool {
        guard !detached, let installedView, recognizer.view === installedView else { return false }
        return attached(installedView)
    }

    @objc private func changed(_ gesture: NSPressGestureRecognizer) {
        guard gesture === recognizer else { return }
        receive(state: gesture.state, location: NSEvent.mouseLocation)
    }

    /// Shares the native transition path with tests, without generating mouse
    /// events, opening a window, requesting permissions or using a microphone.
    func receive(state: NSGestureRecognizer.State, location: CGPoint) {
        if state == .cancelled || state == .failed { finish(cancelled: true); return }
        guard isAttached else { cancel(); return }
        switch state {
        case .began:
            guard armed, !accepted, shouldBegin() else { return }
            armed = false
            origin = location
            let expected = revision
            let didBegin = begin()
            // Beginning may synchronously replace the view or stop its owner.
            guard revision == expected, isAttached else {
                if didBegin { end(true) }
                return
            }
            accepted = didBegin
        case .changed:
            if accepted, hypot(location.x - origin.x, location.y - origin.y) > 20 {
                cancel()
            }
        case .ended:
            finish(cancelled: false)
        default: break
        }
    }

    private func finish(cancelled: Bool) {
        revision &+= 1
        armed = false
        let wasAccepted = accepted
        accepted = false
        if wasAccepted { end(cancelled) }
    }

    isolated deinit {
        recognizer.target = nil
        recognizer.delegate = nil
        recognizer.isEnabled = false
        recognizer.view?.removeGestureRecognizer(recognizer)
        if accepted { end(true) }
    }
}
