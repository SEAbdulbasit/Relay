import Foundation
import Testing
@testable import Relay

/// Inert protocol qualification only: no network, credentials, real models, or
/// paid accounts. Every explicit retry must be a fresh request after settlement.
@MainActor
struct ProviderFailureRecoveryQualificationTests {
    private actor FaultPeer {
        let failure: String
        private(set) var requests = 0
        init(failure: String) { self.failure = failure }
        nonisolated var transport: LMStudioClient.Transport {
            .init(open: { [self] request in try await open(request) })
        }
        func open(_ request: URLRequest) throws -> LMStudioClient.Response {
            requests += 1
            let url = request.url!
            let responses = url.path.hasSuffix("/responses")
            if requests == 1 {
                switch failure {
                case "timeout": throw URLError(.timedOut)
                case "disconnect": throw URLError(.networkConnectionLost)
                case "cancel": throw CancellationError()
                case "stream":
                    let partial = responses
                        ? #"data: {"type":"response.created","response":{"id":"partial","status":"in_progress"}}"# + "\n\n" + #"data: {"type":"response.output_text.delta","delta":"UNVERIFIED_PRIVATE_PARTIAL"}"# + "\n\n"
                        : #"data: {"choices":[{"index":0,"delta":{"content":"UNVERIFIED_PRIVATE_PARTIAL"},"finish_reason":null}]}"# + "\n\n"
                    return .init(url: url, status: 200, contentType: "text/event-stream",
                        body: AsyncThrowingStream { $0.yield(Data(partial.utf8)); $0.finish(throwing: URLError(.networkConnectionLost)) }, cancel: {})
                default:
                    return .init(url: url, status: failure == "auth" ? 401 : 429, contentType: "application/json",
                        body: AsyncThrowingStream { $0.yield(Data("UNVERIFIED_PRIVATE_PARTIAL".utf8)); $0.finish() }, cancel: {})
                }
            }
            let payload: String
            let type: String
            if responses {
                payload = [
                    #"data: {"type":"response.created","response":{"id":"recovered","status":"in_progress"}}"#,
                    #"data: {"type":"response.output_text.delta","delta":"Recovered synthetic response."}"#,
                    #"data: {"type":"response.completed","response":{"id":"recovered","status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Recovered synthetic response."}]}]}}"#,
                    "data: [DONE]"
                ].joined(separator: "\n\n") + "\n\n"
                type = "text/event-stream"
            } else {
                payload = #"{"choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content":"Recovered synthetic response."}}]}"#
                type = "application/json"
            }
            return .init(url: url, status: 200, contentType: type,
                body: AsyncThrowingStream { $0.yield(Data(payload.utf8)); $0.finish() }, cancel: {})
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["lmStudio", "openRouter", "responses"], ["timeout", "disconnect", "cancel", "stream", "auth", "rate"])
    func failureNeverReturnsPartialWorkOrRetriesAndExplicitRecoveryIsUsable(_ provider: String, _ failure: String) async throws {
        let peer = FaultPeer(failure: failure)
        let messages = [ModelMessage(role: "user", content: "Synthetic qualification request")]
        let complete: @MainActor () async throws -> ModelReply
        let drain: @MainActor () async -> Void
        switch provider {
        case "lmStudio":
            let client = LMStudioClient(transport: peer.transport)
            let selected = try LMStudioSelection(endpoint: LMStudioEndpoint(), modelID: "synthetic-model")
            complete = { try await client.complete(messages: messages, tools: [], selection: selected) }
            drain = { await client.drain() }
        case "openRouter":
            let credentials = OpenRouterCredentials(read: { Data("SYNTHETIC-QUALIFICATION-KEY-9001".utf8) }, write: { _ in })
            let client = OpenRouterClient(transport: peer.transport, credentials: credentials)
            let selected = try OpenRouterConfiguration(modelID: "synthetic-model", uploadsApproved: true)
            complete = { try await client.complete(messages: messages, tools: [], configuration: selected) }
            drain = { await client.drain() }
        default:
            let client = CustomResponsesClient(transport: peer.transport, credentials: .init(store: .memory()))
            let selected = try CustomResponsesConfiguration(baseURL: "http://127.0.0.1:1234/v1", modelID: "synthetic-model", requiresAPIKey: false)
            complete = { try await client.complete(messages: messages, tools: [], configuration: selected) }
            drain = { await client.drain() }
        }
        do {
            _ = try await complete()
            Issue.record("A failed or interrupted response must not publish partial content or tool calls.")
        } catch {
            #expect(!error.localizedDescription.contains("UNVERIFIED_PRIVATE_PARTIAL"))
            if failure == "cancel" { #expect(error is CancellationError) }
        }
        await drain()
        #expect(await peer.requests == 1, "No implicit retry after transport, stream, cancellation, or HTTP failure")
        let recovered = try await complete()
        #expect(recovered.content == "Recovered synthetic response.")
        #expect(recovered.toolCalls.isEmpty)
        await drain()
        #expect(await peer.requests == 2)
    }
}
