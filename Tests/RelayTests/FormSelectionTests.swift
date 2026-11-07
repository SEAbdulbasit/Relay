import AppKit
import Testing
@testable import Relay

@Suite(.serialized)
@MainActor
struct FormSelectionTests {
    private func observe(_ tools: MacTools) async throws -> ToolResult {
        try await tools.execute(ToolCall(name: "observe_app", arguments: [
            "bundle_id": .string(AccessibilityCheckRunner.fixtureBundleID), "mode": .string("full")
        ]))
    }

    private func selection(_ tools: MacTools, value: String) async throws -> ToolCall {
        let observation = try await observe(tools)
        let ref = try AccessibilityCheckRunner.controlID("relay.fixture.delivery", in: observation.summary)
        #expect(!ref.hasPrefix("@"))
        return ToolCall(name: "press_control", arguments: ["bundle_id": .string(AccessibilityCheckRunner.fixtureBundleID),
            "element_id": .string(ref), "action": .string("select"), "value": .string(value)])
    }

    private func review(_ call: ToolCall, in tools: MacTools) throws -> String {
        let displayed = try #require(tools.reviewReason(for: call))
        try tools.prepareReview(call)
        return displayed
    }

    private func expectOracle(_ fixture: DesktopFixtureProcess, delivery: String) async throws {
        var oracle: [String: Any]?
        for _ in 0..<20 {
            oracle = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.oracleURL)) as? [String: Any]
            if oracle?["delivery"] as? String == delivery { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(oracle?["delivery"] as? String == delivery)
        #expect(oracle?["clickCount"] as? Int == 0)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_RUN_AGENT_DESKTOP_TESTS"] == "1"))
    func reviewedDropdownChoiceHasExactNativeReadback() async throws {
        try await DesktopFixtureProcess.withLaunch(path: DesktopFixtureProcess.bundledPath,
            environment: ["RELAY_FIXTURE_INCLUDE_SELECTION": "1"]) { fixture in
            let tools = MacTools()
            defer { tools.invalidateApprovals() }
            let observation = try await observe(tools)
            let input = try AccessibilityCheckRunner.controlID("relay.fixture.input", in: observation.summary)
            _ = try await tools.execute(ToolCall(name: "set_value", arguments: ["bundle_id": .string(AccessibilityCheckRunner.fixtureBundleID),
                "element_id": .string(input), "value": .string("Reviewed fixture field")]))
            let call = try await selection(tools, value: "Express — café")
            let displayed = try review(call, in: tools)
            #expect(displayed.contains("Express — café"))
            #expect(displayed.contains("Standard"))
            #expect(displayed.contains("Fixture input"))
            #expect(displayed.contains("Reviewed fixture field"))
            try tools.authorize(call)
            let result = try await tools.execute(call)
            #expect(result.verified)
            try await expectOracle(fixture, delivery: "Express — café")
            await #expect(throws: RelayError.self) { try await tools.execute(call) }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_RUN_AGENT_DESKTOP_TESTS"] == "1"))
    func changedOptionOrSelectionRequiresFreshReview() async throws {
        try await DesktopFixtureProcess.withLaunch(path: DesktopFixtureProcess.bundledPath,
            environment: ["RELAY_FIXTURE_INCLUDE_SELECTION": "1"]) { fixture in
            let tools = MacTools()
            let other = MacTools()
            defer { tools.invalidateApprovals(); other.invalidateApprovals() }
            let call = try await selection(tools, value: "Express — café")
            _ = try review(call, in: tools)
            var changed = call
            changed.arguments["value"] = .string("-Priority")
            #expect(throws: RelayError.self) { try tools.authorize(changed) }
            #expect(throws: RelayError.self) { try tools.authorize(call) }
            try await expectOracle(fixture, delivery: "Standard")

            _ = try review(call, in: tools)
            let competing = try await selection(other, value: "-Priority")
            _ = try review(competing, in: other)
            try other.authorize(competing)
            #expect(try await other.execute(competing).verified)
            #expect(throws: RelayError.self) { try tools.authorize(call) }
            await #expect(throws: RelayError.self) { try await tools.execute(call) }
            try await expectOracle(fixture, delivery: "-Priority")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_RUN_AGENT_DESKTOP_TESTS"] == "1"),
          arguments: ["", "RELAY_FIXTURE_DUPLICATE_SELECTION", "RELAY_FIXTURE_DISABLED_SELECTION"])
    func absentDuplicateOrDisabledOptionLeavesTheSelectionAlone(flag: String) async throws {
        var environment = ["RELAY_FIXTURE_INCLUDE_SELECTION": "1"]
        if !flag.isEmpty { environment[flag] = "1" }
        try await DesktopFixtureProcess.withLaunch(path: DesktopFixtureProcess.bundledPath, environment: environment) { fixture in
            let tools = MacTools()
            defer { tools.invalidateApprovals() }
            let call = try await selection(tools, value: flag.isEmpty ? "Not an option" : "Express — café")
            _ = try review(call, in: tools)
            try tools.authorize(call)
            await #expect(throws: RelayError.self) { try await tools.execute(call) }
            try await expectOracle(fixture, delivery: "Standard")
        }
    }
}
