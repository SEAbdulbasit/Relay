import Dispatch
import Foundation
import Testing
@testable import Relay

/// Actual scoped MacTools file read + real asynchronous proof worker. The only
/// model boundary is inert complete; no device/provider/model process exists.
@Suite(.serialized) @MainActor struct CurrentFileRoleContextStoreTests {
    @Test func aFileChangedAfterNavigatorReadCannotLeakThroughLegacyObservationIntoExecutor() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "relay-current-file-role-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let nonce = UUID().uuidString, old = "PRIVATE_A_" + nonce, replacement = "PRIVATE_B_" + nonce
        let file = root.appending(path: "chosen.txt"); try Data(old.utf8).write(to: file)
        let grants = [ScopeGrant(path: root.path, writable: true)], tools = MacTools(), worker = SelectedFileProofWorker()
        tools.grants = grants
        let barrier = ReadBarrier(); defer { barrier.release() }
        var turns = 0, reads = 0, effects = 0, executorInspected = false
        let store = AssistantStore(persistenceURL: nil, complete: { input, _, _ in
            turns += 1
            if turns == 1 { return .init(content: #"{"steps":[{"id":"read","role":"Navigator","title":"Read the chosen file"},{"id":"use","role":"Executor","title":"Reassess before an inert operation"}]}"#, toolCalls: []) }
            if turns == 2 { return .init(content: "", toolCalls: [.init(id: "actual-read", name: "read_file", arguments: ["path": .string(file.path)])]) }
            if turns == 3 {
                executorInspected = true
                let context = input.map(\.content).joined()
                #expect(barrier.entered && !context.contains(old))
                #expect(context.contains("omitted_native_results") && context.contains("omitted_receipts"))
                return .init(content: "The source changed; no action is proposed from omitted data.", toolCalls: [])
            }
            return .init(content: "UNVERIFIED: A fresh admitted read is needed before further action.", toolCalls: [])
        }, continuationProofWorker: worker, execute: { call in
            guard call.name == "read_file" else { effects += 1; throw CancellationError() }
            let actual = try await tools.execute(call); reads += 1
            #expect(actual.summary.utf8.elementsEqual(old.utf8))
            // This pauses the NEXT actual post-read proof kernel, after the
            // Navigator action has returned. It substitutes no proof/body.
            worker.pauseAfterNextRead { barrier.pauseAfterActualRead() }
            return actual
        }, multiAgent: true)
        store.grants = grants; store.draft = "Read the explicitly chosen file, then reassess before any further operation."
        let writer = Task { @MainActor in
            let end = ContinuousClock.now.advanced(by: .seconds(8))
            while !barrier.entered { try Task.checkCancellation(); try #require(ContinuousClock.now < end); await Task.yield() }
            try Data(replacement.utf8).write(to: file)
            barrier.release()
        }
        do {
            let ticket = try #require(store.send()); #expect(await ticket.waitForAcknowledgment() == .saved)
            await store.waitForConversationTaskToSettle(); try await writer.value
            #expect(executorInspected && reads == 1 && effects == 0 && store.phase == .needsInput)
            #expect(try Data(contentsOf: file) == Data(replacement.utf8))
            // The known original result remains visible to its user; omitting
            // it from a new inference never fabricates a replacement result.
            #expect(store.activity.contains { $0.detail.contains(old) })
        } catch { writer.cancel(); barrier.release(); store.stop(); throw error }
        store.stop(); await worker.drain()
    }
    nonisolated private final class ReadBarrier: @unchecked Sendable {
        private let lock = NSLock(), semaphore = DispatchSemaphore(value: 0)
        private var didEnter = false, released = false
        var entered: Bool { lock.lock(); defer { lock.unlock() }; return didEnter }
        func pauseAfterActualRead() { lock.lock(); didEnter = true; lock.unlock(); semaphore.wait() }
        func release() { lock.lock(); let shouldSignal = !released; released = true; lock.unlock(); if shouldSignal { semaphore.signal() } }
    }
}
