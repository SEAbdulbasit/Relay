import Foundation
import Testing
@testable import Relay
@testable import RelayJournal

@Suite(.serialized) @MainActor struct CalendarReadResultSourcesTests {
    @Test func realSavedResultDistributesOnceAndRevalidatesBeyond1024UsesWithoutANewProposal() async throws {
        try await withCalendarProtocol { f in
            let registry = CalendarReadResultSources(), call = f.call()
            let (result, token) = try await f.settled(registry)
            for _ in 0..<1_025 {
                let proof = try await registry.sourceProof(call: call, result: result, run: f.run,
                    proposalID: f.proposal, context: f.context)
                #expect(proof.dependencyCount == 1)
            }
            try registry.registerSettled(call: call, result: result, run: f.run, proposalID: f.proposal, context: f.context, settlement: token)
            #expect(f.backend.count == 1_026 && registry.retainedCount == 1)
            let rows = try await f.records()
            #expect(rows.filter { if case .intent = $0.event.payload { true } else { false } }.count == 1)
            #expect(rows.filter { if case .result = $0.event.payload { true } else { false } }.count == 1)
            registry.reset()
            #expect(throws: CalendarReadFailure.self) {
                try registry.registerSettled(call: call, result: result, run: f.run, proposalID: f.proposal, context: f.context, settlement: token)
            }
        }
    }
    @Test func namespaceObjectAndWireBytesCannotReconstructSavedAuthority() async throws {
        try await withCalendarProtocol { f in
            let registry = CalendarReadResultSources(), call = f.call()
            let (result, token) = try await f.settled(registry)
            let foreign = try await f.produce()
            #expect(foreign.result.summary == result.summary && foreign.receipt !== result.calendarReadReceipt)
            #expect(throws: CalendarReadFailure.self) {
                try registry.registerSettled(call: call, result: foreign.result, run: f.run,
                    proposalID: f.proposal, context: f.context, settlement: token)
            }
            let restored = try JSONDecoder().decode(ToolResult.self, from: JSONEncoder().encode(result))
            #expect(restored.calendarReadReceipt == nil)
            let encoded = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
            #expect(Set(encoded.keys).isSubset(of: ["summary", "evidence", "verified", "artifactPath"]))
            var alias = call; alias.id = "calendar-cafe\u{301}"
            #expect(alias.id == call.id && Data(alias.id.utf8) != Data(call.id.utf8))
            let otherRun = try AssistantConversationHistory.Run(logicalTaskID: f.context.logicalTaskID, predecessor: f.run, cause: .resume)
            for (candidate, output, run, proposal) in [(alias,result,f.run,f.proposal), (call,restored,f.run,f.proposal),
                (call,result,otherRun,f.proposal), (call,result,f.run,UUID())] {
                await #expect(throws: CalendarReadFailure.self) {
                    _ = try await registry.sourceProof(call: candidate, result: output, run: run, proposalID: proposal, context: f.context)
                }
            }
            var changed = result; changed.summary += " altered"
            await #expect(throws: CalendarReadFailure.self) {
                _ = try await registry.sourceProof(call: call, result: changed, run: f.run, proposalID: f.proposal, context: f.context)
            }
        }
    }
    @Test func evictedReceiptsCannotBeConsumedAgainButLaterAcceptedRepliesCanReuseProviderIDs() async throws {
        try await withCalendarProtocol { f in
            let registry = CalendarReadResultSources(capacity: 1), call = f.call()
            let (first, firstToken) = try await f.settled(registry)
            let firstProof = try await registry.sourceProof(call: call, result: first, run: f.run, proposalID: f.proposal, context: f.context)
            let next = UUID(), (second, _) = try await f.settled(registry, proposal: next)
            #expect(first.calendarReadReceipt !== second.calendarReadReceipt && registry.retainedCount == 1)
            let proof = try await registry.sourceProof(call: call, result: second, run: f.run, proposalID: next, context: f.context)
            try await proof.validate(); try await firstProof.validate()
            let combined = try #require(try ModelInputSourceProof.merging([firstProof, proof]))
            #expect(combined.dependencyCount == 1, "Per-proposal consumption never creates extra source leaves for the same fixed query/run.")
            await #expect(throws: CalendarReadFailure.self) {
                _ = try await registry.sourceProof(call: call, result: first, run: f.run, proposalID: f.proposal, context: f.context)
            }
            #expect(throws: CalendarReadFailure.self) {
                try registry.registerSettled(call: call, result: first, run: f.run, proposalID: f.proposal, context: f.context, settlement: firstToken)
            }
            let rows = try await f.records()
            #expect(rows.filter { if case .intent = $0.event.payload { true } else { false } }.count == 2)
            #expect(rows.filter { if case .result = $0.event.payload { true } else { false } }.count == 2)
        }
    }
    @Test func retirementDuringFreshQueryCannotReturnARegisteredProof() async throws {
        let f = try CalendarProtocolFixture(), barrier = CalendarProtocolBarrier(), registry = CalendarReadResultSources()
        do {
            let (result, _) = try await f.settled(registry), call = f.call()
            f.backend.pauseNext(barrier)
            let task = Task { try await registry.sourceProof(call: call, result: result, run: f.run, proposalID: f.proposal, context: f.context) }
            do {
                try await waitForCalendarBarrier(barrier)
                registry.reset(); barrier.release()
                await #expect(throws: CalendarReadFailure.self) { _ = try await task.value }
                #expect(registry.retainedCount == 0)
            } catch { task.cancel(); barrier.release(); _ = try? await task.value; throw error }
            await f.close()
        } catch { barrier.release(); await f.close(); throw error }
    }
    @Test(arguments: [JournalFault.beforeCommit, .afterCommit])
    func resultFaultNeverIssuesATokenAndRepairSavesOnlyTheKnownFact(_ fault: JournalFault) async throws {
        try await withCalendarProtocol { f in
            let core = try await f.history.journalForTesting(), call = f.call(), scope = try f.scope(f.call())
            await core.injectResultFault(fault, forToolName: "read_calendar")
            var unsaved = 0, tokens = 0
            do {
                _ = try await f.history.perform(call, proposalID: f.proposal, run: f.run,
                    validate: { try scope.validateCurrent(call: call) },
                    action: { try await f.worker.read(call: call, scope: scope).result }, result: { $0 },
                    unsavedResult: { value in
                        unsaved += 1
                        #expect(!value.summary.contains("OWNED_EVENT_CONTEXT") && value.calendarReadReceipt == nil && value.artifactPath == nil)
                    }, settledCalendarReadResult: { _,_ in tokens += 1 })
                Issue.record("Fault did not stop storage acknowledgment.")
            } catch { #expect(error is JournalError) }
            #expect(f.backend.count == 1 && unsaved == 1 && tokens == 0)
            try await f.history.retryResultSaves()
            #expect(f.backend.count == 1 && tokens == 0)
            let rows = try await f.records()
            #expect(rows.filter { if case .result = $0.event.payload { true } else { false } }.count == 1)
        }
    }
    @Test func absentOrForgedCalendarReceiptCannotPersistBodyOrArtifactMetadata() async throws {
        try await withCalendarProtocol { f in
            let marker = "PRIVATE_CALENDAR_SENTINEL_" + UUID().uuidString
            let output = ToolResult(summary: marker, evidence: marker, verified: true, artifactPath: f.root.appendingPathComponent(marker).path)
            var tokens = 0
            _ = try await f.history.perform(f.call(), proposalID: f.proposal, run: f.run, validate: {},
                action: { output }, result: { $0 }, unsavedResult: { _ in Issue.record("Unexpected storage failure.") },
                settledCalendarReadResult: { _,_ in tokens += 1 })
            #expect(tokens == 0)
            let rows = try await f.records()
            for row in rows {
                if case let .result(value) = row.event.payload { #expect(value.artifacts.isEmpty && value.kind == .returnedVerified) }
            }
            // The forged body/path is not journal output metadata even without a receipt.
            let enumerator = try #require(FileManager.default.enumerator(at: f.root, includingPropertiesForKeys: [.isRegularFileKey]))
            while let file = enumerator.nextObject() as? URL {
                if (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                    let bytes = try Data(contentsOf: file)
                    #expect(bytes.range(of: Data(marker.utf8)) == nil)
                }
            }
        }
    }
    @Test func receivedDatabaseInvalidationCannotAliasANewValidatorOntoAnOldLeaf() async throws {
        try await withCalendarProtocol { f in
            let registry = CalendarReadResultSources(), call = f.call()
            let (first, _) = try await f.settled(registry)
            let firstProof = try await registry.sourceProof(call: call, result: first, run: f.run, proposalID: f.proposal, context: f.context)
            f.worker.invalidateDatabaseForTesting()
            let next = UUID(), (second, _) = try await f.settled(registry, proposal: next)
            let secondProof = try await registry.sourceProof(call: call, result: second, run: f.run, proposalID: next, context: f.context)
            #expect(first.summary == second.summary)
            let both = try #require(try ModelInputSourceProof.merging([firstProof, secondProof]))
            #expect(both.dependencyCount == 2)
            await #expect(throws: CalendarReadFailure.self) { try await firstProof.validate() }
            try await secondProof.validate()
        }
    }

}
