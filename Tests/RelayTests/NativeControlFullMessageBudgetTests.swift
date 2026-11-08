import Foundation
import Testing
@preconcurrency import LiteRTLM
@testable import Relay

/// Actual planning phase -> selected router -> LocalModelClient byte admission
/// and SDK schemas. Only the weightless runtime/session are synthetic; no model,
/// HTTP, provider, AX query, app or input is used.
@Suite @MainActor struct NativeControlFullMessageBudgetTests {
    private enum Failure: Error { case unexpectedTextRuntime }

    @Test(arguments: [false, true])
    func actualPhaseRouterAndSerializedSDKCatalogFitRepresentativeFullMessages(_ composite: Bool) async throws {
        let rig = NextNativeControlRig()
        let observation = try await (composite ? rig.plan() : rig.read())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-full-vision-budget-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = root.appendingPathComponent("synthetic.litertlm"); try Data([1]).write(to: model)
        let configuration = ModelConfiguration(modelPath: model.path)
        let runtime = Runtime(), endpoint = LMStudioIntegrationFixture()
        var loads = 0, phaseCalls = 0
        let embedded = LocalModelClient(runtimeFactory: { _, _, _ in throw Failure.unexpectedTextRuntime },
            visionRuntimeFactory: { _, _, _ in loads += 1; return runtime })
        let router = LocalInferenceRouter(embedded: embedded, server: LMStudioClient(transport: endpoint.transport))
        let objective = "In the original editor, prepare one ordinary unsent editing step while preserving unrelated text."
        let step = "Inspect this exact window and report if no ordinary change is needed."
        let operation = try await NativeWindowControlPlanningPhase.plan(taskID: UUID(), runRevision: 1,
            originalObjective: objective, requestedStep: step, observation: observation, session: rig.session,
            taskIsCurrent: { true }, complete: { messages, tools, vision in
                phaseCalls += 1
                #expect(tools.count == (composite ? 4 : 2))
                let payload = try JSONDecoder().decode(JSONValue.self, from: Data(try #require(messages.last?.content).utf8))
                #expect(payload.object?["original_user_task"]?.string?.utf8.elementsEqual(objective.utf8) == true)
                #expect(payload.object?["requested_step_within_task"]?.string == step)
                let context = try LocalModelClient.prepareContext(messages: messages, tools: tools)
                let schemas = LiteRTLM.ToolManager(tools: try LiteRTLM.RelayNativeTools.makeTools(named: tools.map(\.name))).toolsJsonDescription
                let historyBytes = try JSONEncoder().encode(context.messages).count
                let advertisedBytes = try JSONEncoder().encode(tools).count
                let total = context.systemPrompt.utf8.count + historyBytes
                    + max(advertisedBytes, schemas.utf8.count) + vision.frame.annotation.utf8.count
                print("Synthetic full phase budget: composite=\(composite), system=\(context.systemPrompt.utf8.count), history=\(historyBytes), advertised=\(advertisedBytes), sdk=\(schemas.utf8.count), annotation=\(vision.frame.annotation.utf8.count), total=\(total), ceiling=\(NativeVisionPlanningBudget.maximumTextBytes).")
                #expect(total <= NativeVisionPlanningBudget.maximumTextBytes)
                runtime.expectedSystem = context.systemPrompt
                runtime.answer = LiteRTLM.Message(contents: [], role: .model, toolCalls: [LiteRTLM.ToolCall(
                    name: NativeWindowControlTools.observeName, id: "exact-full-budget-provider-id", arguments: [
                        "observation_id": vision.frame.observationID.uuidString, "image_id": vision.frame.id.uuidString,
                        "disposition": "cannot_determine", "detail": "Synthetic unverified original-window report."] )])
                return try await router.complete(messages: messages, tools: tools, configuration: configuration, vision: vision)
            })
        #expect(phaseCalls == 1 && loads == 1 && runtime.conversations == 1 && runtime.sent == 1)
        #expect(runtime.systemMatched && runtime.images == [operation.frame.jpeg])
        #expect(runtime.actualTools == (composite ? 4 : 2) && !runtime.automaticToolCalling)
        #expect(operation.call.id == "exact-full-budget-provider-id")
        guard case .report(let report) = operation.proposal else { Issue.record("Expected unverified report data."); return }
        #expect(!report.genericFact.verified && rig.commands.isEmpty && rig.textWrites == 0)
        #expect(await endpoint.requests.isEmpty)
        router.unload(); await router.drain(); rig.session.stop(); await rig.session.drain()
    }

    @Test func overBudgetActualPhaseFailsThroughRouterBeforeWeightsOrAnyEndpoint() async throws {
        let rig = NextNativeControlRig(), observation = try await rig.plan()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-full-budget-refusal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = root.appendingPathComponent("synthetic.litertlm"); try Data([1]).write(to: model)
        let runtime = Runtime(), endpoint = LMStudioIntegrationFixture(); var loads = 0, phaseCalls = 0
        let router = LocalInferenceRouter(embedded: LocalModelClient(runtimeFactory: { _, _, _ in throw Failure.unexpectedTextRuntime },
            visionRuntimeFactory: { _, _, _ in loads += 1; return runtime }), server: LMStudioClient(transport: endpoint.transport))
        await #expect(throws: NativeVisionFailure.textBudget) {
            try await NativeWindowControlPlanningPhase.plan(taskID: UUID(), runRevision: 1,
                originalObjective: "Preserve this exact synthetic objective: " + String(repeating: "x", count: 6_000),
                requestedStep: "Inspect the original window without input.", observation: observation, session: rig.session,
                taskIsCurrent: { true }, complete: { messages, tools, vision in
                    phaseCalls += 1
                    return try await router.complete(messages: messages, tools: tools,
                        configuration: .init(modelPath: model.path), vision: vision)
                })
        }
        #expect(phaseCalls == 1 && loads == 0 && runtime.conversations == 0 && runtime.sent == 0)
        #expect(await endpoint.requests.isEmpty)
        #expect(rig.commands.isEmpty && rig.textWrites == 0)
        router.unload(); await router.drain(); rig.session.stop(); await rig.session.drain()
    }

    @MainActor private final class Runtime: LocalModelRuntime {
        var answer = LiteRTLM.Message("Synthetic", role: .model)
        var expectedSystem = "", systemMatched = false
        var actualTools = 0, conversations = 0, sent = 0
        var automaticToolCalling = true
        var images: [Data] = []
        func createConversation(config: LiteRTLM.ConversationConfig) async throws -> any LocalConversationSession {
            conversations += 1; actualTools = config.tools.count; automaticToolCalling = config.automaticToolCalling
            systemMatched = config.systemMessage?.toString == expectedSystem
            return Session(runtime: self)
        }
    }
    @MainActor private final class Session: LocalConversationSession {
        unowned let runtime: Runtime
        init(runtime: Runtime) { self.runtime = runtime }
        func send(_ message: LiteRTLM.Message) async throws -> LiteRTLM.Message {
            runtime.sent += 1
            for content in message.contents { if case .imageData(let data) = content { runtime.images.append(data) } }
            return runtime.answer
        }
        nonisolated func cancel() {}
    }
}
