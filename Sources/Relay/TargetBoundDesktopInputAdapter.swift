import AppKit
import ApplicationServices
import Foundation

// MARK: - AUT-20: User & Agent Activity / Focus Conflict Guard

nonisolated enum FocusConflictStatus: Sendable, Equatable, CustomStringConvertible {
    case clean
    case userSwitchedApplication(currentPID: pid_t)
    case userSwitchedWindow(currentWindowTitle: String)
    case userRecentActivity(timeSinceLastInput: TimeInterval)

    var isConflict: Bool { self != .clean }

    var description: String {
        switch self {
        case .clean: return "Clean: no user focus conflict"
        case .userSwitchedApplication(let pid): return "Conflict: user switched application to PID \(pid)"
        case .userSwitchedWindow(let title): return "Conflict: user switched window to '\(title)'"
        case .userRecentActivity(let interval): return "Conflict: recent user keyboard/mouse activity (\(interval)s ago)"
        }
    }
}

final class NativeFocusConflictGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var lastUserActivityTimestamp: Date?
    private let activeAppProvider: @Sendable () -> pid_t?
    private let activeWindowProvider: @Sendable () -> String?

    init(activeAppProvider: @escaping @Sendable () -> pid_t? = {
            MainActor.assumeIsolated { NSWorkspace.shared.frontmostApplication?.processIdentifier }
         },
         activeWindowProvider: @escaping @Sendable () -> String? = { nil }) {
        self.activeAppProvider = activeAppProvider
        self.activeWindowProvider = activeWindowProvider
    }

    func recordUserActivity() {
        lock.lock()
        defer { lock.unlock() }
        lastUserActivityTimestamp = Date()
    }

    func checkConflict(boundPID: pid_t, boundWindowTitle: String, quietPeriod: TimeInterval = 0.5) -> FocusConflictStatus {
        lock.lock()
        defer { lock.unlock() }
        if let currentPID = activeAppProvider(), currentPID != boundPID {
            return .userSwitchedApplication(currentPID: currentPID)
        }
        if let currentTitle = activeWindowProvider(), currentTitle != boundWindowTitle {
            return .userSwitchedWindow(currentWindowTitle: currentTitle)
        }
        if let last = lastUserActivityTimestamp {
            let elapsed = Date().timeIntervalSince(last)
            if elapsed < quietPeriod {
                return .userRecentActivity(timeSinceLastInput: elapsed)
            }
        }
        return .clean
    }
}

// MARK: - AUT-17: Target-Bound Desktop Input Adapter

@MainActor
final class TargetBoundDesktopInputAdapter {
    enum Failure: Error, Equatable, CustomStringConvertible {
        case wrongWindow(expected: String, observed: String)
        case wrongProcess(expected: pid_t, observed: pid_t)
        case secureFieldProhibited
        case cancelled
        case outOfBounds(point: CGPoint, windowBounds: CGRect)
        case executionFailed(String)
        case focusConflict(FocusConflictStatus)

        var description: String {
            switch self {
            case .wrongWindow(let expected, let observed):
                return "Refused: Target window mismatch (expected: '\(expected)', observed: '\(observed)')"
            case .wrongProcess(let expected, let observed):
                return "Refused: Target process ID mismatch (expected: \(expected), observed: \(observed))"
            case .secureFieldProhibited:
                return "Refused: Target is an NSSecureTextField or password field. Automated input and reading are strictly prohibited; 0 protected bytes exposed."
            case .cancelled:
                return "Refused: The desktop automation task was cancelled before event dispatch."
            case .outOfBounds(let point, let bounds):
                return "Refused: Proposed coordinates (\(point.x), \(point.y)) lie outside target window bounds \(bounds)."
            case .executionFailed(let reason):
                return "Execution failed: \(reason)"
            case .focusConflict(let conflict):
                return "Refused due to user focus conflict: \(conflict)"
            }
        }
    }

    struct BoundsCheck: Sendable, Equatable {
        let windowFrame: CGRect

        func validate(point: CGPoint) -> Bool {
            point.x >= 0 && point.x <= windowFrame.width && point.y >= 0 && point.y <= windowFrame.height
        }
    }

    let targetIdentity: DesktopApplicationIdentity
    let targetWindow: TargetBoundNativeObservation.WindowInfo
    private(set) var dispatchedClicks = 0
    private(set) var dispatchedDrags = 0
    private(set) var dispatchedKeys = 0
    private(set) var lastDispatchedPoint: CGPoint?
    private(set) var lastDispatchedDrag: (start: CGPoint, end: CGPoint)?
    private(set) var lastDispatchedKey: NativeControlKey?

    init(targetIdentity: DesktopApplicationIdentity, targetWindow: TargetBoundNativeObservation.WindowInfo) {
        self.targetIdentity = targetIdentity
        self.targetWindow = targetWindow
    }

    /// Verifies safety fences before any pointer click.
    func dispatchClick(at point: CGPoint,
                       activeWindow: TargetBoundNativeObservation.WindowInfo,
                       activeProcessID: pid_t,
                       isSecureFieldFocused: Bool,
                       isCancelled: Bool = false,
                       conflictGuard: NativeFocusConflictGuard? = nil) throws {
        // 1. Cancellation fence
        if isCancelled || Task.isCancelled {
            throw Failure.cancelled
        }

        // 2. Process fence
        guard activeProcessID == targetIdentity.processID else {
            throw Failure.wrongProcess(expected: targetIdentity.processID, observed: activeProcessID)
        }

        // 3. Window fence
        guard activeWindow.matchesExactly(targetWindow) else {
            throw Failure.wrongWindow(expected: targetWindow.title, observed: activeWindow.title)
        }

        // 4. Secure field fence: Zero tolerance, zero protected bytes read or exposed
        guard !isSecureFieldFocused else {
            throw Failure.secureFieldProhibited
        }

        // 5. Bounds fence: Disallow clicks outside target window
        let bounds = CGRect(x: 0, y: 0, width: targetWindow.width, height: targetWindow.height)
        guard BoundsCheck(windowFrame: bounds).validate(point: point) else {
            throw Failure.outOfBounds(point: point, windowBounds: bounds)
        }

        // 6. User focus conflict guard (AUT-20)
        if let conflictGuard {
            let status = conflictGuard.checkConflict(boundPID: targetIdentity.processID, boundWindowTitle: targetWindow.title)
            guard status == .clean else {
                throw Failure.focusConflict(status)
            }
        }

        // Dispatch click
        dispatchedClicks += 1
        lastDispatchedPoint = point
    }

    /// Verifies safety fences before any drag operation.
    func dispatchDrag(from start: CGPoint,
                      to end: CGPoint,
                      activeWindow: TargetBoundNativeObservation.WindowInfo,
                      activeProcessID: pid_t,
                      isSecureFieldFocused: Bool,
                      isCancelled: Bool = false,
                      conflictGuard: NativeFocusConflictGuard? = nil) throws {
        if isCancelled || Task.isCancelled {
            throw Failure.cancelled
        }
        guard activeProcessID == targetIdentity.processID else {
            throw Failure.wrongProcess(expected: targetIdentity.processID, observed: activeProcessID)
        }
        guard activeWindow.matchesExactly(targetWindow) else {
            throw Failure.wrongWindow(expected: targetWindow.title, observed: activeWindow.title)
        }
        guard !isSecureFieldFocused else {
            throw Failure.secureFieldProhibited
        }
        let bounds = CGRect(x: 0, y: 0, width: targetWindow.width, height: targetWindow.height)
        let checker = BoundsCheck(windowFrame: bounds)
        guard checker.validate(point: start) else {
            throw Failure.outOfBounds(point: start, windowBounds: bounds)
        }
        guard checker.validate(point: end) else {
            throw Failure.outOfBounds(point: end, windowBounds: bounds)
        }
        if let conflictGuard {
            let status = conflictGuard.checkConflict(boundPID: targetIdentity.processID, boundWindowTitle: targetWindow.title)
            guard status == .clean else {
                throw Failure.focusConflict(status)
            }
        }

        dispatchedDrags += 1
        lastDispatchedDrag = (start, end)
    }

    /// Verifies safety fences before any navigation key dispatch.
    func dispatchKey(_ key: NativeControlKey,
                     activeWindow: TargetBoundNativeObservation.WindowInfo,
                     activeProcessID: pid_t,
                     isSecureFieldFocused: Bool,
                     isCancelled: Bool = false,
                     conflictGuard: NativeFocusConflictGuard? = nil) throws {
        if isCancelled || Task.isCancelled {
            throw Failure.cancelled
        }
        guard activeProcessID == targetIdentity.processID else {
            throw Failure.wrongProcess(expected: targetIdentity.processID, observed: activeProcessID)
        }
        guard activeWindow.matchesExactly(targetWindow) else {
            throw Failure.wrongWindow(expected: targetWindow.title, observed: activeWindow.title)
        }
        guard !isSecureFieldFocused else {
            throw Failure.secureFieldProhibited
        }
        if let conflictGuard {
            let status = conflictGuard.checkConflict(boundPID: targetIdentity.processID, boundWindowTitle: targetWindow.title)
            guard status == .clean else {
                throw Failure.focusConflict(status)
            }
        }

        dispatchedKeys += 1
        lastDispatchedKey = key
    }
}

// MARK: - AUT-18: Vision Action and Recovery Loop

@MainActor
final class NativeVisionRecoveryLoop {
    enum StepResult: Sendable, Equatable {
        case success(markerFound: String, readbackVerified: Bool)
        case recovered(markerFound: String, readbackVerified: Bool, attempts: Int)
        case failed(reason: String)
    }

    struct CanvasState: Sendable, Equatable {
        let canvasFrame: CGRect
        let marker: String
        let markerPoint: CGPoint
    }

    /// Executes canvas visual action with recovery loop:
    /// Captures initial state, performs target-bound action, verifies readback.
    /// If layout changes or marker shifts, initiates recovery pass.
    static func executeVisualActionWithRecovery(
        initialState: CanvasState,
        currentStateProvider: () -> CanvasState,
        adapter: TargetBoundDesktopInputAdapter,
        activeWindow: TargetBoundNativeObservation.WindowInfo,
        activeProcessID: pid_t,
        maxAttempts: Int = 3
    ) throws -> StepResult {
        var attempts = 0
        var lastObservedMarker = ""

        while attempts < maxAttempts {
            attempts += 1
            let current = currentStateProvider()
            lastObservedMarker = current.marker

            // Check if layout shifted from initial expected canvas frame or marker point
            let layoutShifted = current.canvasFrame != initialState.canvasFrame
                || current.markerPoint != initialState.markerPoint

            // Execute target-bound pointer click on marker
            do {
                try adapter.dispatchClick(
                    at: current.markerPoint,
                    activeWindow: activeWindow,
                    activeProcessID: activeProcessID,
                    isSecureFieldFocused: false
                )
            } catch {
                if attempts >= maxAttempts {
                    return .failed(reason: "Dispatch failed: \(error)")
                }
                continue
            }

            // Independent readback verification
            let readback = currentStateProvider()
            let readbackVerified = (readback.marker == current.marker)

            if layoutShifted {
                return .recovered(markerFound: current.marker, readbackVerified: readbackVerified, attempts: attempts)
            } else {
                return .success(markerFound: current.marker, readbackVerified: readbackVerified)
            }
        }

        return .failed(reason: "Exceeded max recovery attempts (\(maxAttempts)) for marker '\(lastObservedMarker)'")
    }
}
