import AppKit
import Foundation
import Testing
@preconcurrency import LiteRTLM
@testable import Relay

@MainActor private final class FreshReadbackScope {
    var context: MultiAgentContinuation.Context?
    var grants: [ScopeGrant]
    var active = true
    init(context: MultiAgentContinuation.Context, grants: [ScopeGrant]) { self.context = context; self.grants = grants }
}
@MainActor private final class FreshReadbackFixture {
    let root: URL, file: URL, worker: SelectedFileProofWorker, book: MultiAgentContinuation
    let extractionWorker = FileExtractionWorker()
    let initialContext: MultiAgentContinuation.Context
    let scope: FreshReadbackScope
    init(data: Data = Data("OWNED caf\u{65}\u{301} 你好\n".utf8)) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-fresh-readback-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let chosen = directory.appendingPathComponent("chosen.txt"); try data.write(to: chosen)
        let fileWorker = SelectedFileProofWorker(timeout: .seconds(5))
        let context = MultiAgentContinuation.Context(logicalTaskID: UUID(), configuration: .init(), scopeID: UUID(), sourceRevision: 0)
        root = directory; file = chosen; worker = fileWorker; book = MultiAgentContinuation(worker: fileWorker)
        initialContext = context; scope = FreshReadbackScope(context: context, grants: [.init(path: directory.path)])
        book.startTask(context.logicalTaskID)
    }
    func read(_ url: URL? = nil) async throws -> (Relay.ToolCall, ToolResult) {
        let call = Relay.ToolCall(id: UUID().uuidString, name: "read_file", arguments: ["path": .string((url ?? file).path)])
        let tools = MacTools(); tools.grants = scope.grants
        return (call, try await tools.execute(call, fileReadWorker: extractionWorker))
    }
    func admission(_ call: Relay.ToolCall, _ result: ToolResult) async throws -> (@MainActor @Sendable () async throws -> Void) {
        let context = scope.context ?? initialContext, scope = scope
        return try await book.freshReadbackAdmission(call: call, result: result, context: context,
            grants: { scope.grants }, currentContext: { scope.context }, isCurrent: { scope.active })
    }
    func markSticky() async throws {
        let run = try AssistantConversationHistory.Run(logicalTaskID: initialContext.logicalTaskID, cause: .newRequest)
        let prepared = try #require(try await book.prepare(.init(id: "unsupported", name: "control_native_window", arguments: [:]),
            proposalID: UUID(), run: run, context: initialContext, grants: { [] }))
        #expect(book.markUnsupportedSourceContribution(prepared: prepared, currentContext: initialContext))
    }
}
@MainActor private func withFreshReadbackFixture(_ data: Data? = nil,
    body: @MainActor (FreshReadbackFixture) async throws -> Void) async throws {
    let fixture = try FreshReadbackFixture(data: data ?? Data("OWNED cafe\u{301} 你好\n".utf8))
    do {
        try await body(fixture)
        fixture.scope.active = false; fixture.scope.context = nil
        await fixture.worker.drain()
        await fixture.extractionWorker.drain()
        try FileManager.default.removeItem(at: fixture.root)
    } catch {
        fixture.scope.active = false; fixture.scope.context = nil
        await fixture.worker.drain()
        await fixture.extractionWorker.drain()
        try? FileManager.default.removeItem(at: fixture.root)
        throw error
    }
}
private final class FreshReadBarrier: @unchecked Sendable {
    private let lock = NSLock(), semaphore = DispatchSemaphore(value: 0)
    private var entered = false, expired = false
    var isEntered: Bool { lock.withLock { entered } }
    var timedOut: Bool { lock.withLock { expired } }
    func pause() { lock.withLock { entered = true }; if semaphore.wait(timeout: .now() + 5) == .timedOut { lock.withLock { expired = true } } }
    func release() { semaphore.signal() }
}
@MainActor private func awaitFreshRead(_ predicate: () -> Bool) async throws {
    let until = ContinuousClock.now.advanced(by: .seconds(5))
    while !predicate() { guard ContinuousClock.now < until else { throw RelayError.message("Owned real proof read did not reach its boundary.") }; try await Task.sleep(for: .milliseconds(2)) }
}
@MainActor private final class FreshReadbackInertRuntime: LocalModelRuntime {
    var sends: [String] = []
    func createConversation(config: LiteRTLM.ConversationConfig) async throws -> any LocalConversationSession { FreshReadbackInertSession(owner: self) }
}
@MainActor private final class FreshReadbackInertSession: LocalConversationSession {
    let owner: FreshReadbackInertRuntime
    init(owner: FreshReadbackInertRuntime) { self.owner = owner }
    func send(_ message: LiteRTLM.Message) async throws -> LiteRTLM.Message {
        owner.sends.append(message.contents.compactMap { if case let .text(value) = $0 { value } else { nil } }.joined())
        return .init("Independent inert response", role: .model)
    }
    nonisolated func cancel() {}
}

/// Actual selected files/MacTools plain reads and actual proof worker. Runtime
/// fixtures reject private sends or return synthetic text; no weights/provider,
/// native window/body capture, UI, account or external file is involved.
@MainActor @Suite(.serialized) struct FreshReadbackAdmissionTests {
    @Test func aFreshWholeSelectedReadCanBindOneVerdictWhileHistoricalTaintRemainsSticky() async throws {
        try await withFreshReadbackFixture { f in
            try await f.markSticky()
            let (call, result) = try await f.read()
            let run = try AssistantConversationHistory.Run(logicalTaskID: f.initialContext.logicalTaskID, cause: .newRequest)
            let prepared = try await f.book.prepare(call, proposalID: UUID(), run: run, context: f.initialContext, grants: { f.scope.grants })
            await f.book.record(result, prepared: prepared, grants: { f.scope.grants }); f.book.acknowledge(prepared)
            let before = try await f.book.snapshot(context: f.initialContext, isCurrent: { true })
            #expect(before.included == 0 && before.omitted == 2 && !before.modelContext.contains(result.summary))
            let validate = try await f.admission(call, result); try await validate()
            let after = try await f.book.snapshot(context: f.initialContext, isCurrent: { true })
            #expect(after.included == 0 && after.omitted == before.omitted)
        }
    }
    @Test(arguments: ["body", "inode", "grants", "context-nil", "model", "scope", "source-revision", "inactive", "same-task-reset", "replacement-task"])
    func everyCurrentSourceAndContextFenceInvalidatesTheEphemeralVerdict(_ drift: String) async throws {
        try await withFreshReadbackFixture { f in
            let (call, result) = try await f.read(), validate = try await f.admission(call, result)
            try await validate()
            let original = f.initialContext
            switch drift {
            case "body": try Data("DIFFERENT BODY\n".utf8).write(to: f.file)
            case "inode":
                let old = try #require(try FileManager.default.attributesOfItem(atPath: f.file.path)[.systemFileNumber] as? NSNumber)
                try Data(result.summary.utf8).write(to: f.file, options: [.atomic])
                let new = try #require(try FileManager.default.attributesOfItem(atPath: f.file.path)[.systemFileNumber] as? NSNumber)
                try #require(old != new)
            case "grants": f.scope.grants = []
            case "context-nil": f.scope.context = nil
            case "model": f.scope.context = .init(logicalTaskID: original.logicalTaskID, configuration: .init(model: "changed"), scopeID: original.scopeID, sourceRevision: 0)
            case "scope": f.scope.context = .init(logicalTaskID: original.logicalTaskID, configuration: original.configuration, scopeID: UUID(), sourceRevision: 0)
            case "source-revision": f.scope.context = .init(logicalTaskID: original.logicalTaskID, configuration: original.configuration, scopeID: original.scopeID, sourceRevision: 1)
            case "inactive": f.scope.active = false
            case "same-task-reset": f.book.startTask(original.logicalTaskID)
            default: f.book.startTask(UUID())
            }
            await #expect(throws: (any Error).self) { try await validate() }
        }
    }
    @Test func aRetargetedAliasCannotReuseAdmissionEvenForIdenticalBytesInsideTheSameGrant() async throws {
        try await withFreshReadbackFixture { f in
            let second = f.root.appendingPathComponent("second.txt"), alias = f.root.appendingPathComponent("alias.txt")
            try Data(contentsOf: f.file).write(to: second)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.file)
            let (call, result) = try await f.read(alias), validate = try await f.admission(call, result)
            try FileManager.default.removeItem(at: alias); try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: second)
            await #expect(throws: (any Error).self) { try await validate() }
        }
    }
    @Test func actualReadBThenRestoredAIsNotBoundToAProofForA() async throws {
        try await withFreshReadbackFixture(Data("STATE_A".utf8)) { f in
            let run = try AssistantConversationHistory.Run(logicalTaskID: f.initialContext.logicalTaskID, cause: .newRequest)
            _ = try await f.book.prepare(.init(id: "pre-A", name: "read_file", arguments: ["path": .string(f.file.path)]), proposalID: UUID(), run: run, context: f.initialContext, grants: { f.scope.grants })
            try Data("STATE_B".utf8).write(to: f.file)
            let (call, result) = try await f.read(); try #require(result.summary == "STATE_B")
            try Data("STATE_A".utf8).write(to: f.file)
            await #expect(throws: (any Error).self) { _ = try await f.admission(call, result) }
        }
    }
    @Test(arguments: ["unverified", "truncated", "malformed-utf8", "oversize-file", "literal-pdf", "canonical-pdf", "wrong-tool"])
    func unsupportedOrNonWholeBodiesNeverMintAVerdictValidator(_ kind: String) async throws {
        try await withFreshReadbackFixture { f in
            var (call, result) = try await f.read()
            switch kind {
            case "unverified": result.verified = false
            case "truncated": try Data(repeating: 120, count: 12_000).write(to: f.file); (call, result) = try await f.read()
            case "malformed-utf8": try Data([0xff, 0xfe, 0x00]).write(to: f.file); result.summary = "replacement"
            case "oversize-file": try Data(repeating: 120, count: 1_048_577).write(to: f.file)
            case "literal-pdf": call.arguments["path"] = .string(f.root.appendingPathComponent("not-read.pdf").path)
            case "canonical-pdf":
                let physical = f.root.appendingPathComponent("not-decoded.pdf"), alias = f.root.appendingPathComponent("plain-alias.txt")
                try Data(result.summary.utf8).write(to: physical); try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: physical)
                call.arguments["path"] = .string(alias.path)
            default: call.name = "observe_app"
            }
            await #expect(throws: (any Error).self) { _ = try await f.admission(call, result) }
        }
    }
    @Test func cancellationOfARealReadReleasesTheActualInferenceLeaseWithoutSendingLatePrivateBody() async throws {
        try await withFreshReadbackFixture { f in
            let modelFile = f.root.appendingPathComponent("inert.litertlm"); try Data([1]).write(to: modelFile)
            let cfg = ModelConfiguration(modelPath: modelFile.path), old = f.initialContext
            f.scope.context = .init(logicalTaskID: old.logicalTaskID, configuration: cfg, scopeID: old.scopeID, sourceRevision: old.sourceRevision)
            let (call, result) = try await f.read(), validate = try await f.admission(call, result)
            let barrier = FreshReadBarrier(); defer { barrier.release() }
            f.worker.pauseAfterNextRead { barrier.pause() }
            let runtime = FreshReadbackInertRuntime(), client = LocalModelClient(runtimeFactory: { _,_,_ in runtime })
            let router = LocalInferenceRouter(embedded: client, lease: LocalInferenceLease())
            let pending = Task { @MainActor in try await router.complete(messages: [.init(role: "user", content: "PRIVATE_BOUND_BODY " + result.summary)], tools: [], configuration: cfg, sourceAuthorization: validate) }
            do {
                try await awaitFreshRead { barrier.isEntered }
                let started = ContinuousClock.now; pending.cancel()
                await #expect(throws: CancellationError.self) { _ = try await pending.value }
                #expect(started.duration(to: .now) < .seconds(1) && f.worker.activeCount == 1 && runtime.sends.isEmpty)
                _ = try await router.complete(messages: [.init(role: "user", content: "INDEPENDENT")], tools: [], configuration: cfg)
                #expect(runtime.sends == ["INDEPENDENT"])
                barrier.release(); await f.worker.drain()
                #expect(!barrier.timedOut && f.worker.activeCount == 0 && runtime.sends == ["INDEPENDENT"])
                router.unload()
            } catch {
                pending.cancel(); barrier.release(); _ = await pending.result
                await f.worker.drain(); router.unload(); throw error
            }
        }
    }
}

@MainActor @Suite(.serialized) struct HistoricalPlainReadbackReceiptTests {
    @Test func theWholeActualPlainReadBodyRetainsItsExactBytesAndCurrentProof() async throws {
        try await withFreshReadbackFixture { f in
            let call = Relay.ToolCall(id: "whole", name: "read_file", arguments: ["path": .string(f.file.path)])
            let run = try AssistantConversationHistory.Run(logicalTaskID: f.initialContext.logicalTaskID, cause: .newRequest)
            let prepared = try await f.book.prepare(call, proposalID: UUID(), run: run, context: f.initialContext, grants: { f.scope.grants })
            let tools = MacTools(); tools.grants = f.scope.grants
            let result = try await tools.execute(call, fileReadWorker: f.extractionWorker)
            await f.book.record(result, prepared: prepared, grants: { f.scope.grants }); f.book.acknowledge(prepared)
            let snapshot = try await f.book.snapshot(context: f.initialContext, isCurrent: { true }); try await snapshot.validate()
            #expect(snapshot.included == 1 && snapshot.omitted == 0)
            let object = try #require(try JSONSerialization.jsonObject(with: Data(snapshot.modelContext.utf8)) as? [String: Any])
            let entries = try #require(object["historical_tool_receipts"] as? [[String: Any]])
            let summary = try #require(entries.first?["summary"] as? String)
            #expect(Data(summary.utf8) == Data(result.summary.utf8))
        }
    }
    @Test(arguments: ["mismatch", "ABA", "transformed-eml", "truncated"])
    func aMetadataProofNeverSubstitutesForActualWholeReturnedBodyBinding(_ kind: String) async throws {
        try await withFreshReadbackFixture(Data("STATE_A".utf8)) { f in
            var file = f.file
            if kind == "transformed-eml" {
                file = f.root.appendingPathComponent("selected.eml")
                try Data("From: synthetic@example.test\r\nTo: reader@example.test\r\nSubject: Owned fixture\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\nTRANSFORMED_PRIVATE_BODY\r\n".utf8).write(to: file)
            }
            if kind == "truncated" { try Data(String(repeating: "TRUNCATED_PRIVATE_BODY", count: 700).utf8).write(to: file) }
            let call = Relay.ToolCall(id: "read", name: "read_file", arguments: ["path": .string(file.path)])
            let run = try AssistantConversationHistory.Run(logicalTaskID: f.initialContext.logicalTaskID, cause: .newRequest)
            let prepared = try #require(try await f.book.prepare(call, proposalID: UUID(), run: run, context: f.initialContext, grants: { f.scope.grants }))
            if kind == "ABA" { try Data("STATE_B".utf8).write(to: file) }
            let tools = MacTools(); tools.grants = f.scope.grants
            var result = try await tools.execute(call, fileReadWorker: f.extractionWorker)
            if kind == "ABA" { try #require(result.summary == "STATE_B"); try Data("STATE_A".utf8).write(to: file) }
            if kind == "mismatch" {
                // The old actual pre-read proof still validates: the selected
                // file and metadata never changed. The returned body must be
                // matched independently rather than trusting verified/evidence.
                try await prepared.readSource?.validate()
                result.summary = "MISMATCHED_PRIVATE_BODY"
            }
            await f.book.record(result, prepared: prepared, grants: { f.scope.grants }); f.book.acknowledge(prepared)
            let snapshot = try await f.book.snapshot(context: f.initialContext, isCurrent: { true })
            #expect(snapshot.included == 0 && snapshot.omitted == 1)
            #expect(!snapshot.modelContext.contains("MISMATCHED_PRIVATE_BODY") && !snapshot.modelContext.contains("TRANSFORMED_PRIVATE_BODY") && !snapshot.modelContext.contains("TRUNCATED_PRIVATE_BODY") && !snapshot.modelContext.contains("STATE_B"))
            let derived = try await f.book.prepare(.init(id: "derived", name: "calculate", arguments: ["expression": .string("7")]), proposalID: UUID(), run: run, context: f.initialContext, grants: { [] })
            #expect(derived?.supported == false, "An unsupported private read must keep later derived receipts out of automatic context.")
        }
    }
    @Test(arguments: ["context-nil", "inactive"])
    func missingLiveOwnershipRefusesBeforeFreshAdmission(_ state: String) async throws {
        try await withFreshReadbackFixture { f in
            let (call, result) = try await f.read()
            if state == "context-nil" { f.scope.context = nil } else { f.scope.active = false }
            await #expect(throws: CancellationError.self) { _ = try await f.admission(call, result) }
            #expect(f.worker.activeCount == 0)
        }
    }
    @Test func contextChangeWhileTheActualPostReadProofIsSuspendedCannotReturnAValidator() async throws {
        try await withFreshReadbackFixture { f in
            let (call, result) = try await f.read()
            let barrier = FreshReadBarrier(); defer { barrier.release() }
            f.worker.pauseAfterNextRead { barrier.pause() }
            let pending = Task { @MainActor in try await f.admission(call, result) }
            do {
                try await awaitFreshRead { barrier.isEntered }
                f.scope.context = nil
                barrier.release()
                await #expect(throws: CancellationError.self) { _ = try await pending.value }
                await f.worker.drain()
                #expect(!barrier.timedOut && f.worker.activeCount == 0)
            } catch {
                pending.cancel(); barrier.release(); _ = await pending.result
                await f.worker.drain(); throw error
            }
        }
    }
}
