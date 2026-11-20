import Foundation
import Testing
@testable import Relay

@MainActor struct ModelInputSourceProofFinalMetadataTests {
    @Test(arguments: [false, true])
    func finalMetadataFollowsAllAwaitedLeavesThroughBothEntryPoints(_ closure: Bool) async throws {
        var trace: [String] = []
        let owner = UUID()
        let first = ModelInputSourceProof.source(identity: .init(owner: owner, sourceID: Data([1]), purpose: "owned-metadata-protocol"),
            finalMetadata: { trace.append("final-1") }) { trace.append("data-1"); await Task.yield() }
        let second = ModelInputSourceProof.source(identity: .init(owner: owner, sourceID: Data([2]), purpose: "owned-metadata-protocol"),
            finalMetadata: { trace.append("final-2") }) { trace.append("data-2"); await Task.yield() }
        let combined = try #require(try ModelInputSourceProof.merging([first, second]))
        if closure { try await combined.validator() } else { try await combined.validate() }
        #expect(trace == ["data-1", "data-2", "final-1", "final-2"] && combined.dependencyCount == 2)
        trace = []
        try combined.validateFinalMetadata()
        #expect(trace == ["final-1", "final-2"], "Metadata-only publication checks perform no awaited source work.")
    }
    @Test func nilLegacyAndBoundedDedupSemanticsRemainUnchanged() async throws {
        #expect(try ModelInputSourceProof.merging([nil,nil]) == nil)
        var calls = 0
        let owner = UUID(), id = ModelInputSourceProof.Identity(owner: owner, sourceID: Data([0]), purpose: "owned-metadata-only")
        let legacy = ModelInputSourceProof.source(identity: id) { calls += 1 }
        try legacy.validateFinalMetadata(); #expect(calls == 0)
        try await legacy.validate(); try await legacy.validator(); #expect(calls == 2)
        let duplicate = try #require(try ModelInputSourceProof.merging([legacy,legacy]))
        #expect(duplicate.dependencyCount == 1)
        var values: [ModelInputSourceProof?] = []
        for index in 0..<32 {
            values.append(ModelInputSourceProof.source(identity: .init(owner: owner, sourceID: Data([UInt8(index)]), purpose: "bounded-owned-metadata"),
                finalMetadata: {}) {})
        }
        #expect(try ModelInputSourceProof.merging(values)?.dependencyCount == 32)
        values.append(ModelInputSourceProof.source(identity: .init(owner: owner, sourceID: Data([32]), purpose: "bounded-owned-metadata"), finalMetadata: {}) {})
        #expect(throws: ModelInputSourceProof.Failure.self) { try ModelInputSourceProof.merging(values) }
    }
    @Test(arguments: [false, true], [false, true])
    func actualCalendarAndSelectedFileCompositeFencesRecordedRevocationBeforeAdmission(_ closure: Bool, _ revoke: Bool) async throws {
        let f = try CalendarProtocolFixture(), barrier = CalendarProtocolBarrier()
        let fileWorker = FileExtractionWorker(), fileSources = FileReadResultSources(), calendarSources = CalendarReadResultSources()
        let file = f.root.appendingPathComponent("actual-input-a.txt"), bytes = Data("ACTUAL_PRIVATE_A".utf8)
        try bytes.write(to: file)
        let grants = [ScopeGrant(path: f.root.path)], proposal = UUID()
        let call = Relay.ToolCall(id: "actual-a", name: "read_file", arguments: ["path": .string(file.path)])
        let scope = try FileReadExecutionScope(run: f.run, proposalID: proposal, call: call, context: f.context,
            currentContext: { [weak f] in f?.current }, grants: { grants }, isCurrent: { [weak f] in f?.active == true })
        var task: Task<Void, any Error>?
        do {
            let (calendarResult, _) = try await f.settled(calendarSources)
            let b = try await calendarSources.sourceProof(call: f.call(), result: calendarResult, run: f.run,
                proposalID: f.proposal, context: f.context)
            var token: AssistantConversationHistory.FileReadSettlement?
            let fileResult = try await f.history.perform(call, proposalID: proposal, run: f.run,
                validate: { try scope.validateCurrent(call: call) },
                action: { try await fileWorker.extract(call: call, grants: grants, scope: scope) }, result: { $0 },
                unsavedResult: { _ in Issue.record("Unexpected source A result fault.") },
                settledFileResult: { _, value in token = value })
            try fileSources.registerSettled(call: call, result: fileResult, run: f.run,
                proposalID: proposal, context: f.context, settlement: try #require(token))
            let a = try await fileSources.sourceProof(call: call, result: fileResult, run: f.run, proposalID: proposal, context: f.context)
            let composite = try #require(try ModelInputSourceProof.merging([b,a]))
            #expect(composite.dependencyCount == 2)
            fileWorker.pauseAfterNextSnapshot { barrier.pause() }
            var privateAdmissions = 0
            let pending = Task {
                if closure { try await composite.validator() } else { try await composite.validate() }
                privateAdmissions += 1
            }
            task = pending
            try await waitForCalendarBarrier(barrier)
            let source = f.source.calendarReadSeed(), checks = f.worker.generationFenceChecks
            let queries = f.backend.count
            if revoke { f.worker.invalidateDatabaseForTesting() }
            #expect(source.matches(f.source.calendarReadSeed()) && f.current == f.context)
            #expect(try Data(contentsOf: file) == bytes)
            barrier.release()
            if revoke {
                await #expect(throws: CalendarReadFailure.self) { try await pending.value }
                #expect(privateAdmissions == 0)
            } else { try await pending.value; #expect(privateAdmissions == 1) }
            #expect(f.worker.generationFenceChecks > checks && f.backend.count == queries)
            // A genuinely succeeded unchanged; no fabricated or weakened proof.
            try await a.validate(); #expect(try Data(contentsOf: file) == bytes)
            await fileWorker.drain(); await f.close()
        } catch { task?.cancel(); barrier.release(); _ = await task?.result; await fileWorker.drain(); await f.close(); throw error }
    }
}
