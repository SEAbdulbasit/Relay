import AppKit
import ApplicationServices
import Foundation
import Testing
@testable import Relay

/// Real local inference and the production Store/MacTools/review loop. Both
/// opt-ins are mandatory: ordinary test runs never open an app or load a model.
@Suite(.serialized)
@MainActor
struct NativeModelWorkflowIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_RUN_NATIVE_REVIEW_MODEL_TEST"] == "1"
        && ProcessInfo.processInfo.environment["RELAY_GEMMA_MODEL_PATH"] != nil), .timeLimit(.minutes(5)))
    func completeNativeDraftReviewRemainsAvailableImmediatelyAfterRealLocalInference() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["RELAY_GEMMA_MODEL_PATH"])
        let configuration = ModelConfiguration(modelPath: path, computeBackend: "cpu", model: "Gemma 4 E2B")
        let client = LocalModelClient()
        defer { client.unload() }
        try await client.load(configuration: configuration)
        var system: ModelMessage?
        let promptProbe = AssistantStore(persistenceURL: nil, complete: { messages, _, _ in
            system = messages.first(where: { $0.role == "system" })
            return ModelReply(content: "Synthetic prompt capture only.", toolCalls: [])
        })
        promptProbe.draft = "Inspect only the synthetic fixture."
        promptProbe.send()
        for _ in 0..<2_000 where promptProbe.isRunning { await Task.yield() }
        let systemMessage = try #require(system)
        let definitions = MacTools.definitions
        let budget = LocalModelClient.maximumContextBytes - systemMessage.content.utf8.count - (try JSONEncoder().encode(definitions).count)
        try await DesktopFixtureProcess.withLaunch(path: DesktopFixtureProcess.bundledPath,
            environment: ["RELAY_FIXTURE_INCLUDE_DRAFT": "1"]) { fixture in
            let tools = MacTools()
            let observe = ToolCall(name: "observe_app", arguments: ["bundle_id": .string(AccessibilityCheckRunner.fixtureBundleID)])
            let first = try await tools.execute(observe)
            let expected = "Native Gemma café 8431"
            let write = ToolCall(name: "set_value", arguments: ["bundle_id": .string(AccessibilityCheckRunner.fixtureBundleID),
                "element_id": .string(try AccessibilityCheckRunner.controlID("relay.fixture.input", in: first.summary)), "value": .string(expected)])
            let scope = try #require(try tools.prepareMutationReadback(for: write))
            let written = try await tools.execute(write)
            let fresh = try await tools.readback(scope, after: write)
            let apply = ToolCall(name: "press_control", arguments: ["bundle_id": .string(AccessibilityCheckRunner.fixtureBundleID),
                "element_id": .string(try AccessibilityCheckRunner.controlID("relay.fixture.apply", in: fresh.summary))])
            func feedback(_ call: ToolCall, _ result: ToolResult) throws -> ModelMessage {
                ModelMessage(role: "tool", content: String(decoding: try JSONEncoder().encode(result), as: UTF8.self),
                    toolCallID: call.id, toolName: call.name)
            }
            let goal = """
                Only control the already-running Relay Accessibility Fixture app, bundle \(AccessibilityCheckRunner.fixtureBundleID). Do not list, open, inspect or control any other app. In that fixture, replace the field labelled Fixture input with exactly: \(expected)
                Then click its Apply button exactly once. Inspect the resulting Fixture result and report whether it matches. This is an inert local test form, not a submission. Use the ordinary exact review for Apply; do not bypass review or repeat a click. Leave the disabled control untouched.
                """
            let history = [ModelMessage(role: "user", content: goal), ModelMessage(role: "assistant", content: "", toolCalls: [observe]),
                try feedback(observe, first), ModelMessage(role: "assistant", content: "", toolCalls: [write]), try feedback(write, written),
                ModelMessage(role: "assistant", content: "", toolCalls: [scope.call]), try feedback(scope.call, fresh)]
            let window = try ContextWindow.prepare(history, activeStart: 0, budget: budget)
            let before = ContinuousClock.now
            let foregroundBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier == fixture.application.processIdentifier
            // No inferred action is dispatched by this isolated load probe.
            _ = try await client.complete(messages: [systemMessage] + window.messages, tools: definitions, configuration: configuration)
            let elapsed = before.duration(to: ContinuousClock.now).components
            print("Native review load probe: inferenceSeconds=\(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18), fixtureForegroundBefore=\(foregroundBefore), fixtureForegroundAfter=\(NSWorkspace.shared.frontmostApplication?.processIdentifier == fixture.application.processIdentifier).")
            let reason = try #require(tools.reviewReason(for: apply))
            try #require(reason.hasPrefix("Press “Apply”"), Comment(rawValue: reason))
            try tools.prepareReview(apply)
            #expect(try oracle(fixture).clickCount == 0, "The inference probe never authorizes or dispatches Apply.")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_RUN_NATIVE_MODEL_TEST"] == "1"
        && ProcessInfo.processInfo.environment["RELAY_GEMMA_MODEL_PATH"] != nil), .timeLimit(.minutes(5)))
    func actualGemmaFillsAndReviewsOneInertNativeFormWithIndependentOutcomeOracle() async throws {
        try #require(AXIsProcessTrusted(), "Existing Accessibility permission is required; this gate never requests it.")
        let path = try #require(ProcessInfo.processInfo.environment["RELAY_GEMMA_MODEL_PATH"])
        let backend = ProcessInfo.processInfo.environment["RELAY_GEMMA_TEST_BACKEND"] ?? "cpu"
        let modelLabel = ProcessInfo.processInfo.environment["RELAY_GEMMA_TEST_MODEL_LABEL"] ?? "Gemma 4 E2B"
        try #require(["cpu", "gpu"].contains(backend), "Use an explicit supported test compute backend.")
        try #require(["Gemma 4 E2B", "Gemma 4 E4B"].contains(modelLabel), "Use a qualified local package label for this test.")
        let expected = "Native Gemma café 8431"
        // The existing multiline fixture option enables its independent 100 ms
        // state polling, so pre-review field checks do not depend on AX events.
        try await DesktopFixtureProcess.withLaunch(path: DesktopFixtureProcess.bundledPath,
            environment: ["RELAY_FIXTURE_INCLUDE_DRAFT": "1"]) { fixture in
            let initial = try oracle(fixture)
            try #require(initial.input.isEmpty && initial.result == "Not applied" && initial.clickCount == 0)
            let untouchedDraft = try #require(initial.draft?.text)
            let client = LocalModelClient()
            let trace = WorkflowTrace()
            let store = AssistantStore(persistenceURL: nil, complete: { messages, definitions, configuration in
                try fixture.requireExclusiveProcess()
                guard trace.generations < 10 else { throw RelayError.message("Native model gate exceeded ten bounded inference turns.") }
                // This callback preserves the production prompt and full native
                // schemas. It restricts returned actions before Store can dispatch,
                // without replacing its private MacTools instance or review cache.
                try #require(Set(definitions.map(\.name)) == Set(MacTools.definitions.map(\.name)))
                try #require(messages.first?.content.contains("You are Relay, a personal macOS assistant.") == true)
                trace.generations += 1
                let systemBytes = messages.filter { $0.role == "system" }.reduce(0) { $0 + $1.content.utf8.count }
                let schemaBytes = try JSONEncoder().encode(definitions).count
                print("Native model budget turn \(trace.generations): systemBytes=\(systemBytes), schemaBytes=\(schemaBytes), historyBytes=\(ContextWindow.bytes(messages.filter { $0.role != "system" })), historyBudget=\(LocalModelClient.maximumContextBytes - systemBytes - schemaBytes).")
                let foregroundBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier == fixture.application.processIdentifier
                trace.rememberSyntheticRows(messages)
                let inferenceStart = ContinuousClock.now
                let reply = try await client.complete(messages: messages, tools: definitions, configuration: configuration)
                let elapsed = inferenceStart.duration(to: ContinuousClock.now).components
                let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1_000_000_000_000_000_000
                print("Native model turn timing: turn=\(trace.generations), seconds=\(seconds), fixtureForegroundBefore=\(foregroundBefore), fixtureForegroundAfter=\(NSWorkspace.shared.frontmostApplication?.processIdentifier == fixture.application.processIdentifier).")
                try Task.checkCancellation()
                try fixture.requireExclusiveProcess()
                guard trace.proposedCalls.count + reply.toolCalls.count <= 12 else {
                    throw RelayError.message("Native model gate exceeded twelve bounded fixture calls.")
                }
                for call in reply.toolCalls {
                    print(trace.targetDiagnostic(call, messages: messages))
                    try validate(call, messages: messages, expected: expected)
                }
                trace.proposedCalls.append(contentsOf: reply.toolCalls)
                trace.observedResults = messages.filter { $0.role == "tool" && $0.toolName == "observe_app" }.compactMap {
                    (try? JSONDecoder().decode(ToolResult.self, from: Data($0.content.utf8)))?.summary
                }
                print("Native model fixture turn \(trace.generations): \(reply.toolCalls.map(\.name).joined(separator: ", ")); no actions outside the owned fixture are permitted.")
                return reply
            }, modelClient: client)
            defer { store.stop(); client.unload() }
            store.configuration = ModelConfiguration(modelPath: path, computeBackend: backend, model: modelLabel)
            store.draft = """
                Only control the already-running Relay Accessibility Fixture app, bundle \(AccessibilityCheckRunner.fixtureBundleID). Do not list, open, inspect or control any other app. In that fixture, replace the field labelled Fixture input with exactly: \(expected)
                Then click its Apply button exactly once. Inspect the resulting Fixture result and report whether it matches. This is an inert local test form, not a submission. Use the ordinary exact review for Apply; do not bypass review or repeat a click. Leave the disabled control untouched.
                """
            let clock = ContinuousClock()
            let started = clock.now
            store.send()
            while store.isRunning && started.duration(to: clock.now) < .seconds(250) {
                try Task.checkCancellation()
                if let review = store.pendingReview {
                    let state = try oracle(fixture)
                    try #require(!review.sharesWithOpenAI && review.call.name == "press_control")
                    try #require(review.call.arguments["bundle_id"]?.string == AccessibilityCheckRunner.fixtureBundleID)
                    try #require(isApplyClick(review.call))
                    try #require(trace.proposedCalls.last(where: { $0.name == "press_control" })?.id == review.call.id)
                    try #require(review.reason.contains("Press “Apply”") && review.reason.contains(AccessibilityCheckRunner.fixtureBundleID)
                        && review.reason.contains(expected) && review.reason.contains("Fixture input"))
                    if !state.input.utf8.elementsEqual(expected.utf8) || state.result != "Not applied" || state.clickCount != 0 {
                        print("Native fixture pre-review mismatch: input=\(String(reflecting: MacTools.boundedText(state.input, utf8Limit: 256))), inputUTF8=\(Array(state.input.utf8.prefix(256))), editingInput=\(String(reflecting: state.editingInput.map { MacTools.boundedText($0, utf8Limit: 256) })), result=\(String(reflecting: MacTools.boundedText(state.result, utf8Limit: 256))), clickCount=\(state.clickCount).")
                        let inputLine = trace.observedResults.last.flatMap {
                            try? AccessibilityCheckRunner.controlLine("relay.fixture.input", in: $0)
                        } ?? "No native fixture input row"
                        print("Native fixture pre-review latest input: \(MacTools.boundedText(inputLine, utf8Limit: 1600)).")
                        if let receipt = trace.latestWriteReceipt {
                            print("Native fixture pre-review write receipt: verified=\(receipt.verified), summary=\(String(reflecting: MacTools.boundedText(receipt.summary, utf8Limit: 512))), evidence=\(String(reflecting: MacTools.boundedText(receipt.evidence, utf8Limit: 1024))).")
                        }
                    }
                    try #require(state.input.utf8.elementsEqual(expected.utf8) && state.result == "Not applied" && state.clickCount == 0)
                    try #require(trace.approvedReviewIDs.isEmpty, "Only one exact clean-state Apply review may be approved.")
                    trace.approvedReviewIDs.insert(review.id)
                    store.approveReview()
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            let timedOut = store.isRunning
            if timedOut { store.stop() }
            #expect(!timedOut, "Real local model did not finish the bounded native workflow.")
            #expect(store.errorMessage == nil, Comment(rawValue: store.errorMessage ?? "No Store error"))
            let state = try oracle(fixture)
            #expect(state.input.utf8.elementsEqual(expected.utf8), "Independent fixture input must equal the exact requested bytes.")
            #expect(state.result.utf8.elementsEqual(expected.utf8), "Independent fixture result must prove Apply's requested outcome.")
            #expect(state.clickCount == 1, "Apply must run exactly once, with no replay.")
            #expect(state.draft?.text.utf8.elementsEqual(untouchedDraft.utf8) == true,
                "The unrelated fixture editor must remain unchanged.")
            #expect(trace.approvedReviewIDs.count == 1 && store.pendingReview == nil)
            #expect(trace.proposedCalls.filter { $0.name == "set_value" }.count == 1)
            #expect(trace.proposedCalls.filter { $0.name == "press_control" }.count == 1)
            #expect(trace.observedResults.contains { snapshot in
                guard let line = try? AccessibilityCheckRunner.controlLine("relay.fixture.result", in: snapshot) else { return false }
                return line.contains(expected)
            }, "The real model must receive a fresh native result observation after Apply, not infer success from dispatch.")
            #expect(store.activity.filter { $0.name == "set_value" && $0.status == "verified" }.count == 1)
            #expect(store.activity.filter { $0.name == "press_control" && $0.status == "effect uncertain" }.count == 1,
                "An ordinary button dispatch must retain its uncertainty until a separate observation.")
            #expect(store.phase == .needsInput, "The production Store must retain the button receipt's uncertainty rather than invent full-task verification.")
            let elapsed = started.duration(to: clock.now).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1_000_000_000_000_000_000
            let observationBytes = store.activity.filter { $0.name == "observe_app" && $0.status == "verified" }.map { $0.detail.utf8.count }
            print("Native model full Activity observation byte counts: \(observationBytes).")
            let failures = store.activity.filter { $0.status.contains("failed") }.map { "\($0.name): \($0.detail)" }
            print("Native model activity failures: \(failures).")
            print("Native model final response: \(store.messages.last?.text ?? "No final response").")
            print("Native model workflow: backend=\(backend), model=\(modelLabel), package=\(URL(fileURLWithPath: path).lastPathComponent), generations=\(trace.generations), proposedCalls=\(trace.proposedCalls.count), exactReviews=\(trace.approvedReviewIDs.count), oracleClickCount=\(state.clickCount), seconds=\(seconds). Only the inert fixture was controlled.")
        }
    }

    /// Validate the complete reply before returning it to the real Store. No
    /// broad app inventory, browser, file, keyboard or alternate tool is allowed.
    private func validate(_ call: ToolCall, messages: [ModelMessage], expected: String) throws {
        guard ["observe_app", "set_value", "press_control"].contains(call.name),
              call.arguments["bundle_id"]?.string == AccessibilityCheckRunner.fixtureBundleID else {
            throw RelayError.message("Native model proposed an action outside the inert fixture allowlist: \(call.name). Nothing from that reply was dispatched.")
        }
        try ToolPolicy.validate(call, against: MacTools.definitions)
        if call.name == "observe_app" { return }
        guard let content = messages.last(where: { $0.role == "tool" && $0.toolName == "observe_app" })?.content,
              let observed = try? JSONDecoder().decode(ToolResult.self, from: Data(content.utf8)), observed.verified else {
            throw RelayError.message("Native model proposed a mutation without an observed fixture control.")
        }
        let id = call.name == "set_value"
            ? try fixtureInputID(in: observed.summary)
            : try AccessibilityCheckRunner.controlID("relay.fixture.apply", in: observed.summary)
        guard call.arguments["element_id"]?.string == id else {
            throw RelayError.message("Native model proposed a mutation on a control other than the exact observed fixture target.")
        }
        if call.name == "set_value" {
            guard call.arguments["value"]?.string?.utf8.elementsEqual(expected.utf8) == true else {
                throw RelayError.message("Native model changed the requested synthetic text. No action from that reply was dispatched.")
            }
        } else {
            guard isApplyClick(call) else {
                throw RelayError.message("Native model proposed an unsupported fixture Apply action.")
            }
        }
    }

    /// Only the owned fixture's named input has a helper alternative. A helper
    /// name is serialized as `title`; Apply still requires its native identifier.
    private func fixtureInputID(in summary: String) throws -> String {
        guard summary.hasPrefix("agent-desktop snapshot (") else {
            return try AccessibilityCheckRunner.controlID("relay.fixture.input", in: summary)
        }
        let lines = summary.split(separator: "\n").map(String.init)
        let header = lines.first ?? ""
        let headerPattern = #"^agent-desktop snapshot \(Relay Accessibility Fixture, snapshot_id=([A-Za-z0-9_-]{1,80}), refs=([0-9]{1,3})\):$"#
        let headerExpression = try NSRegularExpression(pattern: headerPattern)
        guard let headerMatch = headerExpression.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
              let snapshotRange = Range(headerMatch.range(at: 1), in: header),
              let countRange = Range(headerMatch.range(at: 2), in: header),
              let count = Int(header[countRange]), (1...160).contains(count) else {
            throw RelayError.message("The helper observation is not an exact owned fixture snapshot.")
        }
        let snapshot = String(header[snapshotRange])
        let rowExpression = try NSRegularExpression(pattern:
            #"^element_id=([^ ]+) role=textfield title=Fixture input(?= (?:value=|actions=\[|enabled=))"#)
        let matchingRows = lines.compactMap { line -> (String, String)? in
            guard let match = rowExpression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let reference = Range(match.range(at: 1), in: line) else { return nil }
            return (String(line[reference]), line)
        }
        guard matchingRows.count == 1, let (reference, row) = matchingRows.first,
              row.hasSuffix(" enabled=true"),
              reference.range(of: "^@" + NSRegularExpression.escapedPattern(for: snapshot) + #":e[1-9][0-9]{0,3}$"#,
                  options: .regularExpression) != nil else {
            throw RelayError.message("Expected one enabled helper Fixture input in the latest exact snapshot.")
        }
        return reference
    }

    @Test
    func strictValidatorAcceptsOnlyTheLatestUniqueNamedHelperInput() throws {
        let summary = """
            agent-desktop snapshot (Relay Accessibility Fixture, snapshot_id=sCurrent, refs=2):
            element_id=@sCurrent:e1 role=textfield title=Fixture input actions=[SetValue] enabled=true
            element_id=@sCurrent:e2 role=button title=Apply actions=[Click] enabled=true
            """
        let messages = try syntheticHelperMessages(summary)
        try validate(ToolCall(name: "set_value", arguments: ["bundle_id": .string(AccessibilityCheckRunner.fixtureBundleID),
            "element_id": .string("@sCurrent:e1"), "value": .string("Native Gemma café 8431")]),
            messages: messages, expected: "Native Gemma café 8431")
        #expect(throws: (any Error).self) {
            try validate(ToolCall(name: "press_control", arguments: ["bundle_id": .string(AccessibilityCheckRunner.fixtureBundleID),
                "element_id": .string("@sCurrent:e2")]), messages: messages, expected: "Native Gemma café 8431")
        }
    }

    @Test(arguments: ["ambiguous", "wrong-role", "stale-row", "no-match", "wrong-title", "disabled",
        "other-app", "stale-proposal", "changed-value", "unverified", "earlier-only"])
    func strictValidatorRefusesUnprovenHelperTargets(caseName: String) throws {
        var summary = """
            agent-desktop snapshot (Relay Accessibility Fixture, snapshot_id=sCurrent, refs=1):
            element_id=@sCurrent:e1 role=textfield title=Fixture input actions=[SetValue] enabled=true
            """
        var proposedID = "@sCurrent:e1"
        var value = "Native Gemma café 8431"
        switch caseName {
        case "ambiguous": summary += "\nelement_id=@sCurrent:e2 role=textfield title=Fixture input actions=[SetValue] enabled=true"
        case "wrong-role": summary = summary.replacingOccurrences(of: "role=textfield", with: "role=button")
        case "stale-row": summary = summary.replacingOccurrences(of: "element_id=@sCurrent:e1", with: "element_id=@sEarlier:e1")
        case "no-match", "earlier-only": summary = summary.replacingOccurrences(of: "title=Fixture input", with: "title=Unrelated draft")
        case "wrong-title": summary = summary.replacingOccurrences(of: "title=Fixture input", with: "title=Fixture input extra")
        case "disabled": summary = summary.replacingOccurrences(of: "enabled=true", with: "enabled=false")
        case "other-app": summary = summary.replacingOccurrences(of: "(Relay Accessibility Fixture,", with: "(Other App,")
        case "stale-proposal": proposedID = "@sEarlier:e1"
        case "changed-value": value += " altered"
        default: break
        }
        var messages = try syntheticHelperMessages(summary, verified: caseName != "unverified")
        if caseName == "earlier-only" {
            let earlier = """
                agent-desktop snapshot (Relay Accessibility Fixture, snapshot_id=sEarlier, refs=1):
                element_id=@sEarlier:e1 role=textfield title=Fixture input actions=[SetValue] enabled=true
                """
            messages.insert(contentsOf: try syntheticHelperMessages(earlier), at: 0)
            proposedID = "@sEarlier:e1"
        }
        let call = ToolCall(name: "set_value", arguments: ["bundle_id": .string(AccessibilityCheckRunner.fixtureBundleID),
            "element_id": .string(proposedID), "value": .string(value)])
        #expect(throws: (any Error).self) {
            try validate(call, messages: messages, expected: "Native Gemma café 8431")
        }
    }

    private func syntheticHelperMessages(_ summary: String, verified: Bool = true) throws -> [ModelMessage] {
        let result = ToolResult(summary: summary, evidence: "Synthetic owned fixture observation", verified: verified)
        return [ModelMessage(role: "tool", content: String(decoding: try JSONEncoder().encode(result), as: UTF8.self),
            toolCallID: UUID().uuidString, toolName: "observe_app")]
    }

    private func isApplyClick(_ call: ToolCall) -> Bool {
        // Match production's documented omitted/empty action default and
        // case-insensitive native action spelling without allowing selection.
        let action = call.arguments["action"]?.string?.lowercased() ?? ""
        return ["", "click"].contains(action) && (call.arguments["value"]?.string ?? "").isEmpty
    }

    private struct Oracle: Decodable {
        let input: String
        let editingInput: String?
        let result: String
        let clickCount: Int
        let launchToken: String
        let draft: Draft?
        struct Draft: Decodable { let text: String }
    }
    private func oracle(_ fixture: DesktopFixtureProcess) throws -> Oracle {
        try fixture.requireExclusiveProcess()
        let state = try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: fixture.oracleURL))
        try #require(state.launchToken == fixture.token)
        return state
    }
    @MainActor private final class WorkflowTrace {
        var generations = 0
        var proposedCalls: [ToolCall] = []
        var approvedReviewIDs = Set<UUID>()
        var observedResults: [String] = []
        var latestWriteReceipt: ToolResult?
        private var knownRows: [String: String] = [:]

        func rememberSyntheticRows(_ messages: [ModelMessage]) {
            latestWriteReceipt = messages.last(where: { $0.role == "tool" && $0.toolName == "set_value" }).flatMap {
                try? JSONDecoder().decode(ToolResult.self, from: Data($0.content.utf8))
            }
            for message in messages where message.role == "tool" && message.toolName == "observe_app" {
                for (id, row) in Self.rows(message.content) where knownRows.count < 512 || knownRows[id] != nil {
                    knownRows[id] = row
                }
            }
        }

        func targetDiagnostic(_ call: ToolCall, messages: [ModelMessage]) -> String {
            guard let id = call.arguments["element_id"]?.string else {
                return "Native fixture proposal diagnostic: name=\(MacTools.boundedText(call.name, utf8Limit: 80)), no element_id."
            }
            let latest = messages.last { $0.role == "tool" && $0.toolName == "observe_app" }
                .map { Self.rows($0.content) } ?? [:]
            let match: String
            let row: String?
            if let current = latest[id] { match = "latest-exact"; row = current }
            else if let earlier = knownRows[id] { match = "earlier-exact"; row = earlier }
            else if let uuid = UUID(uuidString: id), let equivalent = latest.first(where: { UUID(uuidString: $0.key) == uuid }) {
                match = "latest-same-UUID-different-spelling"; row = equivalent.value
            } else if let uuid = UUID(uuidString: id), let equivalent = knownRows.first(where: { UUID(uuidString: $0.key) == uuid }) {
                match = "earlier-same-UUID-different-spelling"; row = equivalent.value
            } else { match = "unseen"; row = nil }
            return "Native fixture proposal diagnostic: name=\(MacTools.boundedText(call.name, utf8Limit: 80)), element_id=\(String(reflecting: MacTools.boundedText(id, utf8Limit: 100))), match=\(match), \(row ?? "no matched synthetic role/title/identifier")."
        }

        private static func rows(_ content: String) -> [String: String] {
            guard let result = try? JSONDecoder().decode(ToolResult.self, from: Data(content.utf8)), result.verified else { return [:] }
            var rows: [String: String] = [:]
            for line in result.summary.split(separator: "\n") where line.hasPrefix("element_id=") {
                guard let first = line.split(separator: " ").first else { continue }
                let id = String(first.dropFirst("element_id=".count))
                func field(_ start: String, _ end: String) -> String {
                    guard let from = line.range(of: start), let to = line[from.upperBound...].range(of: end) else { return "<absent>" }
                    return String(decoding: line[from.upperBound..<to.lowerBound].utf8.prefix(160), as: UTF8.self)
                }
                rows[id] = "role=\(String(reflecting: field(" role=", " title="))), title=\(String(reflecting: field(" title=", " description="))), identifier=\(String(reflecting: field(" identifier=", " value=")))"
            }
            return rows
        }
    }
}
