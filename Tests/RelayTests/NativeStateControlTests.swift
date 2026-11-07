import AppKit
import ApplicationServices
import Foundation
import Testing
@testable import Relay

@MainActor struct NativeStateControlContractTests {
    @Test func actionAndRoleDetermineOneExactTargetState() throws {
        #expect(try MacTools.binaryControlTarget(role: "AXCheckBox", action: "check", current: false))
        #expect(try !MacTools.binaryControlTarget(role: "AXCheckBox", action: "uncheck", current: true))
        #expect(try !MacTools.binaryControlTarget(role: "AXCheckBox", action: "toggle", current: true))
        #expect(try MacTools.binaryControlTarget(role: "AXDisclosureTriangle", action: "expand", current: false))
        #expect(try !MacTools.binaryControlTarget(role: "AXDisclosureTriangle", action: "collapse", current: true))
        for (role, action) in [("AXButton", "toggle"), ("AXCheckBox", "expand"), ("AXDisclosureTriangle", "check"), ("AXRow", "expand")] {
            #expect(throws: (any Error).self) { try MacTools.binaryControlTarget(role: role, action: action, current: false) }
        }
    }

    @Test func anAppNamedPermissionCheckboxCannotBypassTheSecurityRestriction() throws {
        try MacTools.validateBinaryControlContext(bundleID: "dev.relay.accessibility-fixture", label: "Show fixture labels")
        for bundleID in ["com.apple.systempreferences", "com.apple.SecurityAgent", "com.apple.TCCUI"] {
            #expect(throws: (any Error).self) { try MacTools.validateBinaryControlContext(bundleID: bundleID, label: "Relay") }
        }
    }
}

@Suite(.serialized) @MainActor
struct NativeStateControlDesktopTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_RUN_NATIVE_CONTROL_TEST"] == "1"))
    func exactCheckboxAndDisclosureStatesHaveIndependentOnePressReceipts() async throws {
        try await DesktopFixtureProcess.withLaunch(path: DesktopFixtureProcess.bundledPath,
            environment: ["RELAY_FIXTURE_INCLUDE_BINARY_CONTROLS": "1"]) { fixture in
            let tools = MacTools()
            let checked = try await reviewedChange(tools, identifier: "relay.fixture.checkbox", action: "check")
            #expect(checked.verified)
            #expect(try oracle(fixture)["checkboxValue"] as? Int == 1)
            #expect(try oracle(fixture)["checkboxPressCount"] as? Int == 1)
            let noop = try await reviewedChange(tools, identifier: "relay.fixture.checkbox", action: "check")
            #expect(noop.verified && noop.evidence.contains("No action was dispatched"))
            #expect(try oracle(fixture)["checkboxPressCount"] as? Int == 1)
            let toggled = try await reviewedChange(tools, identifier: "relay.fixture.checkbox", action: "toggle")
            #expect(toggled.verified)
            #expect(try oracle(fixture)["checkboxValue"] as? Int == 0)
            #expect(try oracle(fixture)["checkboxPressCount"] as? Int == 2)
            let unchecked = try await reviewedChange(tools, identifier: "relay.fixture.checkbox", action: "uncheck")
            #expect(unchecked.verified)
            #expect(try oracle(fixture)["checkboxPressCount"] as? Int == 2)

            let expanded = try await reviewedChange(tools, identifier: "relay.fixture.disclosure", action: "expand")
            #expect(expanded.verified)
            #expect(try oracle(fixture)["disclosureValue"] as? Int == 1)
            #expect(try oracle(fixture)["disclosurePressCount"] as? Int == 1)
            _ = try await reviewedChange(tools, identifier: "relay.fixture.disclosure", action: "expand")
            #expect(try oracle(fixture)["disclosurePressCount"] as? Int == 1)
            let collapsed = try await reviewedChange(tools, identifier: "relay.fixture.disclosure", action: "collapse")
            #expect(collapsed.verified)
            #expect(try oracle(fixture)["disclosureValue"] as? Int == 0)
            #expect(try oracle(fixture)["disclosurePressCount"] as? Int == 2)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_RUN_NATIVE_CONTROL_TEST"] == "1"),
          arguments: ["RELAY_FIXTURE_BINARY_MIXED", "RELAY_FIXTURE_BINARY_DISABLED", "RELAY_FIXTURE_BINARY_CONSEQUENTIAL"])
    func unsupportedCheckboxStatesNeverDispatch(flag: String) async throws {
        try await DesktopFixtureProcess.withLaunch(path: DesktopFixtureProcess.bundledPath,
            environment: ["RELAY_FIXTURE_INCLUDE_BINARY_CONTROLS": "1", flag: "1"]) { fixture in
            let tools = MacTools()
            let call = try await action(tools, identifier: "relay.fixture.checkbox", action: "check")
            _ = tools.reviewReason(for: call)
            #expect(throws: (any Error).self) { try tools.prepareReview(call) }
            await #expect(throws: (any Error).self) { try await tools.execute(call) }
            #expect(try oracle(fixture)["checkboxPressCount"] as? Int == 0)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_RUN_NATIVE_CONTROL_TEST"] == "1"))
    func uncertainStateNeverRetriesAndConsumedReviewCannotReplay() async throws {
        try await DesktopFixtureProcess.withLaunch(path: DesktopFixtureProcess.bundledPath,
            environment: ["RELAY_FIXTURE_INCLUDE_BINARY_CONTROLS": "1", "RELAY_FIXTURE_BINARY_REVERT": "1"]) { fixture in
            let tools = MacTools()
            let call = try await action(tools, identifier: "relay.fixture.checkbox", action: "check")
            _ = tools.reviewReason(for: call)
            try tools.prepareReview(call)
            try tools.authorize(call)
            await #expect(throws: (any Error).self) { try await tools.execute(call) }
            #expect(try oracle(fixture)["checkboxValue"] as? Int == 0)
            #expect(try oracle(fixture)["checkboxPressCount"] as? Int == 1)
            await #expect(throws: (any Error).self) { try await tools.execute(call) }
            #expect(try oracle(fixture)["checkboxPressCount"] as? Int == 1)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_RUN_NATIVE_CONTROL_TEST"] == "1"))
    func changedStateAndStopInvalidateAnAlreadyDisplayedReview() async throws {
        try await DesktopFixtureProcess.withLaunch(path: DesktopFixtureProcess.bundledPath,
            environment: ["RELAY_FIXTURE_INCLUDE_BINARY_CONTROLS": "1"]) { fixture in
            let tools = MacTools()
            let pending = try await action(tools, identifier: "relay.fixture.checkbox", action: "check")
            #expect(tools.reviewReason(for: pending)?.contains("unchecked") == true)
            try tools.prepareReview(pending)
            _ = try await reviewedChange(MacTools(), identifier: "relay.fixture.checkbox", action: "check")
            #expect(throws: (any Error).self) { try tools.authorize(pending) }
            #expect(try oracle(fixture)["checkboxPressCount"] as? Int == 1)
            let stopped = try await action(tools, identifier: "relay.fixture.checkbox", action: "uncheck")
            _ = tools.reviewReason(for: stopped)
            try tools.prepareReview(stopped)
            try tools.authorize(stopped)
            tools.invalidateApprovals()
            await #expect(throws: (any Error).self) { try await tools.execute(stopped) }
            #expect(try oracle(fixture)["checkboxPressCount"] as? Int == 1)
        }
    }

    private func action(_ tools: MacTools, identifier: String, action: String) async throws -> ToolCall {
        let snapshot = try await tools.execute(ToolCall(name: "observe_app", arguments: ["bundle_id": .string(AccessibilityCheckRunner.fixtureBundleID)]))
        let id = try AccessibilityCheckRunner.controlID(identifier, in: snapshot.summary)
        return ToolCall(name: "press_control", arguments: ["bundle_id": .string(AccessibilityCheckRunner.fixtureBundleID), "element_id": .string(id), "action": .string(action)])
    }

    private func reviewedChange(_ tools: MacTools, identifier: String, action: String) async throws -> ToolResult {
        let call = try await self.action(tools, identifier: identifier, action: action)
        #expect(tools.reviewReason(for: call) != nil)
        try tools.prepareReview(call)
        try tools.authorize(call)
        return try await tools.execute(call)
    }

    private func oracle(_ fixture: DesktopFixtureProcess) throws -> [String: Any] {
        let value = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.oracleURL)) as? [String: Any])
        try #require(value["launchToken"] as? String == fixture.token)
        return value
    }
}
