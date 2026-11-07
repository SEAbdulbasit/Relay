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
            let originalInputScope = try #require(tools.recoveryScopeFingerprint(for: write))
            let scope = try #require(try tools.prepareMutationReadback(for: write))
            #expect(try await tools.execute(write).verified)
            let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let fresh = try await tools.readback(scope, after: write)
            #expect(fresh.verified && fresh.evidence.contains("original process and document window"))
            #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground)
            #expect(try AccessibilityCheckRunner.controlLine("relay.fixture.input", in: fresh.summary).contains(expected))
            let applyID = try AccessibilityCheckRunner.controlID("relay.fixture.apply", in: fresh.summary)
            let freshInput = try AccessibilityCheckRunner.controlID("relay.fixture.input", in: fresh.summary)
            let sameIntent = ToolCall(name: "set_value", arguments: ["bundle_id": .string(bundle),
                "element_id": .string(freshInput), "value": .string(expected)])
            #expect(tools.recoveryScopeFingerprint(for: sameIntent) == originalInputScope,
                "Mutable control text must not create a new control identity or reset its recovery budget.")
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
        let value = "Helper bounded readback 5274"
        try await DesktopFixtureProcess.withLaunch(path: DesktopFixtureProcess.bundledPath,
            environment: ["RELAY_FIXTURE_INCLUDE_DRAFT": "1"]) { fixture in
            let tools = MacTools()
            let snapshot = try await observe(tools, mode: "skeleton")
            let input = try ref(containing: " role=textfield title=Fixture input ", in: snapshot.summary)
            try #require(input.hasPrefix("@"), "The live case must qualify the actual helper path.")
            let oldCall = ToolCall(name: "set_value", arguments: ["bundle_id": .string(bundle), "element_id": .string(input), "value": .string("same request")])
            #expect(tools.recoveryScopeFingerprint(for: oldCall) == nil,
                "A helper path is not positive native control identity.")
            let repeated = try await observe(tools, mode: "skeleton")
            let freshInput = try ref(containing: " role=textfield title=Fixture input ", in: repeated.summary)
            let write = ToolCall(name: "set_value", arguments: ["bundle_id": .string(bundle),
                "element_id": .string(freshInput), "value": .string(value)])
            #expect(tools.recoveryScopeFingerprint(for: write) == nil)
            let scope = try #require(try tools.prepareMutationReadback(for: write), "A single exact helper/native window must have provable lineage.")
            let written = try await tools.execute(write)
            let readback = try await tools.readback(scope, after: write)
            #expect(readback.verified && readback.evidence.hasPrefix("Native AX observation"))
            let inputLine = try AccessibilityCheckRunner.controlLine("relay.fixture.input", in: readback.summary)
            #expect(inputLine.contains(value))
            let state = try oracle(fixture)
            print("Helper deterministic write classification: input=\(String(reflecting: state["input"] as? String)), inputUTF8=\(Array((state["input"] as? String ?? "").utf8.prefix(256))), editingInput=\(String(reflecting: state["editingInput"] as? String)), editingInputUTF8=\(Array((state["editingInput"] as? String ?? "").utf8.prefix(256))), result=\(String(reflecting: state["result"] as? String)), clickCount=\(String(reflecting: state["clickCount"] as? Int)), freshNativeInput=\(String(reflecting: MacTools.boundedText(inputLine, utf8Limit: 1600))), writeVerified=\(written.verified), writeEvidence=\(String(reflecting: MacTools.boundedText(written.evidence, utf8Limit: 1024))).")
            #expect(state["clickCount"] as? Int == 0)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_RUN_SCOPED_READBACK_TEST"] == "1"))
    func helperUnicodeRefusalHasNoEffectsAndFreshNativeEntryKeepsExactBytes() async throws {
        try await DesktopFixtureProcess.withLaunch(path: DesktopFixtureProcess.bundledPath,
            environment: ["RELAY_FIXTURE_INCLUDE_DRAFT": "1"]) { fixture in
            let tools = MacTools()
            let initial = try oracle(fixture)
            let originalDraft = try #require((initial["draft"] as? [String: Any])?["text"] as? String)
            let helper = try await observe(tools, mode: "skeleton")
            let helperInput = try ref(containing: " role=textfield title=Fixture input ", in: helper.summary)
            RelayActionPointer.shared.hide()
            for value in ["Native Gemma café 8431", "Native Gemma cafe\u{301} 8431"] {
                let call = ToolCall(name: "set_value", arguments: ["bundle_id": .string(bundle),
                    "element_id": .string(helperInput), "value": .string(value)])
                do {
                    _ = try await tools.execute(call)
                    Issue.record("Unicode helper text must be refused before any action.")
                } catch {
                    #expect(error.localizedDescription.contains("No text was entered"))
                    #expect(error.localizedDescription.contains("mode=windows") && error.localizedDescription.contains("window_id"))
                }
                #expect(!NSApplication.shared.windows.contains { $0.title == "Relay Action Pointer" && $0.isVisible },
                    "A refused helper write must not display an action pointer.")
                let state = try oracle(fixture)
                #expect((state["input"] as? String)?.utf8.elementsEqual("".utf8) == true)
                #expect(state["result"] as? String == "Not applied" && state["clickCount"] as? Int == 0)
                #expect((state["draft"] as? [String: Any])?["text"] as? String == originalDraft)
                #expect(state["editingInput"] == nil)
            }
            // The planner must obtain new native references explicitly. No helper
            // reference is translated, committed or dispatched a second time.
            let windows = try await observe(tools, mode: "windows")
            let window = try ref(containing: " role=AXWindow title=Relay Accessibility Fixture description=", in: windows.summary)
            let native = try await tools.execute(ToolCall(name: "observe_app", arguments: ["bundle_id": .string(bundle),
                "mode": .string("full"), "window_id": .string(window)]))
            let nativeInput = try AccessibilityCheckRunner.controlID("relay.fixture.input", in: native.summary)
            let exact = "Native Gemma café 8431"
            let write = ToolCall(name: "set_value", arguments: ["bundle_id": .string(bundle),
                "element_id": .string(nativeInput), "value": .string(exact)])
            let scope = try #require(try tools.prepareMutationReadback(for: write))
            let written = try await tools.execute(write)
            #expect(written.verified)
            let readback = try await tools.readback(scope, after: write)
            #expect(readback.verified)
            #expect(try AccessibilityCheckRunner.controlLine("relay.fixture.input", in: readback.summary).contains(exact))
            // This fixture publishes independent state on its 100 ms timer.
            // Wait only for an exact oracle match; never send another write.
            var final = try oracle(fixture)
            for _ in 0..<25 where (final["input"] as? String)?.utf8.elementsEqual(exact.utf8) != true {
                try await Task.sleep(for: .milliseconds(20))
                final = try oracle(fixture)
            }
            if (final["input"] as? String)?.utf8.elementsEqual(exact.utf8) != true {
                print("Native Unicode oracle mismatch: input=\(String(reflecting: final["input"] as? String)), inputUTF8=\(Array((final["input"] as? String ?? "").utf8.prefix(256))), editingInput=\(String(reflecting: final["editingInput"] as? String)).")
            }
            #expect((final["input"] as? String)?.utf8.elementsEqual(exact.utf8) == true)
            #expect(final["result"] as? String == "Not applied" && final["clickCount"] as? Int == 0)
            #expect((final["draft"] as? [String: Any])?["text"] as? String == originalDraft)
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

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_RUN_SCOPED_READBACK_TEST"] == "1"))
    func exactCompletedWindowReadsReconcileOnlyTheirReadIssueWithOneUseReceipts() async throws {
        try await DesktopFixtureProcess.withLaunch(path: DesktopFixtureProcess.bundledPath,
            environment: ["RELAY_FIXTURE_INCLUDE_DRAFT": "1"]) { fixture in
            let tools = MacTools()
            defer { tools.invalidateApprovals() }
            let initial = try await observe(tools)
            #expect(try AccessibilityCheckRunner.controlLine("relay.fixture.draft", in: initial.summary).contains("enabled=unknown"))
            let write = ToolCall(name: "set_value", arguments: ["bundle_id": .string(bundle),
                "element_id": .string(try AccessibilityCheckRunner.controlID("relay.fixture.input", in: initial.summary)),
                "value": .string("Window read receipt café 2817")])
            let actionKey = TaskRecoveryBudget.key(for: write, observedScope: tools.recoveryScopeFingerprint(for: write))
            let scope = try #require(try tools.prepareMutationReadback(for: write))
            let window = try #require(scope.recoveryWindowID)
            #expect(try await tools.execute(write).verified)
            var recovery = TaskRecoveryBudget()
            try recovery.recordFailure(actionKey)
            try recovery.recordFailure(TaskRecoveryBudget.windowReadKey(window))
            let start = recovery.captureWindowReadAttempt(for: scope.recoveryAttemptID)
            let (fresh, receipt) = try await tools.readbackWithRecovery(scope, after: write)
            let owned = try #require(receipt)
            #expect(MacTools().consumePreciseReadReceipt(owned, for: scope.call) == nil)
            let proof = try #require(tools.consumePreciseReadReceipt(owned, for: scope.call))
            #expect(proof.windowID == window)
            let windowReadResolved1 = recovery.recordVerifiedWindowRead(start, window: proof.windowID, attemptID: proof.attemptID)
            #expect(windowReadResolved1)
            #expect(recovery.hasUnresolvedErrors, "A read must never clear the original action's issue.")
            #expect(tools.consumePreciseReadReceipt(owned, for: scope.call) == nil)
            recovery.recordVerifiedSuccess(actionKey)
            #expect(!recovery.hasUnresolvedErrors)

            let windowRef = try ref(containing: " role=AXWindow title=Relay Accessibility Fixture description=", in: fresh.summary)
            let call = ToolCall(name: "observe_app", arguments: ["bundle_id": .string(bundle), "window_id": .string(windowRef)])
            let precise = try #require(tools.preparePreciseWindowReadRecovery(for: call))
            #expect(precise.knownWindowID == window)
            try recovery.recordFailure(TaskRecoveryBudget.windowReadKey(window))
            let next = recovery.captureWindowReadAttempt(for: precise.recoveryAttemptID)
            let (result, nextReceipt) = try await tools.executePreciseWindowRead(precise)
            #expect(result.verified)
            let nextOwnedReceipt = try #require(nextReceipt)
            let nextProof = try #require(tools.consumePreciseReadReceipt(nextOwnedReceipt, for: call))
            let windowReadResolved2 = recovery.recordVerifiedWindowRead(next, window: nextProof.windowID, attemptID: nextProof.attemptID)
            #expect(windowReadResolved2)
            await #expect(throws: (any Error).self) { try await tools.executePreciseWindowRead(precise) }
            #expect(!recovery.hasUnresolvedErrors)
            let state = try oracle(fixture)
            #expect(state["input"] as? String == "Window read receipt café 2817" && state["clickCount"] as? Int == 0)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_RUN_SCOPED_READBACK_TEST"] == "1"))
    func newerObservationsWrongCallsAndStopCannotRedeemAnOlderRead() async throws {
        try await DesktopFixtureProcess.withLaunch(path: DesktopFixtureProcess.bundledPath) { fixture in
            let tools = MacTools()
            defer { tools.invalidateApprovals() }
            let windows = try await observe(tools, mode: "windows")
            let windowRef = try ref(containing: " role=AXWindow title=Relay Accessibility Fixture description=", in: windows.summary)
            let call = ToolCall(name: "observe_app", arguments: ["bundle_id": .string(bundle), "window_id": .string(windowRef)])
            #expect(tools.preparePreciseWindowReadRecovery(for: ToolCall(name: "observe_app", arguments: ["bundle_id": .string(bundle)])) == nil)
            let attempt = try #require(tools.preparePreciseWindowReadRecovery(for: call))
            let (_, receipt) = try await tools.executePreciseWindowRead(attempt)
            let firstReceipt = try #require(receipt)
            _ = try await observe(tools)
            #expect(tools.consumePreciseReadReceipt(firstReceipt, for: call) == nil)

            let current = try await observe(tools, mode: "windows")
            let currentRef = try ref(containing: " role=AXWindow title=Relay Accessibility Fixture description=", in: current.summary)
            let currentCall = ToolCall(name: "observe_app", arguments: ["bundle_id": .string(bundle), "window_id": .string(currentRef)])
            let wrongCallAttempt = try #require(tools.preparePreciseWindowReadRecovery(for: currentCall))
            let (_, wrongCallReceipt) = try await tools.executePreciseWindowRead(wrongCallAttempt)
            let wrongOwnedReceipt = try #require(wrongCallReceipt)
            let otherCall = ToolCall(name: "observe_app", arguments: currentCall.arguments)
            #expect(tools.consumePreciseReadReceipt(wrongOwnedReceipt, for: otherCall) == nil)
            #expect(tools.consumePreciseReadReceipt(wrongOwnedReceipt, for: currentCall) == nil)

            let last = try await observe(tools, mode: "windows")
            let lastRef = try ref(containing: " role=AXWindow title=Relay Accessibility Fixture description=", in: last.summary)
            let lastCall = ToolCall(name: "observe_app", arguments: ["bundle_id": .string(bundle), "window_id": .string(lastRef)])
            let stopped = try #require(tools.preparePreciseWindowReadRecovery(for: lastCall))
            tools.invalidateApprovals()
            await #expect(throws: (any Error).self) { try await tools.executePreciseWindowRead(stopped) }
            #expect(try oracle(fixture)["clickCount"] as? Int == 0)
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
