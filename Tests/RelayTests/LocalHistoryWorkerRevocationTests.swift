import Dispatch
import Foundation
import Testing
@testable import Relay

/// Real scoped file IO and provenance bookkeeping; the private-send counter is
/// inert and no model/provider/app/device runtime is involved.
@Suite(.serialized) @MainActor struct LocalHistoryWorkerRevocationTests {
    @Test func tombstoneDuringARealWorkerValidationRefusesTheOldProjectionBeforePrivateSend() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "relay-local-history-retire-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let file = folder.appending(path: "source.txt"), bytes = Data("UNCHANGED_OWNED_SOURCE_cafe\u{301}".utf8)
        try bytes.write(to: file)
        let grants = [ScopeGrant(path: folder.path, writable: false)]
        let worker = SelectedFileProofWorker(timeout: .seconds(5)), barrier = Barrier()
        var pending: Task<Void, any Error>?
        do {
            let actual = try await worker.capture(input: file.path, grants: grants)
            let proof = ModelInputSourceProof.source(identity: .init(owner: UUID(), sourceID: actual.id, purpose: "owned history retirement check")) {
                try await worker.validate(actual, grants: grants)
            }
            let book = LocalModelHistorySources(), group = UUID(), run = UUID()
            let call = ToolCall(id: "actual-file-read", name: "read_file", arguments: ["path": .string(file.path)])
            let reply = ModelReply(content: "", toolCalls: [call])
            let history = [ModelMessage(role: "user", content: "Read this admitted owned file."),
                ModelMessage(role: "assistant", content: "", toolCalls: [call]),
                ModelMessage(role: "tool", content: String(decoding: bytes, as: UTF8.self), toolCallID: call.id, toolName: call.name)]
            try book.acceptReply(at: 1, groupID: group, runID: run, reply: reply, inputProof: nil)
            try book.resultSource(groupID: group, call: call, proof: proof)
            let projection = try await book.project(history, activeStart: 0, currentRun: run, budget: 8_000, gate: {})
            worker.pauseAfterNextRead { barrier.pause() }
            var privateSends = 0
            let validating = Task { @MainActor in
                try await projection.validate()
                privateSends += 1
            }
            pending = validating
            let deadline = ContinuousClock.now.advanced(by: .seconds(4))
            while !barrier.entered {
                guard ContinuousClock.now < deadline else { throw LocalModelHistorySources.Failure.unavailable }
                try await Task.sleep(for: .milliseconds(2))
            }
            book.retireProof(groupID: group)
            barrier.release()
            do {
                try await validating.value
                Issue.record("A retired actual group cannot admit an old projection after the source await.")
            } catch let failure as LocalModelHistorySources.Failure {
                guard case .unavailable = failure else { throw failure }
            }
            pending = nil
            #expect(privateSends == 0)
            // This is metadata revocation, not file invalidity or a substituted
            // source proof: the original exact source still validates.
            try await worker.validate(actual, grants: grants)
            #expect(try Data(contentsOf: file) == bytes)
            await worker.drain()
            #expect(worker.activeCount == 0)
            try FileManager.default.removeItem(at: folder)
            #expect(!FileManager.default.fileExists(atPath: folder.path))
        } catch {
            pending?.cancel(); barrier.release(); _ = await pending?.result
            await worker.drain(); try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    nonisolated private final class Barrier: @unchecked Sendable {
        private let lock = NSLock(), semaphore = DispatchSemaphore(value: 0)
        private var didEnter = false, released = false
        var entered: Bool { lock.lock(); defer { lock.unlock() }; return didEnter }
        func pause() { lock.lock(); didEnter = true; lock.unlock(); semaphore.wait() }
        func release() { lock.lock(); let signal = !released; released = true; lock.unlock(); if signal { semaphore.signal() } }
    }
}
