import Foundation
import Testing
@testable import Relay

@Suite(.serialized) @MainActor
struct NativeChoiceControlDesktopTests {
    private let bundleID = AccessibilityCheckRunner.fixtureBundleID
    private let radioLabel = "Comfortable — café"
    private let rowLabel = "Beta note — café"

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_RUN_NATIVE_CHOICE_TEST"] == "1"))
    func exactRadioAndOneRowSelectionHaveIndependentReceiptsWithoutActivation() async throws {
        try await fixture { fixture in
            let tools = MacTools()
            let radio = try await selection(tools, kind: "radio", value: radioLabel)
            #expect(throws: (any Error).self) { try tools.prepareReview(radio) }
            let reason = try #require(tools.reviewReason(for: radio))
            #expect(reason.contains("Compact") && reason.contains("Expanded") && reason.contains("Fixture input"))
            let receipt = try await approveAndRun(tools, radio)
            #expect(receipt.verified)
            #expect(try oracle(fixture)["radioSelection"] as? Int == 1)
            #expect(try oracle(fixture)["radioPressCount"] as? Int == 1)
            await #expect(throws: (any Error).self) { try await tools.execute(radio) }
            let noop = try await reviewedSelection(tools, kind: "radio", value: radioLabel)
            #expect(noop.verified && noop.evidence.contains("No action was dispatched"))
            #expect(try oracle(fixture)["radioPressCount"] as? Int == 1)

            let row = try await selection(tools, kind: "row", value: rowLabel)
            let rowReason = try #require(tools.reviewReason(for: row))
            #expect(rowReason.contains("Alpha note") && rowReason.contains("Gamma note") && rowReason.contains("Comfortable — café"))
            let selected = try await approveAndRun(tools, row)
            #expect(selected.verified && selected.evidence.contains("AXSelectedRows"))
            #expect(try oracle(fixture)["selectedRow"] as? Int == 1)
            #expect(try oracle(fixture)["rowSelectionCount"] as? Int == 1)
            await #expect(throws: (any Error).self) { try await tools.execute(row) }
            let rowNoop = try await reviewedSelection(tools, kind: "row", value: rowLabel)
            #expect(rowNoop.verified && rowNoop.evidence.contains("No action was dispatched"))
            #expect(try oracle(fixture)["rowSelectionCount"] as? Int == 1)
            #expect(try oracle(fixture)["rowActivationCount"] as? Int == 0)
            #expect(try oracle(fixture)["rowClickCount"] as? Int == 0)
            #expect(try oracle(fixture)["radioPressCount"] as? Int == 1)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_RUN_NATIVE_CHOICE_TEST"] == "1"), arguments: [
        "radio:RELAY_FIXTURE_CHOICE_DUPLICATE", "radio:RELAY_FIXTURE_CHOICE_DISABLED", "radio:RELAY_FIXTURE_CHOICE_CONSEQUENTIAL",
        "row:RELAY_FIXTURE_ROW_DUPLICATE", "row:RELAY_FIXTURE_ROW_DISABLED"])
    func duplicateDisabledAndConsequentialChoicesNeverDispatch(specification: String) async throws {
        let parts = specification.split(separator: ":").map(String.init)
        try await fixture(environment: [parts[1]: "1"]) { fixture in
            let tools = MacTools()
            let value = parts[1] == "RELAY_FIXTURE_CHOICE_CONSEQUENTIAL" ? "Disable security" : parts[0] == "radio" ? radioLabel : rowLabel
            let call = try await selection(tools, kind: parts[0], value: value)
            _ = tools.reviewReason(for: call)
            #expect(throws: (any Error).self) { try tools.prepareReview(call) }
            await #expect(throws: (any Error).self) { try await tools.execute(call) }
            try assertNoDispatch(fixture)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_RUN_NATIVE_CHOICE_TEST"] == "1"), arguments: ["radio", "row"])
    func uncertainSelectionDispatchesOnceAndCannotReplay(kind: String) async throws {
        try await fixture(environment: [kind == "radio" ? "RELAY_FIXTURE_CHOICE_REVERT" : "RELAY_FIXTURE_ROW_REVERT": "1"]) { fixture in
            let tools = MacTools()
            let call = try await selection(tools, kind: kind, value: kind == "radio" ? radioLabel : rowLabel)
            _ = tools.reviewReason(for: call)
            try tools.prepareReview(call)
            try tools.authorize(call)
            await #expect(throws: (any Error).self) { try await tools.execute(call) }
            let key = kind == "radio" ? "radioPressCount" : "rowSelectionCount"
            #expect(try oracle(fixture)[key] as? Int == 1)
            #expect(try oracle(fixture)[kind == "radio" ? "radioSelection" : "selectedRow"] as? Int == 0)
            await #expect(throws: (any Error).self) { try await tools.execute(call) }
            #expect(try oracle(fixture)[key] as? Int == 1)
            #expect(try oracle(fixture)["rowActivationCount"] as? Int == 0)
            #expect(try oracle(fixture)["rowClickCount"] as? Int == 0)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_RUN_NATIVE_CHOICE_TEST"] == "1"), arguments: ["radio", "row"])
    func peerSelectionAndFormDriftInvalidateTheDisplayedReview(kind: String) async throws {
        try await fixture { fixture in
            let tools = MacTools()
            let pending = try await selection(tools, kind: kind, value: kind == "radio" ? radioLabel : rowLabel)
            _ = tools.reviewReason(for: pending)
            try tools.prepareReview(pending)
            _ = try await reviewedSelection(MacTools(), kind: kind, value: kind == "radio" ? "Expanded" : "Gamma note")
            #expect(throws: (any Error).self) { try tools.authorize(pending) }
            let countKey = kind == "radio" ? "radioPressCount" : "rowSelectionCount"
            #expect(try oracle(fixture)[countKey] as? Int == 1)

            let formPending = try await selection(tools, kind: kind, value: kind == "radio" ? radioLabel : rowLabel)
            _ = tools.reviewReason(for: formPending)
            try tools.prepareReview(formPending)
            let other = MacTools()
            let snapshot = try await observe(other)
            let field = try AccessibilityCheckRunner.controlID("relay.fixture.input", in: snapshot.summary)
            _ = try await other.execute(ToolCall(name: "set_value", arguments: ["bundle_id": .string(bundleID),
                "element_id": .string(field), "value": .string("Changed form payload")]))
            #expect(throws: (any Error).self) { try tools.authorize(formPending) }
            #expect(try oracle(fixture)[countKey] as? Int == 1)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_RUN_NATIVE_CHOICE_TEST"] == "1"), arguments: ["radio", "row"])
    func changedChoiceContentAndStopRefuseWithoutSelection(kind: String) async throws {
        try await fixture { fixture in
            let tools = MacTools()
            let pending = try await selection(tools, kind: kind, value: kind == "radio" ? radioLabel : rowLabel)
            _ = tools.reviewReason(for: pending)
            try tools.prepareReview(pending)
            let other = MacTools()
            let snapshot = try await observe(other)
            let button = try AccessibilityCheckRunner.controlID("relay.fixture.changeChoices", in: snapshot.summary)
            let change = ToolCall(name: "press_control", arguments: ["bundle_id": .string(bundleID), "element_id": .string(button)])
            _ = other.reviewReason(for: change)
            _ = try await approveAndRun(other, change)
            let state = try oracle(fixture)
            #expect(throws: (any Error).self) { try tools.authorize(pending) }
            #expect(try oracle(fixture)["radioPressCount"] as? Int == state["radioPressCount"] as? Int)
            #expect(try oracle(fixture)["rowSelectionCount"] as? Int == state["rowSelectionCount"] as? Int)

            let stopped = try await selection(tools, kind: kind, value: kind == "radio" ? "Changed radio label" : "Changed row content")
            _ = tools.reviewReason(for: stopped)
            try tools.prepareReview(stopped)
            try tools.authorize(stopped)
            tools.invalidateApprovals()
            await #expect(throws: (any Error).self) { try await tools.execute(stopped) }
            #expect(try oracle(fixture)["radioPressCount"] as? Int == state["radioPressCount"] as? Int)
            #expect(try oracle(fixture)["rowSelectionCount"] as? Int == state["rowSelectionCount"] as? Int)
            #expect(try oracle(fixture)["rowActivationCount"] as? Int == 0)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_RUN_NATIVE_CHOICE_TEST"] == "1"), arguments: ["radio", "row"])
    func exactRequestedTextIsMandatory(kind: String) async throws {
        try await fixture { fixture in
            let tools = MacTools()
            let valid = try await selection(tools, kind: kind, value: kind == "radio" ? radioLabel : rowLabel)
            var arguments = valid.arguments
            arguments["value"] = .string("Different exact choice")
            let wrong = ToolCall(name: valid.name, arguments: arguments)
            _ = tools.reviewReason(for: wrong)
            #expect(throws: (any Error).self) { try tools.prepareReview(wrong) }
            await #expect(throws: (any Error).self) { try await tools.execute(wrong) }
            try assertNoDispatch(fixture)
        }
    }

    private func fixture(environment: [String: String] = [:], body: (DesktopFixtureProcess) async throws -> Void) async throws {
        try await DesktopFixtureProcess.withLaunch(path: DesktopFixtureProcess.bundledPath,
            environment: environment.merging(["RELAY_FIXTURE_INCLUDE_CHOICES": "1"]) { _, value in value }, body: body)
    }
    private func observe(_ tools: MacTools) async throws -> ToolResult {
        try await tools.execute(ToolCall(name: "observe_app", arguments: ["bundle_id": .string(bundleID)]))
    }
    private func selection(_ tools: MacTools, kind: String, value: String) async throws -> ToolCall {
        let snapshot = try await observe(tools)
        let role = kind == "radio" ? "AXRadioButton" : "AXRow"
        let labelField = kind == "radio" ? "title=" : "description="
        let rows = snapshot.summary.split(whereSeparator: \.isNewline).filter {
            $0.contains("role=\(role) ") && $0.contains("\(labelField)\(value) ")
        }
        // Duplicated labels intentionally still choose a known individual ID; the
        // production peer/container validator must refuse the ambiguity itself.
        let token = try #require(rows.first?.split(separator: " ").first, Comment(rawValue: snapshot.summary))
        let id = String(token.dropFirst("element_id=".count))
        return ToolCall(name: "press_control", arguments: ["bundle_id": .string(bundleID), "element_id": .string(id),
            "action": .string("select"), "value": .string(value)])
    }
    private func approveAndRun(_ tools: MacTools, _ call: ToolCall) async throws -> ToolResult {
        try tools.prepareReview(call)
        try tools.authorize(call)
        return try await tools.execute(call)
    }
    private func reviewedSelection(_ tools: MacTools, kind: String, value: String) async throws -> ToolResult {
        let call = try await selection(tools, kind: kind, value: value)
        _ = tools.reviewReason(for: call)
        return try await approveAndRun(tools, call)
    }
    private func oracle(_ fixture: DesktopFixtureProcess) throws -> [String: Any] {
        let state = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.oracleURL)) as? [String: Any])
        try #require(state["launchToken"] as? String == fixture.token)
        return state
    }
    private func assertNoDispatch(_ fixture: DesktopFixtureProcess) throws {
        #expect(try oracle(fixture)["radioPressCount"] as? Int == 0)
        #expect(try oracle(fixture)["rowSelectionCount"] as? Int == 0)
        #expect(try oracle(fixture)["rowClickCount"] as? Int == 0)
        #expect(try oracle(fixture)["rowActivationCount"] as? Int == 0)
    }
}
