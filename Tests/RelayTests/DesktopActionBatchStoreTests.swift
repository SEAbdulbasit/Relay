import Foundation
import Testing
@testable import Relay

@MainActor
struct DesktopActionBatchStoreTests {
    @Test func rejectedBatchExecutesNothingBeforeThePlannerCorrectsIt() async {
        var turns = 0, dispatched: [ToolCall] = []
        let first = ToolCall(name: "set_value", arguments: ["bundle_id": .string("test.inert.app"),
            "element_id": .string("first-old-ref"), "value": .string("Exact café payload")])
        let second = ToolCall(name: "press_control", arguments: ["bundle_id": .string("test.inert.app"),
            "element_id": .string("second-old-ref")])
        let store = AssistantStore(persistenceURL: nil, complete: { messages, _, _ in
            turns += 1
            switch turns {
            case 1: return ModelReply(content: "", toolCalls: [first, second])
            case 2:
                #expect(dispatched.isEmpty, "The entire invalid batch must be rejected before the first write.")
                #expect(messages.last?.content.contains("at most one desktop control change") == true)
                return ModelReply(content: "", toolCalls: [first])
            default: return ModelReply(content: "The single synthetic edit was checked.", toolCalls: [])
            }
        }, execute: { call in
            dispatched.append(call)
            return ToolResult(summary: "Synthetic exact field readback", evidence: "Inert executor only", verified: true)
        })
        store.draft = "Fill only the first synthetic field."
        store.send()
        for _ in 0..<2_000 where store.isRunning { await Task.yield() }
        #expect(!store.isRunning && store.errorMessage == nil && turns == 4)
        #expect(dispatched.count == 1 && dispatched.first?.id == first.id)
        #expect(store.activity.filter { $0.name == "press_control" && $0.status == "requested" }.isEmpty)
        store.stop()
    }

    @Test func repeatedInvalidBatchesFailWithoutAnyPartialAction() async {
        var calls = 0, turns = 0
        let store = AssistantStore(persistenceURL: nil, complete: { _, _, _ in
            turns += 1
            return ModelReply(content: "", toolCalls: [
                ToolCall(name: "open_app", arguments: ["app": .string("test.inert.app")]),
                ToolCall(name: "press_control", arguments: ["bundle_id": .string("test.inert.app"), "element_id": .string("expired")])
            ])
        }, execute: { _ in
            calls += 1
            Issue.record("An invalidated reference batch must not open an app or press a control.")
            throw CancellationError()
        })
        store.draft = "Use only the synthetic target."
        store.send()
        for _ in 0..<2_000 where store.isRunning { await Task.yield() }
        #expect(!store.isRunning && turns == 3 && calls == 0)
        #expect(store.errorMessage != nil && store.phase == .failed)
        store.stop()
    }
}
