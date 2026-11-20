import Dispatch
import Foundation
import Testing
@testable import Relay

/// Inert transport and synthetic endpoint-scoped credential custody.
/// No Keychain, live model, paid provider, CLI config, or socket is touched.
@MainActor struct CustomResponsesProviderTests {
    private static let endpointA = try! CustomResponsesEndpoint(parsing: "https://gateway-a.example/v1")
    private static let endpointB = try! CustomResponsesEndpoint(parsing: "https://gateway-b.example/v1")
    private static let localEndpoint = try! CustomResponsesEndpoint(parsing: "http://127.0.0.1:1234/v1")

    private func wait(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()) {
            try Task.checkCancellation()
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    @MainActor private final class SourceState {
        var current = true
    }

    private actor ResponsesPeer {
        enum Mode: Sendable {
            case text(String)
            case calculate
            case vision(String)
            case unauthorized
        }

        private(set) var requests: [URLRequest] = []
        private var mode: Mode = .text("Synthetic Responses reply")
        private var holding = false
        private var failNext = false
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func setMode(_ next: Mode) { mode = next }
        func hold() { holding = true }
        func failNextReply() { failNext = true }
        func release() {
            holding = false
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }

        nonisolated var transport: CustomResponsesClient.Transport {
            .init(open: { [self] request in
                try await open(request)
            })
        }

        private func open(_ request: URLRequest) async throws -> CustomResponsesClient.Response {
            requests.append(request)
            if holding {
                await withCheckedContinuation { continuation in
                    releaseWaiters.append(continuation)
                }
            }
            try Task.checkCancellation()
            if failNext {
                failNext = false
                throw CustomResponsesFailure.requestRejected
            }
            guard let url = request.url else {
                throw CustomResponsesFailure.invalidBaseURL
            }
            if url.path.hasSuffix("/models") {
                let data = Data(#"{"data":[{"id":"synthetic/responses-model"},{"id":"qwen/qwen3-coder"}]}"#.utf8)
                return .init(
                    url: url,
                    status: 200,
                    contentType: "application/json",
                    body: AsyncThrowingStream { $0.yield(data); $0.finish() },
                    cancel: {}
                )
            }

            switch mode {
            case .unauthorized:
                let secretLeak = Data("PRIVATE SERVER BODY SYNTHETIC-RESPONSES-KEY-A-9001".utf8)
                return .init(
                    url: url,
                    status: 401,
                    contentType: "application/json",
                    body: AsyncThrowingStream { $0.yield(secretLeak); $0.finish() },
                    cancel: {}
                )
            case .vision(let marker):
                let sse = [
                    #"data: {"type":"response.created","response":{"id":"resp_vis","status":"in_progress"}}"#,
                    #"data: {"type":"response.output_text.delta","delta":"\#(marker)"}"#,
                    #"data: {"type":"response.completed","response":{"id":"resp_vis","status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"\#(marker)"}]}]}}"#,
                    "data: [DONE]"
                ].joined(separator: "\n\n") + "\n\n"
                return .init(
                    url: url,
                    status: 200,
                    contentType: "text/event-stream",
                    body: AsyncThrowingStream { $0.yield(Data(sse.utf8)); $0.finish() },
                    cancel: {}
                )
            case .text(let replyText):
                let sse = [
                    #"data: {"type":"response.created","response":{"id":"resp_txt","status":"in_progress"}}"#,
                    #"data: {"type":"response.output_text.delta","delta":"\#(replyText)"}"#,
                    #"data: {"type":"response.completed","response":{"id":"resp_txt","status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"\#(replyText)"}]}]}}"#,
                    "data: [DONE]"
                ].joined(separator: "\n\n") + "\n\n"
                return .init(
                    url: url,
                    status: 200,
                    contentType: "text/event-stream",
                    body: AsyncThrowingStream { $0.yield(Data(sse.utf8)); $0.finish() },
                    cancel: {}
                )
            case .calculate:
                let bodyObj = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
                let inputItems = (bodyObj?["input"] as? [[String: Any]]) ?? []
                let hasToolOutput = inputItems.contains { ($0["type"] as? String) == "function_call_output" }
                let toolDefs = (bodyObj?["tools"] as? [[String: Any]]) ?? []
                let offeredNames = toolDefs.compactMap { $0["name"] as? String }
                if offeredNames == ["capability_probe"] {
                    let sse = [
                        #"data: {"type":"response.created","response":{"id":"resp_probe","status":"in_progress"}}"#,
                        #"data: {"type":"response.output_item.added","output_index":0,"item":{"id":"fc_probe","type":"function_call","call_id":"call_probe_1","name":"capability_probe","arguments":""}}"#,
                        #"data: {"type":"response.function_call_arguments.delta","item_id":"fc_probe","output_index":0,"delta":"{\"marker\":\"relay-ready\"}"}"#,
                        #"data: {"type":"response.output_item.done","output_index":0,"item":{"id":"fc_probe","type":"function_call","call_id":"call_probe_1","name":"capability_probe","arguments":"{\"marker\":\"relay-ready\"}"}}"#,
                        #"data: {"type":"response.completed","response":{"id":"resp_probe","status":"completed","output":[{"id":"fc_probe","type":"function_call","call_id":"call_probe_1","name":"capability_probe","arguments":"{\"marker\":\"relay-ready\"}"}]}}"#,
                        "data: [DONE]"
                    ].joined(separator: "\n\n") + "\n\n"
                    return .init(
                        url: url,
                        status: 200,
                        contentType: "text/event-stream",
                        body: AsyncThrowingStream { $0.yield(Data(sse.utf8)); $0.finish() },
                        cancel: {}
                    )
                }
                if hasToolOutput {
                    let sse = [
                        #"data: {"type":"response.created","response":{"id":"resp_2","status":"in_progress"}}"#,
                        #"data: {"type":"response.output_text.delta","delta":"42"}"#,
                        #"data: {"type":"response.completed","response":{"id":"resp_2","status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"42"}]}]}}"#,
                        "data: [DONE]"
                    ].joined(separator: "\n\n") + "\n\n"
                    return .init(
                        url: url,
                        status: 200,
                        contentType: "text/event-stream",
                        body: AsyncThrowingStream { $0.yield(Data(sse.utf8)); $0.finish() },
                        cancel: {}
                    )
                }
                guard offeredNames.contains("calculate") else { throw CustomResponsesFailure.invalidResponse }
                let sse = [
                    #"data: {"type":"response.created","response":{"id":"resp_1","status":"in_progress"}}"#,
                    #"data: {"type":"response.output_item.added","output_index":0,"item":{"id":"fc_1","type":"function_call","call_id":"call_calc_1","name":"calculate","arguments":""}}"#,
                    #"data: {"type":"response.function_call_arguments.delta","item_id":"fc_1","output_index":0,"delta":"{\"expression\":"}"#,
                    #"data: {"type":"response.function_call_arguments.delta","item_id":"fc_1","output_index":0,"delta":"\"6*7\"}"}"#,
                    #"data: {"type":"response.output_item.done","output_index":0,"item":{"id":"fc_1","type":"function_call","call_id":"call_calc_1","name":"calculate","arguments":"{\"expression\":\"6*7\"}"}}"#,
                    #"data: {"type":"response.completed","response":{"id":"resp_1","status":"completed","output":[{"id":"fc_1","type":"function_call","call_id":"call_calc_1","name":"calculate","arguments":"{\"expression\":\"6*7\"}"}]}}"#,
                    "data: [DONE]"
                ].joined(separator: "\n\n") + "\n\n"
                return .init(
                    url: url,
                    status: 200,
                    contentType: "text/event-stream",
                    body: AsyncThrowingStream { $0.yield(Data(sse.utf8)); $0.finish() },
                    cancel: {}
                )
            }
        }
    }

    @Test func savedConfigurationPreservesLocalDefaultAndNeverSerializesSecretBytes() throws {
        #expect(ModelConfiguration().backend == .liteRTLM)
        let remoteChoice = try CustomResponsesConfiguration(
            baseURL: "https://gateway-a.example/v1/responses",
            modelID: "openai/gpt-5.4",
            reasoningEffort: "medium",
            uploadsApproved: true
        )
        #expect(remoteChoice.baseURL == "https://gateway-a.example/v1")
        #expect(remoteChoice.usesCloudInference)
        #expect(remoteChoice.isConfigured)

        let modelConfig = ModelConfiguration(backend: .customResponses, customResponses: remoteChoice)
        let encoded = try JSONEncoder().encode(modelConfig)
        let restored = try JSONDecoder().decode(ModelConfiguration.self, from: encoded)
        #expect(restored == modelConfig)
        #expect(restored.inferenceIdentity == modelConfig.inferenceIdentity)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("SYNTHETIC-RESPONSES-KEY"))

        let unapprovedRemote = try CustomResponsesConfiguration(
            baseURL: "https://gateway-a.example/v1",
            modelID: "openai/gpt-5.4",
            uploadsApproved: false
        )
        #expect(!unapprovedRemote.isConfigured)
        #expect(ModelConfiguration(backend: .customResponses, customResponses: unapprovedRemote).inferenceIdentity == nil)

        let localChoice = try CustomResponsesConfiguration(
            baseURL: "http://127.0.0.1:1234/v1",
            modelID: "qwen/qwen3-coder",
            uploadsApproved: false
        )
        #expect(!localChoice.usesCloudInference)
        #expect(!localChoice.effectiveRequiresAPIKey)
        #expect(localChoice.isConfigured)

        #expect(throws: CustomResponsesFailure.invalidBaseURL) {
            _ = try CustomResponsesEndpoint(parsing: "http://gateway-a.example/v1")
        }
        #expect(throws: CustomResponsesFailure.invalidBaseURL) {
            _ = try CustomResponsesEndpoint(parsing: "https://localhost:8443/v1")
        }
        #expect(throws: CustomResponsesFailure.invalidBaseURL) {
            _ = try CustomResponsesEndpoint(parsing: "https://user:pass@gateway-a.example/v1")
        }
    }

    @Test func namespaceToolsArrayOutputsAndStaleImagesRoundTripAndCodexRecipeNeverTouchesUserCLIConfig() throws {
        let rawRequest: [String: Any] = [
            "model": "qwen/qwen3-coder",
            "include": ["reasoning.encrypted_content"],
            "tools": [
                [
                    "type": "namespace",
                    "name": "mcp__github",
                    "description": "GitHub MCP server",
                    "tools": [
                        [
                            "type": "function",
                            "name": "search_issues",
                            "description": "Search repository issues",
                            "parameters": ["type": "object"]
                        ]
                    ]
                ],
                ["type": "web_search"],
                ["type": "file_search"],
                [
                    "type": "function",
                    "name": "local_tool",
                    "description": "Plain function",
                    "parameters": ["type": "object"]
                ]
            ],
            "input": [
                [
                    "type": "message",
                    "role": "user",
                    "content": [
                        ["type": "input_text", "text": "First screenshot"],
                        ["type": "input_image", "image_url": "data:image/jpeg;base64,OLDIMAGE"]
                    ]
                ],
                [
                    "type": "reasoning",
                    "id": "rs_encrypted_1",
                    "encrypted_content": "opaque"
                ],
                [
                    "type": "function_call",
                    "call_id": "call_ns_1",
                    "name": "search_issues",
                    "namespace": "mcp__github",
                    "arguments": "{}"
                ],
                [
                    "type": "function_call_output",
                    "call_id": "call_ns_1",
                    "output": [
                        ["type": "input_text", "text": "Found 1 matching issue"],
                        ["type": "input_image", "image_url": "data:image/jpeg;base64,NEWIMAGE"]
                    ]
                ]
            ]
        ]

        let (rewritten, mapping) = CustomResponsesTranslator.rewriteRequestObject(rawRequest)
        #expect(rewritten["include"] == nil)
        #expect(mapping["mcp__github__search_issues"] == CustomResponsesNamespaceTarget(namespace: "mcp__github", name: "search_issues"))

        let tools = try #require(rewritten["tools"] as? [[String: Any]])
        #expect(tools.count == 2)
        #expect(tools[0]["name"] as? String == "mcp__github__search_issues")
        #expect(tools[0]["description"] as? String == "GitHub MCP server — Search repository issues")
        #expect(tools[0]["strict"] as? Bool == false)
        #expect(tools[1]["name"] as? String == "local_tool")

        let input = try #require(rewritten["input"] as? [[String: Any]])
        #expect(!input.contains(where: { ($0["type"] as? String) == "reasoning" }))
        #expect(input.count == 4)

        let staleMessageContent = try #require(input[0]["content"] as? [[String: Any]])
        #expect(!staleMessageContent.contains(where: { ($0["type"] as? String) == "input_image" }))
        #expect((staleMessageContent.last?["text"] as? String)?.contains("only the newest screenshot is kept") == true)

        #expect(input[1]["type"] as? String == "function_call")
        #expect(input[1]["name"] as? String == "mcp__github__search_issues")
        #expect(input[1]["namespace"] == nil)

        #expect(input[2]["type"] as? String == "function_call_output")
        let plainOutput = try #require(input[2]["output"] as? String)
        #expect(plainOutput.contains("Found 1 matching issue"))
        #expect(plainOutput.contains("attached in the next message"))

        let relocatedUserMessage = input[3]
        #expect(relocatedUserMessage["role"] as? String == "user")
        let relocatedContent = try #require(relocatedUserMessage["content"] as? [[String: Any]])
        #expect(relocatedContent.contains(where: { ($0["type"] as? String) == "input_image" && ($0["image_url"] as? String) == "data:image/jpeg;base64,NEWIMAGE" }))

        var lineBuffer = CustomResponsesTranslator.SSELineBuffer(mapping: mapping)
        let sseAdded = #"data: {"type":"response.output_item.added","output_index":0,"item":{"id":"fc_2","type":"function_call","call_id":"call_ns_2","name":"mcp__github__search_issues","arguments":"{}"}}"# + "\n\n"
        let rewrittenSSE = String(decoding: lineBuffer.push(Data(sseAdded.utf8)) + lineBuffer.flush(), as: UTF8.self)
        #expect(rewrittenSSE.contains(#""name":"search_issues""#))
        #expect(rewrittenSSE.contains(#""namespace":"mcp__github""#))

        let choice = try CustomResponsesConfiguration(
            baseURL: "https://gateway-a.example/v1",
            modelID: "openai/gpt-5.4",
            reasoningEffort: "high",
            uploadsApproved: true
        )
        let recipe = try CodexCustomResponsesRecipe(configuration: choice)
        #expect(recipe.arguments.contains("model_provider=relay_custom"))
        #expect(recipe.arguments.contains(where: { $0.contains(#"env_key = "RELAY_CUSTOM_MODEL_API_KEY""#) && $0.contains("requires_openai_auth = false") }))
    }

    @Test func endpointScopedCredentialCustodyIsolatesDistinctEndpointsAndOtherProviders() async throws {
        let store = CustomResponsesCredentials.Store.memory([
            Self.endpointA.credentialAccount: Data("SYNTHETIC-RESPONSES-KEY-A-9001".utf8)
        ])
        let custody = CustomResponsesCredentials(store: store)
        #expect(Self.endpointA.credentialAccount != Self.endpointB.credentialAccount)
        #expect(CustomResponsesCredentials.serviceName != OpenRouterCredentials.service)

        let peerA = ResponsesPeer()
        await peerA.setMode(.calculate)
        let clientA = CustomResponsesClient(transport: peerA.transport, credentials: custody)
        let configA = try CustomResponsesConfiguration(
            baseURL: Self.endpointA.baseURLString,
            modelID: "synthetic/responses-model",
            uploadsApproved: true
        )
        let tool = ToolDefinition(name: "calculate", description: "Synthetic arithmetic", parameters: .object(["type": .string("object")]))
        let first = try await clientA.complete(messages: [.init(role: "user", content: "6*7")], tools: [tool], configuration: configA)
        let call = try #require(first.toolCalls.first)
        #expect(call.name == "calculate" && call.arguments == ["expression": .string("6*7")])

        let second = try await clientA.complete(
            messages: [
                .init(role: "user", content: "6*7"),
                .init(role: "assistant", content: first.content, toolCalls: first.toolCalls),
                .init(role: "tool", content: "42", toolCallID: call.id, toolName: call.name)
            ],
            tools: [tool],
            configuration: configA
        )
        #expect(second.content == "42")
        let requestsA = await peerA.requests
        #expect(requestsA.count == 2 && requestsA.allSatisfy { $0.url == Self.endpointA.responsesURL })
        #expect(requestsA.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer SYNTHETIC-RESPONSES-KEY-A-9001" })

        // Switching to Endpoint B must NOT use Endpoint A's key.
        let peerB = ResponsesPeer()
        let clientB = CustomResponsesClient(transport: peerB.transport, credentials: custody)
        let configB = try CustomResponsesConfiguration(
            baseURL: Self.endpointB.baseURLString,
            modelID: "synthetic/responses-model",
            uploadsApproved: true
        )
        await #expect(throws: CustomResponsesFailure.missingAPIKey) {
            _ = try await clientB.complete(messages: [.init(role: "user", content: "Hello")], tools: [], configuration: configB)
        }
        let requestsB = await peerB.requests
        #expect(requestsB.isEmpty)

        // Keyless local loopback server works when requiresAPIKey == false and omits Authorization header.
        let localPeer = ResponsesPeer()
        let localClient = CustomResponsesClient(transport: localPeer.transport, credentials: custody)
        let localConfig = try CustomResponsesConfiguration(
            baseURL: Self.localEndpoint.baseURLString,
            modelID: "qwen/qwen3-coder",
            requiresAPIKey: false,
            uploadsApproved: false
        )
        let localReply = try await localClient.complete(messages: [.init(role: "user", content: "Local ping")], tools: [], configuration: localConfig)
        #expect(localReply.content == "Synthetic Responses reply")
        let localRequests = await localPeer.requests
        #expect(localRequests.count == 1 && localRequests[0].value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func explicitCloudApprovalRequiredForRemoteHTTPSBeforeAnyTransportOpen() async throws {
        let store = CustomResponsesCredentials.Store.memory(
            for: Self.endpointA,
            key: Data("SYNTHETIC-RESPONSES-KEY-A-9001".utf8)
        )
        let peer = ResponsesPeer()
        let client = CustomResponsesClient(transport: peer.transport, credentials: CustomResponsesCredentials(store: store))
        let unapproved = try CustomResponsesConfiguration(
            baseURL: Self.endpointA.baseURLString,
            modelID: "synthetic/responses-model",
            uploadsApproved: false
        )
        await #expect(throws: CustomResponsesFailure.uploadsNotApproved) {
            _ = try await client.complete(messages: [.init(role: "user", content: "Private text")], tools: [], configuration: unapproved)
        }
        await #expect(throws: CustomResponsesFailure.uploadsNotApproved) {
            _ = try await client.listModels(configuration: unapproved)
        }
        let requests = await peer.requests
        #expect(requests.isEmpty)
    }

    @Test func providerErrorsNeverEchoPrivateResponseBodyOrCredential() async throws {
        let store = CustomResponsesCredentials.Store.memory(
            for: Self.endpointA,
            key: Data("SYNTHETIC-RESPONSES-KEY-A-9001".utf8)
        )
        let peer = ResponsesPeer()
        await peer.setMode(.unauthorized)
        let client = CustomResponsesClient(transport: peer.transport, credentials: CustomResponsesCredentials(store: store))
        let config = try CustomResponsesConfiguration(
            baseURL: Self.endpointA.baseURLString,
            modelID: "synthetic/responses-model",
            uploadsApproved: true
        )
        do {
            _ = try await client.complete(messages: [.init(role: "user", content: "Owned synthetic data")], tools: [], configuration: config)
            Issue.record("Expected closed unauthorized failure")
        } catch {
            #expect(error as? CustomResponsesFailure == .unauthorized)
            #expect(!error.localizedDescription.contains("PRIVATE") && !error.localizedDescription.contains("9001"))
        }
    }

    enum Refusal: Error { case source }

    @Test(arguments: ["before", "reply", "error"])
    func liveSourceRefusesBeforePrivateSendAndOnBothReplyPathsWithoutReturningLateData(_ mode: String) async throws {
        let store = CustomResponsesCredentials.Store.memory(
            for: Self.endpointA,
            key: Data("SYNTHETIC-RESPONSES-KEY-A-9001".utf8)
        )
        let peer = ResponsesPeer()
        let revokeAfterSend = mode != "before"
        if revokeAfterSend { await peer.hold() }
        if mode == "error" { await peer.failNextReply() }
        let client = CustomResponsesClient(transport: peer.transport, credentials: CustomResponsesCredentials(store: store))
        let state = SourceState()
        state.current = revokeAfterSend
        let config = try CustomResponsesConfiguration(
            baseURL: Self.endpointA.baseURLString,
            modelID: "synthetic/responses-model",
            uploadsApproved: true
        )
        let pending = Task {
            try await client.complete(
                messages: [.init(role: "user", content: "PRIVATE owned source")],
                tools: [],
                configuration: config,
                sourceAuthorization: { if !state.current { throw Refusal.source } }
            )
        }
        do {
            if revokeAfterSend {
                try await wait { await peer.requests.count == 1 }
                state.current = false
                await peer.release()
            }
            await #expect(throws: Refusal.source) { try await pending.value }
            let requests = await peer.requests
            #expect(requests.count == (revokeAfterSend ? 1 : 0))
            await client.drain()
        } catch {
            pending.cancel()
            await peer.release()
            _ = await pending.result
            await client.drain()
            throw error
        }
    }

    @Test func cancellationProviderSwitchAndKeyReplacementHoldSharedLeaseUntilUncooperativeHTTPReturns() async throws {
        let store = CustomResponsesCredentials.Store.memory(
            for: Self.endpointA,
            key: Data("SYNTHETIC-RESPONSES-KEY-A-9001".utf8)
        )
        let peer = ResponsesPeer()
        await peer.hold()
        let client = CustomResponsesClient(transport: peer.transport, credentials: CustomResponsesCredentials(store: store))
        let router = LocalInferenceRouter(customResponses: client)
        let selected = ModelConfiguration(
            backend: .customResponses,
            customResponses: try CustomResponsesConfiguration(
                baseURL: Self.endpointA.baseURLString,
                modelID: "synthetic/responses-model",
                uploadsApproved: true
            )
        )
        let pending = Task {
            try await router.complete(messages: [.init(role: "user", content: "Owned source")], tools: [], configuration: selected)
        }
        do {
            try await wait { await peer.requests.count == 1 }
            pending.cancel()
            router.selectionDidChange(ModelConfiguration())
            await #expect(throws: LocalInferenceFailure.busy) {
                try await router.fork().complete(messages: [.init(role: "user", content: "Later")], tools: [], configuration: selected)
            }
            await peer.release()
            await #expect(throws: CancellationError.self) { try await pending.value }
            await router.drain()
            let requests = await peer.requests
            #expect(requests.count == 1)
        } catch {
            pending.cancel()
            await peer.release()
            _ = await pending.result
            await router.drain()
            throw error
        }
    }

    @Test func storeReadinessToolLoopAndVisionReceiptUseOnlySelectedCustomResponsesRoute() async throws {
        let storeCustody = CustomResponsesCredentials.Store.memory(
            for: Self.endpointA,
            key: Data("SYNTHETIC-RESPONSES-KEY-A-9001".utf8)
        )
        let peer = ResponsesPeer()
        await peer.setMode(.calculate)
        var native = 0, codex = 0, dispatches = 0
        let client = CustomResponsesClient(transport: peer.transport, credentials: CustomResponsesCredentials(store: storeCustody))
        let store = AssistantStore(
            persistenceURL: nil,
            execute: { call in
                #expect(call.name == "calculate")
                dispatches += 1
                return .init(summary: "42", evidence: "Owned inert arithmetic", verified: true)
            },
            modelClient: LocalModelClient(runtimeFactory: { _, _, _ in native += 1; throw CancellationError() }),
            customResponsesClient: client,
            codexComplete: { _, _ in codex += 1; throw CancellationError() }
        )
        await store.waitForConversationTaskToSettle()
        let selected = try CustomResponsesConfiguration(
            baseURL: Self.endpointA.baseURLString,
            modelID: "synthetic/responses-model",
            uploadsApproved: true
        )
        store.configuration = ModelConfiguration(backend: .customResponses, customResponses: selected)
        await store.refreshModels()
        #expect(store.actionsReady && native == 0 && codex == 0)

        store.draft = "Compute six times seven with calculate."
        _ = try #require(store.send())
        await store.waitForConversationTaskToSettle()
        #expect(dispatches == 1)
        #expect(store.phase == .idle)
        #expect(native == 0 && codex == 0)

        // Vision check binds exact configuration and key digest.
        let image = LMStudioVisionAttachment(jpeg: Data([1, 2, 3]), annotation: "Owned synthetic protocol bytes", validate: {})
        await #expect(throws: CustomResponsesFailure.visionUnsupported) {
            _ = try await client.complete(messages: [.init(role: "user", content: "No probe yet")], tools: [], configuration: selected, vision: image)
        }
        await peer.setMode(.vision("OWNED9"))
        try await client.verifyVision(configuration: selected, syntheticImage: image, expectedMarker: "OWNED9")
        #expect(await client.visionIsVerified(for: selected))
        try await client.replaceKey(Data("SYNTHETIC-REPLACEMENT-KEY-7777".utf8), for: Self.endpointA)
        #expect(!(await client.visionIsVerified(for: selected)))

        store.setCustomResponsesUploadsApproved(false)
        #expect(!store.actionsReady && store.configuration.inferenceIdentity == nil)
        store.stop()
        await store.waitForConversationTaskToSettle()
        await client.drain()
    }
    private func decodeStream(_ events: [[String: Any]], fragment: Int) throws -> ModelReply {
        var bytes = Data()
        for event in events {
            bytes.append(Data("data: ".utf8))
            bytes.append(try JSONSerialization.data(withJSONObject: event, options: [.withoutEscapingSlashes]))
            bytes.append(Data("\n\n".utf8))
        }
        bytes.append(Data("data: [DONE]\n\n".utf8))
        var decoder = CustomResponsesSSEDecoder(availableTools: ["calculate", "read_file"])
        for offset in stride(from: 0, to: bytes.count, by: fragment) {
            try decoder.append(Data(bytes[offset..<min(bytes.count, offset + fragment)]))
        }
        return try decoder.finish()
    }
    private func coherentStream() -> [[String: Any]] {
        let args = #"{"text":"Café 🌍","x":1}"#
        let item: [String: Any] = ["type": "function_call", "id": "item-Cafe\u{301}", "call_id": "call-Cafe\u{301}", "name": "calculate", "arguments": args]
        var initial = item; initial["arguments"] = ""
        return [
            ["type": "response.created", "response": ["id": "response-Cafe\u{301}", "status": "in_progress"]],
            ["type": "response.output_item.added", "output_index": 0, "item": initial],
            ["type": "response.function_call_arguments.delta", "item_id": item["id"]!, "output_index": 0, "delta": args],
            ["type": "response.function_call_arguments.done", "item_id": item["id"]!, "output_index": 0, "arguments": args],
            ["type": "response.output_item.done", "output_index": 0, "item": item],
            ["type": "response.completed", "response": ["id": "response-Cafe\u{301}", "status": "completed", "output": [item]]]
        ]
    }
    @Test(arguments: [1, 7, 113])
    func fragmentedSSEDispatchesOnlyTheExactCompletedCall(_ fragment: Int) throws {
        let reply = try decodeStream(coherentStream(), fragment: fragment)
        let call = try #require(reply.toolCalls.first)
        #expect(reply.toolCalls.count == 1 && reply.content.isEmpty && call.name == "calculate")
        #expect(Data(call.id.utf8) == Data("call-Cafe\u{301}".utf8))
        #expect(Data((try #require(call.arguments["text"]?.string)).utf8) == Data("Cafe\u{301} 🌍".utf8))
        #expect(call.arguments["x"] == .number(1))
        // A complete self-contained terminal response is supported without deltas.
        let terminalOnly = try decodeStream([try #require(coherentStream().last)], fragment: fragment)
        #expect(terminalOnly.toolCalls == reply.toolCalls)
    }
    nonisolated enum StreamMutation: String, CaseIterable, Sendable {
        case absentResponse, absentOutput, absentStatus, absentResponseID, omittedPartial, changedResponseID
        case changedItemID, changedCallID, changedName, changedNamespace, changedArguments, changedDoneArguments
        case unknownDeltaItem, conflictingDeltaIndex, unboundDelta, repeatedIndex, reusedItemID, reusedCallID
        case retargetedKind, conflictingEventResponse, duplicateTerminal, deltaAfterDone, booleanIndex
    }
    @Test(arguments: StreamMutation.allCases)
    func fragmentedSSETerminalContradictionsNeverDispatchAPartialCall(_ mutation: StreamMutation) throws {
        var events = coherentStream()
        var terminal = try #require(events.last?["response"] as? [String: Any])
        var output = try #require(terminal["output"] as? [[String: Any]])
        switch mutation {
        case .absentResponse: events[5].removeValue(forKey: "response")
        case .absentOutput: terminal.removeValue(forKey: "output")
        case .absentStatus: terminal.removeValue(forKey: "status")
        case .absentResponseID: terminal.removeValue(forKey: "id")
        case .omittedPartial:
            terminal["output"] = [["type": "message", "content": [["type": "output_text", "text": "Terminal contains no action"]]]]
        case .changedResponseID: terminal["id"] = "response-Café"
        case .changedItemID: output[0]["id"] = "item-Café"
        case .changedCallID: output[0]["call_id"] = "call-Café"
        case .changedName: output[0]["name"] = "read_file"
        case .changedNamespace: output[0]["namespace"] = "foreign_namespace"
        case .changedArguments: output[0]["arguments"] = #"{"x":1,"text":"Café 🌍"}"#
        case .changedDoneArguments:
            var item = try #require(events[4]["item"] as? [String: Any]); item["arguments"] = "{}"; events[4]["item"] = item
        case .unknownDeltaItem: events[2]["item_id"] = "foreign-item"
        case .conflictingDeltaIndex: events[2]["output_index"] = 1
        case .unboundDelta: events[2].removeValue(forKey: "item_id"); events[2].removeValue(forKey: "output_index")
        case .repeatedIndex: events.insert(events[1], at: 2)
        case .reusedItemID: var duplicate = events[1]; duplicate["output_index"] = 1; events.insert(duplicate, at: 2)
        case .reusedCallID:
            var duplicate = events[1], item = try #require(events[1]["item"] as? [String: Any])
            item["id"] = "different-item"; duplicate["item"] = item; duplicate["output_index"] = 1; events.insert(duplicate, at: 2)
        case .retargetedKind: output[0] = ["type": "message", "id": "item-Cafe\u{301}", "content": [["type": "output_text", "text": "Not an action"]]]
        case .conflictingEventResponse: events[2]["response_id"] = "different-response"
        case .duplicateTerminal: events.append(try #require(events.last))
        case .deltaAfterDone: events.insert(events[2], at: 5)
        case .booleanIndex: events[2]["output_index"] = false
        }
        if [.changedItemID, .changedCallID, .changedName, .changedNamespace, .changedArguments, .retargetedKind].contains(mutation) { terminal["output"] = output }
        if ![.absentResponse, .repeatedIndex, .reusedItemID, .reusedCallID, .deltaAfterDone, .duplicateTerminal].contains(mutation) { events[5]["response"] = terminal }
        for fragment in [1, 17] {
            do { _ = try decodeStream(events, fragment: fragment); Issue.record("Accepted contradictory terminal stream: \(mutation.rawValue)") }
            catch { #expect(error as? CustomResponsesFailure == .invalidResponse || error as? CustomResponsesFailure == .streamDisconnected) }
        }
    }
    @Test func keyDraftCannotTravelToADifferentEndpointOrAnEditedSelection() throws {
        let a = ModelConfiguration(backend: .customResponses, customResponses: try .init(baseURL: Self.endpointA.baseURLString, modelID: "owned/model", uploadsApproved: true))
        let b = ModelConfiguration(backend: .customResponses, customResponses: try .init(baseURL: Self.endpointB.baseURLString, modelID: "owned/model", uploadsApproved: true))
        var draft = CustomResponsesKeyDraft(); draft.set("SYNTHETIC-KEY-A-146800", for: a)
        let submitted = try #require(draft.submission(for: a))
        #expect(draft.submission(for: b) == nil && !draft.isCurrent(submitted, configuration: b))
        draft.clear() // Actual settings URL/preset/config/disappear paths use this.
        #expect(draft.value.isEmpty && !draft.isCurrent(submitted, configuration: a))
        draft.set("SYNTHETIC-KEY-B-146800", for: b)
        #expect(!draft.isCurrent(submitted, configuration: a) && draft.submission(for: a) == nil)
    }
    nonisolated private final class OwnedCustody: @unchecked Sendable {
        private let lock = NSLock(), gate = DispatchSemaphore(value: 0)
        private var values: [String: Data] = [:], writes: [String] = []
        private var entered = false, released = false
        let hold: Bool
        init(hold: Bool = false) { self.hold = hold }
        var didEnter: Bool { lock.withLock { entered } }
        var destinations: [String] { lock.withLock { writes } }
        func read(_ account: String) -> Data? { lock.withLock { values[account] } }
        func write(_ account: String, _ data: Data?) throws {
            lock.withLock { entered = true }
            if hold, gate.wait(timeout: .now() + 5) == .timedOut { throw CustomResponsesFailure.keychainFailure(-1) }
            lock.withLock { writes.append(account); values[account] = data }
        }
        func release() { let first = lock.withLock { let first = !released; released = true; return first }; if first { gate.signal() } }
        var store: CustomResponsesCredentials.Store { .init(read: { [self] in read($0) }, write: { [self] in try write($0, $1) }, delete: { [self] in try write($0, nil) }) }
    }
    private func custodyStore(_ custody: OwnedCustody, client supplied: CustomResponsesClient? = nil) -> (AssistantStore, AssistantConversationHistory) {
        let client = supplied ?? CustomResponsesClient(transport: .init(open: { _ in Issue.record("Credential save must not use HTTP"); throw CancellationError() }), credentials: .init(store: custody.store))
        let history = AssistantConversationHistory(stateURL: nil)
        return (AssistantStore(persistenceURL: nil, conversationHistory: history, customResponsesClient: client), history)
    }
    @Test(arguments: [false, true])
    func queuedKeySaveOrRemovalRefusesTheReplacementEndpointBeforeCustody(_ remove: Bool) async throws {
        let custody = OwnedCustody(); let (store, history) = custodyStore(custody)
        await store.waitForConversationTaskToSettle()
        let a = ModelConfiguration(backend: .customResponses, customResponses: try .init(baseURL: Self.endpointA.baseURLString, modelID: "owned/model", uploadsApproved: true))
        let b = ModelConfiguration(backend: .customResponses, customResponses: try .init(baseURL: Self.endpointB.baseURLString, modelID: "owned/model", uploadsApproved: true))
        store.configuration = a
        let queued = Task { await store.replaceCustomResponsesKey(remove ? nil : "SYNTHETIC-KEY-A-146800", expectedConfiguration: a) }
        store.configuration = b // Before the queued MainActor job can enter.
        #expect(!(await queued.value))
        #expect(custody.destinations.isEmpty && store.configuration == b && !store.isPreparingModel)
        store.stop(); await store.waitForConversationTaskToSettle(); try await history.close()
    }
    @Test func inFlightOriginalCustodyCannotRestoreOrPublishTheReplacementConfiguration() async throws {
        let custody = OwnedCustody(hold: true); let (store, history) = custodyStore(custody)
        await store.waitForConversationTaskToSettle()
        let a = ModelConfiguration(backend: .customResponses, customResponses: try .init(baseURL: Self.endpointA.baseURLString, modelID: "owned/model", uploadsApproved: true))
        let b = ModelConfiguration(backend: .customResponses, customResponses: try .init(baseURL: Self.endpointB.baseURLString, modelID: "owned/model", uploadsApproved: true))
        store.configuration = a
        let pending = Task { await store.replaceCustomResponsesKey("SYNTHETIC-KEY-A-146800", expectedConfiguration: a) }
        do {
            try await wait { custody.didEnter }
            store.configuration = b; custody.release()
            #expect(!(await pending.value))
            #expect(custody.destinations == [Self.endpointA.credentialAccount])
            #expect(custody.read(Self.endpointA.credentialAccount) == Data("SYNTHETIC-KEY-A-146800".utf8))
            #expect(custody.read(Self.endpointB.credentialAccount) == nil && store.configuration == b)
            #expect(!store.modelStatus.contains("API key saved") && !store.isPreparingModel)
            store.stop(); await store.waitForConversationTaskToSettle(); try await history.close()
        } catch { custody.release(); pending.cancel(); _ = await pending.value; store.stop(); await store.waitForConversationTaskToSettle(); try? await history.close(); throw error }
    }
    @Test func unchangedEndpointActuallySavesAndRemovesOnlyItsSyntheticKey() async throws {
        let custody = OwnedCustody(); let (store, history) = custodyStore(custody)
        await store.waitForConversationTaskToSettle()
        let a = ModelConfiguration(backend: .customResponses, customResponses: try .init(baseURL: Self.endpointA.baseURLString, modelID: "owned/model", uploadsApproved: true))
        store.configuration = a
        #expect(await store.replaceCustomResponsesKey("SYNTHETIC-KEY-A-146800", expectedConfiguration: a))
        #expect(custody.read(Self.endpointA.credentialAccount) == Data("SYNTHETIC-KEY-A-146800".utf8))
        let afterSave = store.configuration
        #expect(afterSave.customResponses?.endpoint == a.customResponses?.endpoint && afterSave.customResponses?.credentialRevision != a.customResponses?.credentialRevision)
        #expect(await store.replaceCustomResponsesKey(nil, expectedConfiguration: afterSave))
        #expect(custody.destinations == [Self.endpointA.credentialAccount, Self.endpointA.credentialAccount] && custody.read(Self.endpointA.credentialAccount) == nil)
        #expect(custody.read(Self.endpointB.credentialAccount) == nil && !store.isPreparingModel)
        store.stop(); await store.waitForConversationTaskToSettle(); try await history.close()
    }
    @Test func actorQueuedSaveIsCancelledBeforeItsActualCustodyEntry() async throws {
        let custody = OwnedCustody(hold: true)
        let client = CustomResponsesClient(transport: .init(open: { _ in Issue.record("No HTTP during key custody"); throw CancellationError() }), credentials: .init(store: custody.store))
        let (store, history) = custodyStore(custody, client: client)
        await store.waitForConversationTaskToSettle()
        let a = ModelConfiguration(backend: .customResponses, customResponses: try .init(baseURL: Self.endpointA.baseURLString, modelID: "owned/model", uploadsApproved: true))
        let b = ModelConfiguration(backend: .customResponses, customResponses: try .init(baseURL: Self.endpointB.baseURLString, modelID: "owned/model", uploadsApproved: true))
        let original = Data("SYNTHETIC-ORIGINAL-KEY-A-146800".utf8)
        let blocking = Task { try await client.replaceKey(original, for: Self.endpointA) }
        var queued: Task<Bool, Never>?
        do {
            try await wait { custody.didEnter }
            store.configuration = a
            let operation = Task { await store.replaceCustomResponsesKey("SYNTHETIC-MUST-NOT-BE-SAVED-146800", expectedConfiguration: a) }
            queued = operation
            try await wait { store.isPreparingModel }
            // Actual client actor is occupied by the original custody operation.
            // Changing selection cancels Store's retained save task now, before
            // an asynchronously rendered Settings callback can run.
            store.configuration = b; custody.release()
            try await blocking.value
            #expect(!(await operation.value))
            #expect(custody.destinations == [Self.endpointA.credentialAccount])
            #expect(custody.read(Self.endpointA.credentialAccount) == original && custody.read(Self.endpointB.credentialAccount) == nil)
            #expect(store.configuration == b && !store.isPreparingModel)
            store.stop(); await store.waitForConversationTaskToSettle(); try await history.close()
        } catch {
            custody.release(); queued?.cancel(); _ = await queued?.value; _ = await blocking.result
            store.stop(); await store.waitForConversationTaskToSettle(); try? await history.close(); throw error
        }
    }

    private static let mappedNamespace: CustomResponsesNamespaceMapping = [
        "mcp__github__search_issues": CustomResponsesNamespaceTarget(namespace: "mcp__github", name: "search_issues")
    ]

    private func decodeMappedStream(
        _ events: [[String: Any]],
        fragment: Int,
        availableTools: Set<String> = ["mcp__github__search_issues", "read_file"]
    ) throws -> ModelReply {
        var bytes = Data()
        for event in events {
            bytes.append(Data("data: ".utf8))
            bytes.append(try JSONSerialization.data(withJSONObject: event, options: [.withoutEscapingSlashes]))
            bytes.append(Data("\n\n".utf8))
        }
        bytes.append(Data("data: [DONE]\n\n".utf8))
        var decoder = CustomResponsesSSEDecoder(
            availableTools: availableTools,
            mapping: Self.mappedNamespace
        )
        for offset in stride(from: 0, to: bytes.count, by: fragment) {
            try decoder.append(Data(bytes[offset..<min(bytes.count, offset + fragment)]))
        }
        return try decoder.finish()
    }

    private func coherentMappedFlattenedStream() -> [[String: Any]] {
        let args = #"{"query":"owned-bug","limit":2}"#
        let item: [String: Any] = [
            "type": "function_call",
            "id": "item-mapped-1",
            "call_id": "call-mapped-1",
            "name": "mcp__github__search_issues",
            "arguments": args
        ]
        var initial = item
        initial["arguments"] = ""
        return [
            ["type": "response.created", "response": ["id": "resp-mapped-1", "status": "in_progress"]],
            ["type": "response.output_item.added", "output_index": 0, "item": initial],
            ["type": "response.function_call_arguments.delta", "item_id": "item-mapped-1", "output_index": 0, "delta": args],
            ["type": "response.function_call_arguments.done", "item_id": "item-mapped-1", "output_index": 0, "arguments": args],
            ["type": "response.output_item.done", "output_index": 0, "item": item],
            ["type": "response.completed", "response": ["id": "resp-mapped-1", "status": "completed", "output": [item]]]
        ]
    }

    @Test(arguments: [1, 9, 97])
    func mappedFragmentedSSEDispatchesCoherentFlattenedAndUnflattenedCalls(_ fragment: Int) throws {
        let flattened = try decodeMappedStream(coherentMappedFlattenedStream(), fragment: fragment)
        let call = try #require(flattened.toolCalls.first)
        #expect(flattened.toolCalls.count == 1 && call.id == "call-mapped-1" && call.name == "mcp__github__search_issues")
        #expect(call.arguments["query"] == .string("owned-bug") && call.arguments["limit"] == .number(2))

        let unprefixed = try decodeMappedStream(
            coherentMappedFlattenedStream(),
            fragment: fragment,
            availableTools: ["search_issues"]
        )
        #expect(unprefixed.toolCalls.first?.name == "search_issues")

        let args = #"{"query":"owned-bug","limit":2}"#
        let unflattenedItem: [String: Any] = [
            "type": "function_call",
            "id": "item-mapped-2",
            "call_id": "call-mapped-2",
            "name": "search_issues",
            "namespace": "mcp__github",
            "arguments": args
        ]
        var unflattenedInitial = unflattenedItem
        unflattenedInitial.removeValue(forKey: "arguments")
        let unflattenedEvents: [[String: Any]] = [
            ["type": "response.created", "response": ["id": "resp-mapped-2", "status": "in_progress"]],
            ["type": "response.output_item.added", "output_index": 0, "item": unflattenedInitial],
            ["type": "response.function_call_arguments.delta", "item_id": "item-mapped-2", "output_index": 0, "name": "search_issues", "namespace": "mcp__github", "delta": args],
            ["type": "response.function_call_arguments.done", "item_id": "item-mapped-2", "output_index": 0, "arguments": args],
            ["type": "response.output_item.done", "output_index": 0, "item": unflattenedItem],
            ["type": "response.completed", "response": ["id": "resp-mapped-2", "status": "completed", "output": [unflattenedItem]]]
        ]
        let unflattenedReply = try decodeMappedStream(unflattenedEvents, fragment: fragment)
        #expect(unflattenedReply.toolCalls.first?.name == "mcp__github__search_issues")
    }

    nonisolated enum MappedStreamMutation: String, CaseIterable, Sendable {
        case terminalForeignNamespaceOnFlatName
        case terminalExpectedNamespaceWhenAddedOmitted
        case addedExpectedNamespaceWhenTerminalOmitted
        case terminalUnflattenedWhenAddedFlattened
        case addedUnflattenedWhenTerminalFlattened
        case bothForeignNamespaceOnFlatName
        case doneForeignNamespaceOnFlatName
        case deltaUnexpectedNamespace
        case deltaUnflattenedNameWhenAddedFlattened
        case addedNonStringArgumentsInt
        case addedNonStringArgumentsBool
        case addedNonStringArgumentsObject
        case addedNonStringArgumentsNull
        case addedNonStringInputArray
        case addedConflictingArgumentsAndInput
        case addedNonStringNamespace
        case addedEmptyNamespace
    }

    @Test(arguments: MappedStreamMutation.allCases)
    func mappedFragmentedSSERejectsContradictoryWireIdentityAndWrongTypedPlaceholders(_ mutation: MappedStreamMutation) throws {
        var events = coherentMappedFlattenedStream()
        var addedItem = try #require(events[1]["item"] as? [String: Any])
        var doneItem = try #require(events[4]["item"] as? [String: Any])
        var terminal = try #require(events[5]["response"] as? [String: Any])
        var output = try #require(terminal["output"] as? [[String: Any]])

        switch mutation {
        case .terminalForeignNamespaceOnFlatName:
            output[0]["namespace"] = "foreign_namespace"
        case .terminalExpectedNamespaceWhenAddedOmitted:
            output[0]["namespace"] = "mcp__github"
        case .addedExpectedNamespaceWhenTerminalOmitted:
            addedItem["namespace"] = "mcp__github"
            doneItem["namespace"] = "mcp__github"
        case .terminalUnflattenedWhenAddedFlattened:
            output[0]["name"] = "search_issues"
            output[0]["namespace"] = "mcp__github"
        case .addedUnflattenedWhenTerminalFlattened:
            addedItem["name"] = "search_issues"
            addedItem["namespace"] = "mcp__github"
        case .bothForeignNamespaceOnFlatName:
            addedItem["namespace"] = "foreign_namespace"
            doneItem["namespace"] = "foreign_namespace"
            output[0]["namespace"] = "foreign_namespace"
        case .doneForeignNamespaceOnFlatName:
            doneItem["namespace"] = "foreign_namespace"
        case .deltaUnexpectedNamespace:
            events[2]["namespace"] = "mcp__github"
        case .deltaUnflattenedNameWhenAddedFlattened:
            events[2]["name"] = "search_issues"
        case .addedNonStringArgumentsInt:
            addedItem["arguments"] = 123
        case .addedNonStringArgumentsBool:
            addedItem["arguments"] = false
        case .addedNonStringArgumentsObject:
            addedItem["arguments"] = ["query": "owned-bug"]
        case .addedNonStringArgumentsNull:
            addedItem["arguments"] = NSNull()
        case .addedNonStringInputArray:
            addedItem.removeValue(forKey: "arguments")
            addedItem["input"] = ["owned-bug"]
        case .addedConflictingArgumentsAndInput:
            addedItem["arguments"] = ""
            addedItem["input"] = "{}"
        case .addedNonStringNamespace:
            addedItem["namespace"] = 42
        case .addedEmptyNamespace:
            addedItem["namespace"] = ""
        }
        events[1]["item"] = addedItem
        events[4]["item"] = doneItem
        terminal["output"] = output
        events[5]["response"] = terminal

        for fragment in [1, 19] {
            #expect(throws: CustomResponsesFailure.invalidResponse) {
                _ = try decodeMappedStream(events, fragment: fragment)
            }
        }
    }

    @Test func ordinaryJSONNormalizationValidatesRawWireTypesAndPreservesContradictoryIdentity() throws {
        let validResponse: [String: Any] = [
            "id": "resp_json_1",
            "status": "completed",
            "output": [
                [
                    "type": "function_call",
                    "id": "fc_json_1",
                    "call_id": "call_json_1",
                    "name": "mcp__github__search_issues",
                    "arguments": #"{"query":"owned"}"#
                ]
            ]
        ]
        let validData = try JSONSerialization.data(withJSONObject: validResponse)
        let reply = try CustomResponsesWireCodec.reply(
            from: validData,
            availableTools: ["mcp__github__search_issues", "calculate"],
            mapping: Self.mappedNamespace
        )
        #expect(reply.toolCalls.count == 1 && reply.toolCalls.first?.name == "mcp__github__search_issues")

        let foreignItem: [String: Any] = [
            "type": "function_call",
            "id": "fc_json_2",
            "call_id": "call_json_2",
            "name": "mcp__github__search_issues",
            "namespace": "foreign_namespace",
            "arguments": #"{"query":"owned"}"#
        ]
        let unflattenedForeign = CustomResponsesTranslator.unflattenResponseItem(foreignItem, mapping: Self.mappedNamespace)
        #expect(unflattenedForeign["name"] as? String == "mcp__github__search_issues")
        #expect(unflattenedForeign["namespace"] as? String == "foreign_namespace")

        let invalidOutputItems: [[String: Any]] = [
            foreignItem,
            [
                "type": "function_call",
                "id": "fc_json_3",
                "call_id": "call_json_3",
                "name": "calculate",
                "namespace": "foreign_namespace",
                "arguments": #"{"x":1}"#
            ],
            [
                "type": "function_call",
                "id": "fc_json_4",
                "call_id": "call_json_4",
                "name": "mcp__github__search_issues",
                "namespace": 99,
                "arguments": #"{"query":"owned"}"#
            ],
            [
                "type": "function_call",
                "id": "fc_json_5",
                "call_id": "call_json_5",
                "name": "mcp__github__search_issues",
                "arguments": 123,
                "input": #"{"query":"owned"}"#
            ],
            [
                "type": "function_call",
                "id": "fc_json_6",
                "call_id": "call_json_6",
                "name": "mcp__github__search_issues",
                "arguments": #"{"query":"owned"}"#,
                "input": #"{"query":"other"}"#
            ]
        ]
        for badItem in invalidOutputItems {
            let payload = try JSONSerialization.data(withJSONObject: [
                "id": "resp_bad",
                "status": "completed",
                "output": [badItem]
            ])
            #expect(throws: CustomResponsesFailure.invalidResponse) {
                _ = try CustomResponsesWireCodec.reply(
                    from: payload,
                    availableTools: ["mcp__github__search_issues", "calculate"],
                    mapping: Self.mappedNamespace
                )
            }
        }

        let contradictoryRequest: [String: Any] = [
            "model": "qwen/qwen3-coder",
            "tools": [
                [
                    "type": "namespace",
                    "name": "mcp__github",
                    "description": "GitHub MCP",
                    "tools": [
                        [
                            "type": "function",
                            "name": "search_issues",
                            "description": "Search issues",
                            "parameters": ["type": "object"]
                        ]
                    ]
                ]
            ],
            "input": [
                [
                    "type": "function_call",
                    "call_id": "call_bad_req",
                    "name": "mcp__github__search_issues",
                    "namespace": "foreign_namespace",
                    "arguments": "{}"
                ]
            ]
        ]
        let (rewrittenReq, reqMapping) = CustomResponsesTranslator.rewriteRequestObject(contradictoryRequest)
        let rewrittenInput = try #require(rewrittenReq["input"] as? [[String: Any]])
        #expect(rewrittenInput[0]["name"] as? String == "mcp__github__search_issues")
        #expect(rewrittenInput[0]["namespace"] as? String == "foreign_namespace")
        #expect(reqMapping["mcp__github__search_issues"] == CustomResponsesNamespaceTarget(namespace: "mcp__github", name: "search_issues"))
        let contradictoryReqData = try JSONSerialization.data(withJSONObject: contradictoryRequest)
        #expect(throws: CustomResponsesFailure.invalidResponse) {
            _ = try CustomResponsesTranslator.rewriteRequestData(contradictoryReqData)
        }
    }

    @Test(arguments: [false, true])
    func queuedKeySaveOrRemovalRefusesPreEntryABAAndStopAndUnappliedBaseURL(_ remove: Bool) async throws {
        let custody = OwnedCustody()
        let (store, history) = custodyStore(custody)
        await store.waitForConversationTaskToSettle()
        let a = ModelConfiguration(
            backend: .customResponses,
            customResponses: try .init(baseURL: Self.endpointA.baseURLString, modelID: "owned/model", uploadsApproved: true)
        )
        let b = ModelConfiguration(
            backend: .customResponses,
            customResponses: try .init(baseURL: Self.endpointB.baseURLString, modelID: "owned/model", uploadsApproved: true)
        )
        store.configuration = a

        // 1. Synchronous Store admission captured at button click must fail on A -> B -> A before async entry.
        let abaAdmission = try #require(store.captureCustomResponsesKeySaveAdmission(typedBaseURL: Self.endpointA.baseURLString))
        var draft = CustomResponsesKeyDraft()
        draft.set(
            "SYNTHETIC-KEY-A-146800",
            for: store.configuration,
            typedBaseURL: Self.endpointA.baseURLString,
            storeEpoch: abaAdmission.epoch
        )
        let submittedABA = try #require(draft.submission(for: abaAdmission, typedBaseURL: Self.endpointA.baseURLString))
        let queuedABA = Task {
            await store.replaceCustomResponsesKey(remove ? nil : submittedABA.value, admission: abaAdmission)
        }
        store.configuration = b
        store.configuration = a
        #expect(!store.isCustomResponsesKeySaveAdmissionCurrent(abaAdmission, typedBaseURL: Self.endpointA.baseURLString))
        #expect(draft.displayedValue(for: store.configuration, typedBaseURL: Self.endpointA.baseURLString, storeEpoch: store.customResponsesKeySaveEpoch).isEmpty)
        #expect(!draft.isCurrent(submittedABA, configuration: store.configuration, typedBaseURL: Self.endpointA.baseURLString, storeEpoch: store.customResponsesKeySaveEpoch))
        #expect(!(await queuedABA.value))
        #expect(!custody.didEnter && custody.destinations.isEmpty && store.configuration == a && !store.isPreparingModel)

        // 2. Synchronous Store admission captured at button click must fail on stop() before async entry.
        let stopAdmission = try #require(store.captureCustomResponsesKeySaveAdmission(typedBaseURL: Self.endpointA.baseURLString))
        let queuedStop = Task {
            await store.replaceCustomResponsesKey(remove ? nil : "SYNTHETIC-KEY-A-146800", admission: stopAdmission)
        }
        store.stop()
        #expect(!store.isCustomResponsesKeySaveAdmissionCurrent(stopAdmission, typedBaseURL: Self.endpointA.baseURLString))
        #expect(!(await queuedStop.value))
        #expect(!custody.didEnter && custody.destinations.isEmpty && store.configuration == a && !store.isPreparingModel)

        // 3. Unapplied / pending typed baseURL disables key edits, Save key, and Remove key for selected endpoint A.
        #expect(CustomResponsesKeyDraft.isBaseURLApplied(Self.endpointA.baseURLString, to: store.configuration))
        #expect(!CustomResponsesKeyDraft.isBaseURLApplied(Self.endpointB.baseURLString, to: store.configuration))
        #expect(!CustomResponsesKeyDraft.isBaseURLApplied("https://gateway-a.example/v1/responses", to: store.configuration))
        #expect(!CustomResponsesKeyDraft.isBaseURLApplied("http://gateway-b.example/v1", to: store.configuration))
        #expect(store.captureCustomResponsesKeySaveAdmission(typedBaseURL: Self.endpointB.baseURLString) == nil)

        var unappliedDraft = CustomResponsesKeyDraft()
        unappliedDraft.set(
            "SYNTHETIC-KEY-B-146800",
            for: store.configuration,
            typedBaseURL: Self.endpointB.baseURLString,
            storeEpoch: store.customResponsesKeySaveEpoch
        )
        #expect(unappliedDraft.value.isEmpty)
        #expect(unappliedDraft.displayedValue(for: store.configuration, typedBaseURL: Self.endpointB.baseURLString, storeEpoch: store.customResponsesKeySaveEpoch).isEmpty)
        #expect(unappliedDraft.submission(for: store.configuration, typedBaseURL: Self.endpointB.baseURLString, storeEpoch: store.customResponsesKeySaveEpoch) == nil)

        store.stop()
        await store.waitForConversationTaskToSettle()
        try await history.close()
    }

    @Test func productionRequestDeduplicatesIdenticalMappedToolsAndRefusesContradictoryDeclarations() throws {
        let baseParams: JSONValue = .object(["type": .string("object")])
        let loopbackTools = [
            ToolDefinition(name: "mcp__calc__calculate", description: "Synthetic", parameters: baseParams),
            ToolDefinition(name: "local_tool", description: "Local tool", parameters: baseParams)
        ]
        let loopbackNamespaces = [
            CustomResponsesNamespaceDefinition(
                name: "mcp__calc",
                description: "Synthetic namespace",
                tools: [ToolDefinition(name: "calculate", description: "Synthetic", parameters: baseParams)]
            )
        ]
        let (requestData, mapping) = try CustomResponsesWireCodec.request(
            model: "owned/tool",
            messages: [.init(role: "user", content: "Synthetic protocol only")],
            tools: loopbackTools,
            namespaces: loopbackNamespaces
        )
        #expect(mapping == ["mcp__calc__calculate": CustomResponsesNamespaceTarget(namespace: "mcp__calc", name: "calculate")])
        let requestObj = try #require(try JSONSerialization.jsonObject(with: requestData) as? [String: Any])
        let emittedTools = try #require(requestObj["tools"] as? [[String: Any]])
        #expect(emittedTools.count == 2)
        #expect(emittedTools.filter { ($0["name"] as? String) == "mcp__calc__calculate" }.count == 1)
        #expect(emittedTools[0]["name"] as? String == "mcp__calc__calculate")
        #expect(emittedTools[0]["description"] as? String == "Synthetic namespace — Synthetic")
        #expect(emittedTools[1]["name"] as? String == "local_tool")

        // Combined description overlap in tools + namespaces also emits exactly once.
        let (combinedData, combinedMapping) = try CustomResponsesWireCodec.request(
            model: "owned/tool",
            messages: [.init(role: "user", content: "Synthetic protocol only")],
            tools: [ToolDefinition(name: "mcp__calc__calculate", description: "Synthetic namespace — Synthetic", parameters: baseParams)],
            namespaces: loopbackNamespaces
        )
        #expect(combinedMapping == mapping)
        let combinedObj = try #require(try JSONSerialization.jsonObject(with: combinedData) as? [String: Any])
        let combinedTools = try #require(combinedObj["tools"] as? [[String: Any]])
        #expect(combinedTools.count == 1 && combinedTools[0]["name"] as? String == "mcp__calc__calculate")

        // Contradictory parameters between tools and namespaces must be refused by production request.
        let mismatchedParams: JSONValue = .object([
            "type": .string("object"),
            "required": .array([.string("expression")])
        ])
        #expect(throws: CustomResponsesFailure.invalidResponse) {
            _ = try CustomResponsesWireCodec.request(
                model: "owned/tool",
                messages: [.init(role: "user", content: "Synthetic")],
                tools: [ToolDefinition(name: "mcp__calc__calculate", description: "Synthetic", parameters: mismatchedParams)],
                namespaces: loopbackNamespaces
            )
        }

        // Contradictory description between tools and namespaces must be refused by production request.
        #expect(throws: CustomResponsesFailure.invalidResponse) {
            _ = try CustomResponsesWireCodec.request(
                model: "owned/tool",
                messages: [.init(role: "user", content: "Synthetic")],
                tools: [ToolDefinition(name: "mcp__calc__calculate", description: "Unrelated tool description", parameters: baseParams)],
                namespaces: loopbackNamespaces
            )
        }

        // Alternate namespace/name split in namespaces producing the same flat name must be refused.
        #expect(throws: CustomResponsesFailure.invalidResponse) {
            _ = try CustomResponsesWireCodec.request(
                model: "owned/tool",
                messages: [.init(role: "user", content: "Synthetic")],
                tools: [ToolDefinition(name: "mcp__github__search_issues", description: "Search issues", parameters: baseParams)],
                namespaces: [
                    CustomResponsesNamespaceDefinition(
                        name: "mcp__github",
                        description: "GitHub MCP",
                        tools: [ToolDefinition(name: "search_issues", description: "Search issues", parameters: baseParams)]
                    ),
                    CustomResponsesNamespaceDefinition(
                        name: "mcp",
                        description: "Alternate MCP split",
                        tools: [ToolDefinition(name: "github__search_issues", description: "Search issues", parameters: baseParams)]
                    )
                ]
            )
        }
    }

    @Test func alternateNamespaceAndNameSplitsAreRefusedAcrossOrdinaryJSONAndFragmentedSSERoutes() throws {
        let baseParams: JSONValue = .object(["type": .string("object")])
        let (_, mapping) = try CustomResponsesWireCodec.request(
            model: "owned/tool",
            messages: [.init(role: "user", content: "Search")],
            tools: [ToolDefinition(name: "mcp__github__search_issues", description: "Search issues", parameters: baseParams)],
            namespaces: [
                CustomResponsesNamespaceDefinition(
                    name: "mcp__github",
                    description: "GitHub MCP",
                    tools: [ToolDefinition(name: "search_issues", description: "Search issues", parameters: baseParams)]
                )
            ]
        )
        #expect(mapping == Self.mappedNamespace)
        let allowed: Set<String> = ["mcp__github__search_issues", "github__search_issues", "search_issues"]

        // Coherent exact split (mcp__github + search_issues) succeeds in ordinary JSON and SSE.
        let exactUnflattenedJSON = try JSONSerialization.data(withJSONObject: [
            "id": "resp_exact_split",
            "status": "completed",
            "output": [
                [
                    "type": "function_call",
                    "id": "fc_exact_1",
                    "call_id": "call_exact_1",
                    "name": "search_issues",
                    "namespace": "mcp__github",
                    "arguments": #"{"query":"owned"}"#
                ]
            ]
        ])
        let exactReply = try CustomResponsesWireCodec.reply(
            from: exactUnflattenedJSON,
            availableTools: ["mcp__github__search_issues"],
            mapping: mapping
        )
        #expect(exactReply.toolCalls.count == 1 && exactReply.toolCalls.first?.name == "mcp__github__search_issues")

        // Alternate splits (mcp + github__search_issues, mcp__github__search + issues) must be refused even when flat key matches allowedTools.
        for (badNS, badName) in [("mcp", "github__search_issues"), ("mcp__github__search", "issues")] {
            let badJSON = try JSONSerialization.data(withJSONObject: [
                "id": "resp_bad_split",
                "status": "completed",
                "output": [
                    [
                        "type": "function_call",
                        "id": "fc_bad_split",
                        "call_id": "call_bad_split",
                        "name": badName,
                        "namespace": badNS,
                        "arguments": #"{"query":"owned"}"#
                    ]
                ]
            ])
            #expect(throws: CustomResponsesFailure.invalidResponse) {
                _ = try CustomResponsesWireCodec.reply(
                    from: badJSON,
                    availableTools: allowed,
                    mapping: mapping
                )
            }
            #expect(throws: CustomResponsesFailure.invalidResponse) {
                _ = try CustomResponsesWireCodec.reply(
                    from: badJSON,
                    availableTools: allowed,
                    mapping: [:]
                )
            }

            let args = #"{"query":"owned"}"#
            let badSSEItem: [String: Any] = [
                "type": "function_call",
                "id": "item-bad-split",
                "call_id": "call-bad-split",
                "name": badName,
                "namespace": badNS,
                "arguments": args
            ]
            var badInitial = badSSEItem
            badInitial["arguments"] = ""
            let badSSEEvents: [[String: Any]] = [
                ["type": "response.created", "response": ["id": "resp-bad-split", "status": "in_progress"]],
                ["type": "response.output_item.added", "output_index": 0, "item": badInitial],
                ["type": "response.function_call_arguments.delta", "item_id": "item-bad-split", "output_index": 0, "name": badName, "namespace": badNS, "delta": args],
                ["type": "response.function_call_arguments.done", "item_id": "item-bad-split", "output_index": 0, "arguments": args],
                ["type": "response.output_item.done", "output_index": 0, "item": badSSEItem],
                ["type": "response.completed", "response": ["id": "resp-bad-split", "status": "completed", "output": [badSSEItem]]]
            ]
            for fragment in [1, 17] {
                #expect(throws: CustomResponsesFailure.invalidResponse) {
                    _ = try decodeMappedStream(badSSEEvents, fragment: fragment, availableTools: allowed)
                }
                #expect(throws: CustomResponsesFailure.invalidResponse) {
                    _ = try decodeMappedStream([try #require(badSSEEvents.last)], fragment: fragment, availableTools: allowed)
                }
            }
        }
    }

    private func sseData(_ events: [[String: Any]]) throws -> Data {
        var bytes = Data()
        for event in events {
            bytes.append(Data("data: ".utf8))
            bytes.append(try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]))
            bytes.append(Data("\n\n".utf8))
        }
        return bytes
    }

    @Test func canonicalEquivalentUnicodeToolAndNamespaceNamesAreRefusedAcrossRequestOrdinaryJSONAndFragmentedSSE() throws {
        let baseParams: JSONValue = .object(["type": .string("object")])
        let kelvin = "\u{212A}" // K (UTF-8 E2 84 AA), canonically equivalent in Swift String to ASCII "K" (0x4B)
        #expect(kelvin == "K")
        #expect(Data(kelvin.utf8) != Data("K".utf8))

        let (_, kMapping) = try CustomResponsesWireCodec.request(
            model: "owned/tool",
            messages: [.init(role: "user", content: "Search")],
            tools: [
                ToolDefinition(name: "mcp__K__search", description: "Search K", parameters: baseParams),
                ToolDefinition(name: "mcp__K__K", description: "Tool K", parameters: baseParams)
            ],
            namespaces: [
                CustomResponsesNamespaceDefinition(
                    name: "mcp__K",
                    description: "K MCP",
                    tools: [
                        ToolDefinition(name: "search", description: "Search K", parameters: baseParams),
                        ToolDefinition(name: "K", description: "Tool K", parameters: baseParams)
                    ]
                )
            ]
        )
        let expectedSearchTarget = CustomResponsesNamespaceTarget(namespace: "mcp__K", name: "search")
        let expectedKTarget = CustomResponsesNamespaceTarget(namespace: "mcp__K", name: "K")
        #expect(kMapping["mcp__K__search"] == expectedSearchTarget)
        #expect(kMapping["mcp__K__K"] == expectedKTarget)
        #expect(CustomResponsesNamespaceTarget(namespace: "mcp__\(kelvin)", name: "search") != expectedSearchTarget)
        #expect(CustomResponsesNamespaceTarget(namespace: "mcp__K", name: kelvin) != expectedKTarget)
        #expect(CustomResponsesTranslator.validToolIdentifier("mcp__K__search") == "mcp__K__search")
        #expect(CustomResponsesTranslator.validToolIdentifier("mcp__\(kelvin)__search") == nil)
        #expect(CustomResponsesTranslator.exactMappedTarget(for: "mcp__K__search", in: kMapping) == expectedSearchTarget)
        #expect(CustomResponsesTranslator.exactMappedTarget(for: "mcp__\(kelvin)__search", in: kMapping) == nil)

        let allowedK: Set<String> = ["mcp__K__search", "mcp__K__K", "search", "K"]
        let args = #"{"query":"owned"}"#

        // 1. Positive controls: exact ASCII flattened and unflattened tool calls succeed in ordinary JSON and fragmented SSE.
        for positiveItem in [
            [
                "type": "function_call",
                "id": "fc_ascii_flat",
                "call_id": "call_ascii_flat",
                "name": "mcp__K__search",
                "arguments": args
            ] as [String: Any],
            [
                "type": "function_call",
                "id": "fc_ascii_unflat",
                "call_id": "call_ascii_unflat",
                "name": "search",
                "namespace": "mcp__K",
                "arguments": args
            ] as [String: Any]
        ] {
            let unflattened = CustomResponsesTranslator.unflattenResponseItem(positiveItem, mapping: kMapping)
            #expect(unflattened["name"] as? String == "search")
            #expect(unflattened["namespace"] as? String == "mcp__K")

            let okJSON = try JSONSerialization.data(withJSONObject: [
                "id": "resp_ascii_ok",
                "status": "completed",
                "output": [positiveItem]
            ])
            let okReply = try CustomResponsesWireCodec.reply(
                from: okJSON,
                availableTools: ["mcp__K__search"],
                mapping: kMapping
            )
            #expect(okReply.toolCalls.count == 1)
            #expect(okReply.toolCalls.first?.name == "mcp__K__search")

            var initial = positiveItem
            initial["arguments"] = ""
            let itemID = try #require(positiveItem["id"] as? String)
            let itemName = try #require(positiveItem["name"] as? String)
            var deltaEvent: [String: Any] = [
                "type": "response.function_call_arguments.delta",
                "item_id": itemID,
                "output_index": 0,
                "name": itemName,
                "delta": args
            ]
            if let ns = positiveItem["namespace"] as? String {
                deltaEvent["namespace"] = ns
            }
            let okSSEEvents: [[String: Any]] = [
                ["type": "response.created", "response": ["id": "resp-ascii-ok", "status": "in_progress"]],
                ["type": "response.output_item.added", "output_index": 0, "item": initial],
                deltaEvent,
                ["type": "response.function_call_arguments.done", "item_id": itemID, "output_index": 0, "arguments": args],
                ["type": "response.output_item.done", "output_index": 0, "item": positiveItem],
                ["type": "response.completed", "response": ["id": "resp-ascii-ok", "status": "completed", "output": [positiveItem]]]
            ]
            for fragment in [1, 17] {
                var decoder = CustomResponsesSSEDecoder(availableTools: ["mcp__K__search"], mapping: kMapping)
                let bytes = try sseData(okSSEEvents)
                var index = bytes.startIndex
                while index < bytes.endIndex {
                    let end = min(index + fragment, bytes.endIndex)
                    try decoder.append(Data(bytes[index..<end]))
                    index = end
                }
                let sseReply = try decoder.finish()
                #expect(sseReply.toolCalls.count == 1 && sseReply.toolCalls.first?.name == "mcp__K__search")
            }
        }

        // 2. Negative controls: unflattenResponseItem must NOT rewrite Kelvin-sign or NFD/NFC canonical-equivalent names.
        let kelvinFlatItem: [String: Any] = [
            "type": "function_call",
            "id": "fc_kelvin_flat",
            "call_id": "call_kelvin_flat",
            "name": "mcp__\(kelvin)__search",
            "arguments": args
        ]
        let untouchedFlat = CustomResponsesTranslator.unflattenResponseItem(kelvinFlatItem, mapping: kMapping)
        #expect(Data((untouchedFlat["name"] as? String ?? "").utf8) == Data("mcp__\(kelvin)__search".utf8))
        #expect(untouchedFlat["namespace"] == nil)

        let kelvinNSOnFlatItem: [String: Any] = [
            "type": "function_call",
            "id": "fc_kelvin_ns_flat",
            "call_id": "call_kelvin_ns_flat",
            "name": "mcp__K__search",
            "namespace": "mcp__\(kelvin)",
            "arguments": args
        ]
        let untouchedNSFlat = CustomResponsesTranslator.unflattenResponseItem(kelvinNSOnFlatItem, mapping: kMapping)
        #expect(Data((untouchedNSFlat["name"] as? String ?? "").utf8) == Data("mcp__K__search".utf8))
        #expect(Data((untouchedNSFlat["namespace"] as? String ?? "").utf8) == Data("mcp__\(kelvin)".utf8))

        // 3. Negative controls across ordinary JSON and fragmented SSE for canonical-equivalent raw tool/namespace names.
        let negativeItems: [[String: Any]] = [
            kelvinFlatItem,
            kelvinNSOnFlatItem,
            [
                "type": "function_call",
                "id": "fc_kelvin_ns_unflat",
                "call_id": "call_kelvin_ns_unflat",
                "name": "search",
                "namespace": "mcp__\(kelvin)",
                "arguments": args
            ],
            [
                "type": "function_call",
                "id": "fc_kelvin_name_unflat",
                "call_id": "call_kelvin_name_unflat",
                "name": kelvin,
                "namespace": "mcp__K",
                "arguments": args
            ],
            [
                "type": "function_call",
                "id": "fc_kelvin_both",
                "call_id": "call_kelvin_both",
                "name": kelvin,
                "namespace": "mcp__\(kelvin)",
                "arguments": args
            ],
            [
                "type": "function_call",
                "id": "fc_nfd_flat",
                "call_id": "call_nfd_flat",
                "name": "mcp__Cafe\u{0301}__search",
                "arguments": args
            ]
        ]

        for badItem in negativeItems {
            let badJSON = try JSONSerialization.data(withJSONObject: [
                "id": "resp_bad_kelvin",
                "status": "completed",
                "output": [badItem]
            ])
            #expect(throws: CustomResponsesFailure.invalidResponse) {
                _ = try CustomResponsesWireCodec.reply(
                    from: badJSON,
                    availableTools: allowedK,
                    mapping: kMapping
                )
            }
            #expect(throws: CustomResponsesFailure.invalidResponse) {
                _ = try CustomResponsesWireCodec.reply(
                    from: badJSON,
                    availableTools: allowedK.union(["mcp__\(kelvin)__search", kelvin]),
                    mapping: [:]
                )
            }

            var badInitial = badItem
            badInitial["arguments"] = ""
            let itemID = try #require(badItem["id"] as? String)
            let badName = try #require(badItem["name"] as? String)
            var badDelta: [String: Any] = [
                "type": "response.function_call_arguments.delta",
                "item_id": itemID,
                "output_index": 0,
                "name": badName,
                "delta": args
            ]
            if let badNS = badItem["namespace"] as? String {
                badDelta["namespace"] = badNS
            }
            let badSSEEvents: [[String: Any]] = [
                ["type": "response.created", "response": ["id": "resp-bad-kelvin", "status": "in_progress"]],
                ["type": "response.output_item.added", "output_index": 0, "item": badInitial],
                badDelta,
                ["type": "response.function_call_arguments.done", "item_id": itemID, "output_index": 0, "arguments": args],
                ["type": "response.output_item.done", "output_index": 0, "item": badItem],
                ["type": "response.completed", "response": ["id": "resp-bad-kelvin", "status": "completed", "output": [badItem]]]
            ]
            for fragment in [1, 17] {
                for stream in [badSSEEvents, [try #require(badSSEEvents.last)]] {
                    var decoder = CustomResponsesSSEDecoder(availableTools: allowedK, mapping: kMapping)
                    let bytes = try sseData(stream)
                    var index = bytes.startIndex
                    #expect(throws: CustomResponsesFailure.invalidResponse) {
                        while index < bytes.endIndex {
                            let end = min(index + fragment, bytes.endIndex)
                            try decoder.append(Data(bytes[index..<end]))
                            index = end
                        }
                        _ = try decoder.finish()
                    }
                }
            }
        }

        // 4. Fragmented SSE mid-stream drift from ASCII "mcp__K" / "mcp__K__search" in added to Kelvin sign in delta/done/completed.
        let validAddedFlat: [String: Any] = [
            "type": "function_call",
            "id": "item-drift-flat",
            "call_id": "call-drift-flat",
            "name": "mcp__K__search",
            "arguments": ""
        ]
        let validDoneFlat: [String: Any] = [
            "type": "function_call",
            "id": "item-drift-flat",
            "call_id": "call-drift-flat",
            "name": "mcp__K__search",
            "arguments": args
        ]
        let driftDeltaEvents: [[String: Any]] = [
            ["type": "response.created", "response": ["id": "resp-drift-1", "status": "in_progress"]],
            ["type": "response.output_item.added", "output_index": 0, "item": validAddedFlat],
            ["type": "response.function_call_arguments.delta", "item_id": "item-drift-flat", "output_index": 0, "name": "mcp__\(kelvin)__search", "delta": args],
            ["type": "response.function_call_arguments.done", "item_id": "item-drift-flat", "output_index": 0, "arguments": args],
            ["type": "response.output_item.done", "output_index": 0, "item": validDoneFlat],
            ["type": "response.completed", "response": ["id": "resp-drift-1", "status": "completed", "output": [validDoneFlat]]]
        ]
        let validAddedUnflat: [String: Any] = [
            "type": "function_call",
            "id": "item-drift-ns",
            "call_id": "call-drift-ns",
            "name": "search",
            "namespace": "mcp__K",
            "arguments": ""
        ]
        let validDoneUnflat: [String: Any] = [
            "type": "function_call",
            "id": "item-drift-ns",
            "call_id": "call-drift-ns",
            "name": "search",
            "namespace": "mcp__K",
            "arguments": args
        ]
        let driftNSDeltaEvents: [[String: Any]] = [
            ["type": "response.created", "response": ["id": "resp-drift-2", "status": "in_progress"]],
            ["type": "response.output_item.added", "output_index": 0, "item": validAddedUnflat],
            ["type": "response.function_call_arguments.delta", "item_id": "item-drift-ns", "output_index": 0, "name": "search", "namespace": "mcp__\(kelvin)", "delta": args],
            ["type": "response.function_call_arguments.done", "item_id": "item-drift-ns", "output_index": 0, "arguments": args],
            ["type": "response.output_item.done", "output_index": 0, "item": validDoneUnflat],
            ["type": "response.completed", "response": ["id": "resp-drift-2", "status": "completed", "output": [validDoneUnflat]]]
        ]
        for stream in [driftDeltaEvents, driftNSDeltaEvents] {
            for fragment in [1, 17] {
                var decoder = CustomResponsesSSEDecoder(availableTools: allowedK, mapping: kMapping)
                let bytes = try sseData(stream)
                var index = bytes.startIndex
                #expect(throws: CustomResponsesFailure.invalidResponse) {
                    while index < bytes.endIndex {
                        let end = min(index + fragment, bytes.endIndex)
                        try decoder.append(Data(bytes[index..<end]))
                        index = end
                    }
                    _ = try decoder.finish()
                }
            }
        }

        // 5. Request path: CustomResponsesWireCodec.request, rewriteRequestData, and rewriteRequestObject refuse Kelvin sign names.
        #expect(throws: CustomResponsesFailure.invalidResponse) {
            _ = try CustomResponsesWireCodec.request(
                model: "owned/tool",
                messages: [.init(role: "user", content: "Search")],
                tools: [ToolDefinition(name: "mcp__\(kelvin)__search", description: "Search", parameters: baseParams)]
            )
        }
        #expect(throws: CustomResponsesFailure.invalidResponse) {
            _ = try CustomResponsesWireCodec.request(
                model: "owned/tool",
                messages: [.init(role: "user", content: "Search")],
                tools: [],
                namespaces: [
                    CustomResponsesNamespaceDefinition(
                        name: "mcp__\(kelvin)",
                        description: "Kelvin NS",
                        tools: [ToolDefinition(name: "search", description: "Search", parameters: baseParams)]
                    )
                ]
            )
        }
        let kelvinInputReq: [String: Any] = [
            "model": "qwen/qwen3-coder",
            "tools": [
                [
                    "type": "namespace",
                    "name": "mcp__K",
                    "description": "K MCP",
                    "tools": [
                        [
                            "type": "function",
                            "name": "search",
                            "description": "Search",
                            "parameters": ["type": "object"]
                        ]
                    ]
                ]
            ],
            "input": [
                [
                    "type": "function_call",
                    "call_id": "call_kelvin_req",
                    "name": "search",
                    "namespace": "mcp__\(kelvin)",
                    "arguments": "{}"
                ]
            ]
        ]
        let (fallbackReq, fallbackMap) = CustomResponsesTranslator.rewriteRequestObject(kelvinInputReq)
        let fallbackInput = try #require(fallbackReq["input"] as? [[String: Any]])
        #expect(Data((fallbackInput[0]["name"] as? String ?? "").utf8) == Data("search".utf8))
        #expect(Data((fallbackInput[0]["namespace"] as? String ?? "").utf8) == Data("mcp__\(kelvin)".utf8))
        #expect(fallbackMap == ["mcp__K__search": expectedSearchTarget])
        let kelvinInputReqData = try JSONSerialization.data(withJSONObject: kelvinInputReq)
        #expect(throws: CustomResponsesFailure.invalidResponse) {
            _ = try CustomResponsesTranslator.rewriteRequestData(kelvinInputReqData)
        }
    }

}
