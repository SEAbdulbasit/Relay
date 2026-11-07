import Foundation
import Testing
@testable import Relay

@MainActor
struct EmptyModelResponseRecoveryTests {
    @Test
    func emptyRepliesPreserveCompletedToolPairsAndNeverReplayTheirEffects() async throws {
        let completed = ToolCall(id: "synthetic-completed-launch", name: "open_app", arguments: ["app": .string("Calculator")])
        var turns = 0
        var dispatches = 0
        var completedPairWasPreserved = true
        let store = AssistantStore(persistenceURL: nil, complete: { messages, _, _ in
            turns += 1
            if turns == 1 { return ModelReply(content: "", toolCalls: [completed]) }
            let requests = messages.flatMap(\.toolCalls).filter { $0.id == completed.id }
            let results = messages.filter { $0.role == "tool" && $0.toolCallID == completed.id }
            completedPairWasPreserved = completedPairWasPreserved && requests == [completed]
                && results.count == 1 && results[0].content.contains("Synthetic completed launch")
            if turns <= 3 { throw ModelProtocolError.emptyResponse }
            if turns == 4 {
                #expect(messages.last?.content.contains("Do not replay a completed action") == true)
            } else {
                #expect(messages.last?.content.contains("ENTIRE current request") == true)
                #expect(messages.last?.content.contains("Never repeat a completed effect") == true)
            }
            return ModelReply(content: "The synthetic launch was checked.", toolCalls: [])
        }, execute: { call in
            #expect(call == completed)
            dispatches += 1
            return ToolResult(summary: "Synthetic completed launch", evidence: "Inert executor oracle; no application was opened.", verified: true)
        })
        store.draft = "Open the synthetic Calculator fixture."
        store.send()
        for _ in 0..<2_000 where store.isRunning { await Task.yield() }
        #expect(!store.isRunning && store.errorMessage == nil)
        #expect(turns == 5 && dispatches == 1 && completedPairWasPreserved)
        #expect(store.activity.filter { $0.name == "Correcting action request" }.count == 2)
        #expect(store.activity.filter { $0.name == "Checking requested outcome" }.count == 1)
        #expect(store.messages.last?.text.contains("Synthetic completed launch") == true)
    }

    @Test
    func aThirdConsecutiveEmptyReplyStopsWithoutDispatch() async throws {
        var turns = 0
        var dispatches = 0
        let store = AssistantStore(persistenceURL: nil, complete: { _, _, _ in
            turns += 1
            throw ModelProtocolError.emptyResponse
        }, execute: { _ in
            dispatches += 1
            return ToolResult(summary: "Must not run", evidence: "No tool was proposed.", verified: false)
        })
        store.draft = "Read the synthetic fixture."
        store.send()
        for _ in 0..<2_000 where store.isRunning { await Task.yield() }
        #expect(!store.isRunning && store.phase == .failed && store.errorMessage != nil)
        #expect(turns == 3 && dispatches == 0)
        #expect(store.activity.filter { $0.name == "Correcting action request" }.count == 2)
    }
}
