import Dispatch
import Foundation
import Testing
@testable import Relay
@testable import RelayJournal

@MainActor private final class SettledFilenameFixture {
    let root: URL, selected: URL, file: URL, history: AssistantConversationHistory
    let run: AssistantConversationHistory.Run, context: MultiAgentContinuation.Context
    let worker = FilenameSearchWorker()
    var grants: [ScopeGrant], live = true
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-settled-query-" + UUID().uuidString)
        selected = root.appendingPathComponent("selected", isDirectory: true)
        file = selected.appendingPathComponent("PRIVATE_needle.txt")
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        try Data("Not read by filename discovery".utf8).write(to: file)
        grants = [.init(path: selected.path)]
        context = .init(logicalTaskID: UUID(), configuration: .init(), scopeID: UUID(), sourceRevision: 0)
        run = try .init(logicalTaskID: context.logicalTaskID, cause: .newRequest)
        // The query deliberately excludes the independently mutable journal.
        history = AssistantConversationHistory(stateURL: root.appendingPathComponent("state.json"))
    }
    func call(_ id: String = "original-call") -> Relay.ToolCall {
        .init(id: id, name: "search_files", arguments: ["query": .string("needle")])
    }
    func scope(_ call: Relay.ToolCall, _ proposal: UUID) throws -> FilenameSearchExecutionScope {
        try .init(run: run, proposalID: proposal, call: call, context: context,
            currentContext: { [weak self] in self?.context }, grants: { [weak self] in self?.grants ?? [] },
            isCurrent: { [weak self] in self?.live == true })
    }
    func settled(_ call: Relay.ToolCall, _ proposal: UUID) async throws -> (ToolResult, AssistantConversationHistory.FilenameSearchSettlement) {
        let scope = try scope(call, proposal)
        var saved: AssistantConversationHistory.FilenameSearchSettlement?
        let result = try await history.perform(call, proposalID: proposal, run: run, journalEffect: .readOnly,
            validate: { try scope.validateCurrent(call: call) },
            action: { try await self.worker.search(call: call, scope: scope).result }, result: { $0 },
            unsavedResult: { _ in Issue.record("The positive saved-query fixture unexpectedly produced an unsaved result.") },
            settledFilenameSearchResult: { _, token in saved = token })
        return (result, try #require(saved))
    }
    func close() async {
        live = false; await worker.drain(); try? await history.close(); try? FileManager.default.removeItem(at: root)
    }
}

@MainActor struct FilenameSearchResultSourcesTests {
    @Test func actualSavedTokenDistributesOnceAndWireDecodingNeverRestoresTheReceipt() async throws {
        let f = try SettledFilenameFixture()
        do {
            let call = f.call(), proposal = UUID(), registry = FilenameSearchResultSources()
            let (result, token) = try await f.settled(call, proposal)
            #expect(token.sequence > 0 && token.receipt === result.filenameSearchReceipt)
            let proof = try registry.registerSettled(call: call, result: result, run: f.run,
                proposalID: proposal, context: f.context, settlement: token)
            try await proof.validate()
            _ = try registry.registerSettled(call: call, result: result, run: f.run,
                proposalID: proposal, context: f.context, settlement: token)
            #expect(registry.retainedCount == 1)
            let encoded = try JSONEncoder().encode(result)
            let decoded = try JSONDecoder().decode(ToolResult.self, from: encoded)
            #expect(decoded.filenameSearchReceipt == nil && decoded.fileExtractionReceipt == nil)
            #expect(decoded.summary.utf8.elementsEqual(result.summary.utf8))
            #expect(!String(decoding: encoded, as: UTF8.self).contains("filenameSearchReceipt"))
            #expect(throws: FilenameSearchWorker.Failure.self) {
                _ = try registry.registerSettled(call: call, result: decoded, run: f.run,
                    proposalID: proposal, context: f.context, settlement: token)
            }
            let receipt = try #require(result.filenameSearchReceipt)
            #expect(throws: FilenameSearchWorker.Failure.self) {
                _ = try receipt.consume(call: call, result: result, run: f.run, proposalID: proposal,
                    context: f.context, settlement: token)
            }
            await f.close()
        } catch { await f.close(); throw error }
    }

    @Test func boundedRegistryEvictionDoesNotResetConsumptionOrCapLaterAcceptedQueries() async throws {
        let f = try SettledFilenameFixture()
        do {
            let registry = FilenameSearchResultSources(capacity: 1), call = f.call(), proposal = UUID()
            let (first, token) = try await f.settled(call, proposal)
            let firstProof = try registry.registerSettled(call: call, result: first, run: f.run,
                proposalID: proposal, context: f.context, settlement: token)
            var latest = firstProof
            for _ in 0..<34 {
                // Different app-owned accepted replies may reuse a provider ID.
                let proposal = UUID(), (result, saved) = try await f.settled(call, proposal)
                latest = try registry.registerSettled(call: call, result: result, run: f.run,
                    proposalID: proposal, context: f.context, settlement: saved)
                try await latest.validate(); #expect(registry.retainedCount == 1)
            }
            let merged = try #require(try ModelInputSourceProof.merging([firstProof, latest]))
            #expect(merged.dependencyCount == 1, "Stable actual query/source identity is independent of proposal count.")
            #expect(throws: FilenameSearchWorker.Failure.self) {
                _ = try registry.registerSettled(call: call, result: first, run: f.run,
                    proposalID: proposal, context: f.context, settlement: token)
            }
            registry.reset()
            #expect(throws: FilenameSearchWorker.Failure.self) {
                _ = try registry.registerSettled(call: call, result: first, run: f.run,
                    proposalID: proposal, context: f.context, settlement: token)
            }
            let core = try await f.history.journalForTesting(), scope = try await core.scope()
            let page = try await core.page(expectedScope: scope)
            #expect(page.records.filter { if case .intent = $0.event.payload { true } else { false } }.count == 35)
            #expect(page.records.filter { if case .result = $0.event.payload { true } else { false } }.count == 35)
            await f.close()
        } catch { await f.close(); throw error }
    }

    @Test func currentCrossRoleProjectionUsesActualReceiptAndOmitsChangedQueryBodies() async throws {
        let f = try SettledFilenameFixture()
        do {
            let registry = FilenameSearchResultSources(), call = f.call(), proposal = UUID()
            let (result, token) = try await f.settled(call, proposal)
            _ = try registry.registerSettled(call: call, result: result, run: f.run,
                proposalID: proposal, context: f.context, settlement: token)
            let context = NativeCurrentModelContext(admission: { call, proposal, result in
                try await registry.sourceProof(call: call, result: result, run: f.run, proposalID: proposal, context: f.context)
            }, gate: { guard f.live else { throw CancellationError() } })
            let handle = context.record(call: call, acceptedProposalID: proposal, result: result, inputProof: nil)
            let original = try await context.prepare([handle], maximumBytes: 4_000)
            #expect(original.included == 1 && original.omitted == 0 && original.text.contains("PRIVATE_needle.txt"))
            try await original.validate()
            try FileManager.default.moveItem(at: f.file, to: f.selected.appendingPathComponent("CHANGED_needle.txt"))
            await #expect(throws: (any Error).self) { try await original.validate() }
            let changed = try await context.prepare([handle], maximumBytes: 4_000)
            #expect(changed.included == 0 && changed.omitted == 1 && !changed.text.contains("PRIVATE_needle.txt"))
            await f.close()
        } catch { await f.close(); throw error }
    }

    @Test func anEqualBodyFromAnotherActualReceiptCannotBorrowTheSavedToken() async throws {
        let f = try SettledFilenameFixture()
        do {
            let call = f.call(), firstProposal = UUID(), secondProposal = UUID()
            let (first, firstToken) = try await f.settled(call, firstProposal)
            let (second, secondToken) = try await f.settled(call, secondProposal)
            #expect(first.summary.utf8.elementsEqual(second.summary.utf8))
            #expect(first.filenameSearchReceipt !== second.filenameSearchReceipt)
            let registry = FilenameSearchResultSources()
            #expect(throws: FilenameSearchWorker.Failure.self) {
                _ = try registry.registerSettled(call: call, result: second, run: f.run,
                    proposalID: firstProposal, context: f.context, settlement: firstToken)
            }
            let proof = try registry.registerSettled(call: call, result: second, run: f.run,
                proposalID: secondProposal, context: f.context, settlement: secondToken)
            try await proof.validate()
            #expect(registry.retainedCount == 1)
            await f.close()
        } catch { await f.close(); throw error }
    }

    @Test func resetDuringActualQueryRevalidationCannotReleaseItsOldProjection() async throws {
        let f = try SettledFilenameFixture(), barrier = SearchDistributionBarrier()
        do {
            let registry = FilenameSearchResultSources(), call = f.call(), proposal = UUID()
            let (result, token) = try await f.settled(call, proposal)
            _ = try registry.registerSettled(call: call, result: result, run: f.run,
                proposalID: proposal, context: f.context, settlement: token)
            f.worker.pauseAfterNextTraversal { barrier.pause() }
            var published = 0
            let pending = Task { @MainActor in
                _ = try await registry.sourceProof(call: call, result: result, run: f.run, proposalID: proposal, context: f.context)
                published += 1
            }
            try await wait(barrier)
            registry.reset(); barrier.release()
            await #expect(throws: (any Error).self) { try await pending.value }
            #expect(published == 0 && registry.retainedCount == 0 && f.live)
            await f.close()
        } catch { barrier.release(); await f.close(); throw error }
    }

    @Test(arguments: [JournalFault.beforeCommit, .afterCommit])
    func resultSaveFailureAndRepairNeverMintASettledTokenOrRerunTheQuery(_ fault: JournalFault) async throws {
        let f = try SettledFilenameFixture()
        do {
            let core = try await f.history.journalForTesting(), call = f.call(), proposal = UUID()
            await core.injectResultFault(fault, forToolName: "search_files")
            let scope = try f.scope(call, proposal)
            var queries = 0, tokens = 0, unsaved = 0
            await #expect(throws: (any Error).self) {
                _ = try await f.history.perform(call, proposalID: proposal, run: f.run, journalEffect: .readOnly,
                    validate: { try scope.validateCurrent(call: call) }, action: {
                        queries += 1; return try await f.worker.search(call: call, scope: scope).result
                    }, result: { $0 }, unsavedResult: { observed in
                        unsaved += 1
                        #expect(observed.verified && observed.filenameSearchReceipt != nil)
                    }, settledFilenameSearchResult: { _,_ in tokens += 1 })
            }
            #expect(queries == 1 && tokens == 0 && unsaved == 1)
            try await f.history.retryResultSaves()
            #expect(queries == 1 && tokens == 0 && unsaved == 1)
            let journalScope = try await core.scope(), page = try await core.page(expectedScope: journalScope)
            #expect(page.records.filter { if case .intent = $0.event.payload { true } else { false } }.count == 1)
            #expect(page.records.filter { if case .result = $0.event.payload { true } else { false } }.count == 1)
            await f.close()
        } catch { await f.close(); throw error }
    }

    private func wait(_ barrier: SearchDistributionBarrier) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(4))
        while !barrier.entered { try #require(ContinuousClock.now < end); try await Task.sleep(for: .milliseconds(2)) }
    }
}

nonisolated private final class SearchDistributionBarrier: @unchecked Sendable {
    private let lock = NSLock(), semaphore = DispatchSemaphore(value: 0)
    private var started = false, released = false
    var entered: Bool { lock.withLock { started } }
    func pause() { lock.withLock { started = true }; _ = semaphore.wait(timeout: .now() + 6) }
    func release() { let signal = lock.withLock { let value = !released; released = true; return value }; if signal { semaphore.signal() } }
}
