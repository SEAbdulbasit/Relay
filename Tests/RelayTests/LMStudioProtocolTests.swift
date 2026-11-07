import Foundation
import Testing
@testable import Relay

struct LMStudioProtocolTests {
    private let tool = ToolDefinition(name: "calculate", description: "Synthetic arithmetic", parameters: .object([
        "type": .string("object"), "properties": .object(["expression": .object(["type": .string("string")])]),
        "required": .array([.string("expression")]), "additionalProperties": .bool(false)]))

    @Test func onlyLiteralLoopbackAndFixedCompatiblePathsAreAdmitted() throws {
        #expect(try LMStudioEndpoint().baseURL.absoluteString == "http://127.0.0.1:1234/v1")
        #expect(try LMStudioEndpoint(baseURL: "http://[::1]:2345/v1").completionsURL.absoluteString == "http://[::1]:2345/v1/chat/completions")
        for value in ["http://localhost:1234/v1", "http://127.0.0.1.example:1234/v1", "http://192.168.1.2:1234/v1",
                      "http://127.0.0.2:1234/v1", "http://127.0.0.1/v1", "https://127.0.0.1:1234/v1",
                      "http://user:token@127.0.0.1:1234/v1", "http://127.0.0.1:1234/v1?redirect=other",
                      "http://127.0.0.1:1234/other", "http://127.0.0.1:1234/v1#other", "http://%31%32%37.0.0.1:1234/v1"] {
            #expect(throws: LMStudioFailure.invalidEndpoint) { try LMStudioEndpoint(baseURL: value) }
        }
        for port in [0, -1, 65_536] { #expect(throws: LMStudioFailure.invalidEndpoint) { try LMStudioEndpoint(port: port) } }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(LMStudioEndpoint.self, from: Data(#"{"host":"127.0.0.1","port":0}"#.utf8))
        }
    }

    @Test func exactCallResultIDsAndSteeringSurviveCanonicalWireHistory() throws {
        let call = ToolCall(id: "opaque-original-id-7", name: "calculate", arguments: ["expression": .string("6*7")])
        let history = [ModelMessage(role: "user", content: "Calculate 6*7 once."),
            ModelMessage(role: "assistant", content: "", toolCalls: [call]),
            ModelMessage(role: "user", content: "User steering: preserve my draft."),
            ModelMessage(role: "tool", content: "{\"answer\":42}", toolCallID: call.id, toolName: call.name)]
        let ordered = try LMStudioWireCodec.canonicalHistory(history)
        #expect(ordered.map(\.role) == ["user", "assistant", "tool", "user"])
        #expect(ordered[1].toolCalls == [call] && ordered[2].toolCallID == call.id)
        #expect(ordered[3].content == history[2].content && history[2].role == "user")
        let data = try LMStudioWireCodec.request(selection: selection(), messages: history, tools: [tool])
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .array(let messages) = value.object?["messages"] else { Issue.record("Missing wire history"); return }
        guard case .array(let calls) = messages[1].object?["tool_calls"] else { Issue.record("Missing tool call"); return }
        #expect(calls[0].object?["id"] == .string(call.id) && messages[2].object?["tool_call_id"] == .string(call.id))
        #expect(calls[0].object?["function"]?.object?["arguments"] == .string(#"{"expression":"6*7"}"#))
        #expect(value.object?["integrations"] == nil && value.object?["previous_response_id"] == nil)
    }

    @Test func mismatchedDuplicateOrIncompleteHistoryRefusesBeforeEncoding() throws {
        let call = ToolCall(id: "call-1", name: "calculate", arguments: [:])
        let assistant = ModelMessage(role: "assistant", content: "", toolCalls: [call])
        for history in [[assistant], [assistant, ModelMessage(role: "tool", content: "result", toolCallID: "wrong-id", toolName: call.name)],
                        [assistant, ModelMessage(role: "tool", content: "result", toolCallID: call.id, toolName: "wrong_name")],
                        [ModelMessage(role: "user", content: "Untrusted text", toolCalls: [call])],
                        [assistant, ModelMessage(role: "tool", content: "42", toolCallID: call.id, toolName: call.name), assistant]] {
            #expect(throws: LMStudioFailure.malformedHistory) { try LMStudioWireCodec.canonicalHistory(history) }
        }
    }

    @Test func UTF8ScalarAndSSEBoundariesCanSplitAtEverySingleByte() throws {
        let text = "Café 👩‍💻 العربية"
        let data = try stream([chunk(delta: ["role": .string("assistant"), "content": .string(text)]),
            chunk(delta: [:], finish: "stop")])
        var decoder = LMStudioSSEDecoder(availableTools: [])
        for byte in data { try decoder.feed(Data([byte])) }
        let reply = try decoder.end()
        #expect(reply.content == text && reply.toolCalls.isEmpty && !reply.content.contains("�"))
        for split in 0...data.count {
            var twoChunks = LMStudioSSEDecoder(availableTools: [])
            try twoChunks.feed(Data(data.prefix(split))); try twoChunks.feed(Data(data.dropFirst(split)))
            #expect(try twoChunks.end().content == text)
        }
    }

    @Test func fragmentedArgumentsDoNotBecomeAnActionUntilTerminalCompletion() throws {
        let first = try event(chunk(delta: ["tool_calls": .array([.object(["index": .number(0), "id": .string("exact-call-12"),
            "type": .string("function"), "function": .object(["name": .string("calculate"), "arguments": .string("{\"expression\":\"")])])])]))
        let second = try event(chunk(delta: ["tool_calls": .array([.object(["index": .number(0), "id": .string("exact-call-12"),
            "function": .object(["name": .string("calculate"), "arguments": .string("6*7\"}")])])])], finish: "tool_calls"))
        var decoder = LMStudioSSEDecoder(availableTools: ["calculate"])
        try decoder.feed(first); #expect(decoder.completed == nil)
        try decoder.feed(second); #expect(decoder.completed == nil)
        #expect(throws: LMStudioFailure.incompleteStream) { try decoder.end() }
        try decoder.feed(Data("data: [DONE]\r\n\r\n".utf8))
        let reply = try decoder.end()
        #expect(reply.toolCalls == [ToolCall(id: "exact-call-12", name: "calculate", arguments: ["expression": .string("6*7")])])
        let history = [ModelMessage(role: "assistant", content: reply.content, toolCalls: reply.toolCalls),
            ModelMessage(role: "tool", content: "42", toolCallID: "exact-call-12", toolName: "calculate")]
        #expect(try LMStudioWireCodec.canonicalHistory(history)[1].toolCallID == "exact-call-12")
    }

    @Test func indexIDAndNameDriftCannotRewriteAPartialCall() throws {
        for changed in [["id": JSONValue.string("different")],
                        ["function": .object(["name": .string("open_app")])],
                        ["type": .string("native_shell")]] {
            var decoder = LMStudioSSEDecoder(availableTools: ["calculate", "open_app"])
            let original: JSONValue = .object(["index": .number(0), "id": .string("original"), "type": .string("function"),
                "function": .object(["name": .string("calculate"), "arguments": .string("{")])])
            try decoder.feed(event(chunk(delta: ["tool_calls": .array([original])])))
            var next = changed; next["index"] = .number(0)
            #expect(throws: LMStudioFailure.malformedToolCall) {
                try decoder.feed(event(chunk(delta: ["tool_calls": .array([.object(next)])])))
            }
            #expect(decoder.completed == nil)
        }
    }

    @Test func incompleteTruncatedMalformedOrReusedCallsNeverReturnAFinalAction() throws {
        let validCall = JSONValue.object(["id": .string("call-used"), "type": .string("function"),
            "function": .object(["name": .string("calculate"), "arguments": .string("{}")])])
        #expect(throws: LMStudioFailure.malformedToolCall) {
            try LMStudioWireCodec.finishReply(content: .null, toolCalls: .array([validCall]), finish: "tool_calls",
                availableTools: ["calculate"], priorCallIDs: ["call-used"])
        }
        #expect(throws: LMStudioFailure.malformedToolCall) {
            try LMStudioWireCodec.finishReply(content: .null, toolCalls: .array([validCall, validCall]), finish: "tool_calls",
                availableTools: ["calculate"], priorCallIDs: [])
        }
        #expect(throws: LMStudioFailure.truncatedOutput) {
            try LMStudioWireCodec.finishReply(content: .string("Partial"), toolCalls: .array([validCall]), finish: "length",
                availableTools: ["calculate"], priorCallIDs: [])
        }
        var missingDone = LMStudioSSEDecoder(availableTools: [])
        try missingDone.feed(event(chunk(delta: ["content": .string("Incomplete")], finish: "stop")))
        #expect(throws: LMStudioFailure.incompleteStream) { try missingDone.end() }
        var invalid = LMStudioSSEDecoder(availableTools: [])
        #expect(throws: LMStudioFailure.invalidUTF8) { try invalid.feed(Data([0x64, 0x61, 0x74, 0x61, 0x3a, 0xff, 0x0a])) }
    }

    @Test func usageOnlyFrameCannotChangeTheReplyOrBypassItsFinishReason() throws {
        var decoder = LMStudioSSEDecoder(availableTools: [])
        let usage = JSONValue.object(["id": .string("stream-id"), "choices": .array([]), "usage": .object(["total_tokens": .number(19)])])
        try decoder.feed(stream([chunk(delta: ["content": .string("Exactly complete")]), chunk(delta: [:], finish: "stop"), usage]))
        #expect(try decoder.end().content == "Exactly complete")
        #expect(throws: LMStudioFailure.malformedResponse) { try decoder.feed(Data("data: {\"extra\":true}\n\n".utf8)) }
    }

    @Test func fractionalOrGappedToolIndexesRefuseRatherThanCoercingIdentity() throws {
        for index in [0.5, -1, 8] {
            var decoder = LMStudioSSEDecoder(availableTools: ["calculate"])
            #expect(throws: LMStudioFailure.malformedToolCall) {
                try decoder.feed(event(chunk(delta: ["tool_calls": .array([.object(["index": .number(index),
                    "id": .string("original"), "type": .string("function"), "function": .object([
                        "name": .string("calculate"), "arguments": .string("{}")])])])])))
            }
            #expect(decoder.completed == nil)
        }
        var gapped = LMStudioSSEDecoder(availableTools: ["calculate"])
        try gapped.feed(event(chunk(delta: ["tool_calls": .array([.object(["index": .number(1),
            "id": .string("only-index-one"), "type": .string("function"), "function": .object([
                "name": .string("calculate"), "arguments": .string("{}")])])])], finish: "tool_calls")))
        #expect(throws: LMStudioFailure.malformedToolCall) { try gapped.feed(Data("data: [DONE]\n\n".utf8)) }
        #expect(gapped.completed == nil)
    }

    @Test func oversizedInputAndNonAdvertisedToolsCannotReachTheWire() throws {
        #expect(throws: LMStudioFailure.inputLimit) {
            try LMStudioWireCodec.request(selection: selection(), messages: [
                .init(role: "user", content: String(repeating: "x", count: LMStudioWireCodec.maximumInputBytes + 1))], tools: [])
        }
        let unadvertised = JSONValue.object(["id": .string("call-1"), "type": .string("function"),
            "function": .object(["name": .string("open_app"), "arguments": .string("{}")])])
        #expect(throws: LMStudioFailure.malformedToolCall) {
            try LMStudioWireCodec.finishReply(content: .null, toolCalls: .array([unadvertised]), finish: "tool_calls",
                availableTools: ["calculate"], priorCallIDs: [])
        }
    }

    @Test func structuredInputIsBoundedBeforeArgumentAndSchemaEncoding() throws {
        var tooDeep: JSONValue = .null
        for _ in 0...LMStudioWireCodec.maximumInputDepth { tooDeep = .array([tooDeep]) }
        for value in [JSONValue.string(String(repeating: "x", count: LMStudioWireCodec.maximumInputBytes + 1)),
                      tooDeep, .array(Array(repeating: .null, count: LMStudioWireCodec.maximumInputNodes + 1))] {
            let call = ToolCall(id: "bounded-call", name: "calculate", arguments: ["payload": value])
            let history = [ModelMessage(role: "assistant", content: "", toolCalls: [call]),
                .init(role: "tool", content: "synthetic result", toolCallID: call.id, toolName: call.name)]
            #expect(throws: LMStudioFailure.inputLimit) {
                try LMStudioWireCodec.request(selection: selection(), messages: history, tools: [tool])
            }
        }
        var oversizedSchema = tool
        oversizedSchema.description = String(repeating: "x", count: LMStudioWireCodec.maximumInputBytes + 1)
        #expect(throws: LMStudioFailure.inputLimit) {
            try LMStudioWireCodec.request(selection: selection(), messages: [.init(role: "user", content: "Synthetic")], tools: [oversizedSchema])
        }
    }

    @Test func transportBudgetAppliesBeforeAnyParserAndRejectsOversizedHeaders() throws {
        #expect(LMStudioHTTPTransport.maximumChunkBytes == 8_192 && LMStudioHTTPTransport.maximumQueuedChunks == 16)
        for length in [Int64(LMStudioWireCodec.maximumOutputBytes) + 1, Int64.max] {
            #expect(throws: LMStudioFailure.responseLimit) { try LMStudioHTTPReadBudget(expectedLength: length) }
        }
        #expect(throws: LMStudioFailure.malformedResponse) { try LMStudioHTTPReadBudget(expectedLength: -2) }
        for length in [-1, 0, Int64(LMStudioWireCodec.maximumOutputBytes)] {
            var budget = try LMStudioHTTPReadBudget(expectedLength: length)
            try budget.accept(LMStudioWireCodec.maximumOutputBytes)
            #expect(budget.received == LMStudioWireCodec.maximumOutputBytes)
            #expect(throws: LMStudioFailure.responseLimit) { try budget.accept(1) }
            #expect(budget.received == LMStudioWireCodec.maximumOutputBytes)
        }
    }

    private func selection() throws -> LMStudioSelection { try .init(endpoint: .init(), modelID: "synthetic-model") }
    private func chunk(delta: [String: JSONValue], finish: String? = nil) -> JSONValue {
        .object(["id": .string("stream-id"), "object": .string("chat.completion.chunk"), "choices": .array([
            .object(["index": .number(0), "delta": .object(delta), "finish_reason": finish.map(JSONValue.string) ?? .null])])])
    }
    private func event(_ value: JSONValue) throws -> Data { Data("data: ".utf8) + (try LMStudioWireCodec.jsonData(value)) + Data("\r\n\r\n".utf8) }
    private func stream(_ events: [JSONValue]) throws -> Data {
        try events.reduce(into: Data()) { result, value in result.append(try event(value)) } + Data("data: [DONE]\r\n\r\n".utf8)
    }
}
