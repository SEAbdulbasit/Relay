import AppKit
import Foundation
import Testing
@testable import Relay

@MainActor struct LMStudioStoreIntegrationTests {
    private func configuration(port: Int = 1234, model: String = "synthetic-server-model") throws -> ModelConfiguration {
        ModelConfiguration(backend: .lmStudio, lmStudio: try .init(endpoint: LMStudioEndpoint(port: port), modelID: model))
    }
    @Test func changingProviderClearsThePreviousServicesErrorWithoutLoadingAFallback() async throws {
        let fixture = LMStudioIntegrationFixture()
        await fixture.failNextReply()
        var nativeLoads = 0
        let store = AssistantStore(persistenceURL: nil,
            modelClient: LocalModelClient(runtimeFactory: { _, _, _ in nativeLoads += 1; throw CancellationError() }),
            lmStudioClient: LMStudioClient(transport: fixture.transport))
        store.configuration = try configuration()
        await store.discoverLMStudioModels()
        #expect(store.errorMessage != nil && !store.actionsReady)
        store.selectLocalProvider(.liteRTLM)
        #expect(store.configuration.backend == .liteRTLM && store.errorMessage == nil)
        #expect(!store.actionsReady && nativeLoads == 0)
    }
    @Test func readinessAndRealStoreToolLoopUseExactServerCallResultPairsWithoutNativeFallback() async throws {
        let fixture = LMStudioIntegrationFixture(); await fixture.setMode(.calculate)
        var nativeLoads = 0, dispatches = 0
        let store = AssistantStore(persistenceURL: nil, execute: { call in
            dispatches += 1
            #expect(call.name == "calculate" && call.arguments == ["expression": .string("6*7")])
            return ToolResult(summary: "42", evidence: "Synthetic arithmetic only", verified: true)
        }, modelClient: LocalModelClient(runtimeFactory: { _, _, _ in nativeLoads += 1; throw CancellationError() }),
           lmStudioClient: LMStudioClient(transport: fixture.transport))
        store.configuration = try configuration()
        #expect(!store.actionsReady)
        await store.refreshModels()
        #expect(store.actionsReady && nativeLoads == 0)
        store.draft = "Use the synthetic workflow to compute six times seven and return the result."
        store.send()
        try await awaitLMStudioCondition { !store.isRunning }
        #expect(store.phase == .idle && store.errorMessage == nil)
        #expect(store.messages.last?.text == "42\n\nChecked by Relay:\n• 42 — Synthetic arithmetic only")
        #expect(dispatches == 1 && nativeLoads == 0)
        let requests = await fixture.requests
        let final = try JSONDecoder().decode(JSONValue.self, from: #require(requests.last?.httpBody))
        guard case .array(let messages) = final.object?["messages"] else { Issue.record("Missing final paired history"); return }
        let results = messages.filter { $0.object?["role"] == .string("tool") }
        let resultID = try #require(results.first?.object?["tool_call_id"]?.string)
        let assistantCalls = messages.flatMap { value -> [JSONValue] in
            if case .array(let calls) = value.object?["tool_calls"] { return calls }; return []
        }
        #expect(results.count == 1 && assistantCalls.contains { $0.object?["id"] == .string(resultID) })
    }
    @Test func nativeSummaryUsesSelectedEndpointAndPreservesDraftWithoutHostedGeneration() async throws {
        let fixture = LMStudioIntegrationFixture()
        var hosted = 0
        let store = AssistantStore(persistenceURL: nil, lmStudioClient: LMStudioClient(transport: fixture.transport), codexComplete: { _, _ in
            hosted += 1; throw CancellationError()
        })
        store.configuration = try configuration(); await store.refreshModels()
        store.draft = "Preserve this unrelated draft."
        store.summaries.prepareNativeCapture = { _, active in
            .init(kind: .nativeDocument, isSourceAuthorized: active, capture: {
                try DocumentSummarySource(kind: .nativeDocument, title: "Synthetic original", application: "Synthetic editor",
                    text: "SYNTHETIC source: the review is Monday at 10:00.", coverage: "Only this inert invocation source.")
            })
        }
        let summary = try store.startCurrentDocumentSummary(application: .current, presentPanel: false)
        try await awaitLMStudioCondition { !store.summaries.isBusy }
        #expect(summary.phase == .ready && summary.resultText == "Synthetic endpoint answer.")
        #expect(store.draft == "Preserve this unrelated draft." && store.messages.isEmpty && hosted == 0)
        let request = try #require(await fixture.requests.last?.httpBody)
        let payload = try JSONDecoder().decode(JSONValue.self, from: request)
        #expect(payload.object?["tools"] == nil && String(decoding: request, as: UTF8.self).contains("SYNTHETIC source"))
        store.stop(); #expect(summary.source == nil && summary.resultText.isEmpty)
    }
    @Test func providerSwitchAndRestartPreserveNativeChoiceWithoutAutoSelectingIt() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "relay-provider-state-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let state = folder.appending(path: "state.json")
        let store = AssistantStore(persistenceURL: state)
        store.configuration = .init(modelPath: "/SYNTHETIC/original.litertlm", computeBackend: "gpu", model: "Original")
        store.selectLocalProvider(.lmStudio)
        #expect(store.configuration.backend == .lmStudio && store.configuration.modelPath == "/SYNTHETIC/original.litertlm")
        #expect(!store.actionsReady && !store.configuration.hasConfiguredInferenceModel)
        let restored = AssistantStore(persistenceURL: state)
        #expect(restored.configuration.backend == .lmStudio && restored.configuration.computeBackend == "gpu")
        restored.selectLocalProvider(.liteRTLM)
        #expect(restored.configuration.modelPath == "/SYNTHETIC/original.litertlm" && !restored.actionsReady)
    }
    @Test func independentDraftUsesItsOwnEndpointAndLeavesChatConfigurationUntouched() async throws {
        let fixture = LMStudioIntegrationFixture(), store = AssistantStore(persistenceURL: nil,
            lmStudioClient: LMStudioClient(transport: fixture.transport))
        let main = store.configuration
        let separate = try configuration(port: 2345, model: "synthetic-independent-draft")
        store.draftModel.selectLMStudio(separate)
        #expect(store.focusedDraft.availability() == nil)
        let answer = try await store.focusedDraft.generate([.init(role: "user", content: "Synthetic draft context")])
        #expect(answer.content == "Synthetic endpoint answer." && store.configuration == main)
        #expect(await fixture.requests.last?.url == separate.lmStudio?.endpoint.completionsURL)
        let sent = try JSONDecoder().decode(JSONValue.self, from: #require(await fixture.requests.last?.httpBody))
        #expect(sent.object?["model"] == .string("synthetic-independent-draft") && sent.object?["tools"] == nil)
    }
    @Test func portChangeDuringAuxiliaryInferenceRejectsLateReplyAndClearsReadiness() async throws {
        let fixture = LMStudioIntegrationFixture(), store = AssistantStore(persistenceURL: nil,
            lmStudioClient: LMStudioClient(transport: fixture.transport))
        store.configuration = try configuration(); await store.refreshModels(); await fixture.hold()
        let pending = Task { try await store.auxiliaryText([.init(role: "user", content: "SYNTHETIC private text")]) }
        try await awaitLMStudioCondition { await fixture.requests.count == 3 }
        #expect(store.setLMStudioPort("2345"))
        #expect(!store.actionsReady && store.configuration.lmStudio?.modelID.isEmpty == true)
        await fixture.release()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(await fixture.requests.count == 3)
    }
    @Test func unknownOrNullProviderPreservesTheActualSavedHistoryFile() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "relay-provider-recovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appending(path: "state.json")
        let original = AssistantStore(persistenceURL: path)
        original.messages = [.init(role: "user", text: "SYNTHETIC preserved history")]
        original.saveConfiguration()
        let saved = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: path))
        for invalid in [JSONValue.string("future-provider"), .null] {
            var state = try #require(saved.object)
            var configuration = try #require(state["configuration"]?.object)
            configuration["backend"] = invalid; state["configuration"] = .object(configuration)
            let bytes = try JSONEncoder().encode(JSONValue.object(state))
            try bytes.write(to: path)
            let restored = AssistantStore(persistenceURL: path)
            #expect(restored.errorMessage?.contains("Saved history could not be read safely") == true)
            restored.saveConfiguration()
            #expect(try Data(contentsOf: path) == bytes)
        }
    }
}
