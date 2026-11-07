import Foundation
import Testing
@testable import Relay

struct ActiveContextCompactionTests {
    @Test func sequentialReusedCallIDsTrackTheirOwnObservationOrderWithoutLosingTheFreshResult() throws {
        let observe = ToolCall(id: "shared-observe-id", name: "observe_app", arguments: ["bundle_id": .string("dev.relay.fixture")])
        let changed = ToolCall(id: "change", name: "set_value", arguments: ["bundle_id": .string("dev.relay.fixture"),
            "element_id": .string("old"), "value": .string("Exact new text")])
        let history = [ModelMessage(role: "user", content: "Inspect the updated field"),
            ModelMessage(role: "assistant", content: "", toolCalls: [observe]), result(observe, "Historical source", verified: true),
            ModelMessage(role: "assistant", content: "", toolCalls: [changed]), result(changed, "New text read back", verified: true),
            ModelMessage(role: "assistant", content: "", toolCalls: [observe]), result(observe, "Exact fresh control source", verified: true)]
        let window = try ContextWindow.prepare(history, activeStart: 0, budget: 4_000)
        let previous = try JSONDecoder().decode([String: JSONValue].self, from: Data(window.messages[2].content.utf8))
        #expect(previous["reference_status"]?.string?.contains("Expired") == true)
        #expect(window.messages.last?.content == history.last?.content)
        #expect(ContextWindow.isWellFormed(window.messages) && window.messages.flatMap(\.toolCalls) == history.flatMap(\.toolCalls))
    }

    @Test func laterCallsInOneAssistantBatchExpireEarlierNativeObservationReferences() throws {
        let bundle = "dev.relay.fixture"
        let fieldID = "36E9E462-7797-40CE-8AD0-A78A449F5049"
        let observe = ToolCall(id: "observe-in-batch", name: "observe_app", arguments: ["bundle_id": .string(bundle)])
        let mutation = ToolCall(id: "mutation-in-batch", name: "set_value", arguments: ["bundle_id": .string(bundle),
            "element_id": .string(fieldID), "value": .string("Exact requested text")])
        let snapshot = "element_id=\(fieldID) role=AXTextField title=Fixture input description= identifier=field value=Old café enabled=true"
        let observation = ModelMessage(role: "tool", content: JSONValue.object([
            "summary": .string(snapshot), "evidence": .string("Native AX observation of \(bundle), process 123."),
            "verified": .bool(true)]).pretty, toolCallID: observe.id, toolName: observe.name)
        let history = [ModelMessage(role: "user", content: "Update only the observed fixture field"),
            ModelMessage(role: "assistant", content: "", toolCalls: [observe, mutation]), observation,
            result(mutation, "Effect uncertain; inspect before retrying.", verified: false)]
        let window = try ContextWindow.prepare(history, activeStart: 0, budget: 4_000)
        let payload = try JSONDecoder().decode([String: JSONValue].self, from: Data(window.messages[2].content.utf8))
        #expect(payload["reference_status"]?.string?.contains("Expired") == true)
        #expect(payload["summary"]?.string?.contains(fieldID) == false)
        #expect(payload["summary"]?.string?.contains("value=Old café") == true)
        #expect(window.messages.flatMap(\.toolCalls) == history.flatMap(\.toolCalls))
        #expect(window.messages.last?.content == history.last?.content && ContextWindow.isWellFormed(window.messages))
    }

    @Test func expiredNativeRecordsLoseOnlyExecutableReferenceLocationsAndFreshRecordsStayByteExact() throws {
        let windowID = "C562D460-2852-43EC-9729-C23709B61A05", fieldID = "36E9E462-7797-40CE-8AD0-A78A449F5049"
        let literal = "Literal element_id=DF2C0F7E-C6BE-4ED0-A4E8-65C58D343594 window_id=not-a-reference café\u{301}"
        let snapshot = "element_id=\(windowID) role=AXWindow title=Fixture description= identifier=window value= enabled=true focused=true minimized=false\n"
            + "element_id=\(fieldID) role=AXTextField title=Fixture input description= identifier=field value=\(literal) enabled=true window_id=\(windowID)"
        let observe = ToolCall(id: "observe", name: "observe_app", arguments: ["bundle_id": .string("dev.relay.fixture")])
        let native = ModelMessage(role: "tool", content: JSONValue.object(["summary": .string(snapshot),
            "evidence": .string("Native AX observation of dev.relay.fixture, process 123. IDs expire after 60 seconds or the next observation or mutation."),
            "verified": .bool(true)]).pretty, toolCallID: observe.id, toolName: observe.name)
        let fresh = [ModelMessage(role: "user", content: "Inspect the fixture"), ModelMessage(role: "assistant", content: "", toolCalls: [observe]), native]
        let unchanged = try ContextWindow.prepare(fresh, activeStart: 0, budget: 4_000)
        #expect(unchanged.messages.last?.content.utf8.elementsEqual(native.content.utf8) == true)
        let mutation = ToolCall(id: "changed", name: "set_value", arguments: ["bundle_id": .string("dev.relay.fixture"),
            "element_id": .string(fieldID), "value": .string("Exact requested value")])
        let history = fresh + [ModelMessage(role: "assistant", content: "", toolCalls: [mutation]), result(mutation, "Exact value read back", verified: true)]
        let window = try ContextWindow.prepare(history, activeStart: 0, budget: 4_000)
        let payload = try JSONDecoder().decode([String: JSONValue].self, from: Data(window.messages[2].content.utf8))
        let expired = try #require(payload["summary"]?.string)
        #expect(expired.contains(literal) && expired.contains("role=AXTextField title=Fixture input"))
        #expect(!expired.contains(windowID) && !expired.contains(fieldID))
        #expect(expired.split(separator: "\n").allSatisfy { $0.hasPrefix("expired_control role=AX") })
        #expect(payload["reference_status"]?.string?.contains("Executable native reference tokens were removed") == true)
        #expect(window.messages.flatMap(\.toolCalls) == history.flatMap(\.toolCalls), "Historical executed call arguments remain exact.")
        #expect(native.content.contains(windowID), "The original audit retains the original native references.")
    }

    @Test func anEarlierCompletedTaskCanContributeFactsButNeverActionableNativeIDs() throws {
        let call = ToolCall(id: "earlier", name: "observe_app", arguments: ["bundle_id": .string("dev.relay.source")])
        let source = "Earlier fact café\u{301}; element_id=earlier-id title=Original source"
        let history = [ModelMessage(role: "user", content: "Earlier completed request"),
            ModelMessage(role: "assistant", content: "", toolCalls: [call]), result(call, source, verified: true),
            ModelMessage(role: "assistant", content: "Earlier answer"), ModelMessage(role: "user", content: "A new small request")]
        let window = try ContextWindow.prepare(history, activeStart: 4, budget: 4_000)
        let message = try #require(window.messages.first(where: { $0.toolCallID == call.id }))
        let payload = try JSONDecoder().decode([String: JSONValue].self, from: Data(message.content.utf8))
        #expect(payload["summary"]?.string?.utf8.elementsEqual(source.utf8) == true)
        #expect(payload["reference_status"]?.string?.contains("Expired from an earlier task") == true)
        #expect(window.messages.last?.content == "A new small request" && ContextWindow.isWellFormed(window.messages))
    }

    @Test func anyLaterMutationAttemptMarksNativeRefsExpiredWithoutDroppingHistoricalFactsOrUncertainty() throws {
        let observe = ToolCall(id: "observe", name: "observe_app", arguments: ["bundle_id": .string("dev.relay.source")])
        let mutation = ToolCall(id: "mutation", name: "set_value", arguments: ["bundle_id": .string("dev.relay.other-app"),
            "element_id": .string("other-field"), "value": .string("Exact requested text")])
        let source = "Historical source fact café\u{301}; element_id=source-field state=original"
        let history = [ModelMessage(role: "user", content: "Keep exact source facts"),
            ModelMessage(role: "assistant", content: "", toolCalls: [observe]), result(observe, source, verified: true),
            ModelMessage(role: "assistant", content: "", toolCalls: [mutation]), result(mutation, "Effect uncertain. Do not retry.", verified: false)]
        let window = try ContextWindow.prepare(history, activeStart: 0, budget: 4_000)
        let payload = try JSONDecoder().decode([String: JSONValue].self, from: Data(window.messages[2].content.utf8))
        #expect(payload["summary"]?.string?.utf8.elementsEqual(source.utf8) == true)
        #expect(payload["reference_status"]?.string?.contains("Expired") == true)
        #expect(payload["reference_status"]?.string?.contains("does not prove") == true)
        #expect(window.messages.last?.content == history.last?.content)
        #expect(window.compactedMessages == 0 && ContextWindow.isWellFormed(window.messages))
    }

    @Test func supersededNativeReceiptsFitWhileLatestLastControlExactTaskAndOpaqueWorkflowIDsSurvive() throws {
        let bundle = "dev.relay.synthetic-editor"
        let goal = "Keep exact decomposed bytes cafe\u{301} 🌍 and review the dependent draft before Apply."
        let old = ToolCall(id: "observe-old", name: "observe_app", arguments: ["bundle_id": .string(bundle)])
        let draft = ToolCall(id: "draft", name: "create_mail_draft", arguments: ["message_json": .string("exact synthetic payload")])
        let changed = ToolCall(id: "set", name: "set_value", arguments: ["bundle_id": .string(bundle), "element_id": .string("old-field"), "value": .string(goal)])
        let fresh = ToolCall(id: "observe-fresh", name: "observe_app", arguments: ["bundle_id": .string(bundle)])
        let oldSource = String(repeating: "old-control has superseded label and state\n", count: 100)
        let latestSource = String(repeating: "fresh-static source text\n", count: 120) + "element_id=LAST-CONTROL role=AXButton title=Apply enabled=true value=current-state"
        let opaque = "draft_id: OPAQUE-DRAFT-3921\nreview_id: OPAQUE-REVIEW-8247\nuncertain: do not send or retry"
        let history = [ModelMessage(role: "user", content: goal),
            ModelMessage(role: "assistant", content: "I will inspect this source.", toolCalls: [old]), result(old, oldSource, verified: false),
            ModelMessage(role: "assistant", content: "", toolCalls: [draft]), result(draft, opaque, verified: true),
            ModelMessage(role: "assistant", content: "Now update only the exact user field.", toolCalls: [changed]), result(changed, "Exact value read back: \(goal)", verified: true),
            ModelMessage(role: "assistant", content: "Inspect refreshed controls.", toolCalls: [fresh]), result(fresh, latestSource, verified: true)]
        let window = try ContextWindow.prepare(history, activeStart: 0, budget: 4_300)
        let originalLatest = try #require(history.last)
        #expect(ContextWindow.isWellFormed(window.messages) && window.compactedMessages > 0)
        #expect(ContextWindow.bytes(window.messages) <= 4_300 && window.messages.count == history.count)
        #expect(window.messages.first?.content.utf8.elementsEqual(goal.utf8) == true)
        #expect(window.messages.last?.content.utf8.elementsEqual(originalLatest.content.utf8) == true)
        #expect(window.messages.first(where: { $0.toolCallID == "draft" })?.content == history[4].content)
        #expect(window.messages.flatMap(\.toolCalls) == history.flatMap(\.toolCalls))
        let abbreviated = try #require(window.messages.first(where: { $0.toolCallID == old.id }))
        let value = try JSONDecoder().decode([String: JSONValue].self, from: Data(abbreviated.content.utf8))
        #expect(value["verified"] == .bool(false) && value["bundle_id"] == .string(bundle))
        #expect(abbreviated.content.contains("Re-observe for source facts"))
        let originalAudit = try JSONDecoder().decode(ToolResult.self, from: Data(history[2].content.utf8))
        #expect(originalAudit.summary.utf8.elementsEqual(oldSource.utf8), "The original audit is never changed.")
    }

    @Test func latestOversizedObservationFailsInsteadOfTruncatingItsLastTarget() throws {
        let call = ToolCall(id: "fresh", name: "observe_app", arguments: ["bundle_id": .string("dev.relay.fixture")])
        let snapshot = String(repeating: "Control metadata\n", count: 400) + "element_id=only-target title=Apply"
        let history = [ModelMessage(role: "user", content: "Click Apply after review"),
            ModelMessage(role: "assistant", content: "", toolCalls: [call]), result(call, snapshot, verified: true)]
        #expect(throws: RelayError.self) { try ContextWindow.prepare(history, activeStart: 0, budget: 1_000) }
        #expect(history.last?.content.contains("only-target") == true)
    }

    @Test func unrelatedAppSourceAndOpaqueReceiptsCannotBeSacrificedToFit() throws {
        let first = ToolCall(id: "first", name: "observe_app", arguments: ["bundle_id": .string("dev.relay.source")])
        let second = ToolCall(id: "second", name: "observe_app", arguments: ["bundle_id": .string("dev.relay.destination")])
        let history = [ModelMessage(role: "user", content: "Keep both selected source facts"),
            ModelMessage(role: "assistant", content: "", toolCalls: [first]), result(first, String(repeating: "SOURCE FACT\n", count: 200), verified: true),
            ModelMessage(role: "assistant", content: "", toolCalls: [second]), result(second, "Current target", verified: true)]
        #expect(throws: RelayError.self) { try ContextWindow.prepare(history, activeStart: 0, budget: 1_000) }
    }

    @Test func noPressurePreservesEveryOriginalByteAndAssistantNarration() throws {
        let call = ToolCall(id: "fresh", name: "observe_app", arguments: ["bundle_id": .string("dev.relay.fixture")])
        let history = [ModelMessage(role: "user", content: "Exact request"),
            ModelMessage(role: "assistant", content: "Preserved model narration", toolCalls: [call]), result(call, "Exact fresh source", verified: true)]
        let window = try ContextWindow.prepare(history, activeStart: 0, budget: 4_000)
        #expect(window.compactedMessages == 0 && window.messages.count == history.count)
        #expect(window.messages.map(\.content) == history.map(\.content))
    }

    private func result(_ call: ToolCall, _ summary: String, verified: Bool) -> ModelMessage {
        ModelMessage(role: "tool", content: JSONValue.object(["summary": .string(summary), "evidence": .string("Synthetic fixture receipt"),
            "verified": .bool(verified)]).pretty, toolCallID: call.id, toolName: call.name)
    }
}
