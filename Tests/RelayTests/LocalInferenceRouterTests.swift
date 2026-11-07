import Foundation
import Testing
@testable import Relay

@MainActor struct LocalInferenceRouterTests {
    private var messages: [ModelMessage] { [.init(role: "user", content: "Synthetic routing request")] }
    private func serverConfiguration(port: Int = 1234) throws -> ModelConfiguration {
        ModelConfiguration(backend: .lmStudio, modelPath: "/SYNTHETIC/dormant.litertlm",
            lmStudio: try .init(endpoint: LMStudioEndpoint(port: port), modelID: "synthetic-server-model"))
    }
    @Test func defaultEmbeddedRouteKeepsTheInjectedClientAndNeverContactsServer() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "relay-router-native-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "synthetic.litertlm"); try Data([1]).write(to: file)
        let runtime = LMStudioRouterRuntime(), fixture = LMStudioIntegrationFixture()
        var loads = 0
        let embedded = LocalModelClient(runtimeFactory: { _, _, _ in loads += 1; return runtime })
        let router = LocalInferenceRouter(embedded: embedded, server: LMStudioClient(transport: fixture.transport))
        let reply = try await router.complete(messages: messages, tools: [], configuration: .init(modelPath: file.path))
        #expect(reply.content == "Synthetic native answer." && loads == 1 && runtime.conversations == 1)
        let requests = await fixture.requests
        #expect(embedded.isLoaded && router.isLoaded && requests.isEmpty)
    }
    @Test func serverRouteDoesNotOpenDormantNativePathOrLoadItsRuntime() async throws {
        let fixture = LMStudioIntegrationFixture()
        var loads = 0
        let router = LocalInferenceRouter(embedded: LocalModelClient(runtimeFactory: { _, _, _ in
            loads += 1; throw CancellationError()
        }), server: LMStudioClient(transport: fixture.transport))
        let configuration = try serverConfiguration()
        let reply = try await router.complete(messages: messages, tools: [], configuration: configuration)
        #expect(reply.content == "Synthetic endpoint answer." && loads == 0 && !router.isLoaded)
        #expect(await fixture.requests.count == 1)
        let wire = try JSONDecoder().decode(JSONValue.self, from: #require(await fixture.requests.first?.httpBody))
        #expect(wire.object?["model"] == .string("synthetic-server-model"))
    }
    @Test func forkSharesLeaseAndStopRejectsLateReplyUntilUncooperativePeerDrains() async throws {
        let fixture = LMStudioIntegrationFixture(); await fixture.hold()
        let router = LocalInferenceRouter(server: LMStudioClient(transport: fixture.transport)), draft = router.fork()
        let configuration = try serverConfiguration()
        let pending = Task { try await router.complete(messages: messages, tools: [], configuration: configuration) }
        try await awaitLMStudioCondition { await fixture.requests.count == 1 }
        router.invalidateConversation()
        await #expect(throws: LocalInferenceFailure.busy) { try await draft.complete(messages: messages, tools: [], configuration: configuration) }
        #expect(await fixture.requests.count == 1)
        await fixture.release()
        await #expect(throws: CancellationError.self) { try await pending.value }
        await router.drain()
        _ = try await draft.complete(messages: messages, tools: [], configuration: configuration)
        #expect(await fixture.requests.count == 2)
    }
    @Test func switchingEndpointRejectsItsOldFailureAndNextRequestUsesOnlyTheNewEndpoint() async throws {
        let fixture = LMStudioIntegrationFixture(); await fixture.hold()
        let router = LocalInferenceRouter(server: LMStudioClient(transport: fixture.transport))
        let original = try serverConfiguration(), replacement = try serverConfiguration(port: 2345)
        let pending = Task { try await router.complete(messages: messages, tools: [], configuration: original) }
        try await awaitLMStudioCondition { await fixture.requests.count == 1 }
        router.selectionDidChange(replacement)
        await fixture.failNextReply(); await fixture.release()
        await #expect(throws: CancellationError.self) { try await pending.value }
        await router.drain()
        _ = try await router.complete(messages: messages, tools: [], configuration: replacement)
        #expect(await fixture.requests.last?.url == replacement.lmStudio?.endpoint.completionsURL)
    }
    @Test func unqualifiedImageModelNeverGetsPrivateImageOrNativeFallback() async throws {
        let fixture = LMStudioIntegrationFixture(), router = LocalInferenceRouter(server: LMStudioClient(transport: fixture.transport))
        let owner = ValidationOwner()
        await #expect(throws: LMStudioFailure.visionProbeFailed) {
            try await router.inspect(.init(jpeg: Data([1]), label: "synthetic"), question: "Read synthetic image",
                configuration: serverConfiguration(), sourceIsCurrent: { owner.validations += 1; return true })
        }
        let requests = await fixture.requests
        #expect(owner.validations > 0 && requests.count == 1 && !router.isLoaded)
        #expect(!String(decoding: requests[0].httpBody ?? Data(), as: UTF8.self).contains("data:image/jpeg;base64,AQ=="))
    }
    @MainActor private final class ValidationOwner { var validations = 0 }
}
