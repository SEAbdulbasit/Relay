import Foundation
@preconcurrency import LiteRTLM
@testable import Relay

// Inert protocol peer. It is never bound to a socket and never owns a model.
actor LMStudioIntegrationFixture {
    enum Mode: Sendable, Equatable { case answer, calculate }
    private(set) var requests: [URLRequest] = []
    var held = false
    private var latch: CheckedContinuation<Void, Never>?
    private var mode: Mode = .answer
    private var fail = false
    private var probeAnswer: String?
    private var models = ["synthetic-server-model"]
    nonisolated var transport: LMStudioClient.Transport { .init(open: { [self] in try await open($0) }) }
    func hold() { held = true }
    func release() { held = false; latch?.resume(); latch = nil }
    func setMode(_ mode: Mode) { self.mode = mode }
    func failNextReply() { fail = true }
    func setProbeAnswer(_ answer: String) { probeAnswer = answer }
    func setModels(_ ids: [String]) { models = ids }
    private func open(_ request: URLRequest) async throws -> LMStudioClient.Response {
        requests.append(request)
        if held { await withCheckedContinuation { latch = $0 } }
        if fail { fail = false; throw LMStudioFailure.unavailable }
        let value: JSONValue
        if request.httpMethod == "GET" {
            value = .object(["data": .array(models.map { .object(["id": .string($0)]) })])
        } else {
            let payload = try JSONDecoder().decode(JSONValue.self, from: request.httpBody ?? Data())
            let toolNames: [String]
            if case .array(let tools) = payload.object?["tools"] { toolNames = tools.compactMap { $0.object?["function"]?.object?["name"]?.string } }
            else { toolNames = [] }
            let message: JSONValue, finish: String
            let isVisionProbe: Bool
            if case .array(let messages) = payload.object?["messages"] {
                isVisionProbe = messages.contains { $0.object?["content"]?.string?.contains("synthetic local image") == true }
            } else { isVisionProbe = false }
            if isVisionProbe {
                message = .object(["role": .string("assistant"), "content": .string(probeAnswer ?? "WRONG MARKER")]); finish = "stop"
            } else if toolNames.contains("capability_probe") {
                message = action("capability_probe", arguments: #"{"marker":"relay-ready"}"#); finish = "tool_calls"
            } else if mode == .calculate, case .array(let messages) = payload.object?["messages"],
                      !messages.contains(where: { $0.object?["role"] == .string("tool") }) {
                message = action("calculate", arguments: #"{"expression":"6*7"}"#); finish = "tool_calls"
            } else {
                message = .object(["role": .string("assistant"), "content": .string(mode == .calculate ? "42" : "Synthetic endpoint answer.")]); finish = "stop"
            }
            value = .object(["id": .string("synthetic-response"), "choices": .array([.object([
                "index": .number(0), "message": message, "finish_reason": .string(finish)])])])
        }
        let data = try LMStudioWireCodec.jsonData(value)
        let stream = AsyncThrowingStream<Data, any Error> { continuation in continuation.yield(data); continuation.finish() }
        return .init(url: request.url!, status: 200, contentType: "application/json", body: stream, cancel: {})
    }
    private func action(_ name: String, arguments: String) -> JSONValue {
        .object(["role": .string("assistant"), "content": .null, "tool_calls": .array([.object([
            "id": .string("original-call-\(requests.count)"), "type": .string("function"),
            "function": .object(["name": .string(name), "arguments": .string(arguments)])])])])
    }
}

@MainActor final class LMStudioRouterRuntime: LocalModelRuntime {
    private(set) var conversations = 0
    func createConversation(config: LiteRTLM.ConversationConfig) async throws -> any LocalConversationSession {
        conversations += 1; return Session()
    }
    private final class Session: LocalConversationSession {
        func send(_ message: LiteRTLM.Message) async throws -> LiteRTLM.Message { LiteRTLM.Message("Synthetic native answer.", role: .model) }
        nonisolated func cancel() {}
    }
}

@MainActor func awaitLMStudioCondition(_ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while ContinuousClock.now < deadline { if await condition() { return }; try await Task.sleep(for: .milliseconds(1)) }
    throw LocalInferenceFailure.busy
}
