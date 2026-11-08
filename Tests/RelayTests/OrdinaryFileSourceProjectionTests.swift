import Dispatch
import Foundation
import Testing
@testable import Relay

@Suite(.serialized) @MainActor struct OrdinaryFileSourceProjectionTests {
    @Test func actualSingleAgentFileChangeAfterReadKeepsTheResultInActivityButOutOfNextModelInput() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "relay-ordinary-file-proof-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "selected.txt"), nonce = UUID().uuidString
        let a = "PRIVATE_A_" + nonce, b = "PRIVATE_B_" + nonce
        try Data(a.utf8).write(to: file)
        let grants = [ScopeGrant(path: folder.path, writable: true)], tools = MacTools(), worker = FileExtractionWorker(extractionTimeout: .seconds(5), validationTimeout: .seconds(5))
        tools.grants = grants
        let legacyWorker = SelectedFileProofWorker(timeout: .seconds(5))
        let barrier = Barrier(); defer { barrier.release() }
        var turns = 0, reads = 0, effects = 0
        let store = AssistantStore(persistenceURL: nil, complete: { input, _, _ in
            turns += 1
            if turns == 1 { return .init(content: "", toolCalls: [.init(id: "ordinary-real-file-read", name: "read_file", arguments: ["path": .string(file.path)])]) }
            #expect(barrier.entered && !input.map(\.content).joined().contains(a))
            #expect(!input.flatMap(\.toolCalls).contains { $0.id == "ordinary-real-file-read" })
            #expect(ContextWindow.isWellFormed(input.filter { $0.role != "system" }))
            return .init(content: "The selected file changed; its earlier body is omitted. No mutation was repeated.", toolCalls: [])
        }, continuationProofWorker: legacyWorker, execute: { _ in effects += 1; throw CancellationError() }, executeFileRead: { call, scope in
            guard call.name == "read_file" else { effects += 1; throw CancellationError() }
            let result = try await tools.execute(call, fileReadScope: scope, fileReadWorker: worker); reads += 1
            worker.pauseAfterNextSnapshot { barrier.pause() }
            return result
        }, fileReadWorker: worker)
        store.grants = grants; store.draft = "Read the explicitly selected file and report only admitted current evidence."
        let writer = Task { @MainActor in
            let end = ContinuousClock.now.advanced(by: .seconds(8))
            while !barrier.entered { try Task.checkCancellation(); try #require(ContinuousClock.now < end); await Task.yield() }
            try Data(b.utf8).write(to: file); barrier.release()
        }
        do {
            let ticket = try #require(store.send()); #expect(await ticket.waitForAcknowledgment() == .saved)
            await store.waitForConversationTaskToSettle(); try await writer.value
            #expect(turns == 2 && reads == 1 && effects == 0)
            #expect(!store.activity.contains { $0.detail.contains(a) })
            #expect(store.activity.contains { $0.name == "read_file" && $0.detail.contains("The file result is unavailable for this task.") })
            #expect(try Data(contentsOf: file) == Data(b.utf8))
        } catch {
            writer.cancel(); barrier.release(); store.stop()
            await store.waitForConversationTaskToSettle(); _ = await writer.result
            await worker.drain(); await legacyWorker.drain(); throw error
        }
        store.stop(); await worker.drain(); await legacyWorker.drain()
    }
    @Test func sourceFreeProtocolLedgerNeverCopiesOldPrivateArgumentsResultsOrNarration() {
        let secret = "PRIVATE_OMITTED_A_" + UUID().uuidString
        let call = ToolCall(id: secret, name: "write_file", arguments: ["path": .string("/owned/" + secret), "content": .string(secret)])
        let history = [ModelMessage(role: "assistant", content: secret, toolCalls: [call]),
            ModelMessage(role: "tool", content: JSONValue.object(["summary": .string(secret), "evidence": .string(secret), "verified": .bool(true)]).pretty,
                toolCallID: call.id, toolName: call.name)]
        let metadata = TaskToolLedger.summary(history: history[...], toolNames: ["write_file", "read_file"])
        #expect(!metadata.contains(secret) && metadata.contains("write_file: requests=1, verified_receipts=1"))
        #expect(metadata.contains("Requests do not prove dispatch or completion"))
    }
    nonisolated private final class Barrier: @unchecked Sendable {
        private let lock = NSLock(), semaphore = DispatchSemaphore(value: 0)
        private var didEnter = false, released = false
        var entered: Bool { lock.lock(); defer { lock.unlock() }; return didEnter }
        func pause() { lock.lock(); didEnter = true; lock.unlock(); semaphore.wait() }
        func release() { lock.lock(); let signal = !released; released = true; lock.unlock(); if signal { semaphore.signal() } }
    }
}
