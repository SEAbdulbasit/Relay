import AppKit
import ApplicationServices
import Foundation

/// Explicit reviewed focus only. Construction retains the original process and
/// actual AX window; it never looks up a replacement by title or a current tab.
/// The controller must first bind the authorization to this exact proposal's
/// retained source/context. Calling this helper is itself an effect phase.
@MainActor final class NativeOriginalWindowFocus {
    struct IO {
        let validateOriginalSource: @MainActor () throws -> Void
        let validateForInput: @MainActor () throws -> Void
        let sessionIsActive: @MainActor () -> Bool
        let isOriginalApplicationForeground: @MainActor () -> Bool
        let isOriginalInputFocused: @MainActor (ContinuousClock.Instant) throws -> Bool
        let qualifyFocusOperations: @MainActor (ContinuousClock.Instant) throws -> Void
        let activateOriginal: @MainActor (ContinuousClock.Instant) throws -> Void
        let raiseOriginal: @MainActor (ContinuousClock.Instant) throws -> Void
        let selectOriginal: (@MainActor (ContinuousClock.Instant) throws -> Void)?
        let now: @MainActor () -> ContinuousClock.Instant
        let pause: @MainActor (Duration) async throws -> Void
    }
    /// Pure finite-IO seam. Only trusted policy/controller code supplies these
    /// callbacks; source/model data cannot construct executable callbacks.
    struct Review {
        let sourceID: UUID
        let validateOriginalScope: @MainActor () throws -> Void
        let admitOriginalFocusOnce: @MainActor () throws -> Void
    }
    private enum Failure: LocalizedError {
        case inactive, expired, changed, unsupported, activation, ax
        var errorDescription: String? {
            switch self {
            case .inactive: "The task or native input owner stopped."
            case .expired: "The original native reservation expired."
            case .changed: "The retained original process, window or focus changed."
            case .unsupported: "The original window does not expose the required finite focus operations."
            case .activation: "The original process did not accept activation."
            case .ax: "The retained original window did not accept its focus operation."
            }
        }
    }
    private let io: IO
    private let sourceID: UUID
    init(sourceID: UUID, io: IO) { self.sourceID = sourceID; self.io = io }

    convenience init(sourceID: UUID, application: NSRunningApplication, identity: DesktopApplicationIdentity,
                     originalWindow: AXUIElement,
                     validateOriginalSource: @escaping @MainActor () throws -> Void,
                     validateForInput: @escaping @MainActor () throws -> Void,
                     sessionIsActive: @escaping @MainActor () -> Bool) {
        let root = AXUIElementCreateApplication(identity.processID)
        let clock = ContinuousClock()
        let validate: @MainActor () throws -> Void = {
            try validateOriginalSource()
            guard DesktopApplicationTarget.matches(identity, application: application) else { throw Failure.changed }
            var pid: pid_t = 0
            guard AXUIElementGetPid(originalWindow, &pid) == .success, pid == identity.processID else { throw Failure.changed }
        }
        let limit: @MainActor (AXUIElement, ContinuousClock.Instant) throws -> Void = { element, deadline in
            let remaining = clock.now.duration(to: deadline).components
            let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
            guard seconds > 0 else { throw Failure.expired }
            guard AXUIElementSetMessagingTimeout(element, Float(min(seconds, 0.1))) == .success else { throw Failure.unsupported }
        }
        self.init(sourceID: sourceID, io: IO(validateOriginalSource: validate, validateForInput: validateForInput,
            sessionIsActive: sessionIsActive,
            isOriginalApplicationForeground: { NSWorkspace.shared.frontmostApplication?.processIdentifier == identity.processID },
            isOriginalInputFocused: { deadline in
                try validate(); try limit(root, deadline)
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == identity.processID else { return false }
                var selected: CFTypeRef?
                guard AXUIElementCopyAttributeValue(root, kAXFocusedWindowAttribute as CFString, &selected) == .success,
                      let selected, CFGetTypeID(selected) == AXUIElementGetTypeID() else { throw Failure.changed }
                guard CFEqual(selected, originalWindow) else { return false }
                try validateForInput()
                return true
            }, qualifyFocusOperations: { deadline in
                try validate(); try limit(originalWindow, deadline); try limit(root, deadline)
                var actions: CFArray?
                guard AXUIElementCopyActionNames(originalWindow, &actions) == .success,
                      let names = actions as? [String], names.contains(kAXRaiseAction) else { throw Failure.unsupported }
            }, activateOriginal: { _ in
                // No activateAllWindows, open/relaunch or replacement process.
                guard application.activate(options: []) else { throw Failure.activation }
            }, raiseOriginal: { deadline in
                try limit(originalWindow, deadline)
                guard AXUIElementPerformAction(originalWindow, kAXRaiseAction as CFString) == .success else { throw Failure.ax }
            }, selectOriginal: nil, now: { clock.now }, pause: { try await Task.sleep(for: $0) }))
    }

    func restore(authorization: NativeReviewedFocusAuthorization, gate: NativeInputRevocation,
                 notAfter: ContinuousClock.Instant) async -> NativeReviewedFocusOutcome {
        await restore(review: Review(sourceID: authorization.sourceID, validateOriginalScope: { try authorization.validateOriginalScope() },
            admitOriginalFocusOnce: { try authorization.admitOriginalFocusOnce() }), gate: gate, notAfter: notAfter)
    }

    func restore(review: Review, gate: NativeInputRevocation,
                 notAfter: ContinuousClock.Instant) async -> NativeReviewedFocusOutcome {
        guard review.sourceID == sourceID else { return .refused("The review belongs to a different original source.") }
        var attempted = false
        func check() throws {
            try Task.checkCancellation()
            guard io.sessionIsActive(), gate.isActive else { throw Failure.inactive }
            guard io.now() < notAfter else { throw Failure.expired }
            try io.validateOriginalSource(); try review.validateOriginalScope()
            try Task.checkCancellation()
            guard io.sessionIsActive(), gate.isActive else { throw Failure.inactive }
            guard io.now() < notAfter else { throw Failure.expired }
        }
        func effect(_ operation: @MainActor (ContinuousClock.Instant) throws -> Void) throws {
            try check()
            // The shared client-close/Stop gate linearizes each focus admission.
            // A later revocation cannot turn an admitted effect into no effect.
            try Task.checkCancellation()
            guard gate.ticket().admit(now: io.now(), notAfter: notAfter) == .admitted else { throw Failure.inactive }
            attempted = true
            try operation(notAfter)
            try check()
        }
        do {
            try check()
            if try io.isOriginalInputFocused(notAfter) {
                try io.validateForInput(); try check()
                return .alreadyFocused
            }
            try io.qualifyFocusOperations(notAfter); try check()
            try review.admitOriginalFocusOnce(); try check()
            if !io.isOriginalApplicationForeground() { try effect(io.activateOriginal) }
            try effect(io.raiseOriginal)
            // The real binding uses AXRaise and verifies its focused-window
            // result. No read-only AX attribute is assumed to be writable.
            if let selectOriginal = io.selectOriginal { try effect(selectOriginal) }
            while true {
                try check()
                if try io.isOriginalInputFocused(notAfter) {
                    try io.validateForInput(); try check()
                    return .restored
                }
                // Uses the existing reservation's deadline; never creates a new
                // retry budget or selects a different window while waiting.
                try await io.pause(min(.milliseconds(20), io.now().duration(to: notAfter)))
            }
        } catch {
            let reason = NativeVisualStepOutcome.bounded(error.localizedDescription)
            return attempted ? .uncertain(reason) : .refused(reason)
        }
    }
}
