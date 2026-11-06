import AppKit
import CoreGraphics
import ScreenCaptureKit

enum ScreenCaptureCheckState {
    case notRun
    case checking
    case blocked
    case passed
    case failed(String)
    case stopped

    var summary: String {
        switch self {
        case .notRun: "Not run. Uses macOS screen capture permission separately from Accessibility."
        case .checking: "Checking a screenshot of the Relay test window…"
        case .blocked: "Blocked. macOS screen capture permission is unavailable for this copy of Relay."
        case .passed: "Passed. Relay read the unique marker in a screenshot of the test window. The image was discarded."
        case .failed(let reason): "Failed. " + reason
        case .stopped: "Stopped. Screen capture was not verified."
        }
    }
}

@MainActor
enum ScreenCaptureCheck {
    private static let markerPrefix = "RELAY SCREEN CHECK "

    static func run(fixtureURL: URL) async throws -> AccessibilityCheckReport {
        try Task.checkCancellation()
        let bundleID = AccessibilityCheckRunner.fixtureBundleID
        guard Bundle(url: fixtureURL)?.bundleIdentifier == bundleID else {
            throw RelayError.message("The bundled Relay test app is missing or has the wrong identity.")
        }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else {
            throw RelayError.message("Close the existing Relay test window, then run this check again.")
        }

        let nonce = String(Int.random(in: 10_000...99_999))
        let title = "Relay Capture Fixture " + nonce
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.createsNewApplicationInstance = true
        config.environment = ["RELAY_FIXTURE_SCREEN_MARKER": nonce]
        let application = try await NSWorkspace.shared.openApplication(at: fixtureURL, configuration: config)
        defer { application.terminate() }
        guard application.bundleIdentifier == bundleID else {
            throw RelayError.message("The launched test app did not have the expected identity.")
        }

        let window = try await locateWindow(title: title, application: application, bundleID: bundleID)
        try Task.checkCancellation()
        let text = try await SidekickWindowText.recognize(window)
        try Task.checkCancellation()
        guard markerIsVisible(in: text, nonce: nonce) else {
            throw RelayError.message("The screenshot did not contain the test window’s unique marker.")
        }
        return AccessibilityCheckReport(cases: [
            .init(name: "Capture the test window", passed: true, evidence: ScreenCaptureCheckState.passed.summary)
        ])
    }

    static func markerIsVisible(in image: CGImage, nonce: String) async throws -> Bool {
        let text = try await LocalOCR.recognize(image: image, orientation: .up, preferCPU: true)
        return markerIsVisible(in: text, nonce: nonce)
    }

    private static func markerIsVisible(in text: String, nonce: String) -> Bool {
        let expected = normalized(markerPrefix + nonce)
        return text.split(whereSeparator: \.isNewline).contains { normalized(String($0)) == expected }
    }

    private static func normalized(_ text: String) -> String {
        text.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func locateWindow(title: String, application: NSRunningApplication, bundleID: String) async throws -> SCWindow {
        for attempt in 0..<10 {
            try Task.checkCancellation()
            guard !application.isTerminated else { throw RelayError.message("The Relay test app closed before capture.") }
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let matches = content.windows.filter { window in
                window.title == title &&
                    window.owningApplication?.processID == application.processIdentifier &&
                    window.owningApplication?.bundleIdentifier == bundleID
            }
            if matches.count == 1, let window = matches.first { return window }
            if matches.count > 1 { throw RelayError.message("More than one test window matched. No screenshot was taken.") }
            if attempt < 9 { try await Task.sleep(for: .milliseconds(120)) }
        }
        throw RelayError.message("The uniquely identified Relay test window was not available for capture.")
    }
}

extension AssistantStore {
    func runScreenCaptureCheck() async {
        guard !isRunning, !voice.isBusy else { return }
        // Unlike an explicit permission request, a blocked preflight does not launch a fixture,
        // enumerate windows, ask for a grant, or call ScreenCaptureKit.
        guard CGPreflightScreenCaptureAccess() else { screenCaptureCheckStatus = .blocked; return }
        guard let resources = Bundle.main.resourceURL else {
            screenCaptureCheckStatus = .failed("Relay’s bundled test resources are missing.")
            return
        }
        screenCaptureCheckStatus = .checking
        accessibilityCheckRunning = true
        defer { accessibilityCheckRunning = false; accessibilityCheckTask = nil }
        let fixtureURL = resources.appendingPathComponent("RelayAccessibilityFixture.app")
        do {
            let check = Task { try await ScreenCaptureCheck.run(fixtureURL: fixtureURL) }
            accessibilityCheckTask = check
            _ = try await check.value
            screenCaptureCheckStatus = .passed
        } catch is CancellationError {
            screenCaptureCheckStatus = .stopped
        } catch {
            screenCaptureCheckStatus = CGPreflightScreenCaptureAccess() ? .failed(error.localizedDescription) : .blocked
        }
    }
}
