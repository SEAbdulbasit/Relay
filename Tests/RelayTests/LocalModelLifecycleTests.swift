import Foundation
import Testing
@preconcurrency import LiteRTLM
@testable import Relay

/// Scripted native-session boundary tests. No real model, app, microphone or network.
@MainActor
struct LocalModelLifecycleTests {
    private func fixture() throws -> (URL, ModelConfiguration) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-model-lifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = root.appendingPathComponent("synthetic.litertlm")
        try Data([1]).write(to: model)
        return (root, ModelConfiguration(modelPath: model.path))
    }
    private var tools: [ToolDefinition] { MacTools.definitions.filter { $0.name == "list_apps" } }
    private var messages: [ModelMessage] { [ModelMessage(role: "system", content: "Synthetic read-only scope"), ModelMessage(role: "user", content: "List installed apps.")] }
    private func action() -> LiteRTLM.Message {
        // Empty native IDs exercise the real runtime shape: the application repairs
        // identity and replays that validated pair in a fresh conversation.
        LiteRTLM.Message(contents: [], role: .model, toolCalls: [LiteRTLM.ToolCall(name: "list_apps", id: "", arguments: [:])])
    }

    private func settleSessions(_ runtime: LifecycleRuntime) async {
        // A cancelled timeout task can briefly hold its session until its executor
        // observes cancellation; require release after that bounded settling window.
        for _ in 0..<2_000 where runtime.sessions.contains(where: { $0.value != nil }) { await Task.yield() }
        #expect(runtime.sessions.allSatisfy { $0.value == nil })
    }

    @Test func toolContinuationColdReplaysValidatedIdentityAndReleasesBothSessions() async throws {
        let (root, configuration) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let runtime = LifecycleRuntime(replies: [action(), LiteRTLM.Message("Synthetic installed inventory.", role: .model)])
        var loads = 0
        let client = LocalModelClient(runtimeFactory: { _, _, _ in loads += 1; return runtime })
        let first = try await client.complete(messages: messages, tools: tools, configuration: configuration)
        let call = try #require(first.toolCalls.first)
        #expect(!call.id.isEmpty)
        await settleSessions(runtime)
        let next = messages + [ModelMessage(role: "assistant", content: first.content, toolCalls: first.toolCalls), ModelMessage(role: "tool", content: "{\"installed\":true}", toolCallID: call.id, toolName: call.name)]
        let final = try await client.complete(messages: next, tools: tools, configuration: configuration)
        #expect(final.content == "Synthetic installed inventory.")
        #expect(loads == 1)
        #expect(client.isLoaded)
        #expect(client.conversationMetrics.created == 2)
        #expect(runtime.records.map(\.initialMessages) == [0, 2])
        #expect(runtime.records[1].historicalCallIDs == [call.id])
        #expect(runtime.records[1].receivedToolIDs == [call.id])
        #expect(runtime.records.map(\.roles) == [[.user], [.tool]])
        await settleSessions(runtime)
    }

    @Test func invalidationRejectsUncooperativeLateNativeReply() async throws {
        let (root, configuration) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let runtime = LifecycleRuntime(replies: [action()])
        let latch = LifecycleLatch()
        runtime.beforeReply = { await latch.wait() }
        let client = LocalModelClient(runtimeFactory: { _, _, _ in runtime })
        let operation = Task { try await client.complete(messages: messages, tools: tools, configuration: configuration) }
        for _ in 0..<2_000 where !latch.waiting { await Task.yield() }
        #expect(latch.waiting)
        client.invalidateConversation()
        #expect(runtime.records.first?.cancelled.value == 1)
        latch.release()
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(client.isLoaded)
        await settleSessions(runtime)
    }

    @Test func taskCancellationCancelsNativeSessionAndRejectsItsLateReply() async throws {
        let (root, configuration) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let runtime = LifecycleRuntime(replies: [action()])
        let latch = LifecycleLatch()
        runtime.beforeReply = { await latch.wait() }
        let client = LocalModelClient(runtimeFactory: { _, _, _ in runtime })
        let operation = Task { try await client.complete(messages: messages, tools: tools, configuration: configuration) }
        for _ in 0..<2_000 where !latch.waiting { await Task.yield() }
        #expect(latch.waiting)
        operation.cancel()
        #expect(runtime.records.first?.cancelled.value == 1)
        latch.release()
        await #expect(throws: CancellationError.self) { try await operation.value }
        await settleSessions(runtime)
    }

    @Test func unloadWhilePendingCancelsNativeReplyAndReleasesLoadedRuntime() async throws {
        let (root, configuration) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let runtime = LifecycleRuntime(replies: [action()])
        let latch = LifecycleLatch()
        runtime.beforeReply = { await latch.wait() }
        let client = LocalModelClient(runtimeFactory: { _, _, _ in runtime })
        let operation = Task { try await client.complete(messages: messages, tools: tools, configuration: configuration) }
        for _ in 0..<2_000 where !latch.waiting { await Task.yield() }
        #expect(latch.waiting)
        client.unload()
        #expect(!client.isLoaded)
        #expect(runtime.records.first?.cancelled.value == 1)
        latch.release()
        await #expect(throws: CancellationError.self) { try await operation.value }
        await settleSessions(runtime)
    }

    @Test func concurrentCompletionIsRefusedWithoutCancelingTheFirst() async throws {
        let (root, configuration) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let runtime = LifecycleRuntime(replies: [action()])
        let latch = LifecycleLatch()
        runtime.beforeReply = { await latch.wait() }
        let client = LocalModelClient(runtimeFactory: { _, _, _ in runtime })
        let operation = Task { try await client.complete(messages: messages, tools: tools, configuration: configuration) }
        for _ in 0..<2_000 where !latch.waiting { await Task.yield() }
        #expect(latch.waiting)
        await #expect(throws: (any Error).self) { try await client.complete(messages: messages, tools: tools, configuration: configuration) }
        #expect(client.conversationMetrics.created == 1)
        #expect(runtime.records.first?.cancelled.value == 0)
        latch.release()
        _ = try await operation.value
        await settleSessions(runtime)
    }

    @Test(arguments: ["stop", "forget", "reset", "unload"])
    func storeLifecycleRejectsLateAction(event: String) async throws {
        let (root, configuration) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let runtime = LifecycleRuntime(replies: [action()])
        let latch = LifecycleLatch()
        runtime.beforeReply = { await latch.wait() }
        let client = LocalModelClient(runtimeFactory: { _, _, _ in runtime })
        var dispatches = 0
        let store = AssistantStore(persistenceURL: nil, execute: { _ in
            dispatches += 1
            return ToolResult(summary: "Unexpected test dispatch", evidence: "No real action", verified: true)
        }, modelClient: client)
        store.configuration = configuration
        store.actionsReady = true
        store.draft = "List installed apps; do not launch anything."
        store.send()
        for _ in 0..<2_000 where !latch.waiting { await Task.yield() }
        #expect(latch.waiting)
        switch event {
        case "stop": store.stop()
        case "forget": store.invalidateDerivedContext(reason: "Synthetic source/memory/calendar invalidation")
        case "reset": store.clearConversation()
        default: store.unloadModel()
        }
        #expect((runtime.records.first?.cancelled.value ?? 0) > 0)
        latch.release()
        for _ in 0..<2_000 where runtime.sessions.contains(where: { $0.value != nil }) || store.isRunning { await Task.yield() }
        #expect(!store.isRunning)
        #expect(dispatches == 0)
        await settleSessions(runtime)
    }

    @Test func settingsProbeReleasesItsSessionWhileKeepingModelReady() async throws {
        let (root, configuration) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let probe = LiteRTLM.Message(contents: [], role: .model, toolCalls: [LiteRTLM.ToolCall(name: "capability_probe", id: "", arguments: ["marker": "relay-ready"])])
        let runtime = LifecycleRuntime(replies: [probe])
        let client = LocalModelClient(runtimeFactory: { _, _, _ in runtime })
        let store = AssistantStore(persistenceURL: nil, modelClient: client)
        store.configuration = configuration
        await store.refreshModels()
        #expect(store.actionsReady)
        #expect(!store.isPreparingModel)
        #expect(!store.isRunning)
        #expect(client.isLoaded)
        #expect(client.conversationMetrics.created == 1)
        await settleSessions(runtime)
    }

    @Test(arguments: ["load", "probe"])
    func duplicatePreparationKeepsStatusAndStopPreventsLateReadiness(stage: String) async throws {
        let (root, configuration) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let probe = LiteRTLM.Message(contents: [], role: .model, toolCalls: [LiteRTLM.ToolCall(name: "capability_probe", id: "", arguments: ["marker": "relay-ready"])])
        let runtime = LifecycleRuntime(replies: [probe])
        let latch = LifecycleLatch()
        if stage == "probe" { runtime.beforeReply = { await latch.wait() } }
        var loads = 0
        let client = LocalModelClient(runtimeFactory: { _, _, _ in
            loads += 1
            if stage == "load" { await latch.wait() }
            return runtime
        })
        let store = AssistantStore(persistenceURL: nil, modelClient: client)
        store.configuration = configuration
        let preparation = Task { await store.refreshModels() }
        for _ in 0..<2_000 where !latch.waiting { await Task.yield() }
        try #require(latch.waiting)
        #expect(store.isPreparingModel)
        #expect(store.isRunning)
        let status = store.modelStatus
        let error = store.errorMessage
        await store.refreshModels()
        #expect(store.modelStatus == status)
        #expect(store.errorMessage == error)
        #expect(loads == 1)
        store.draft = "Keep this draft while preparing."
        store.send()
        #expect(store.draft == "Keep this draft while preparing.")
        #expect(store.messages.isEmpty)
        store.stop()
        #expect(!store.actionsReady)
        latch.release()
        await preparation.value
        #expect(!store.isPreparingModel)
        #expect(!store.isRunning)
        #expect(!store.actionsReady)
        #expect(store.errorMessage == nil)
        #expect(store.modelStatus == "Model preparation stopped")
        if stage == "load" { #expect(runtime.records.isEmpty) }
        else { #expect(runtime.records.count == 1) }
        await settleSessions(runtime)
    }

    @Test(arguments: ["load", "probe"])
    func changedSelectionDuringPreparationCannotBecomeReady(stage: String) async throws {
        let (root, configuration) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let probe = LiteRTLM.Message(contents: [], role: .model, toolCalls: [LiteRTLM.ToolCall(name: "capability_probe", id: "", arguments: ["marker": "relay-ready"])])
        let runtime = LifecycleRuntime(replies: [probe])
        let latch = LifecycleLatch()
        if stage == "probe" { runtime.beforeReply = { await latch.wait() } }
        let client = LocalModelClient(runtimeFactory: { _, _, _ in
            if stage == "load" { await latch.wait() }
            return runtime
        })
        let store = AssistantStore(persistenceURL: nil, modelClient: client)
        store.configuration = configuration
        let preparation = Task { await store.refreshModels() }
        for _ in 0..<2_000 where !latch.waiting { await Task.yield() }
        try #require(latch.waiting)
        // Bypass the disabled UI intentionally: post-await validation must also
        // protect against programmatic configuration changes, not just button state.
        store.configuration.computeBackend = "gpu"
        store.configuration.modelPath += ".changed"
        latch.release()
        await preparation.value
        #expect(!store.isPreparingModel)
        #expect(!store.actionsReady)
        #expect(store.modelStatus == "Model selection changed — load to check it")
        if stage == "load" { #expect(runtime.records.isEmpty) }
        else { #expect(runtime.records.count == 1) }
        await settleSessions(runtime)
    }
}

@MainActor private final class LifecycleRuntime: LocalModelRuntime {
    var replies: [LiteRTLM.Message]
    var records: [LifecycleRecord] = []
    var sessions: [LifecycleWeakSession] = []
    var beforeReply: (() async -> Void)?
    init(replies: [LiteRTLM.Message]) { self.replies = replies }
    func createConversation(config: LiteRTLM.ConversationConfig) async throws -> any LocalConversationSession {
        let record = LifecycleRecord()
        record.initialMessages = config.initialMessages.count
        record.historicalCallIDs = config.initialMessages.flatMap { $0.toolCalls.map(\.id) }
        let session = LifecycleSession(runtime: self, record: record)
        records.append(record)
        sessions.append(LifecycleWeakSession(session))
        return session
    }
}

@MainActor private final class LifecycleSession: LocalConversationSession {
    unowned let runtime: LifecycleRuntime
    let record: LifecycleRecord
    nonisolated let cancelled: LifecycleCancellationCount
    init(runtime: LifecycleRuntime, record: LifecycleRecord) { self.runtime = runtime; self.record = record; self.cancelled = record.cancelled }
    func send(_ message: LiteRTLM.Message) async throws -> LiteRTLM.Message {
        record.roles.append(message.role)
        for content in message.contents {
            if case .toolResponse(_, _, let id) = content { record.receivedToolIDs.append(id) }
        }
        await runtime.beforeReply?()
        guard !runtime.replies.isEmpty else { throw RelayError.message("Synthetic reply queue exhausted") }
        return runtime.replies.removeFirst()
    }
    nonisolated func cancel() { cancelled.increment() }
}

@MainActor private final class LifecycleRecord {
    var initialMessages = 0
    var historicalCallIDs: [String] = []
    var receivedToolIDs: [String] = []
    var roles: [LiteRTLM.Role] = []
    let cancelled = LifecycleCancellationCount()
}

@MainActor private final class LifecycleWeakSession {
    weak var value: LifecycleSession?
    init(_ session: LifecycleSession) { value = session }
}

nonisolated private final class LifecycleCancellationCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

@MainActor private final class LifecycleLatch {
    var waiting = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { waiting = true; continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
