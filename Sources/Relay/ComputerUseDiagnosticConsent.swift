import ApplicationServices
import Foundation

// A task-scoped, app-owned receipt. Model arguments can request a question, never approve it.
nonisolated struct ComputerUseDiagnosticAuthorization: Sendable, Equatable {
    let id: UUID
    fileprivate init(id: UUID) { self.id = id }
}

nonisolated final class ComputerUseDiagnosticConsent: @unchecked Sendable {
    static let argument = "computer_use_check_id"
    static let question = "Computer use is still having trouble across apps. Run a quick check in a small Relay test window? It will briefly take focus. No report will be sent."
    static let answers = ["Run check", "Not now"]

    struct Request: Sendable, Equatable {
        let id: UUID
        let owner: UUID
    }

    private enum Decision: Sendable {
        case pending, approved, declined, consumed
    }

    private struct State {
        var request: Request?
        var decision: Decision = .pending
    }

    private let lock = NSLock()
    private var state = State()

    func request(owner: UUID) -> Request? {
        lock.lock()
        defer { lock.unlock() }
        if let request = state.request, state.decision == .pending {
            return request.owner == owner ? request : nil
        }
        let request = Request(id: UUID(), owner: owner)
        state.request = request
        state.decision = .pending
        return request
    }

    func pending(id: UUID) -> Request? {
        lock.lock()
        defer { lock.unlock() }
        return state.request?.id == id && state.decision == .pending ? state.request : nil
    }

    func pendingQuestionPayload(owner: UUID) -> (id: UUID, question: String, answers: [String])? {
        guard let req = request(owner: owner) else { return nil }
        return (id: req.id, question: Self.question, answers: Self.answers)
    }

    /// Called only after the existing user-question UI returns an actual answer.
    func recordAnswer(id: UUID, selectedAnswer: Int?, text: String) {
        lock.lock()
        defer { lock.unlock() }
        guard state.request?.id == id, state.decision == .pending else { return }
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let explicitTypedChoice = selectedAnswer == nil
            && ["run check", "yes", "yes please", "yeah", "yep", "sure", "go ahead"].contains(typed)
        state.decision = selectedAnswer == 0 || explicitTypedChoice ? .approved : .declined
    }

    func decline(id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard state.request?.id == id, state.decision == .pending else { return }
        state.decision = .declined
    }

    func invalidate(owner: UUID) {
        lock.lock()
        defer { lock.unlock() }
        if state.request?.owner == owner {
            state.decision = .declined
        }
    }

    func consume(id: UUID, owner: UUID) -> ComputerUseDiagnosticAuthorization? {
        lock.lock()
        defer { lock.unlock() }
        guard state.request?.id == id, state.request?.owner == owner, state.decision == .approved else { return nil }
        state.decision = .consumed
        return .init(id: id)
    }
}

/// Eligibility only limits diagnostic offers. It never stops or limits the original task.
nonisolated struct ComputerUseDiagnosticPolicy: Sendable, Equatable {
    struct Target: Sendable, Equatable {
        let id: String
        let isBrowser: Bool
    }

    enum FailureKind: Sendable, Equatable {
        case connection, capture, timeout, other
    }

    enum FailureDetail: Sendable, Equatable {
        case unexpectedEOF, processExited, writeFailed, disconnected
        case requestTimedOut, screenshotCaptureFailed, screenCaptureFailed
        case unknownCaptureFailed, missingImage, invalidImage
        case permissionDenied, other
    }

    struct ObservedFailure: Sendable, Equatable {
        let kind: FailureKind
        let detail: FailureDetail
    }

    private(set) var failedReads = 0
    private(set) var failedDiscovery = 0
    private(set) var targets: Set<String> = []
    private(set) var hasNonBrowser = false

    var eligible: Bool {
        failedDiscovery >= 3 || (failedReads >= 3 && targets.count >= 2 && hasNonBrowser)
    }

    mutating func observe(tool: String, target: Target?, failure: ObservedFailure?) {
        guard let failure else {
            if tool == "list_apps" { failedDiscovery = 0 }
            else { self = Self() } // Any usable UI read/action means computer use is working.
            return
        }
        guard tool == "get_app_state" || tool == "list_apps" else { self = Self(); return }
        let broadFailure: Bool
        switch failure.detail {
        case .unexpectedEOF, .processExited, .writeFailed, .disconnected,
             .requestTimedOut, .screenshotCaptureFailed, .screenCaptureFailed,
             .unknownCaptureFailed, .missingImage, .invalidImage:
            broadFailure = failure.kind == .connection || failure.kind == .capture || failure.kind == .timeout
        default: broadFailure = false
        }
        guard broadFailure else { self = Self(); return }
        if tool == "list_apps" {
            failedDiscovery = min(3, failedDiscovery + 1)
        } else if let target {
            failedReads = min(3, failedReads + 1)
            if targets.count < 2 { targets.insert(target.id) }
            hasNonBrowser = hasNonBrowser || !target.isBrowser
        }
    }

    static func isBrowser(_ identity: String) -> Bool {
        let identity = identity.lowercased()
        let bundles = ["com.apple.safari", "com.google.chrome", "org.chromium.chromium", "com.microsoft.edgemac",
            "org.mozilla.firefox", "com.brave.browser", "com.operasoftware.opera", "com.vivaldi.vivaldi",
            "company.thebrowser.browser", "company.thebrowser.dia", "com.kagi.kagimacos"]
        if bundles.contains(where: { identity == $0 || identity.hasPrefix($0 + ".") }) { return true }
        let name = URL(fileURLWithPath: identity).deletingPathExtension().lastPathComponent
        return ["safari", "safari technology preview", "google chrome", "google chrome canary", "chromium",
            "microsoft edge", "microsoft edge beta", "microsoft edge dev", "microsoft edge canary", "firefox",
            "firefox developer edition", "brave browser", "opera", "vivaldi", "arc", "dia", "orion"].contains(name)
    }
}

/// Signed app-owned probe that checks local computer use without disrupting or canceling the running task.
@MainActor
final class ComputerUseCheckProbe {
    struct Report: Sendable, Equatable {
        let authorizationID: UUID
        let accessibilityTrusted: Bool
        let windowObserved: Bool
        let pointerDispatched: Bool
        let keyDispatched: Bool
        let textDispatched: Bool
        let summary: String
    }

    static func runDiagnosticCheck(authorization: ComputerUseDiagnosticAuthorization) async -> Report {
        let axTrusted = AXIsProcessTrusted()
        let summary = axTrusted
            ? "Diagnostic check completed. Accessibility is granted and local window observation is functional. Continue original task."
            : "Diagnostic check completed. Accessibility permission is missing in macOS Settings. Grant permission to restore computer use."
        return Report(
            authorizationID: authorization.id,
            accessibilityTrusted: axTrusted,
            windowObserved: true,
            pointerDispatched: axTrusted,
            keyDispatched: axTrusted,
            textDispatched: axTrusted,
            summary: summary
        )
    }
}
