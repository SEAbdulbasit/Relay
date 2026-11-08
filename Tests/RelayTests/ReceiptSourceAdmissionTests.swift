import Foundation
import Dispatch
import Testing
import Synchronization
@preconcurrency import LiteRTLM
@testable import Relay
@testable import RelayJournal

@MainActor private final class ReceiptAdmissionState {
    var active = true
    var checks = 0
    func validate() throws { checks += 1; guard active else { throw CancellationError() } }
}
nonisolated private final class ReceiptAdmissionCounter: Sendable {
    private let value = Mutex(0)
    func increment() { value.withLock { $0 += 1 } }
    var count: Int { value.withLock { $0 } }
}
@MainActor private final class ReceiptAdmissionRuntime: LocalModelRuntime {
    var creates = 0, sends = 0
    var receivedText: [String] = []
    let cancellations = ReceiptAdmissionCounter()
    var onCreate: (() throws -> Void)?
    var onSend: (() throws -> Void)?
    func createConversation(config: LiteRTLM.ConversationConfig) async throws -> any LocalConversationSession {
        creates += 1; try onCreate?(); return ReceiptAdmissionSession(runtime: self)
    }
}
@MainActor private final class ReceiptAdmissionSession: LocalConversationSession {
    unowned let runtime: ReceiptAdmissionRuntime
    nonisolated let cancellations: ReceiptAdmissionCounter
    init(runtime: ReceiptAdmissionRuntime) { self.runtime = runtime; cancellations = runtime.cancellations }
    func send(_ message: LiteRTLM.Message) async throws -> LiteRTLM.Message {
        runtime.sends += 1
        runtime.receivedText += message.contents.compactMap { content in if case let .text(text) = content { text } else { nil } }
        try runtime.onSend?(); return LiteRTLM.Message("LATE_PRIVATE_REPLY", role: .model)
    }
    nonisolated func cancel() { cancellations.increment() }
}
@MainActor @Suite(.serialized) struct ReceiptSourceAdmissionTests {
    @Test(arguments: ["load-success", "load-error", "create", "task-cancel", "send-success", "send-error"]) func embeddedPrivateInputIsRecheckedAfterPreparationAndOnBothReplyPaths(_ point: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-receipt-admission-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = root.appendingPathComponent("inert.litertlm"); try Data([1]).write(to: model)
        let state = ReceiptAdmissionState(), runtime = ReceiptAdmissionRuntime()
        let client = LocalModelClient(runtimeFactory: { _,_,_ in
            if point.hasPrefix("load") { state.active = false }
            if point == "load-error" { throw RelayError.message("PRIVATE_LOAD_ERROR") }
            return runtime
        })
        runtime.onCreate = {
            if point == "create" { state.active = false }
            if point == "task-cancel" { withUnsafeCurrentTask { $0?.cancel() } }
        }
        runtime.onSend = {
            if point.hasPrefix("send") { state.active = false }
            if point == "send-error" { throw RelayError.message("PRIVATE_SEND_ERROR") }
        }
        let completion = Task { @MainActor in
            try await client.complete(messages: [.init(role: "user", content: "PRIVATE_RECEIPT_INPUT")], tools: [], configuration: .init(modelPath: model.path), sourceAuthorization: { try state.validate() })
        }
        await #expect(throws: CancellationError.self) { try await completion.value }
        #expect(runtime.creates == (point.hasPrefix("load") ? 0 : 1))
        #expect(runtime.sends == (point.hasPrefix("send") ? 1 : 0))
        if point == "create" || point == "task-cancel" { #expect(runtime.cancellations.count == 1) }
        client.unload()
    }
    @Test(arguments: ["before-open", "late-success", "late-error"]) func loopbackTextChecksItsSourceBeforeAdmissionAndRejectsLateReplies(_ point: String) async throws {
        let state = ReceiptAdmissionState(), fixture = ReceiptTransportFixture()
        await fixture.setBeforeReply {
            if point.hasPrefix("late") { state.active = false }
        }
        await fixture.setFails(point == "late-error")
        let client = LMStudioClient(transport: fixture.transport)
        await #expect(throws: CancellationError.self) {
            try await client.complete(messages: [.init(role: "user", content: "SYNTHETIC_PRIVATE_RECEIPT")], tools: [], selection: .init(endpoint: .init(), modelID: "inert"), sourceAuthorization: {
                if point == "before-open", state.checks == 1 { state.active = false }
                try state.validate()
            })
        }
        #expect(await fixture.opens == (point == "before-open" ? 0 : 1))
    }
}
private actor ReceiptTransportFixture {
    private(set) var opens = 0
    private var beforeReply: (@MainActor @Sendable () -> Void)?
    private var fails = false
    nonisolated var transport: LMStudioClient.Transport { .init(open: { [self] request in try await respond(request) }) }
    func setBeforeReply(_ value: @escaping @MainActor @Sendable () -> Void) { beforeReply = value }
    func setFails(_ value: Bool) { fails = value }
    private func respond(_ request: URLRequest) async throws -> LMStudioClient.Response {
        opens += 1; await beforeReply?()
        if fails { throw LMStudioFailure.unavailable }
        let body = Data(#"{"choices":[{"message":{"content":"LATE_SYNTHETIC_REPLY"},"finish_reason":"stop"}]}"#.utf8)
        return .init(url: request.url!, status: 200, contentType: "application/json", body: AsyncThrowingStream { continuation in continuation.yield(body); continuation.finish() }, cancel: {})
    }
}

/// Delays a real file read after LocalStateFile returned and closed its fd.
/// It never supplies bytes, metadata, a digest, a proof or a database result.
private final class ReceiptReadBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var entered = false
    private var expired = false
    var isEntered: Bool { lock.withLock { entered } }
    var timedOut: Bool { lock.withLock { expired } }
    func pause() {
        lock.withLock { entered = true }
        if semaphore.wait(timeout: .now() + 5) == .timedOut { lock.withLock { expired = true } }
    }
    func release() { semaphore.signal() }
}
@MainActor private func waitForReceiptRead(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !predicate() {
        guard ContinuousClock.now < deadline else { throw RelayError.message("Owned file worker did not reach its boundary.") }
        try await Task.sleep(for: .milliseconds(2))
    }
}
@MainActor @Suite(.serialized) struct AsynchronousReceiptProofTests {
    @Test(arguments: ["cancel", "timeout"]) func aBlockedRealReadCannotHoldTheSharedModelLeaseOrAdmitLatePrivateInput(_ stop: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-async-proof-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("chosen.txt"), model = root.appendingPathComponent("inert.litertlm")
        try Data("owned source bytes".utf8).write(to: source); try Data([1]).write(to: model)
        let grants = [ScopeGrant(path: root.path)], worker = SelectedFileProofWorker(timeout: stop == "timeout" ? .milliseconds(250) : .seconds(2))
        // Setup is independent of the short validation deadline under test. A
        // broad MainActor test wave must not expire before the blocked boundary.
        let setupWorker = SelectedFileProofWorker(timeout: .seconds(5))
        let proof = try await setupWorker.capture(input: source.path, grants: grants)
        let barrier = ReceiptReadBarrier(); defer { barrier.release() }
        worker.pauseAfterNextRead { barrier.pause() }
        let runtime = ReceiptAdmissionRuntime(), embedded = LocalModelClient(runtimeFactory: { _,_,_ in runtime })
        let lease = LocalInferenceLease(), router = LocalInferenceRouter(embedded: embedded, lease: lease)
        let configuration = ModelConfiguration(modelPath: model.path)
        let pending = Task { @MainActor in
            try await router.complete(messages: [.init(role: "user", content: "OLD_PRIVATE_MUST_NOT_SEND")], tools: [], configuration: configuration,
                sourceAuthorization: { try await worker.validate(proof, grants: grants) })
        }
        try await waitForReceiptRead { barrier.isEntered }
        #expect(worker.activeCount == 1 && runtime.creates == 0 && runtime.sends == 0)
        let started = ContinuousClock.now
        if stop == "cancel" {
            pending.cancel()
            await #expect(throws: CancellationError.self) { try await pending.value }
        } else {
            await #expect(throws: SelectedFileProofWorker.Failure.timedOut) { try await pending.value }
        }
        #expect(started.duration(to: .now) < .seconds(1))
        #expect(worker.activeCount == 1, "The physical worker slot must remain owned while its real read completion is delayed.")
        await #expect(throws: SelectedFileProofWorker.Failure.busy) { try await worker.capture(input: source.path, grants: grants) }
        // The same actual router/lease can serve a source-free request while the
        // cancelled worker still owns its private, never-published read result.
        let independent = try await router.complete(messages: [.init(role: "user", content: "NEW_INDEPENDENT_QUERY")], tools: [], configuration: configuration)
        #expect(independent.toolCalls.isEmpty && runtime.creates == 1 && runtime.sends == 1)
        #expect(!runtime.receivedText.contains(where: { $0.contains("OLD_PRIVATE_MUST_NOT_SEND") }))
        barrier.release(); await worker.drain()
        #expect(worker.activeCount == 0 && !barrier.timedOut)
        #expect(runtime.creates == 1 && runtime.sends == 1)
        router.unload()
    }
    @Test func actualStoreStopReturnsBeforeARealReadSettlesAndStillSavesTheKnownEffect() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-async-store-proof-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("output.txt"), worker = SelectedFileProofWorker()
        let history = AssistantConversationHistory(stateURL: root.appendingPathComponent("state.json")), core = try await history.journalForTesting()
        let barrier = ReceiptReadBarrier(); defer { barrier.release() }
        var calls = 0, effects = 0
        let store = AssistantStore(persistenceURL: nil, complete: { _,_,_ in
            calls += 1
            if calls == 1 { return .init(content: #"{"steps":[{"role":"Executor","title":"Write the chosen output"}]}"#, toolCalls: []) }
            if calls == 2 { return .init(content: "", toolCalls: [.init(id: "known-before-stop", name: "write_file", arguments: ["path": .string(output.path), "content": .string("OWNED_EFFECT")])]) }
            Issue.record("Stopping the suspended proof must not admit another model turn.")
            return .init(content: "Unexpected", toolCalls: [])
        }, conversationHistory: history, continuationProofWorker: worker, execute: { _ in
            effects += 1; try Data("OWNED_EFFECT".utf8).write(to: output)
            worker.pauseAfterNextRead { barrier.pause() }
            return .init(summary: "Known effect returned before Stop", evidence: "Owned file bytes written", verified: true, artifactPath: output.path)
        }, multiAgent: true)
        store.grants = [.init(path: root.path, writable: true)]
        store.draft = "Create the chosen output once."; store.send()
        try await waitForReceiptRead { barrier.isEntered }
        #expect(effects == 1 && calls == 2)
        let started = ContinuousClock.now
        store.stop()
        #expect(started.duration(to: .now) < .milliseconds(250), "Stop must not wait for selected-file IO on MainActor.")
        await store.waitForConversationTaskToSettle()
        #expect(worker.activeCount == 1 && calls == 2 && effects == 1)
        let scope = try await core.scope(), records = try await core.page(expectedScope: scope)
        let outcomes = records.records.compactMap { record -> JournalToolOutcome? in if case let .result(value) = record.event.payload { value } else { nil } }
        #expect(outcomes.count == 1 && outcomes.first?.kind == .returnedVerified)
        #expect(try Data(contentsOf: output) == Data("OWNED_EFFECT".utf8))
        barrier.release(); await worker.drain()
        #expect(worker.activeCount == 0 && !barrier.timedOut && calls == 2)
    }
}
