import Foundation
import Testing
@testable import Relay

@MainActor
struct ProductionContextCapacityTests {
    @Test func aLargeCompleteLocalAuditDoesNotBlockANewSmallTaskOrDeletePriorConversation() async throws {
        let archivedAnswer = String(repeating: "Archived synthetic answer — café 🌍. ", count: 180)
        let exactCurrent = "Current request preserves cafe\u{301} 🌍 exactly."
        var turns = 0, finalInput: [ModelMessage] = []
        let store = AssistantStore(persistenceURL: nil, complete: { messages, tools, _ in
            turns += 1
            _ = try LocalModelClient.prepareContext(messages: messages, tools: tools)
            if turns <= 20 { return ModelReply(content: archivedAnswer, toolCalls: []) }
            finalInput = messages
            return ModelReply(content: "Current task finished.", toolCalls: [])
        })
        for index in 0..<20 {
            store.draft = "Earlier completed synthetic request \(index)"
            store.send()
            for _ in 0..<2_000 where store.isRunning { await Task.yield() }
            try #require(!store.isRunning && store.errorMessage == nil)
        }
        let priorConversation = store.messages.map(\.text)
        try #require(priorConversation.reduce(0) { $0 + $1.utf8.count } > 110_000)
        store.draft = exactCurrent
        store.send()
        for _ in 0..<2_000 where store.isRunning { await Task.yield() }
        #expect(turns == 21 && !store.isRunning && store.errorMessage == nil)
        #expect(finalInput.contains { $0.role == "user" && $0.content.utf8.elementsEqual(exactCurrent.utf8) })
        #expect(Array(store.messages.prefix(priorConversation.count)).map(\.text) == priorConversation,
            "Compaction may reduce only the inference view, never the complete local conversation.")
        #expect(store.activity.filter { $0.name == "Response finished" }.count == 21)
    }

    @Test func productionPromptAndFullSchemasLeaveRoomForACompleteFreshNativeObservation() async throws {
        let expected = "Native Gemma café 8431"
        let goal = """
            Only control the already-running Relay Accessibility Fixture app, bundle \(AccessibilityCheckRunner.fixtureBundleID). Do not list, open, inspect or control any other app. In that fixture, replace the field labelled Fixture input with exactly: \(expected)
            Then click its Apply button exactly once. Inspect the resulting Fixture result and report whether it matches. This is an inert local test form, not a submission. Use the ordinary exact review for Apply; do not bypass review or repeat a click. Leave the disabled control untouched.
            """
        let controls = (0..<16).map { index in
            "element_id=fixture-control-\(index) role=AXStaticText title=Native fixture source row \(index) value=\(String(repeating: "ordinary bounded source text ", count: 5)) window_id=original-window"
        }.joined(separator: "\n")
        let snapshot = controls + "\nelement_id=fresh-input-8431 role=AXTextField title=Fixture input value= identifier=relay.fixture.input window_id=original-window\n"
            + "element_id=fresh-apply-8431 role=AXButton title=Apply identifier=relay.fixture.apply window_id=original-window\n"
        var turns = 0
        let store = AssistantStore(persistenceURL: nil, complete: { messages, tools, _ in
            turns += 1
            let systemBytes = messages.filter { $0.role == "system" }.reduce(0) { $0 + $1.content.utf8.count }
            let schemaBytes = try JSONEncoder().encode(tools).count
            let historyBytes = ContextWindow.bytes(messages.filter { $0.role != "system" })
            print("Production native context budget: turn=\(turns), systemBytes=\(systemBytes), schemaBytes=\(schemaBytes), historyBytes=\(historyBytes), availableHistoryBytes=\(LocalModelClient.maximumContextBytes - systemBytes - schemaBytes), freshSummaryBytes=\(snapshot.utf8.count).")
            _ = try LocalModelClient.prepareContext(messages: messages, tools: tools)
            if turns == 1 { return ModelReply(content: "", toolCalls: [ToolCall(name: "observe_app", arguments: ["bundle_id": .string(AccessibilityCheckRunner.fixtureBundleID)])]) }
            let message = try #require(messages.last(where: { $0.role == "tool" && $0.toolName == "observe_app" }))
            let result = try JSONDecoder().decode(ToolResult.self, from: Data(message.content.utf8))
            #expect(result.summary.utf8.elementsEqual(snapshot.utf8), "Every fresh control and state byte must survive; the requested Apply target is deliberately last.")
            #expect(messages.contains { $0.role == "user" && $0.content.utf8.elementsEqual(goal.utf8) })
            return ModelReply(content: "Synthetic native observation retained.", toolCalls: [])
        }, execute: { call in
            try #require(call.name == "observe_app")
            return ToolResult(summary: snapshot, evidence: "Synthetic native fixture observation; no desktop controlled.", verified: true)
        })
        store.configuration = ModelConfiguration(modelPath: "/synthetic/context-capacity.litertlm")
        store.draft = goal
        store.send()
        for _ in 0..<2_000 where store.isRunning { await Task.yield() }
        #expect(!store.isRunning && store.errorMessage == nil, Comment(rawValue: store.errorMessage ?? "No Store error"))
        #expect(turns == 2)
    }
}
