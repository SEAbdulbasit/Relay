import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
@preconcurrency import LiteRTLM
@testable import Relay

/// Requires the ignored Store/SDK patch. These tests have not run yet. All
/// native state is inert, while Store scheduling and scoped file IO are real.
@Suite(.serialized)
@MainActor
struct NativeWindowReadStoreIntegrationTests {
    @Test func ordinaryComposerReturnsFromVisualReadToOneScopedFileWriteWithCompleteToolPairs() async throws {
        let fixture = NativeReadTaskFixture()
        let runtime = NativeReadTaskRuntime()
        let client = LocalModelClient(runtimeFactory: { _, _, _ in runtime }, visionRuntimeFactory: { _, _, _ in runtime })
        let folder = try fixture.folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let model = folder.appending(path: "synthetic.litertlm"), output = folder.appending(path: "read-result.txt")
        try Data([1]).write(to: model)
        var turns = 0, observedProtocol: [ModelMessage] = []
        let store = AssistantStore(persistenceURL: nil, complete: { messages, definitions, _ in
            turns += 1
            #expect(definitions.contains { $0.name == NativeWindowReadTool.name })
            observedProtocol = messages
            switch turns {
            case 1: return .init(content: "", toolCalls: [fixture.readCall(id: "native-read")])
            case 2:
                let content = try #require(messages.last(where: { $0.role == "tool" && $0.toolName == NativeWindowReadTool.name })?.content)
                let result = try JSONDecoder().decode(ToolResult.self, from: Data(content.utf8))
                #expect(result.summary.contains(runtime.answer))
                #expect(result.evidence.contains("not the interpretation's facts"))
                return .init(content: "", toolCalls: [.init(id: "write-result", name: "write_file",
                    arguments: ["path": .string(output.path), "content": .string(runtime.answer)])])
            default: return .init(content: "The captured read was saved to the requested file.", toolCalls: [])
            }
        }, modelClient: client, nativeWindowBackendFactory: { _ in fixture.backend() })
        store.configuration = .init(modelPath: model.path)
        store.grants = [.init(path: folder.path, writable: true)]
        store.draft = "Read the chosen synthetic native window, then save its answer to \(output.path)."
        // A trusted original invocation narrows this otherwise ordinary local
        // task. No Sidekick context/checkbox or production fixture ID is used.
        store.send(nativeReadRestrictions: [fixture.admission])
        try await settled(store, fixture: fixture)
        #expect(store.errorMessage == nil && store.phase == .idle)
        #expect(turns == 4, "The existing bounded completion audit must not replay the file write.")
        #expect(try Data(contentsOf: output) == Data(runtime.answer.utf8))
        #expect(store.activity.filter { $0.name == "write_file" && $0.status == "verified" }.count == 1)
        #expect(fixture.factoryCalls == 1 && fixture.captures == 1 && fixture.closes == 1)
        #expect(runtime.imagePayloads.count == 1 && runtime.toolCounts == [0])
        let request = try #require(observedProtocol.first { $0.role == "assistant" && $0.toolCalls.contains(where: { $0.id == "native-read" }) })
        #expect(request.toolCalls.count == 1)
        #expect(observedProtocol.filter { $0.role == "tool" && $0.toolCallID == "native-read" }.count == 1)
        let bytes = try #require(runtime.imagePayloads.first)
        let serialized = String(decoding: try JSONEncoder().encode(observedProtocol), as: UTF8.self)
        #expect(!serialized.contains(bytes.base64EncodedString()))
        #expect(!store.activity.contains { $0.detail.contains(bytes.base64EncodedString()) })
        client.unload()
    }

    @Test func multiAgentReadersShareOneTaskResourceAndReturnToOrdinarySynthesis() async throws {
        let fixture = NativeReadTaskFixture(), runtime = NativeReadTaskRuntime()
        let client = LocalModelClient(runtimeFactory: { _, _, _ in runtime }, visionRuntimeFactory: { _, _, _ in runtime })
        let folder = try fixture.folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let model = folder.appending(path: "synthetic.litertlm"); try Data([1]).write(to: model)
        var turns = 0
        let store = AssistantStore(persistenceURL: nil, complete: { _, definitions, _ in
            turns += 1
            switch turns {
            case 1:
                #expect(definitions.isEmpty)
                return .init(content: #"{"taskType":"automation","steps":[{"id":"r1","role":"Navigator","title":"Read the chosen native window"},{"id":"r2","role":"Critic","title":"Inspect the chosen native window again"}]}"#, toolCalls: [])
            case 2, 3:
                #expect(definitions.contains { $0.name == NativeWindowReadTool.name })
                return .init(content: "", toolCalls: [fixture.readCall(id: "role-read-\(turns)")])
            default: return .init(content: "Synthetic native window reading finished.", toolCalls: [])
            }
        }, modelClient: client, multiAgent: true, nativeWindowBackendFactory: { _ in fixture.backend() })
        store.configuration = .init(modelPath: model.path)
        store.draft = "Read the chosen native window twice without changing it."
        store.send(nativeReadRestrictions: [fixture.admission])
        try await settled(store, fixture: fixture)
        #expect(store.errorMessage == nil && store.phase == .idle && turns == 4)
        #expect(fixture.factoryCalls == 1 && fixture.captures == 2 && fixture.closes == 1)
        #expect(runtime.imagePayloads.count == 2 && runtime.toolCounts == [0, 0])
        #expect(store.activity.filter { $0.name == NativeWindowReadTool.name && $0.status == "verified" }.count == 2)
        client.unload()
    }

    @Test func stoppingActualRegisteredVisualReadDrainsBeforeReplacementAndSuppressesLateAnswer() async throws {
        let fixture = NativeReadTaskFixture(), runtime = NativeReadTaskRuntime()
        runtime.answer = "LATE_PRIVATE_NATIVE_ANSWER"
        var waiting: CheckedContinuation<Void, Never>?
        runtime.pauseBeforeReply = { await withCheckedContinuation { waiting = $0 } }
        let client = LocalModelClient(runtimeFactory: { _, _, _ in runtime }, visionRuntimeFactory: { _, _, _ in runtime })
        let folder = try fixture.folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let model = folder.appending(path: "synthetic.litertlm"); try Data([1]).write(to: model)
        var turns = 0
        let store = AssistantStore(persistenceURL: nil, complete: { _, _, _ in
            turns += 1
            return turns == 1 ? .init(content: "", toolCalls: [fixture.readCall(id: "stopped-read")])
                : .init(content: "Next task answered without a device action.", toolCalls: [])
        }, modelClient: client, nativeWindowBackendFactory: { _ in fixture.backend() })
        store.configuration = .init(modelPath: model.path)
        store.draft = "Read the chosen window."
        store.send(nativeReadRestrictions: [fixture.admission])
        for _ in 0..<10_000 where waiting == nil { await Task.yield() }
        try #require(waiting != nil)
        store.stop()
        waiting?.resume(); waiting = nil
        store.draft = "Answer the next task without reading a window."
        store.send()
        try await settled(store, fixture: fixture)
        #expect(turns == 2 && store.phase == .idle)
        #expect(runtime.cancellations.count > 0)
        #expect(!store.messages.contains { $0.text.contains(runtime.answer) })
        #expect(!store.activity.contains { $0.detail.contains(runtime.answer) })
        #expect(fixture.factoryCalls == 1 && fixture.captures == 1)
        client.unload()
    }

    @Test func changingOnlyEndpointAndModelIdentityRejectsALateNativeVisualCompletion() async throws {
        let fixture = NativeReadTaskFixture(), runtime = NativeReadTaskRuntime()
        runtime.answer = "PRIVATE_REPLY_FROM_OLD_CONFIGURATION"
        let client = LocalModelClient(runtimeFactory: { _, _, _ in runtime }, visionRuntimeFactory: { _, _, _ in runtime })
        let folder = try fixture.folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let model = folder.appending(path: "synthetic.litertlm"); try Data([1]).write(to: model)
        var turns = 0
        let store = AssistantStore(persistenceURL: nil, complete: { _, _, _ in
            turns += 1
            return .init(content: "", toolCalls: [fixture.readCall(id: "configuration-read")])
        }, modelClient: client, nativeWindowBackendFactory: { _ in fixture.backend() })
        store.configuration = .init(modelPath: model.path)
        let original = store.configuration
        let replacement = ModelConfiguration(backend: .lmStudio, modelPath: original.modelPath,
            computeBackend: original.computeBackend,
            lmStudio: try .init(endpoint: .init(host: .ipv4, port: 1235), modelID: "model-b"))
        runtime.beforeReply = { [weak store] in
            store?.configuration = replacement
        }
        store.draft = "Read the chosen window only."
        store.send(nativeReadRestrictions: [fixture.admission])
        try await settled(store, fixture: fixture)
        #expect(store.configuration.modelPath == original.modelPath)
        #expect(store.configuration.computeBackend == original.computeBackend)
        #expect(store.configuration.inferenceIdentity != original.inferenceIdentity)
        #expect(turns == 1 && store.phase == .stopped)
        #expect(!store.activity.contains { $0.detail.contains(runtime.answer) })
        #expect(!store.messages.contains { $0.text.contains(runtime.answer) })
        client.unload()
    }

    private func settled(_ store: AssistantStore, fixture: NativeReadTaskFixture) async throws {
        for _ in 0..<10_000 where store.isRunning || fixture.closes == 0 { await Task.yield() }
        try #require(!store.isRunning && fixture.closes == 1)
    }
}

@MainActor private final class NativeReadTaskFixture {
    let application = DesktopApplicationIdentity(processID: 4646, launchedAt: Date(timeIntervalSince1970: 1000),
        bundleID: "test.native.read.task", bundleURL: URL(fileURLWithPath: "/Applications/Native Read Task.app"))
    var captures = 0, closes = 0, factoryCalls = 0
    var admission: NativeWindowTaskAdapter.ApplicationAdmission { .init(application: application, validate: {}) }

    func folder() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appending(path: "native-read-task-" + UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: false)
        return value
    }

    func readCall(id: String) -> Relay.ToolCall {
        .init(id: id, name: NativeWindowReadTool.name,
            arguments: ["bundle_id": .string(application.bundleID), "question": .string("What does the chosen synthetic window show?")])
    }

    func backend() -> NativeWindowTaskAdapter.Backend {
        factoryCalls += 1
        let observer = TargetBoundNativeObservation(backend: .init(capture: { [self] _, _ in
            captures += 1
            let text = """
                Computer Use state (CUA App Version: 1001824)
                <app_state>
                App=/Applications/Native Read Task.app/ (bundleID test.native.read.task, pid 4646)
                Window: "Native Read Task", App: Native Read Task.
                0 standard window Native Read Task, ID: read.window
                </app_state>
                """
            let content: [JSONValue] = [.object(["type": .string("text"), "text": .string(text)]), try image()]
            return .init(raw: .object(["content": .array(content)]), content: content, isError: false)
        }, close: { [self] in closes += 1 }), sessionIsActive: { true })
        return .init(initial: { admission in
            let preparation = TargetBoundNativeObservation.Preparation(application: admission.application,
                window: .init(title: "Native Read Task", role: "AXWindow", identifier: "read.window", document: "task://read",
                    url: "", x: 0, y: 0, width: 560, height: 300, minimized: false, hidden: false, modal: false),
                validate: admission.validate)
            let snapshot = try await observer.observe(observer.prepare(preparation))
            return .init(snapshot: snapshot, isCurrent: { observer.isCurrent(snapshot) }, refreshOriginal: nil)
        }, stop: { observer.stop() }, drain: { await observer.drain() })
    }

    private func image() throws -> JSONValue {
        let context = try #require(CGContext(data: nil, width: 4, height: 3, bitsPerComponent: 8,
            bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let bitmap = try #require(context.makeImage()), data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, bitmap, nil); try #require(CGImageDestinationFinalize(destination))
        return .object(["type": .string("image"), "mimeType": .string("image/png"), "data": .string((data as Data).base64EncodedString())])
    }
}

@MainActor private final class NativeReadTaskRuntime: LocalModelRuntime {
    var answer = "There are three synthetic blue shapes."
    var imagePayloads: [Data] = [], toolCounts: [Int] = []
    var pauseBeforeReply: (() async -> Void)?
    var beforeReply: (() -> Void)?
    let cancellations = NativeReadTaskCancellationCount()
    func createConversation(config: LiteRTLM.ConversationConfig) async throws -> any LocalConversationSession {
        toolCounts.append(config.tools.count)
        return NativeReadTaskSession(runtime: self)
    }
}

@MainActor private final class NativeReadTaskSession: LocalConversationSession {
    unowned let runtime: NativeReadTaskRuntime
    nonisolated let cancellations: NativeReadTaskCancellationCount
    init(runtime: NativeReadTaskRuntime) { self.runtime = runtime; cancellations = runtime.cancellations }
    func send(_ message: LiteRTLM.Message) async throws -> LiteRTLM.Message {
        for content in message.contents { if case .imageData(let data) = content { runtime.imagePayloads.append(data) } }
        runtime.beforeReply?()
        await runtime.pauseBeforeReply?()
        return LiteRTLM.Message(runtime.answer, role: .model)
    }
    nonisolated func cancel() { cancellations.increment() }
}

nonisolated private final class NativeReadTaskCancellationCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}
