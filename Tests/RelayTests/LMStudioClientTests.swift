import Foundation
import Testing
@testable import Relay

@MainActor struct LMStudioClientTests {
    @Test func keylessRequestNeverContainsAuthCookiesOrCLIStateAndPrivateTextStaysInTheRequest() async throws {
        let fixture = Fixture(), client = LMStudioClient(transport: fixture.transport)
        let selection = try LMStudioSelection(endpoint: .init(), modelID: "inert-fixture-model")
        let source = [ModelMessage(role: "user", content: "SYNTHETIC PRIVATE SOURCE café 42")]
        let reply = try await client.complete(messages: source, tools: [], selection: selection)
        #expect(reply.content == "Synthetic complete answer." && reply.toolCalls.isEmpty)
        let requests = await fixture.requests
        #expect(requests.count == 1 && requests[0].url == selection.endpoint.completionsURL)
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") == nil && requests[0].value(forHTTPHeaderField: "Cookie") == nil)
        let payload = try JSONDecoder().decode(JSONValue.self, from: #require(requests[0].httpBody))
        #expect(payload.object?["model"] == .string(selection.modelID))
        #expect(payload.object?["integrations"] == nil && payload.object?["api_key"] == nil)
        #expect(source[0].content == "SYNTHETIC PRIVATE SOURCE café 42")
        try await wait { await fixture.cancelCount == 1 }
    }

    @Test func cancelledUncooperativeResponseCannotReturnAndNewRequestWaitsForDrain() async throws {
        let fixture = Fixture(); await fixture.setHeld(true)
        let client = LMStudioClient(transport: fixture.transport), selection = try selected()
        let request = Task { try await client.complete(messages: messages, tools: [], selection: selection) }
        try await wait { await fixture.requests.count == 1 }
        await client.invalidate()
        await #expect(throws: LMStudioFailure.busy) { try await client.complete(messages: messages, tools: [], selection: selection) }
        await fixture.release()
        await #expect(throws: CancellationError.self) { try await request.value }
        await client.drain()
        _ = try await client.complete(messages: messages, tools: [], selection: selection)
        #expect(await fixture.requests.count == 2)
    }

    @Test func callerCancellationAndHTTPAuthFailureNeverProduceAnActionOrUseCredentials() async throws {
        let fixture = Fixture(); await fixture.setHeld(true)
        let client = LMStudioClient(transport: fixture.transport), selection = try selected()
        let request = Task { try await client.complete(messages: messages, tools: [], selection: selection) }
        try await wait { await fixture.requests.count == 1 }
        request.cancel(); await fixture.release()
        await #expect(throws: CancellationError.self) { try await request.value }
        await fixture.setStatus(401)
        await #expect(throws: LMStudioFailure.authenticationRequired) { try await client.complete(messages: messages, tools: [], selection: selection) }
        #expect(await fixture.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
    }

    @Test func redirectedResponseIsRejectedBeforeAnyBodyIsAccepted() async throws {
        let fixture = Fixture(); await fixture.setResponseURL(URL(string: "https://example.invalid/receive")!)
        let client = LMStudioClient(transport: fixture.transport)
        await #expect(throws: LMStudioFailure.invalidEndpoint) { try await client.complete(messages: messages, tools: [], selection: selected()) }
    }

    @Test func imageRequiresExactSelectionProbeAndMarkerIsNotPutIntoThePrompt() async throws {
        let fixture = Fixture(), client = LMStudioClient(transport: fixture.transport), selection = try selected()
        let attachment = LMStudioVisionAttachment(jpeg: Data("INERT JPEG BYTES".utf8), annotation: "Synthetic image only", validate: {})
        await #expect(throws: LMStudioFailure.visionNotVerified) {
            try await client.complete(messages: messages, tools: [], selection: selection, vision: attachment)
        }
        #expect(await fixture.requests.isEmpty)
        await fixture.setAnswer("GX47QP")
        try await client.verifyVision(selection: selection, syntheticImage: attachment, expectedMarker: "GX47QP")
        let probe = try #require(await fixture.requests.first?.httpBody)
        #expect(!String(decoding: probe, as: UTF8.self).contains("GX47QP"))
        _ = try await client.complete(messages: messages, tools: [], selection: selection, vision: attachment)
        let changed = try LMStudioSelection(endpoint: selection.endpoint, modelID: "different-model")
        await #expect(throws: LMStudioFailure.visionNotVerified) {
            try await client.complete(messages: messages, tools: [], selection: changed, vision: attachment)
        }
        await fixture.setAnswer("NOT THE MARKER")
        await #expect(throws: LMStudioFailure.visionProbeFailed) {
            try await client.verifyVision(selection: selection, syntheticImage: attachment, expectedMarker: "GX47QP")
        }
        await #expect(throws: LMStudioFailure.visionNotVerified) {
            try await client.complete(messages: messages, tools: [], selection: selection, vision: attachment)
        }
        await client.invalidate()
        await #expect(throws: LMStudioFailure.visionNotVerified) {
            try await client.complete(messages: messages, tools: [], selection: selection, vision: attachment)
        }
    }

    @Test func malformedPairFailsBeforeTransportAndVisibleModelListDoesNotClaimCapabilities() async throws {
        let fixture = Fixture(), client = LMStudioClient(transport: fixture.transport), selection = try selected()
        let invalid = [ModelMessage(role: "tool", content: "Source", toolCallID: "orphan", toolName: "calculate")]
        await #expect(throws: LMStudioFailure.malformedHistory) { try await client.complete(messages: invalid, tools: [], selection: selection) }
        #expect(await fixture.requests.isEmpty)
        let models = try await client.listModels(endpoint: selection.endpoint)
        #expect(models == ["inert-fixture-model"])
        #expect(await fixture.requests.last?.url == selection.endpoint.modelsURL)
    }

    @Test func sourceRevokedDuringInferenceRejectsTheLateImageReply() async throws {
        let fixture = Fixture(), client = LMStudioClient(transport: fixture.transport), selection = try selected()
        let source = SourceLifetime()
        let attachment = LMStudioVisionAttachment(jpeg: Data("INERT SYNTHETIC IMAGE".utf8), annotation: "Synthetic image only", validate: {
            guard source.current else { throw SourceFailure.changed }
        })
        await fixture.setAnswer("GX47QP")
        try await client.verifyVision(selection: selection, syntheticImage: attachment, expectedMarker: "GX47QP")
        await fixture.setHeld(true)
        let request = Task { try await client.complete(messages: messages, tools: [], selection: selection, vision: attachment) }
        try await wait { await fixture.requests.count == 2 }
        source.current = false
        await fixture.release()
        await #expect(throws: SourceFailure.changed) { try await request.value }
    }

    @Test func streamReplyAndExactResultIDRoundTripThroughTheClient() async throws {
        let fixture = Fixture(), client = LMStudioClient(transport: fixture.transport), selection = try selected()
        let call = ToolCall(id: "original-id-opaque-12", name: "calculate", arguments: ["expression": .string("6*7")])
        let delta: JSONValue = .object(["id": .string("fixture-stream"), "choices": .array([.object([
            "index": .number(0), "delta": .object(["role": .string("assistant"), "content": .string("Café 👩‍💻"),
                "tool_calls": .array([.object(["index": .number(0), "id": .string(call.id), "type": .string("function"),
                    "function": .object(["name": .string(call.name), "arguments": .string(#"{"expression":"6*7"}"#)])])])]),
            "finish_reason": .string("tool_calls")])])])
        let bytes = Data("data: ".utf8) + (try LMStudioWireCodec.jsonData(delta)) + Data("\n\ndata: [DONE]\n\n".utf8)
        await fixture.setStream(bytes.map { Data([$0]) })
        let definition = ToolDefinition(name: call.name, description: "Synthetic arithmetic", parameters: .object(["type": .string("object")]))
        let reply = try await client.complete(messages: messages, tools: [definition], selection: selection)
        #expect(reply.content == "Café 👩‍💻" && reply.toolCalls == [call])
        await fixture.setStream(nil)
        let history = messages + [.init(role: "assistant", content: reply.content, toolCalls: reply.toolCalls),
            .init(role: "tool", content: "42", toolCallID: call.id, toolName: call.name)]
        _ = try await client.complete(messages: history, tools: [definition], selection: selection)
        let sent = try JSONDecoder().decode(JSONValue.self, from: #require(await fixture.requests.last?.httpBody))
        guard case .array(let wire) = sent.object?["messages"] else { Issue.record("Missing exact history"); return }
        #expect(wire.last?.object?["tool_call_id"] == .string(call.id))
        #expect(wire.last?.object?["content"] == .string("42"))
    }

    @Test func unfinishedStreamAndRawTransportErrorProduceOnlyTypedFailures() async throws {
        let fixture = Fixture(), client = LMStudioClient(transport: fixture.transport), selection = try selected()
        await fixture.setStream([Data("data: {\"id\":\"one\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"partial\"},\"finish_reason\":\"stop\"}]}\n\n".utf8)])
        await #expect(throws: LMStudioFailure.incompleteStream) { try await client.complete(messages: messages, tools: [], selection: selection) }
        await fixture.setStream(nil)
        await fixture.setTransportFailure(true)
        await #expect(throws: LMStudioFailure.unavailable) { try await client.complete(messages: messages, tools: [], selection: selection) }
        await fixture.setHeld(true)
        let request = Task { try await client.complete(messages: messages, tools: [], selection: selection) }
        try await wait { await fixture.requests.count == 3 }
        request.cancel(); await fixture.release()
        await #expect(throws: CancellationError.self) { try await request.value }
    }

    private var messages: [ModelMessage] { [.init(role: "user", content: "Synthetic request")] }
    private func selected() throws -> LMStudioSelection { try .init(endpoint: .init(), modelID: "inert-fixture-model") }
    private func wait(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw LMStudioFailure.busy
    }
    @MainActor private final class SourceLifetime { var current = true }
    private enum SourceFailure: Error, Equatable { case changed }
    private actor Fixture {
        private(set) var requests: [URLRequest] = []
        private(set) var cancelCount = 0
        private var held = false, status = 200, answer = "Synthetic complete answer."
        private var responseURL: URL?
        private var chunks: [Data]?
        private var transportFailure = false
        private var continuation: CheckedContinuation<Void, Never>?
        nonisolated var transport: LMStudioClient.Transport { .init(open: { [self] in try await open($0) }) }
        func setHeld(_ value: Bool) { held = value }
        func setStatus(_ value: Int) { status = value }
        func setAnswer(_ value: String) { answer = value }
        func setResponseURL(_ value: URL) { responseURL = value }
        func setStream(_ value: [Data]?) { chunks = value }
        func setTransportFailure(_ value: Bool) { transportFailure = value }
        func release() { held = false; continuation?.resume(); continuation = nil }
        private func cancelled() { cancelCount += 1 }
        private func open(_ request: URLRequest) async throws -> LMStudioClient.Response {
            requests.append(request)
            if held { await withCheckedContinuation { continuation = $0 } }
            if transportFailure { throw NSError(domain: "synthetic-only", code: -1, userInfo: [NSLocalizedDescriptionKey: "PRIVATE SYNTHETIC ERROR MUST NOT LEAK"]) }
            let value: JSONValue
            if request.httpMethod == "GET" { value = .object(["data": .array([.object(["id": .string("inert-fixture-model")])])]) }
            else { value = .object(["id": .string("fixture-reply"), "choices": .array([.object(["index": .number(0),
                "message": .object(["role": .string("assistant"), "content": .string(answer)]), "finish_reason": .string("stop")])])]) }
            let bytes = try LMStudioWireCodec.jsonData(value)
            let preparedChunks = chunks ?? [bytes]
            let stream = AsyncThrowingStream<Data, any Error> { continuation in
                for chunk in preparedChunks { continuation.yield(chunk) }
                continuation.finish()
            }
            return .init(url: responseURL ?? request.url!, status: status, contentType: chunks == nil ? "application/json" : "text/event-stream", body: stream,
                cancel: { [self] in Task { await cancelled() } })
        }
    }
}
