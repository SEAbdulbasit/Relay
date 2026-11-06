import AppKit
import ApplicationServices
import Testing
@testable import Relay

@MainActor
@Suite(.serialized)
struct RelayActionPointerIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_RUN_POINTER_TESTS"] == "1"))
    func pointerTracksBothControlBackendsAndStopHidesIt() async throws {
        _ = NSApplication.shared
        try #require(AXIsProcessTrusted(), "The test runner needs existing macOS Accessibility permission.")
        try await DesktopFixtureProcess.withLaunch(path: DesktopFixtureProcess.bundledPath) { fixture in
            try await verifyPointer(in: fixture)
        }
    }

    private func verifyPointer(in fixture: DesktopFixtureProcess) async throws {
        let bundleID = AccessibilityCheckRunner.fixtureBundleID
        let pid = fixture.application.processIdentifier
        for _ in 0..<30 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(NSWorkspace.shared.frontmostApplication?.processIdentifier == pid, "The test-owned fixture must be frontmost.")
        let tools = MacTools()
        defer { tools.invalidateApprovals() }
        for mode in ["full", "find"] {
            try fixture.requireExclusiveProcess()
            var args: [String: JSONValue] = ["bundle_id": .string(bundleID), "mode": .string(mode)]
            if mode == "find" { args["query"] = .string("Fixture input") }
            let observation = try await tools.execute(ToolCall(name: "observe_app", arguments: args))
            let row = try #require(observation.summary.components(separatedBy: "\n").first {
                $0.contains("Fixture input") && ($0.contains("AXTextField") || $0.contains("textfield")) && $0.contains("element_id=")
            }, Comment(rawValue: observation.summary))
            let suffix = try #require(row.range(of: "element_id=")).upperBound
            let ref = String(row[suffix...].prefix(while: { !$0.isWhitespace }))
            try fixture.requireExclusiveProcess()
            _ = try await tools.execute(ToolCall(name: "set_value", arguments: [
                "bundle_id": .string(bundleID), "element_id": .string(ref), "value": .string("Relay pointer fixture")
            ]))
            if mode == "find" {
                #expect(tools.desktopSession.isRendered, Comment(rawValue: tools.desktopSession.lastCursorResult?.rawJSON ?? "Cursor command did not return"))
                tools.invalidateApprovals()
                _ = await tools.desktopSession.stop()?.value
                #expect(!tools.desktopSession.isRendered)
            } else {
                let panel = try #require(NSApplication.shared.windows.first { $0.title == "Relay Action Pointer" })
                #expect(panel.isVisible)
                #expect(panel.ignoresMouseEvents)
                #expect(!panel.isKeyWindow)
                tools.invalidateApprovals()
                #expect(!panel.isVisible)
            }
        }
    }
}
