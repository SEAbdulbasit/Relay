import AppKit
import ApplicationServices
import Foundation

/// Explicit reviewed focus only. Construction retains the original process and
/// actual AX window; it never looks up a replacement by title or a current tab.
/// The controller must first bind the authorization to this exact proposal's
/// retained source/context. Calling this helper is itself an effect phase.
@MainActor final class NativeOriginalWindowFocus {
    nonisolated enum ExactDisposition: Sendable, Equatable { case alreadyFocused, restored, refused, uncertain }
    nonisolated enum ExactStep: String, Sendable, Hashable { case activateOriginal, raiseOriginal, selectOriginal }
    nonisolated enum ExactStepState: Sendable, Equatable { case admitted, returned }
    nonisolated struct ExactStepFact: Sendable, Equatable {
        let step: ExactStep
        let state: ExactStepState
    }
    /// Produced only around the actual gate-admitted operations below. No
    /// callback/report from a caller can manufacture this composite fact.
    nonisolated struct ExactReport: Sendable, Equatable {
        let disposition: ExactDisposition
        let steps: [ExactStepFact]
        fileprivate init(disposition: ExactDisposition, steps: [ExactStepFact]) {
            self.disposition = disposition; self.steps = steps
        }
        var verified: Bool {
            NativeOriginalWindowFocus.exactCoverageIsComplete(disposition: disposition, steps: steps)
        }
    }
    /// Data-only completeness predicate, not a report/source/permission maker.
    nonisolated static func exactCoverageIsComplete(disposition: ExactDisposition, steps: [ExactStepFact]) -> Bool {
        guard steps.allSatisfy({ $0.state == .returned }) else { return false }
        switch disposition {
        case .alreadyFocused: return steps.isEmpty
        case .restored:
            let actual = steps.map(\.step)
            return actual == [.raiseOriginal] || actual == [.activateOriginal, .raiseOriginal]
                || actual == [.raiseOriginal, .selectOriginal]
                || actual == [.activateOriginal, .raiseOriginal, .selectOriginal]
        case .refused, .uncertain: return false
        }
    }
    @MainActor private final class ExactRecorder {
        var steps: [ExactStepFact] = []
        func perform(_ step: ExactStep, deadline: ContinuousClock.Instant,
                     operation: @MainActor (ContinuousClock.Instant) throws -> Void) throws {
            // The finite core invokes this wrapper only AFTER its actual gate
            // admitted the operation. Even a thrown operation remains a fact.
            let index = steps.count
            steps.append(.init(step: step, state: .admitted))
            try operation(deadline)
            steps[index] = .init(step: step, state: .returned)
        }
    }
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

    /// The direct permit is Controller-minted from the actual acknowledged
    /// literal/original anchor, never an invented ordinary PolicyContext.
    /// Reuse the exact finite restoration core, including its admission gates.
    func restoreExactUnsent(authorization: NativeControlSession.ExactUnsentFocusPermit,
                            gate: NativeInputRevocation,
                            notAfter: ContinuousClock.Instant) async -> ExactReport {
        guard authorization.sourceID == sourceID else { return .init(disposition: .refused, steps: []) }
        let recorder = ExactRecorder()
        let select: (@MainActor (ContinuousClock.Instant) throws -> Void)?
        if let original = io.selectOriginal {
            select = { deadline in try recorder.perform(.selectOriginal, deadline: deadline, operation: original) }
        } else { select = nil }
        let actual = NativeOriginalWindowFocus(sourceID: sourceID, io: IO(
            validateOriginalSource: io.validateOriginalSource, validateForInput: io.validateForInput,
            sessionIsActive: io.sessionIsActive,
            isOriginalApplicationForeground: io.isOriginalApplicationForeground,
            isOriginalInputFocused: io.isOriginalInputFocused,
            qualifyFocusOperations: io.qualifyFocusOperations,
            activateOriginal: { deadline in
                try recorder.perform(.activateOriginal, deadline: deadline, operation: self.io.activateOriginal)
            }, raiseOriginal: { deadline in
                try recorder.perform(.raiseOriginal, deadline: deadline, operation: self.io.raiseOriginal)
            }, selectOriginal: select, now: io.now, pause: io.pause))
        let result = await actual.restore(review: Review(sourceID: sourceID,
            validateOriginalScope: { try authorization.validate() },
            admitOriginalFocusOnce: { try authorization.consume() }), gate: gate, notAfter: notAfter)
        let disposition: ExactDisposition
        switch result {
        case .alreadyFocused: disposition = .alreadyFocused
        case .restored: disposition = .restored
        case .notRequested, .refused: disposition = recorder.steps.isEmpty ? .refused : .uncertain
        case .uncertain: disposition = .uncertain
        }
        return .init(disposition: disposition, steps: recorder.steps)
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
