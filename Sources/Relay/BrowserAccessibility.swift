import AppKit
import ApplicationServices
import Foundation

/// Chrome 156 activates its renderer tree after an application-level Enhanced UI
/// request settles for two seconds. Each repeated write restarts that debounce.
/// https://raw.githubusercontent.com/chromium/chromium/refs/tags/156.0.8078.80/chrome/browser/chrome_browser_application_mac.mm
@MainActor
final class BrowserAccessibility {
    struct Identity: Equatable {
        let processID: pid_t
        let launchedAt: Date
        let bundleURL: URL
    }

    enum Failure: LocalizedError {
        case accessibilityRequired, applicationChanged, applicationNotReady

        var errorDescription: String? {
            switch self {
            case .accessibilityRequired: "Reading browser content requires existing macOS Accessibility access."
            case .applicationChanged: "The selected Chrome process changed while preparing its accessible content. Inspect the intended browser again."
            case .applicationNotReady: "The selected Chrome window did not become ready for accessible content. Inspect the intended browser window and try again."
            }
        }
    }

    private struct Attempt {
        let identity: Identity
        let requestedAt: ContinuousClock.Instant
    }
    private static let shared = BrowserAccessibility()
    static let activationWait: Duration = .milliseconds(2_100)
    private var attempts: [pid_t: Attempt] = [:]
    private let now: @MainActor () -> ContinuousClock.Instant
    private let isCurrent: @MainActor (Identity) -> Bool
    private let waitUntilReady: @MainActor (Identity) async throws -> Void
    private let activate: @MainActor (Identity) throws -> Void
    private let wait: @MainActor (Duration) async throws -> Void

    init(now: @escaping @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now },
         isCurrent: @escaping @MainActor (Identity) -> Bool = { BrowserAccessibility.isCurrent($0) },
         waitUntilReady: @escaping @MainActor (Identity) async throws -> Void = { try await BrowserAccessibility.waitUntilReady($0) },
         activate: @escaping @MainActor (Identity) throws -> Void = { try BrowserAccessibility.activate($0) },
         wait: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.now = now
        self.isCurrent = isCurrent
        self.waitUntilReady = waitUntilReady
        self.activate = activate
        self.wait = wait
    }

    static func prepareContent(for application: NSRunningApplication) async throws {
        guard application.bundleIdentifier == "com.google.Chrome" else { return }
        guard AXIsProcessTrusted() else { throw Failure.accessibilityRequired }
        guard !application.isTerminated, let launchedAt = application.launchDate, let bundleURL = application.bundleURL else {
            throw Failure.applicationChanged
        }
        let identity = Identity(processID: application.processIdentifier, launchedAt: launchedAt,
                                bundleURL: bundleURL.resolvingSymlinksInPath().standardizedFileURL)
        try await shared.prepare(identity)
    }

    /// Cancellation preserves the original attempt. A later read waits only for the
    /// remaining debounce window and cannot keep postponing Chrome's activation.
    func prepare(_ identity: Identity) async throws {
        try Task.checkCancellation()
        guard isCurrent(identity) else { throw Failure.applicationChanged }
        if attempts[identity.processID]?.identity != identity {
            // A cold process may answer the activation write before its application
            // accessibility object is ready, losing the request. Observe its real
            // window and application role first; this does not navigate or focus it.
            try await waitUntilReady(identity)
            try Task.checkCancellation()
            guard isCurrent(identity) else { throw Failure.applicationChanged }
            // Another read can finish readiness while this one is suspended. Only
            // one of them may write, or Chromium's activation debounce restarts.
            if attempts[identity.processID]?.identity != identity {
                try activate(identity)
                attempts[identity.processID] = Attempt(identity: identity, requestedAt: now())
            }
        }
        guard let attempt = attempts[identity.processID], attempt.identity == identity else { throw Failure.applicationChanged }
        let elapsed = attempt.requestedAt.duration(to: now())
        let remaining = Self.activationWait - elapsed
        if remaining > .zero { try await wait(remaining) }
        try Task.checkCancellation()
        guard isCurrent(identity) else { throw Failure.applicationChanged }
    }

    private static func isCurrent(_ identity: Identity) -> Bool {
        guard let application = NSRunningApplication(processIdentifier: identity.processID), !application.isTerminated,
              application.bundleIdentifier == "com.google.Chrome", application.launchDate == identity.launchedAt,
              let bundleURL = application.bundleURL else { return false }
        return bundleURL.resolvingSymlinksInPath().standardizedFileURL == identity.bundleURL
    }

    private static func activate(_ identity: Identity) throws {
        guard AXIsProcessTrusted() else { throw Failure.accessibilityRequired }
        guard isCurrent(identity) else { throw Failure.applicationChanged }
        let application = AXUIElementCreateApplication(identity.processID)
        AXUIElementSetMessagingTimeout(application, 0.2)
        // Chromium changes its accessibility state before forwarding this request to
        // AppKit. The forwarded result can report notImplemented (-25208) or an
        // unsupported operation, so actual document readiness is verified by the
        // existing browser identity/readback code. cannotComplete is not accepted.
        let result = AXUIElementSetAttributeValue(application, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        try validateActivationStatus(result)
    }

    static func validateActivationStatus(_ result: AXError) throws {
        switch result {
        case .success, .notImplemented, .actionUnsupported, .attributeUnsupported: return
        case .apiDisabled: throw Failure.accessibilityRequired
        default: throw Failure.applicationNotReady
        }
    }

    private static func waitUntilReady(_ identity: Identity) async throws {
        let application = AXUIElementCreateApplication(identity.processID)
        AXUIElementSetMessagingTimeout(application, 0.1)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        repeat {
            try Task.checkCancellation()
            guard AXIsProcessTrusted() else { throw Failure.accessibilityRequired }
            guard isCurrent(identity) else { throw Failure.applicationChanged }
            var role: CFTypeRef?
            var window: CFTypeRef?
            if AXUIElementCopyAttributeValue(application, kAXRoleAttribute as CFString, &role) == .success,
               role as? String == kAXApplicationRole,
               AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &window) == .success,
               let window, CFGetTypeID(window) == AXUIElementGetTypeID() {
                let element = unsafeDowncast(window, to: AXUIElement.self)
                var owner: pid_t = 0
                guard AXUIElementGetPid(element, &owner) == .success, owner == identity.processID else {
                    throw Failure.applicationChanged
                }
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        } while ContinuousClock.now < deadline
        throw Failure.applicationNotReady
    }
}
