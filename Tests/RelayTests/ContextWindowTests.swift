import Foundation
import Testing
@testable import Relay

struct ContextWindowTests {
    @Test func removesOnlyEarlierSegmentsAndKeepsCurrentToolPair() throws {
        let call = ToolCall(id: "current", name: "list_apps", arguments: [:])
        let history = [ModelMessage(role: "user", content: String(repeating: "old", count: 1000)),
                       ModelMessage(role: "assistant", content: "Earlier answer"),
                       ModelMessage(role: "user", content: "Open Calculator"),
                       ModelMessage(role: "assistant", content: "", toolCalls: [call]),
                       ModelMessage(role: "tool", content: "Installed Calculator", toolCallID: "current", toolName: "list_apps")]
        let selected = try ContextWindow.prepare(history, activeStart: 2, budget: 700)
        #expect(selected.omittedMessages == 2)
        #expect(ContextWindow.isWellFormed(selected.messages))
        #expect(selected.messages.contains { $0.content == "Open Calculator" })
        #expect(selected.messages.first?.content.contains("Full history remains") == true)
        #expect(history.count == 5)
    }
    @Test func refusesToDiscardCurrentOversizedRequest() {
        #expect(throws: (any Error).self) { try ContextWindow.prepare([ModelMessage(role: "user", content: String(repeating: "x", count: 1000))], activeStart: 0, budget: 500) }
    }
    @Test func interruptedActionSettlingAfterNewRequestKeepsItsOrigin() throws {
        let call = ToolCall(id: "late", name: "open_app", arguments: [:])
        let history = [ModelMessage(role: "user", content: "Open Calculator"),
                       ModelMessage(role: "assistant", content: "", toolCalls: [call]),
                       ModelMessage(role: "user", content: "Now help me write"),
                       ModelMessage(role: "tool", content: "Settled after Stop", toolCallID: "late", toolName: "open_app")]
        let selected = try ContextWindow.prepare(history, activeStart: 2, budget: 700)
        #expect(selected.omittedMessages == 0)
        #expect(ContextWindow.isWellFormed(selected.messages))
        #expect(throws: (any Error).self) { try ContextWindow.prepare(history, activeStart: 2, budget: 30) }
    }
    @Test func malformedActiveTailFailsBeforeInference() {
        #expect(throws: (any Error).self) { try ContextWindow.prepare([ModelMessage(role: "user", content: "Hi"), ModelMessage(role: "tool", content: "orphan", toolCallID: "missing", toolName: "list_apps")], activeStart: 0, budget: 700) }
    }
    @Test func boundedObservationRetainsUncertaintyAndProtocolWithoutChangingAudit() throws {
        let original = ModelMessage(role: "tool", content: JSONValue.object(["summary": .string(String(repeating: "🌍", count: 5000)), "evidence": .string("Not independently checked"), "verified": .bool(false)]).pretty, toolCallID: "source", toolName: "read_file")
        let compact = ContextWindow.boundedObservation(original)
        #expect(compact.content.utf8.count < 4000)
        #expect(compact.toolCallID == original.toolCallID)
        #expect(compact.content.contains("omitted content is not evidence"))
        let data = try #require(compact.content.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["verified"] as? Bool == false)
        #expect(original.content.utf8.count > 20000)
        #expect(ContextWindow.boundedObservation(ModelMessage(role: "user", content: original.content)).content == original.content)
    }
    @Test func orphanToolResultsAreNotTreatedAsACompleteProtocol() {
        #expect(!ContextWindow.isWellFormed([ModelMessage(role: "tool", content: "old", toolCallID: "missing", toolName: "list_apps")]))
    }
}
