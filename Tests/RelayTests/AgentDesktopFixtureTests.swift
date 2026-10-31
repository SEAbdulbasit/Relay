import AppKit
import Foundation
import Testing
@testable import Relay

/// Opt-in real interaction, confined to Relay's inert fixture and temporary oracle.
/// No personal app, clipboard, account, microphone or permission changes.
@Suite(.serialized)
@MainActor
struct AgentDesktopFixtureTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_RUN_AGENT_DESKTOP_TESTS"] == "1"))
    func realFindTypeClickAndIndependentReadback() async throws {
        let status = await AgentDesktopBridge.queryStatus()
        _ = try #require(status.accessibilityGranted, "agent-desktop needs existing Accessibility access; test does not request it")
        let bundleID = "dev.relay.accessibility-fixture"
        #expect(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty)
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else { return }
        let path = ProcessInfo.processInfo.environment["RELAY_AX_FIXTURE_APP"]
            ?? FileManager.default.currentDirectoryPath + "/build/Relay.app/Contents/Resources/RelayAccessibilityFixture.app"
        let fixtureURL = URL(fileURLWithPath: path)
        _ = try #require(Bundle(url: fixtureURL)?.bundleIdentifier == bundleID)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let oracleURL = temporary.appendingPathComponent("oracle.json")
        let token = UUID().uuidString
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.environment = ["RELAY_FIXTURE_TOKEN": token, "RELAY_FIXTURE_STATE_PATH": oracleURL.path]
        let application = try await NSWorkspace.shared.openApplication(at: fixtureURL, configuration: config)
        defer { application.terminate() }
        for _ in 0..<50 {
            if FileManager.default.fileExists(atPath: oracleURL.path) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let initial = try oracle(oracleURL)
        #expect(initial["launchToken"] as? String == token)
        #expect(initial["clickCount"] as? Int == 0)
        let appName = "Relay Accessibility Fixture"
        let snapshot = try await AgentDesktopBridge.snapshot(app: appName, skeleton: true)
        _ = try #require(snapshot.ok, Comment(rawValue: snapshot.formattedSummary))
        let field = try await uniqueRef(app: appName, name: "Fixture input", role: "textfield")
        let payload = "sf.webm — Résumé 日本語 👋"
        let typed = try await AgentDesktopBridge.act(command: "set-value", ref: field, value: payload)
        _ = try #require(typed.ok, Comment(rawValue: typed.formattedSummary))
        // Mutation invalidates the observation: explicitly acquire a new button ref.
        let button = try await uniqueRef(app: appName, name: "Apply", role: "button")
        let clicked = try await AgentDesktopBridge.act(command: "click", ref: button)
        _ = try #require(clicked.ok, Comment(rawValue: clicked.formattedSummary))
        for _ in 0..<30 {
            if try oracle(oracleURL)["clickCount"] as? Int == 1 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let final = try oracle(oracleURL)
        #expect(final["launchToken"] as? String == token)
        #expect(final["input"] as? String == payload)
        #expect(final["result"] as? String == payload)
        #expect(final["clickCount"] as? Int == 1)
        let readback = try await AgentDesktopBridge.snapshot(app: appName, interactiveOnly: false)
        #expect(readback.ok)
        #expect(readback.formattedSummary.contains(payload))
        let disabled = try await uniqueRef(app: appName, name: "Disabled action", role: "button")
        let refused = try await AgentDesktopBridge.act(command: "click", ref: disabled)
        #expect(!refused.ok, "A disabled fixture control must not report successful delivery")
        #expect(try oracle(oracleURL)["clickCount"] as? Int == 1)
        let absent = try await AgentDesktopBridge.find(app: appName, query: "absent-" + token)
        #expect(absent.ok)
        #expect(!absent.formattedSummary.contains("element_id="))
    }

    private func oracle(_ url: URL) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func uniqueRef(app: String, name: String, role: String) async throws -> String {
        let envelope = try await AgentDesktopBridge.find(app: app, query: name, role: role)
        _ = try #require(envelope.ok, Comment(rawValue: envelope.formattedSummary))
        let json = try #require(JSONSerialization.jsonObject(with: Data(envelope.rawJSON.utf8)) as? [String: Any])
        let data = try #require(json["data"] as? [String: Any])
        let matches = try #require(data["matches"] as? [[String: Any]])
        let exact = matches.filter { ($0["name"] as? String) == name && ($0["role"] as? String) == role }
        _ = try #require(exact.count == 1, "Refuse ambiguous or missing fixture target")
        return try #require(exact.first?["ref_id"] as? String)
    }
}
