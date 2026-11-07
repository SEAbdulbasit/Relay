import AppKit
import Foundation
import Testing
@testable import Relay

@Suite(.serialized)
@MainActor
struct ScopedMutationReadbackTests {
    @Test
    func recoveryIdentityDoesNotInspectOrBindAnUnknownControl() {
        let tools = MacTools()
        for key in ["element_id", "root_ref", "window_id"] {
            let call = ToolCall(name: "observe_app", arguments: ["bundle_id": .string(bundle), key: .string("unbound-reference")])
            #expect(tools.recoveryScopeFingerprint(for: call) == nil)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_RUN_SCOPED_READBACK_TEST"] == "1"))
    func cachedRecoveryIdentitySurvivesFreshIDsAndDistinguishesDifferentControls() async throws {
        try await DesktopFixtureProcess.withLaunch(path: DesktopFixtureProcess.bundledPath) { fixture in
            let tools = MacTools()
            let first = try await observe(tools)
            let oldID = try AccessibilityCheckRunner.controlID("relay.fixture.apply", in: first.summary)
            let bundleID = bundle
            func action(_ id: String) -> ToolCall {
                ToolCall(name: "press_control", arguments: ["bundle_id": .string(bundleID), "element_id": .string(id)])
            }
            let original = try #require(tools.recoveryScopeFingerprint(for: action(oldID)))
            let other = try AccessibilityCheckRunner.controlID("relay.fixture.input", in: first.summary)
            #expect(tools.recoveryScopeFingerprint(for: action(other)) != original)
            let second = try await observe(tools)
            let newID = try AccessibilityCheckRunner.controlID("relay.fixture.apply", in: second.summary)
            #expect(oldID != newID)
            #expect(tools.recoveryScopeFingerprint(for: action(newID)) == original)
            #expect(tools.recoveryScopeFingerprint(for: action(oldID)) == nil)
            #expect(try oracle(fixture)["clickCount"] as? Int == 0)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_RUN_SCOPED_READBACK_TEST"] == "1"))
    func exactNativeReadbackSuppliesFreshControlsAfterOneWriteAndOneReviewedClick() async throws {
        try await DesktopFixtureProcess.withLaunch(path: DesktopFixtureProcess.bundledPath,
            environment: ["RELAY_FIXTURE_INCLUDE_DRAFT": "1"]) { fixture in
            let tools = MacTools()
            let initial = try await observe(tools)
            let input = try AccessibilityCheckRunner.controlID("relay.fixture.input", in: initial.summary)
            let oldApply = try AccessibilityCheckRunner.controlID("relay.fixture.apply", in: initial.summary)
            let expected = "Scoped exact café 🌍 7392"
            let write = ToolCall(name: "set_value", arguments: ["bundle_id": .string(bundle),
                "element_id": .string(input), "value": .string(expected)])
            let scope = try #require(try tools.prepareMutationReadback(for: write))
            #expect(try await tools.execute(write).verified)
            let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let fresh = try await tools.readback(scope, after: write)
            #expect(fresh.verified && fresh.evidence.contains("original process and document window"))
            #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground)
            #expect(try AccessibilityCheckRunner.controlLine("relay.fixture.input", in: fresh.summary).contains(expected))
            let applyID = try AccessibilityCheckRunner.controlID("relay.fixture.apply", in: fresh.summary)
            #expect(applyID != oldApply)
            await #expect(throws: (any Error).self) { try await tools.readback(scope, after: write) }
            let staleApply = ToolCall(name: "press_control", arguments: ["bundle_id": .string(bundle), "element_id": .string(oldApply)])
            #expect(tools.reviewReason(for: staleApply)?.contains("The control is stale") == true)
            do {
                try tools.prepareReview(staleApply)
                Issue.record("An expired Apply reference must never acquire a review approval.")
            } catch {
                #expect(error.localizedDescription.contains("The control is stale"), "Preserve the concrete read-only review failure.")
            }
            let apply = ToolCall(name: "press_control", arguments: ["bundle_id": .string(bundle), "element_id": .string(applyID)])
            let reason = try #require(tools.reviewReason(for: apply))
            try #require(reason.hasPrefix("Press “Apply”"), Comment(rawValue: reason))
            try tools.prepareReview(apply)
            try tools.authorize(apply)
            let afterApply = try #require(try tools.prepareMutationReadback(for: apply))
            #expect(try await tools.execute(apply).verified == false)
            let final = try await tools.readback(afterApply, after: apply)
            #expect(try AccessibilityCheckRunner.controlLine("relay.fixture.result", in: final.summary).contains(expected))
            let state = try oracle(fixture)
            #expect(state["input"] as? String == expected && state["result"] as? String == expected)
            #expect(state["clickCount"] as? Int == 1)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_RUN_SCOPED_READBACK_TEST"] == "1"))
    func stopAndWrongExecutorCannotReuseAnActionReadbackCapability() async throws {
        try await DesktopFixtureProcess.withLaunch(path: DesktopFixtureProcess.bundledPath,
            environment: ["RELAY_FIXTURE_INCLUDE_DRAFT": "1"]) { fixture in
            let tools = MacTools()
            let snapshot = try await observe(tools)
            let input = try AccessibilityCheckRunner.controlID("relay.fixture.input", in: snapshot.summary)
            let write = ToolCall(name: "set_value", arguments: ["bundle_id": .string(bundle),
                "element_id": .string(input), "value": .string("One owned fixture write")])
            let scope = try #require(try tools.prepareMutationReadback(for: write))
            _ = try await tools.execute(write)
            await #expect(throws: (any Error).self) { try await MacTools().readback(scope, after: write) }
            tools.invalidateApprovals()
            await #expect(throws: (any Error).self) { try await tools.readback(scope, after: write) }
            #expect(try oracle(fixture)["clickCount"] as? Int == 0)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_RUN_SCOPED_READBACK_TEST"] == "1"))
    func aDifferentSelectedWindowRefusesReadbackWithoutInspectingTheNewWindow() async throws {
        try await DesktopFixtureProcess.withLaunch(path: DesktopFixtureProcess.bundledPath,
            environment: ["RELAY_FIXTURE_INCLUDE_SECOND_WINDOW": "1"]) { fixture in
            let tools = MacTools()
            let snapshot = try await observe(tools)
            let input = try AccessibilityCheckRunner.controlID("relay.fixture.input", in: snapshot.summary)
            let write = ToolCall(name: "set_value", arguments: ["bundle_id": .string(bundle),
                "element_id": .string(input), "value": .string("Original window only")])
            let scope = try #require(try tools.prepareMutationReadback(for: write))
            _ = try await tools.execute(write)
            let another = MacTools()
            let windows = try await another.execute(ToolCall(name: "observe_app", arguments: ["bundle_id": .string(bundle), "mode": .string("windows")]))
            let secondary = try ref(containing: " role=AXWindow title=Relay Fixture Second Window description=", in: windows.summary)
            _ = try await another.execute(ToolCall(name: "press_control", arguments: ["bundle_id": .string(bundle),
                "element_id": .string(secondary), "action": .string("focus")]))
            await #expect(throws: (any Error).self) { try await tools.readback(scope, after: write) }
            #expect(try oracle(fixture)["clickCount"] as? Int == 0)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_RUN_SCOPED_READBACK_TEST"] == "1"))
    func aHelperWindowSnapshotCanReadBackOnlyItsProvenOriginalNativeWindow() async throws {
        try await DesktopFixtureProcess.withLaunch(path: DesktopFixtureProcess.bundledPath,
            environment: ["RELAY_FIXTURE_INCLUDE_DRAFT": "1"]) { fixture in
            let tools = MacTools()
            let snapshot = try await observe(tools, mode: "skeleton")
            let input = try ref(containing: " role=textfield title=Fixture input ", in: snapshot.summary)
            try #require(input.hasPrefix("@"), "The live case must qualify the actual helper path.")
            let oldCall = ToolCall(name: "set_value", arguments: ["bundle_id": .string(bundle), "element_id": .string(input), "value": .string("same request")])
            let originalIdentity = try #require(tools.recoveryScopeFingerprint(for: oldCall))
            let repeated = try await observe(tools, mode: "skeleton")
            let freshInput = try ref(containing: " role=textfield title=Fixture input ", in: repeated.summary)
            let write = ToolCall(name: "set_value", arguments: ["bundle_id": .string(bundle),
                "element_id": .string(freshInput), "value": .string("Helper bounded readback 5274")])
            #expect(tools.recoveryScopeFingerprint(for: write) == originalIdentity)
            let scope = try #require(try tools.prepareMutationReadback(for: write), "A single exact helper/native window must have provable lineage.")
            _ = try await tools.execute(write)
            let readback = try await tools.readback(scope, after: write)
            #expect(readback.verified && readback.evidence.hasPrefix("Native AX observation"))
            #expect(try AccessibilityCheckRunner.controlLine("relay.fixture.input", in: readback.summary).contains("Helper bounded readback 5274"))
            #expect(try oracle(fixture)["clickCount"] as? Int == 0)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_RUN_SCOPED_READBACK_TEST"] == "1"),
        arguments: ["checkbox", "radio", "popup", "row"])
    func applyingAFormCannotReuseReviewAfterAnotherNativeSelectionChanges(kind: String) async throws {
        let flag = switch kind {
        case "checkbox": "RELAY_FIXTURE_INCLUDE_BINARY_CONTROLS"
        case "popup": "RELAY_FIXTURE_INCLUDE_SELECTION"
        default: "RELAY_FIXTURE_INCLUDE_CHOICES"
        }
        try await DesktopFixtureProcess.withLaunch(path: DesktopFixtureProcess.bundledPath,
            environment: [flag: "1"]) { fixture in
            let tools = MacTools()
            let initial = try await observe(tools)
            let apply = ToolCall(name: "press_control", arguments: ["bundle_id": .string(bundle),
                "element_id": .string(try AccessibilityCheckRunner.controlID("relay.fixture.apply", in: initial.summary))])
            let reason = try #require(tools.reviewReason(for: apply))
            try #require(reason.hasPrefix("Press “Apply”"), Comment(rawValue: reason))
            try tools.prepareReview(apply)

            let other = MacTools()
            let snapshot = try await observe(other)
            let id: String
            let action: String
            var selection: String?
            switch kind {
            case "checkbox":
                id = try AccessibilityCheckRunner.controlID("relay.fixture.checkbox", in: snapshot.summary)
                action = "check"
            case "popup":
                id = try AccessibilityCheckRunner.controlID("relay.fixture.delivery", in: snapshot.summary)
                action = "select"
                selection = "Express — café"
            case "radio":
                id = try AccessibilityCheckRunner.controlID("relay.fixture.radio.1", in: snapshot.summary)
                action = "select"
                selection = "Comfortable — café"
            default:
                id = try ref(containing: " description=Beta note — café ", in: snapshot.summary, role: "AXRow")
                action = "select"
                selection = "Beta note — café"
            }
            var arguments: [String: JSONValue] = ["bundle_id": .string(bundle), "element_id": .string(id), "action": .string(action)]
            if let selection { arguments["value"] = .string(selection) }
            let change = ToolCall(name: "press_control", arguments: arguments)
            _ = other.reviewReason(for: change)
            try other.prepareReview(change)
            try other.authorize(change)
            #expect(try await other.execute(change).verified)
            let state = try oracle(fixture)
            switch kind {
            case "checkbox": #expect(state["checkboxValue"] as? Int == 1)
            case "popup": #expect(state["delivery"] as? String == selection)
            case "radio": #expect(state["radioSelection"] as? Int == 1)
            default: #expect(state["selectedRow"] as? Int == 1)
            }
            #expect(throws: (any Error).self) { try tools.authorize(apply) }
            await #expect(throws: (any Error).self) { try await tools.execute(apply) }
            #expect(try oracle(fixture)["clickCount"] as? Int == 0, "A changed selection must invalidate the whole-form Apply approval.")
        }
    }

    private var bundle: String { AccessibilityCheckRunner.fixtureBundleID }
    private func ref(containing marker: String, in summary: String, role: String? = nil) throws -> String {
        let lines = summary.split(separator: "\n").filter { line in
            line.hasPrefix("element_id=") && line.contains(marker) && (role.map { line.contains(" role=\($0) ") } ?? true)
        }
        let line = try #require(lines.count == 1 ? lines.first : nil, Comment(rawValue: summary))
        return String(try #require(line.split(separator: " ").first).dropFirst("element_id=".count))
    }
    private func observe(_ tools: MacTools, mode: String = "full") async throws -> ToolResult {
        try await tools.execute(ToolCall(name: "observe_app", arguments: ["bundle_id": .string(bundle), "mode": .string(mode)]))
    }
    private func oracle(_ fixture: DesktopFixtureProcess) throws -> [String: Any] {
        let state = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.oracleURL)) as? [String: Any])
        try #require(state["launchToken"] as? String == fixture.token)
        return state
    }
}
