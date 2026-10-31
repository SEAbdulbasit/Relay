import AppKit
import ApplicationServices
import Foundation

nonisolated struct AccessibilityCaseResult: Codable, Sendable {
    var name: String
    var passed: Bool
    var evidence: String
}
nonisolated struct AccessibilityCheckReport: Codable, Sendable {
    var cases: [AccessibilityCaseResult]
    var allPassed: Bool { !cases.isEmpty && cases.allSatisfy(\.passed) }
    var summary: String { cases.map { "\($0.passed ? "PASS" : "FAIL") · \($0.name): \($0.evidence)" }.joined(separator: "\n") }
}

/// Exercises real AX tools against a separate, harmless native process, independently of Gemma.
@MainActor
enum AccessibilityCheckRunner {
    static let fixtureBundleID = "dev.relay.accessibility-fixture"
    private struct Oracle: Decodable {
        let input: String
        let result: String
        let clickCount: Int
        let launchToken: String
    }

    static func run(fixtureURL: URL) async throws -> AccessibilityCheckReport {
        guard AXIsProcessTrusted() else { throw RelayError.message("Not run: enable Accessibility for Relay in System Settings, relaunch Relay, then run this check. Permission has not been granted automatically.") }
        guard Bundle(url: fixtureURL)?.bundleIdentifier == fixtureBundleID else { throw RelayError.message("The bundled accessibility fixture is missing or has the wrong identity. Rebuild with Scripts/build-app.sh.") }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: fixtureBundleID).isEmpty else { throw RelayError.message("Close the existing Relay Accessibility Fixture window before starting another check.") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-ax-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let oracleURL = directory.appendingPathComponent("state.json")
        let token = UUID().uuidString
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.environment = ["RELAY_FIXTURE_STATE_PATH": oracleURL.path, "RELAY_FIXTURE_TOKEN": token]
        let application = try await NSWorkspace.shared.openApplication(at: fixtureURL, configuration: config)
        defer { application.terminate() }
        for _ in 0..<30 {
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: oracleURL.path) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let initial = try oracle(oracleURL, token: token)
        guard initial.clickCount == 0, initial.result == "Not applied" else { throw RelayError.message("The fixture was not in its clean initial state.") }
        let tools = MacTools()
        var report = AccessibilityCheckReport(cases: [])
        let first = try await observe(tools)
        let field = try controlID("relay.fixture.input", in: first.summary)
        let oldButton = try controlID("relay.fixture.apply", in: first.summary)
        report.cases.append(.init(name: "Observe native controls", passed: true, evidence: "Found stable input/button identifiers in a separate process; independent launch token matched."))
        let expected = "Relay AX check 🌍"
        let entered = try await tools.execute(call("set_value", field, ["value": .string(expected)]))
        guard entered.verified else { throw RelayError.message("AX text readback was not verified.") }
        report.cases.append(.init(name: "Type and read back", passed: true, evidence: entered.evidence))
        var staleRejected = false
        do { try tools.prepareReview(call("press_control", oldButton)) }
        catch is CancellationError { throw CancellationError() }
        catch {
            guard error.localizedDescription.contains("stale") else { throw error }
            staleRejected = true
        }
        guard staleRejected else { throw RelayError.message("A pre-typing button token was accepted after mutation.") }
        report.cases.append(.init(name: "Reject stale token", passed: true, evidence: "Typing invalidated the previous button observation."))
        let fresh = try await observe(tools)
        let button = try controlID("relay.fixture.apply", in: fresh.summary)
        let click = call("press_control", button)
        try tools.prepareReview(click)
        try tools.authorize(click)
        let dispatched = try await tools.execute(click)
        guard !dispatched.verified else { throw RelayError.message("A button dispatch was incorrectly treated as outcome verification.") }
        for _ in 0..<20 {
            if let state = try? oracle(oracleURL, token: token), state.clickCount == 1 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let after = try await observe(tools)
        let state = try oracle(oracleURL, token: token)
        let resultLine = try controlLine("relay.fixture.result", in: after.summary)
        guard state.input == expected, state.result == expected, state.clickCount == 1, resultLine.contains(expected) else {
            throw RelayError.message("Click returned but the independent result did not match exactly once.")
        }
        report.cases.append(.init(name: "Click and verify effect", passed: true, evidence: "Fresh AX result and separate fixture JSON both matched; clickCount=1."))
        guard try controlLine("relay.fixture.disabled", in: after.summary).contains("enabled=false") else { throw RelayError.message("The negative fixture control was not actually disabled.") }
        let disabled = try controlID("relay.fixture.disabled", in: after.summary)
        var disabledRejected = false
        do { try tools.prepareReview(call("press_control", disabled)) } catch is CancellationError { throw CancellationError() } catch { disabledRejected = true }
        guard disabledRejected else { throw RelayError.message("A disabled button was accepted.") }
        report.cases.append(.init(name: "Reject disabled control", passed: true, evidence: "No second click or mutation occurred."))

        // Freeze the visible review, then edit its payload. The pending click must be invalid.
        let beforeDrift = try await observe(tools)
        let pending = call("press_control", try controlID("relay.fixture.apply", in: beforeDrift.summary))
        try tools.prepareReview(pending)
        try mutateFixtureInputOutsideController(pid: application.processIdentifier, token: token, value: "Changed during review")
        var driftRejected = false
        do { try tools.authorize(pending) } catch is CancellationError { throw CancellationError() } catch { driftRejected = true }
        guard driftRejected, try oracle(oracleURL, token: token).clickCount == 1 else { throw RelayError.message("A changed review payload was accepted or clicked.") }
        report.cases.append(.init(name: "Invalidate changed review", passed: true, evidence: "Input changed after review was prepared; approval was refused and clickCount stayed 1."))

        let beforeStop = try await observe(tools)
        let stoppedClick = call("press_control", try controlID("relay.fixture.apply", in: beforeStop.summary))
        try tools.prepareReview(stoppedClick)
        try tools.authorize(stoppedClick)
        tools.invalidateApprovals()
        var stoppedRejected = false
        do { _ = try await tools.execute(stoppedClick) } catch is CancellationError { throw CancellationError() } catch { stoppedRejected = true }
        guard stoppedRejected, try oracle(oracleURL, token: token).clickCount == 1 else { throw RelayError.message("An invalidated click dispatched after Stop.") }
        report.cases.append(.init(name: "Invalidation blocks queued click", passed: true, evidence: "Invalidating approvals/observations prevented dispatch; clickCount stayed 1."))
        try Task.checkCancellation()
        return report
    }

    /// Simulate another actor editing the harmless fixture without invalidating MacTools' cache.
    /// This makes the review-drift case exercise the payload hash, rather than just stale IDs.
    private static func mutateFixtureInputOutsideController(pid: pid_t, token: String, value: String) throws {
        try Task.checkCancellation()
        guard NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == fixtureBundleID else { throw RelayError.message("Fixture process identity changed.") }
        let root = AXUIElementCreateApplication(pid)
        var queue = [root]
        var cursor = 0
        var input: AXUIElement?
        var foundToken = false
        while cursor < queue.count && cursor < 120 {
            let element = queue[cursor]; cursor += 1
            AXUIElementSetMessagingTimeout(element, 0.025)
            var rawID: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute as CFString, &rawID)
            if rawID as? String == "relay.fixture.input" { input = element }
            if rawID as? String == "relay.fixture.token" {
                var rawValue: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &rawValue)
                foundToken = rawValue as? String == token
            }
            var rawChildren: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &rawChildren) == .success,
               let children = rawChildren as? [AXUIElement] { queue.append(contentsOf: children.prefix(120)) }
        }
        guard foundToken, let input else { throw RelayError.message("The independent edit target did not match this fixture launch.") }
        try Task.checkCancellation()
        AXUIElementSetMessagingTimeout(input, 0.5)
        let result = AXUIElementSetAttributeValue(input, kAXValueAttribute as CFString, value as CFString)
        guard result == .success else { throw RelayError.message("Could not simulate the independent fixture edit (AX error \(result.rawValue)); inspect its state before retrying.") }
    }

    static func controlLine(_ identifier: String, in snapshot: String) throws -> String {
        let lines = snapshot.split(separator: "\n").filter { $0.contains("identifier=\(identifier) ") }
        guard lines.count == 1 else { throw RelayError.message("Expected exactly one accessible control with identifier \(identifier), found \(lines.count).") }
        return String(lines[0])
    }
    static func controlID(_ identifier: String, in snapshot: String) throws -> String {
        let line = try controlLine(identifier, in: snapshot)
        guard let first = line.split(separator: " ").first, first.hasPrefix("element_id=") else { throw RelayError.message("Observation did not include an element token.") }
        return String(first.dropFirst("element_id=".count))
    }
    private static func call(_ name: String, _ id: String, _ extras: [String: JSONValue] = [:]) -> ToolCall {
        ToolCall(name: name, arguments: ["bundle_id": .string(fixtureBundleID), "element_id": .string(id)].merging(extras) { _, new in new })
    }
    private static func observe(_ tools: MacTools) async throws -> ToolResult {
        try await tools.execute(ToolCall(name: "observe_app", arguments: ["bundle_id": .string(fixtureBundleID)]))
    }
    private static func oracle(_ url: URL, token: String) throws -> Oracle {
        let state = try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: url))
        guard state.launchToken == token else { throw RelayError.message("The fixture oracle belongs to a different launch.") }
        return state
    }
}

extension AssistantStore {
    func runAccessibilityCheck() async {
        guard !isRunning, !voice.isBusy else { accessibilityCheckStatus = "Stop the current task before running this check."; return }
        accessibilityCheckStatus = "Checking actual accessibility typing and clicking…"
        accessibilityCheckRunning = true
        defer { accessibilityCheckRunning = false; accessibilityCheckTask = nil }
        guard let resources = Bundle.main.resourceURL else { accessibilityCheckStatus = "Fixture resources missing."; return }
        do {
            let fixtureURL = resources.appendingPathComponent("RelayAccessibilityFixture.app")
            let check = Task { try await AccessibilityCheckRunner.run(fixtureURL: fixtureURL) }
            accessibilityCheckTask = check
            let report = try await check.value
            accessibilityCheckStatus = report.summary
            record("Accessibility test", report.summary, report.allPassed ? "passed" : "failed")
        } catch is CancellationError {
            accessibilityCheckStatus = "Stopped. Remaining accessibility cases were not run; no pass is claimed."
            record("Accessibility test", accessibilityCheckStatus, "stopped")
        } catch {
            accessibilityCheckStatus = error.localizedDescription
            record("Accessibility test", error.localizedDescription, "not passed")
        }
    }
}
