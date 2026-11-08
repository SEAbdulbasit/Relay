import Dispatch
import Foundation
import Testing
@testable import Relay
@testable import RelayJournal

nonisolated private final class SettledReadBarrier: @unchecked Sendable {
    private let lock = NSLock(), semaphore = DispatchSemaphore(value: 0)
    private var started = false, released = false
    var entered: Bool { lock.withLock { started } }
    func pause() { lock.withLock { started = true }; semaphore.wait() }
    func release() { let signal = lock.withLock { let value = !released; released = true; return value }; if signal { semaphore.signal() } }
}

@MainActor private final class SettledFileFixture {
    let root: URL, file: URL
    let history: AssistantConversationHistory, run: AssistantConversationHistory.Run
    let worker = FileExtractionWorker(extractionTimeout: .seconds(5), validationTimeout: .seconds(5))
    let context: MultiAgentContinuation.Context
    var grants: [ScopeGrant]
    var live = true
    init() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "relay-settled-extraction-" + UUID().uuidString)
        let selected = folder.appending(path: "source.eml"), task = UUID()
        root = folder; file = selected
        history = AssistantConversationHistory(stateURL: folder.appending(path: "state.json"))
        run = try .init(logicalTaskID: task, cause: .newRequest)
        context = .init(logicalTaskID: task, configuration: .init(), scopeID: UUID(), sourceRevision: 0)
        grants = [.init(path: folder.path)]
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            try Data("Subject: OWNED\r\nContent-Type: text/plain\r\n\r\nACTUAL_PRIVATE_BODY\r\n".utf8).write(to: selected)
        } catch { try? FileManager.default.removeItem(at: folder); throw error }
    }
    func call(_ id: String = "actual-caf\u{00e9}") -> Relay.ToolCall {
        .init(id: id, name: "read_file", arguments: ["path": .string(file.path)])
    }
    func scope(_ call: Relay.ToolCall, proposal: UUID) throws -> FileReadExecutionScope {
        try .init(run: run, proposalID: proposal, call: call, context: context,
            currentContext: { [weak self] in self?.context }, grants: { [weak self] in self?.grants ?? [] },
            isCurrent: { [weak self] in self?.live == true })
    }
    func actualSettled(_ call: Relay.ToolCall, proposal: UUID, registry: FileReadResultSources)
        async throws -> (ToolResult, AssistantConversationHistory.FileReadSettlement) {
        let scope = try scope(call, proposal: proposal)
        var saved: AssistantConversationHistory.FileReadSettlement?, registrationError: (any Error)?
        let output = try await history.perform(call, proposalID: proposal, run: run,
            validate: { try scope.validateCurrent(call: call) },
            action: { try await self.worker.extract(call: call, grants: self.grants, scope: scope) }, result: { $0 },
            unsavedResult: { _ in Issue.record("The success fixture unexpectedly failed result storage.") },
            settledFileResult: { output, token in
                saved = token
                do { try registry.registerSettled(call: call, result: output, run: self.run,
                    proposalID: proposal, context: self.context, settlement: token) }
                catch { registrationError = error }
            })
        if let registrationError { throw registrationError }
        return (output, try #require(saved))
    }
}
@MainActor private func withSettledFile(_ body: @MainActor (SettledFileFixture) async throws -> Void) async throws {
    let fixture = try SettledFileFixture()
    do {
        try await body(fixture); fixture.live = false; await fixture.worker.drain()
        try await fixture.history.close(); try FileManager.default.removeItem(at: fixture.root)
    } catch {
        fixture.live = false; await fixture.worker.drain(); try? await fixture.history.close()
        try? FileManager.default.removeItem(at: fixture.root); throw error
    }
}
@MainActor private func settledRecords(_ history: AssistantConversationHistory) async throws -> [JournalRecord] {
    let journal = try await history.journalForTesting(), scope = try await journal.scope()
    var records: [JournalRecord] = [], cursor: JournalCursor?
    repeat {
        let page = try await journal.page(after: cursor, expectedScope: scope)
        records += page.records; cursor = page.hasLater ? page.cursor : nil
    } while cursor != nil
    return records
}
@MainActor private func refusesFileSource(_ body: @MainActor () async throws -> Void) async {
    do { try await body(); Issue.record("An unavailable or foreign file capability admitted private data.") }
    catch { #expect(error is FileExtractionWorker.Failure || error is CancellationError) }
}

@Suite(.serialized) @MainActor struct FileReadResultSourcesTests {
    @Test func actualSQLiteSettledResultCanBeIncludedManyTimesWithoutASecondConsumeOrReadProposal() async throws {
        try await withSettledFile { f in
            let registry = FileReadResultSources(), call = f.call(), proposal = UUID()
            let (result, settlement) = try await f.actualSettled(call, proposal: proposal, registry: registry)
            for _ in 0..<12 {
                let proof = try await registry.sourceProof(call: call, result: result, run: f.run,
                    proposalID: proposal, context: f.context)
                #expect(proof.dependencyCount == 1); try await proof.validate()
            }
            try registry.registerSettled(call: call, result: result, run: f.run,
                proposalID: proposal, context: f.context, settlement: settlement)
            await refusesFileSource { _ = try #require(result.fileExtractionReceipt).consume(call: call, result: result,
                run: f.run, proposalID: proposal, context: f.context) }
            let records = try await settledRecords(f.history)
            #expect(registry.retainedCount == 1)
            #expect(records.filter { if case .intent = $0.event.payload { true } else { false } }.count == 1)
            #expect(records.filter { if case .result = $0.event.payload { true } else { false } }.count == 1)
        }
    }

    @Test func exactObjectNamespaceAndSettlementAreRequiredEvenForIdenticalBodyBytes() async throws {
        try await withSettledFile { f in
            let registry = FileReadResultSources(), call = f.call(), proposal = UUID()
            let (result, settlement) = try await f.actualSettled(call, proposal: proposal, registry: registry)
            var equivalentID = call; equivalentID.id = "actual-cafe\u{0301}"
            await refusesFileSource { _ = try await registry.sourceProof(call: equivalentID, result: result, run: f.run,
                proposalID: proposal, context: f.context) }
            await refusesFileSource { _ = try await registry.sourceProof(call: call, result: result, run: f.run,
                proposalID: UUID(), context: f.context) }
            let otherRun = try AssistantConversationHistory.Run(logicalTaskID: f.context.logicalTaskID, cause: .newRequest)
            await refusesFileSource { _ = try await registry.sourceProof(call: call, result: result, run: otherRun,
                proposalID: proposal, context: f.context) }
            let foreign = try await f.worker.extract(call: call, grants: f.grants, scope: f.scope(call, proposal: proposal))
            #expect(foreign.summary == result.summary && foreign.fileExtractionReceipt !== result.fileExtractionReceipt)
            await refusesFileSource { _ = try registry.registerSettled(call: call, result: foreign, run: f.run,
                proposalID: proposal, context: f.context, settlement: settlement) }
            await refusesFileSource { _ = try await registry.sourceProof(call: call, result: foreign, run: f.run,
                proposalID: proposal, context: f.context) }
            let restored = try JSONDecoder().decode(ToolResult.self, from: JSONEncoder().encode(result))
            await refusesFileSource { _ = try await registry.sourceProof(call: call, result: restored, run: f.run,
                proposalID: proposal, context: f.context) }
            var changed = result; changed.evidence += "changed"
            await refusesFileSource { _ = try await registry.sourceProof(call: call, result: changed, run: f.run,
                proposalID: proposal, context: f.context) }
            #expect(registry.retainedCount == 1)
        }
    }

    @Test func evictionCannotReconsumeOrRestoreOldDataAndDoesNotStopLaterProposals() async throws {
        try await withSettledFile { f in
            let registry = FileReadResultSources(capacity: 1), a = f.call("first"), pa = UUID()
            let (first, token) = try await f.actualSettled(a, proposal: pa, registry: registry)
            for index in 0..<34 {
                let call = f.call("next-\(index)"), proposal = UUID()
                let (result, _) = try await f.actualSettled(call, proposal: proposal, registry: registry)
                _ = try await registry.sourceProof(call: call, result: result, run: f.run,
                    proposalID: proposal, context: f.context)
                #expect(registry.retainedCount == 1)
            }
            await refusesFileSource { _ = try await registry.sourceProof(call: a, result: first, run: f.run,
                proposalID: pa, context: f.context) }
            await refusesFileSource { _ = try registry.registerSettled(call: a, result: first, run: f.run,
                proposalID: pa, context: f.context, settlement: token) }
            let records = try await settledRecords(f.history)
            #expect(records.filter { if case .intent = $0.event.payload { true } else { false } }.count == 35)
            #expect(records.filter { if case .result = $0.event.payload { true } else { false } }.count == 35)
            #expect(first.summary.contains("ACTUAL_PRIVATE_BODY"), "Known factual UI output remains available separately.")
        }
    }

    @Test func sourceDriftRefusesRepeatedInclusionWithoutLosingTheSavedFactualRead() async throws {
        try await withSettledFile { f in
            let registry = FileReadResultSources(), call = f.call(), proposal = UUID()
            let (result, _) = try await f.actualSettled(call, proposal: proposal, registry: registry)
            _ = try await registry.sourceProof(call: call, result: result, run: f.run, proposalID: proposal, context: f.context)
            try Data("Subject: OTHER\r\nContent-Type: text/plain\r\n\r\nCHANGED_PRIVATE_BODY\r\n".utf8).write(to: f.file)
            await refusesFileSource { _ = try await registry.sourceProof(call: call, result: result, run: f.run,
                proposalID: proposal, context: f.context) }
            #expect(result.summary.contains("ACTUAL_PRIVATE_BODY"))
            let records = try await settledRecords(f.history)
            #expect(records.filter { if case .intent = $0.event.payload { true } else { false } }.count == 1)
        }
    }

    @Test func registryResetDuringRealRevalidationCannotPublishAnOldProjectionEvenWhenTheFileIsUnchanged() async throws {
        try await withSettledFile { f in
            let registry = FileReadResultSources(), call = f.call(), proposal = UUID(), barrier = SettledReadBarrier()
            let (result, _) = try await f.actualSettled(call, proposal: proposal, registry: registry)
            let bytes = try Data(contentsOf: f.file)
            f.worker.pauseAfterNextSnapshot { barrier.pause() }
            var privateSends = 0
            let pending = Task { @MainActor in
                _ = try await registry.sourceProof(call: call, result: result, run: f.run, proposalID: proposal, context: f.context)
                privateSends += 1
            }
            do {
                let end = ContinuousClock.now.advanced(by: .seconds(4))
                while !barrier.entered { try #require(ContinuousClock.now < end); try await Task.sleep(for: .milliseconds(2)) }
                registry.reset(); barrier.release()
                await refusesFileSource { try await pending.value }
                #expect(privateSends == 0 && registry.retainedCount == 0 && f.live)
                #expect(try Data(contentsOf: f.file) == bytes)
                await f.worker.drain(); #expect(f.worker.activeCount == 0)
            } catch {
                pending.cancel(); barrier.release(); _ = await pending.result; await f.worker.drain(); throw error
            }
        }
    }

    @Test(arguments: [JournalFault.beforeCommit, .afterCommit])
    func lostResultAcknowledgmentAndStorageOnlyRepairNeverMintASettledSourceToken(_ fault: JournalFault) async throws {
        try await withSettledFile { f in
            let registry = FileReadResultSources(), call = f.call(), proposal = UUID()
            let journal = try await f.history.journalForTesting(), scope = try f.scope(call, proposal: proposal)
            var factual: ToolResult?, reads = 0, tokens = 0
            do {
                _ = try await f.history.perform(call, proposalID: proposal, run: f.run, validate: {}, action: {
                    reads += 1
                    let actual = try await f.worker.extract(call: call, grants: f.grants, scope: scope)
                    await journal.injectFault(fault)
                    return actual
                }, result: { $0 }, unsavedResult: { factual = $0 }, settledFileResult: { _,_ in tokens += 1 })
                Issue.record("The real result checkpoint fault did not occur.")
            } catch let failure as JournalError {
                switch fault {
                case .beforeCommit: #expect(failure == .injectedBeforeCommit)
                case .afterCommit: #expect(failure == .acknowledgmentLost)
                }
            }
            let actual = try #require(factual)
            #expect(tokens == 0 && reads == 1 && registry.retainedCount == 0)
            await refusesFileSource { _ = try await registry.sourceProof(call: call, result: actual, run: f.run,
                proposalID: proposal, context: f.context) }
            try await f.history.retryResultSaves()
            await refusesFileSource { _ = try await registry.sourceProof(call: call, result: actual, run: f.run,
                proposalID: proposal, context: f.context) }
            let records = try await settledRecords(f.history)
            #expect(reads == 1 && tokens == 0 && actual.summary.contains("ACTUAL_PRIVATE_BODY"))
            #expect(records.filter { if case .intent = $0.event.payload { true } else { false } }.count == 1)
            #expect(records.filter { if case .result = $0.event.payload { true } else { false } }.count == 1)
        }
    }
}
