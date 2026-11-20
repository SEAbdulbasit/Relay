import Foundation
import Testing
@testable import Relay

/// Inert transport and synthetic credential custody. No Keychain, model, paid
/// provider or socket is touched by these default tests.
@MainActor struct OpenRouterProviderTests {
    nonisolated private final class Keys: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Data? = Data("SYNTHETIC-OPENROUTER-KEY-4926".utf8)
        private var failure = false
        func change(_ value: String?) { lock.withLock { self.value = value.map { Data($0.utf8) } } }
        func fail() { lock.withLock { failure = true } }
        var custody: OpenRouterCredentials {
            .init(read: { [self] in try lock.withLock { if failure { throw OpenRouterFailure.secureStorage }; return value } },
                  write: { [self] data in lock.withLock { value = data } })
        }
    }
    private func wait(_ condition: @MainActor () async -> Bool) async throws {
        let start = ContinuousClock.now, deadline = start.advanced(by: .seconds(5))
        var polls = 0
        while !(await condition()) {
            polls += 1; try Task.checkCancellation()
            try #require(ContinuousClock.now < deadline, "OpenRouter inert bounded wait expired: elapsed_ms=\(WorkerSettlementDiagnostics.milliseconds(start.duration(to: .now))), polls=\(polls).")
            try await Task.sleep(for: .milliseconds(2))
        }
    }
    @MainActor private final class SourceState { var current = true }
    private func configuration(model: String = "synthetic-server-model", approved: Bool = true) throws -> ModelConfiguration {
        .init(backend: .openRouter, openRouter: try .init(modelID: model, uploadsApproved: approved))
    }
    @Test func savedConfigurationContainsOnlySelectionAndApprovalAndKeyVersionNeverSecretBytes() throws {
        let chosen = try configuration(), data = try JSONEncoder().encode(chosen)
        let restored = try JSONDecoder().decode(ModelConfiguration.self, from: data)
        #expect(restored == chosen && restored.inferenceIdentity == chosen.inferenceIdentity)
        #expect(!String(decoding: data, as: UTF8.self).contains("SYNTHETIC-OPENROUTER"))
        #expect(try configuration(approved: false).inferenceIdentity == nil)
        var rotated = chosen; rotated.openRouter?.credentialRevision = UUID()
        #expect(rotated.inferenceIdentity != chosen.inferenceIdentity)
        #expect(ModelConfiguration().backend == .liteRTLM)
        #expect(OpenRouterCredentials.service != OpenRouterCredentials.account)
    }
    @Test func exactBearerIsIndependentAndStructuredHistoryDoesNotReadAnotherProviderOrFallback() async throws {
        let keys = Keys(), peer = LMStudioIntegrationFixture(); await peer.setMode(.calculate)
        let client = OpenRouterClient(transport: peer.transport, credentials: keys.custody)
        let choice = try #require(configuration().openRouter)
        let tool = ToolDefinition(name: "calculate", description: "Synthetic arithmetic", parameters: .object(["type": .string("object")]))
        let first = try await client.complete(messages: [.init(role: "user", content: "6*7")], tools: [tool], configuration: choice)
        let call = try #require(first.toolCalls.first)
        let second = try await client.complete(messages: [.init(role: "user", content: "6*7"),
            .init(role: "assistant", content: first.content, toolCalls: first.toolCalls),
            .init(role: "tool", content: "42", toolCallID: call.id, toolName: call.name)], tools: [tool], configuration: choice)
        #expect(second.content == "42")
        let requests = await peer.requests
        #expect(requests.count == 2 && requests.allSatisfy { $0.url == OpenRouterClient.completionsURL })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer SYNTHETIC-OPENROUTER-KEY-4926" })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == nil && $0.value(forHTTPHeaderField: "Proxy-Authorization") == nil })
        let body = try JSONDecoder().decode(JSONValue.self, from: #require(requests.last?.httpBody))
        #expect(body.object?["provider"]?.object?["allow_fallbacks"] == .bool(false))
        #expect(body.object?["provider"]?.object?["require_parameters"] == .bool(true))
        #expect(!String(decoding: requests.last!.httpBody!, as: UTF8.self).contains("SYNTHETIC-OPENROUTER"))
        await client.drain()
    }
    @Test(arguments: [false, true])
    func missingOrLockedDedicatedKeyFailsBeforeTransportAndNeverReadsAnotherCredential(_ locked: Bool) async throws {
        let keys = Keys(), peer = LMStudioIntegrationFixture()
        if locked { keys.fail() } else { keys.change(nil) }
        let client = OpenRouterClient(transport: peer.transport, credentials: keys.custody)
        await #expect(throws: locked ? OpenRouterFailure.secureStorage : .keyRequired) {
            try await client.complete(messages: [.init(role: "user", content: "Owned synthetic data")], tools: [], configuration: #require(configuration().openRouter))
        }
        let requests = await peer.requests; #expect(requests.isEmpty)
    }
    @Test func explicitCloudApprovalIsRequiredBeforeAnyPrivateTransportOpen() async throws {
        let keys = Keys(), peer = LMStudioIntegrationFixture(), client = OpenRouterClient(transport: peer.transport, credentials: keys.custody)
        let selected = try #require(configuration(approved: false).openRouter)
        await #expect(throws: OpenRouterFailure.invalidModel) {
            try await client.complete(messages: [.init(role: "user", content: "PRIVATE owned text")], tools: [], configuration: selected)
        }
        let requests = await peer.requests; #expect(requests.isEmpty)
    }
    @Test func providerErrorsNeverEchoPrivateResponseBodyOrCredential() async throws {
        let keys = Keys()
        let client = OpenRouterClient(transport: .init(open: { request in
            let stream = AsyncThrowingStream<Data, any Error> { $0.yield(Data("PRIVATE ECHO SYNTHETIC-OPENROUTER-KEY-4926".utf8)); $0.finish() }
            return .init(url: request.url!, status: 401, contentType: "application/json", body: stream, cancel: {})
        }), credentials: keys.custody)
        do {
            _ = try await client.complete(messages: [.init(role: "user", content: "Owned synthetic data")], tools: [], configuration: #require(configuration().openRouter))
            Issue.record("Expected closed authentication failure")
        } catch {
            #expect(error as? OpenRouterFailure == .rejected(401))
            #expect(!error.localizedDescription.contains("PRIVATE") && !error.localizedDescription.contains("4926"))
        }
    }
    enum Refusal: Error { case source }
    @Test(arguments: ["before", "reply", "error"])
    func liveSourceRefusesBeforePrivateSendAndOnBothReplyPathsWithoutReturningLateData(_ mode: String) async throws {
        let peer = LMStudioIntegrationFixture(), keys = Keys(), revokeAfterSend = mode != "before"
        if revokeAfterSend { await peer.hold() }
        if mode == "error" { await peer.failNextReply() }
        let client = OpenRouterClient(transport: peer.transport, credentials: keys.custody)
        let state = SourceState(); state.current = revokeAfterSend
        let choice = try #require(configuration().openRouter)
        let pending = Task { try await client.complete(messages: [.init(role: "user", content: "PRIVATE owned source")], tools: [], configuration: choice,
            sourceAuthorization: { if !state.current { throw Refusal.source } }) }
        do {
            if revokeAfterSend {
                try await wait { await peer.requests.count == 1 }
                state.current = false; await peer.release()
            }
            await #expect(throws: Refusal.source) { try await pending.value }
            let requests = await peer.requests; #expect(requests.count == (revokeAfterSend ? 1 : 0))
            await client.drain()
        } catch { pending.cancel(); await peer.release(); _ = await pending.result; await client.drain(); throw error }
    }
    @Test func cancellationAndProviderSwitchKeepSharedLeaseUntilUncooperativeHTTPReturns() async throws {
        let peer = LMStudioIntegrationFixture(), keys = Keys(); await peer.hold()
        let client = OpenRouterClient(transport: peer.transport, credentials: keys.custody)
        let router = LocalInferenceRouter(openRouter: client), selected = try configuration()
        let pending = Task { try await router.complete(messages: [.init(role: "user", content: "Owned source")], tools: [], configuration: selected) }
        do {
            try await wait { await peer.requests.count == 1 }
            pending.cancel(); router.selectionDidChange(ModelConfiguration())
            await #expect(throws: LocalInferenceFailure.busy) { try await router.fork().complete(messages: [.init(role: "user", content: "Later")], tools: [], configuration: selected) }
            await peer.release()
            await #expect(throws: CancellationError.self) { try await pending.value }
            await router.drain()
            let requests = await peer.requests; #expect(requests.count == 1)
        } catch { pending.cancel(); await peer.release(); _ = await pending.result; await router.drain(); throw error }
    }
    @Test func switchingToLMStudioNeverForwardsTheOpenRouterKeyOrReusesItsEndpoint() async throws {
        let remote = LMStudioIntegrationFixture(), local = LMStudioIntegrationFixture(), keys = Keys()
        let cloud = OpenRouterClient(transport: remote.transport, credentials: keys.custody)
        let router = LocalInferenceRouter(server: LMStudioClient(transport: local.transport), openRouter: cloud)
        _ = try await router.complete(messages: [.init(role: "user", content: "Owned cloud protocol")], tools: [], configuration: configuration())
        let onMac = ModelConfiguration(backend: .lmStudio, lmStudio: try .init(endpoint: LMStudioEndpoint(), modelID: "synthetic-server-model"))
        router.selectionDidChange(onMac)
        _ = try await router.complete(messages: [.init(role: "user", content: "Owned local protocol")], tools: [], configuration: onMac)
        let cloudRequests = await remote.requests, localRequests = await local.requests
        #expect(cloudRequests.count == 1 && localRequests.count == 1)
        #expect(cloudRequests[0].url == OpenRouterClient.completionsURL)
        #expect(localRequests[0].url == onMac.lmStudio?.endpoint.completionsURL)
        #expect(localRequests[0].value(forHTTPHeaderField: "Authorization") == nil)
        await router.drain()
    }
    @Test func keyReplacementDuringUncooperativeRequestRejectsOldReplyAndRevokesVisionReceipt() async throws {
        let peer = LMStudioIntegrationFixture(), keys = Keys(); await peer.hold()
        let client = OpenRouterClient(transport: peer.transport, credentials: keys.custody)
        let choice = try #require(configuration().openRouter)
        let pending = Task { try await client.complete(messages: [.init(role: "user", content: "Owned source")], tools: [], configuration: choice) }
        do {
            try await wait { await peer.requests.count == 1 }
            try await client.replaceKey(Data("SYNTHETIC-REPLACEMENT-KEY-7348".utf8))
            await peer.release(); await #expect(throws: CancellationError.self) { try await pending.value }
            await client.drain(); let verified = await client.visionIsVerified(for: choice); #expect(!verified)
        } catch { pending.cancel(); await peer.release(); _ = await pending.result; await client.drain(); throw error }
    }
    @Test func realStoreReadinessAndToolLoopUseOnlyExplicitOpenRouterRouteAndRevokeOnApprovalRemoval() async throws {
        let peer = LMStudioIntegrationFixture(), keys = Keys(); await peer.setMode(.calculate)
        var native = 0, codex = 0, dispatches = 0
        let client = OpenRouterClient(transport: peer.transport, credentials: keys.custody)
        let store = AssistantStore(persistenceURL: nil, execute: { call in
            #expect(call.name == "calculate"); dispatches += 1
            return .init(summary: "42", evidence: "Owned inert arithmetic", verified: true)
        }, modelClient: LocalModelClient(runtimeFactory: { _, _, _ in native += 1; throw CancellationError() }),
            openRouterClient: client, codexComplete: { _, _ in codex += 1; throw CancellationError() })
        await store.waitForConversationTaskToSettle(); store.configuration = try configuration(); await store.refreshModels()
        #expect(store.actionsReady && native == 0 && codex == 0)
        store.draft = "Compute six times seven with calculate."; _ = try #require(store.send()); await store.waitForConversationTaskToSettle()
        #expect(dispatches == 1 && store.phase == .idle && native == 0 && codex == 0)
        store.setOpenRouterUploadsApproved(false)
        #expect(!store.actionsReady && store.configuration.inferenceIdentity == nil)
        store.stop(); await store.waitForConversationTaskToSettle(); await client.drain()
    }
    @Test func syntheticVisionCheckBindsExactModelAndKeyVersionWithoutClaimingActualModelQuality() async throws {
        let peer = ProbePeer(), keys = Keys(), client = OpenRouterClient(transport: peer.transport, credentials: keys.custody)
        let selected = try #require(configuration().openRouter)
        let image = LMStudioVisionAttachment(jpeg: Data([1, 2, 3]), annotation: "Owned synthetic protocol bytes", validate: {})
        await #expect(throws: OpenRouterFailure.protocolFailure) {
            try await client.complete(messages: [.init(role: "user", content: "No probe yet")], tools: [], configuration: selected, vision: image)
        }
        try await client.verifyVision(configuration: selected, syntheticImage: image, expectedMarker: "OWNED7")
        let verified = await client.visionIsVerified(for: selected); #expect(verified)
        let first = await peer.requests; #expect(first.count == 1)
        #expect(!String(decoding: try #require(first.first?.httpBody), as: UTF8.self).contains("OWNED7"))
        _ = try await client.complete(messages: [.init(role: "user", content: "Owned private-image protocol")], tools: [], configuration: selected, vision: image)
        var changed = selected; changed.credentialRevision = UUID()
        await #expect(throws: OpenRouterFailure.protocolFailure) {
            try await client.complete(messages: [.init(role: "user", content: "Wrong version")], tools: [], configuration: changed, vision: image)
        }
        let requests = await peer.requests; #expect(requests.count == 2)
        try await client.replaceKey(Data("SYNTHETIC-REPLACEMENT-KEY-7348".utf8))
        let retained = await client.visionIsVerified(for: selected); #expect(!retained)
        await client.drain()
    }
    private actor ProbePeer {
        private(set) var requests: [URLRequest] = []
        nonisolated var transport: OpenRouterClient.Transport { .init(open: { [self] in try await open($0) }) }
        private func open(_ request: URLRequest) throws -> OpenRouterClient.Response {
            requests.append(request)
            let value = JSONValue.object(["choices": .array([.object(["index": .number(0), "finish_reason": .string("stop"),
                "message": .object(["role": .string("assistant"), "content": .string("OWNED7")])])])])
            let data = try LMStudioWireCodec.jsonData(value)
            return .init(url: request.url!, status: 200, contentType: "application/json",
                body: AsyncThrowingStream { $0.yield(data); $0.finish() }, cancel: {})
        }
    }
    @Test func streamingUsageFrameCannotAppendToolsOrTextAndImageWireUsesOnlyInlineBytes() throws {
        let base = "data: {\"id\":\"owned\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Café 🌍\"},\"finish_reason\":\"stop\"}]}\n\n"
        let usage = "data: {\"id\":\"owned\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"\",\"role\":\"assistant\"},\"finish_reason\":\"stop\"}],\"usage\":{\"total_tokens\":2}}\n\n"
        var decoder = LMStudioSSEDecoder(availableTools: [], acceptsTerminalUsage: true)
        for byte in Data((base + usage + "data: [DONE]\n\n").utf8) { try decoder.feed(Data([byte])) }
        #expect(try decoder.end().content == "Café 🌍")
        var legacy = LMStudioSSEDecoder(availableTools: [])
        try legacy.feed(Data(base.utf8))
        #expect(throws: LMStudioFailure.malformedResponse) { try legacy.feed(Data(usage.utf8)) }
        var forged = LMStudioSSEDecoder(availableTools: [], acceptsTerminalUsage: true)
        try forged.feed(Data(base.utf8))
        #expect(throws: LMStudioFailure.malformedResponse) { try forged.feed(Data(usage.replacingOccurrences(of: "\"content\":\"\"", with: "\"content\":\"forged\"").utf8)) }
        let bytes = try OpenRouterWireCodec.request(modelID: "owned/vision", messages: [.init(role: "user", content: "Owned image")], tools: [], image: Data([1, 2, 3]), imageAnnotation: "Synthetic bytes only")
        let decoded = try JSONSerialization.jsonObject(with: bytes)
        let body = try #require(decoded as? [String: Any])
        let messages = try #require(body["messages"] as? [[String: Any]])
        let imageMessage = try #require(messages.last)
        #expect(imageMessage["role"] as? String == "user")
        let parts = try #require(imageMessage["content"] as? [[String: Any]])
        #expect(parts.count == 2)
        let annotation = try #require(parts.first), imagePart = try #require(parts.last)
        #expect(annotation["type"] as? String == "text")
        #expect(annotation["text"] as? String == "Synthetic bytes only")
        #expect(imagePart["type"] as? String == "image_url")
        let inline = try #require(imagePart["image_url"] as? [String: String])
        #expect(inline == ["url": "data:image/jpeg;base64,AQID"])
        #expect(!String(decoding: bytes, as: UTF8.self).contains("Authorization"))
    }
}
