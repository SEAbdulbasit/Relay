import Testing
import Foundation
import SQLite3
import Darwin
@testable import RelayJournal

@Suite(.serialized) struct JournalAdditionalFaultTests {
    @Test func sameProviderIDReadThenWriteAcrossDistinctAcceptedRepliesIsValid() async throws {
        let root = temporaryJournal(); defer { cleanup(root) }
        let journal = try await ConversationJournal.open(directory: root), scope = try await journal.scope()
        let (task, attempt) = try await start(journal, scope: scope)
        let readProposal = UUID(), writeProposal = UUID(), providerID = try JournalOpaqueID("reused-provider-ID")
        let read = try JournalIntent(proposalID: readProposal, producerEpoch: journal.producerEpoch, toolCallID: providerID, toolName: "owned_read", callDigest: Data(repeating: 1, count: 32), effect: .readOnly)
        let readEvent = JournalEvent(id: try JournalOpaqueID("read"), taskID: task, attemptID: attempt, payload: .intent(read))
        guard case .inserted = try await journal.commitIntent(readEvent, expectedScope: scope) else { throw JournalError.invalidTransition }
        _ = try await journal.commitResult(resultEvent(readEvent), expectedScope: scope)
        let write = try JournalIntent(proposalID: writeProposal, producerEpoch: journal.producerEpoch, toolCallID: providerID, toolName: "owned_write", callDigest: Data(repeating: 2, count: 32), effect: .mutation)
        let writeEvent = JournalEvent(id: try JournalOpaqueID("write"), taskID: task, attemptID: attempt, payload: .intent(write))
        guard case .inserted = try await journal.commitIntent(writeEvent, expectedScope: scope) else { throw JournalError.invalidTransition }
        _ = try await journal.commitResult(resultEvent(writeEvent), expectedScope: scope)
        let retry = try JournalIntent(proposalID: writeProposal, producerEpoch: journal.producerEpoch, toolCallID: providerID, toolName: write.toolName, callDigest: write.callDigest, effect: write.effect)
        let duplicate = JournalEvent(id: try JournalOpaqueID("new-invocation-same-proposal"), taskID: task, attemptID: attempt, payload: .intent(retry))
        guard case .alreadyRecorded = try await journal.commitIntent(duplicate, expectedScope: scope) else { Issue.record("Same accepted proposal reminted eligibility"); return }
        #expect(try await journal.page(expectedScope: scope).records.count == 6)
        try await journal.close()
    }
    @Test(arguments: [false, true]) func changedCallIdentityConflictsBeforeAndAfterSettlement(_ settled: Bool) async throws {
        let root = temporaryJournal(); defer { cleanup(root) }
        let journal = try await ConversationJournal.open(directory: root), scope = try await journal.scope()
        let (task, attempt) = try await start(journal, scope: scope), event = try intentEvent(journal, task: task, attempt: attempt, callID: "cafe\u{301}")
        _ = try await journal.commitIntent(event, expectedScope: scope)
        if settled { _ = try await journal.commitResult(resultEvent(event), expectedScope: scope) }
        guard case let .intent(original) = event.payload else { throw JournalError.invalidEvent }
        for changed in 0..<3 {
            let value = try JournalIntent(proposalID: task, producerEpoch: journal.producerEpoch, toolCallID: original.toolCallID,
                toolName: changed == 0 ? "other_action" : original.toolName,
                callDigest: changed == 1 ? Data(repeating: 9, count: 32) : original.callDigest,
                effect: changed == 2 ? .readOnly : original.effect)
            let duplicate = JournalEvent(id: try JournalOpaqueID(UUID().uuidString), taskID: task, attemptID: attempt, payload: .intent(value))
            await assertFailure(.conflictingID) { _ = try await journal.commitIntent(duplicate, expectedScope: scope) }
        }
        #expect(try await journal.page(expectedScope: scope).records.count == (settled ? 4 : 3))
        try await journal.close()
    }
    @Test func pendingDuplicateCallIDAndWrongResultDigestRefuse() async throws {
        let root = temporaryJournal(); defer { cleanup(root) }
        let journal = try await ConversationJournal.open(directory: root), scope = try await journal.scope()
        let (task, attempt) = try await start(journal, scope: scope)
        let event = try intentEvent(journal, task: task, attempt: attempt, callID: "café")
        _ = try await journal.commitIntent(event, expectedScope: scope)
        guard case .alreadyRecorded = try await journal.commitIntent(intentEvent(journal, task: task, attempt: attempt, callID: "café"), expectedScope: scope) else { Issue.record("Pending call ID reminted eligibility"); return }
        guard case let .intent(original) = event.payload else { throw JournalError.invalidEvent }
        let changed = try JournalIntent(invocationID: original.invocationID, proposalID: original.proposalID, producerEpoch: journal.producerEpoch, toolCallID: JournalOpaqueID("cafe\u{301}"), toolName: original.toolName, callDigest: journalDigest(Data("cafe\u{301}".utf8)), effect: .mutation)
        let forged = JournalEvent(id: try JournalOpaqueID("forged-result"), taskID: task, attemptID: attempt, payload: .result(JournalToolOutcome(intent: changed, kind: .returnedVerified)))
        await assertFailure(.invalidTransition) { _ = try await journal.commitResult(forged, expectedScope: scope) }
        #expect(try await journal.page(expectedScope: scope).records.count == 3)
        try await journal.close()
    }
    @Test func liveLateResultDoesNotReopenStoppedTask() async throws {
        let root = temporaryJournal(); defer { cleanup(root) }
        let journal = try await ConversationJournal.open(directory: root), scope = try await journal.scope()
        let (task, attempt) = try await start(journal, scope: scope), event = try intentEvent(journal, task: task, attempt: attempt)
        _ = try await journal.commitIntent(event, expectedScope: scope)
        _ = try await journal.finishTask(JournalEvent(id: JournalOpaqueID("stopped"), taskID: task, attemptID: attempt, payload: .finished(.stopped)), expectedScope: scope)
        _ = try await journal.commitResult(resultEvent(event, id: "late"), expectedScope: scope)
        await assertFailure(.invalidTransition) { _ = try await journal.finishTask(JournalEvent(id: JournalOpaqueID("reopen"), taskID: task, attemptID: attempt, payload: .finished(.success)), expectedScope: scope) }
        var projection = JournalProjection(); try projection.apply(try await journal.page(expectedScope: scope).records)
        #expect(projection.taskOutcomes[task] == .stopped)
        try await journal.close()
    }
    @Test func newProducerCannotSaveAnInventedOldResult() async throws {
        let root = temporaryJournal(); defer { cleanup(root) }
        let journal = try await ConversationJournal.open(directory: root), scope = try await journal.scope()
        let (task, attempt) = try await start(journal, scope: scope), event = try intentEvent(journal, task: task, attempt: attempt)
        _ = try await journal.commitIntent(event, expectedScope: scope); try await journal.close()
        let reopened = try await ConversationJournal.open(directory: root)
        await assertFailure(.invalidTransition) { _ = try await reopened.commitResult(resultEvent(event), expectedScope: scope) }
        let result = try await reopened.recoverInterrupted(expectedScope: scope)
        #expect(result.count == 1); #expect(result[0].event.payload == .finished(.interrupted))
        try await reopened.close()
    }
    @Test func recoveryDoesNotInterruptCurrentProducer() async throws {
        let root = temporaryJournal(); defer { cleanup(root) }
        let journal = try await ConversationJournal.open(directory: root), scope = try await journal.scope()
        _ = try await start(journal, scope: scope)
        #expect(try await journal.recoverInterrupted(expectedScope: scope).isEmpty)
        try await journal.close()
    }
    @Test func heldReaderPinsWALAndGrowthRefusesTruthfully() async throws {
        let root = temporaryJournal(); defer { cleanup(root) }
        var limits = JournalLimits(); limits.walThresholdBytes = 4096
        let journal = try await ConversationJournal.open(directory: root, limits: limits), scope = try await journal.scope()
        let (task, attempt) = try await start(journal, scope: scope)
        let other = try JournalSQLite(path: canonicalJournalDirectory(root) + "/Conversation.sqlite")
        try other.execute("BEGIN"); _ = try other.integer("SELECT COUNT(*) FROM events")
        let text = try JournalVisibleText(String(repeating: "read-pinned", count: 2000), origin: .assistant)
        let first = JournalEvent(id: try JournalOpaqueID("first-large"), taskID: task, attemptID: attempt, payload: .assistant(text))
        _ = try await journal.appendBatch([first], expectedScope: scope)
        let second = JournalEvent(id: try JournalOpaqueID("second-large"), taskID: task, attemptID: attempt, payload: .assistant(text))
        await assertFailure(.tooLarge) { _ = try await journal.appendBatch([second], expectedScope: scope) }
        #expect(try await journal.page(expectedScope: scope).records.count == 3)
        try other.execute("ROLLBACK"); try other.close()
        _ = try await journal.appendBatch([second], expectedScope: scope)
        #expect(try await journal.page(expectedScope: scope).records.count == 4)
        try await journal.close()
    }
    @Test func corruptOversizedStoredPayloadRefusesBeforeDecode() async throws {
        let root = temporaryJournal(); defer { cleanup(root) }
        let journal = try await ConversationJournal.open(directory: root), scope = try await journal.scope()
        _ = try await start(journal, scope: scope)
        let other = try JournalSQLite(path: canonicalJournalDirectory(root) + "/Conversation.sqlite")
        try other.execute("PRAGMA ignore_check_constraints=ON")
        try other.execute("UPDATE events SET payload=zeroblob(262145) WHERE kind=1")
        await assertFailure(.corrupt) { _ = try await journal.page(expectedScope: scope) }
        try other.close(); try await journal.close()
    }
    @Test func nonemptyACLAndRootSymlinkAreRejected() async throws {
        let root = temporaryJournal(), alias = temporaryJournal(); defer { cleanup(alias); cleanup(root) }
        let journal = try await ConversationJournal.open(directory: root); try await journal.close()
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        await assertFailure(.unsafeLocation) { _ = try await ConversationJournal.open(directory: alias) }
        let chmod = Process(); chmod.executableURL = URL(fileURLWithPath: "/bin/chmod"); chmod.arguments = ["+a", "everyone allow read", root.path]
        chmod.standardOutput = FileHandle.nullDevice; chmod.standardError = FileHandle.nullDevice
        try chmod.run(); chmod.waitUntilExit(); #expect(chmod.terminationStatus == 0)
        await assertFailure(.unsafeLocation) { _ = try await ConversationJournal.open(directory: root) }
    }
    @Test func inconsistentOperationalIndexRefusesEvenWhenPayloadHashMatches() async throws {
        let root = temporaryJournal(); defer { cleanup(root) }
        let journal = try await ConversationJournal.open(directory: root), scope = try await journal.scope()
        let (task, attempt) = try await start(journal, scope: scope), event = try intentEvent(journal, task: task, attempt: attempt)
        _ = try await journal.commitIntent(event, expectedScope: scope)
        _ = try await journal.commitResult(resultEvent(event), expectedScope: scope)
        let other = try JournalSQLite(path: canonicalJournalDirectory(root) + "/Conversation.sqlite")
        try other.execute("UPDATE intents SET tool_call_id=?", [.blob(Data("different opaque ID".utf8))])
        // Starting after the intent still validates the result's original intent relationship.
        let cursor = JournalCursor(scope: scope, sequence: 3)
        await assertFailure(.corrupt) { _ = try await journal.page(after: cursor, expectedScope: scope) }
        try other.close(); try await journal.close()
    }
}

@Suite(.serialized) @MainActor struct JournalStopFaultTests {
    @Test func moreThan1024UniqueDispatchesHaveNoInvocationCountCutoff() async throws {
        let root = temporaryJournal(); defer { cleanup(root) }
        let journal = try await ConversationJournal.open(directory: root), scope = try await journal.scope()
        let (task, attempt) = try await start(journal, scope: scope)
        let checkpoint = JournalDispatchCheckpoint(journal: journal); var dispatches = 0
        for index in 0..<1030 {
            let event = try intentEvent(journal, task: task, attempt: attempt, callID: "call-\(index)")
            guard case let .intent(intent) = event.payload else { throw JournalError.invalidEvent }
            _ = try await checkpoint.execute(event, expectedScope: scope, validate: {}, action: { dispatches += 1; return JournalToolOutcome(intent: intent, kind: .returnedVerified) })
        }
        #expect(dispatches == 1030); #expect(checkpoint.pendingResultCount == 0)
        var count = 0, cursor: JournalCursor?
        repeat {
            let page = try await journal.page(after: cursor, limit: 500, expectedScope: scope)
            count += page.records.count; cursor = page.hasLater ? page.cursor : nil
        } while cursor != nil
        #expect(count == 2062)
        try await journal.close()
    }
    @Test func lostAcknowledgmentCannotRemintWithNewInvocationAndEventID() async throws {
        let root = temporaryJournal(); defer { cleanup(root) }
        let journal = try await ConversationJournal.open(directory: root), scope = try await journal.scope()
        let (task, attempt) = try await start(journal, scope: scope), event = try intentEvent(journal, task: task, attempt: attempt, callID: "stable-call")
        guard case let .intent(intent) = event.payload else { throw JournalError.invalidEvent }
        let checkpoint = JournalDispatchCheckpoint(journal: journal); var dispatches = 0
        await journal.injectFault(.afterCommit)
        await assertFailure(.acknowledgmentLost) { _ = try await checkpoint.execute(event, expectedScope: scope, validate: {}, action: { dispatches += 1; return JournalToolOutcome(intent: intent, kind: .returnedVerified) }) }
        let reminted = try intentEvent(journal, task: task, attempt: attempt, callID: "stable-call")
        await assertFailure(.duplicateIntent) { _ = try await checkpoint.execute(reminted, expectedScope: scope, validate: {}, action: { dispatches += 1; return JournalToolOutcome(intent: intent, kind: .returnedVerified) }) }
        #expect(dispatches == 0); #expect(try await journal.page(expectedScope: scope).records.count == 3)
        try await journal.close()
    }
    @Test func stopWhileCommitAwaitsBlocksDispatchAndSavesKnownNonDispatch() async throws {
        let root = temporaryJournal(); defer { cleanup(root) }
        let journal = try await ConversationJournal.open(directory: root), scope = try await journal.scope()
        let (task, attempt) = try await start(journal, scope: scope), event = try intentEvent(journal, task: task, attempt: attempt)
        guard case let .intent(intent) = event.payload else { throw JournalError.invalidEvent }
        let checkpoint = JournalDispatchCheckpoint(journal: journal)
        let other = try JournalSQLite(path: canonicalJournalDirectory(root) + "/Conversation.sqlite")
        try other.execute("BEGIN IMMEDIATE")
        var began = false, dispatches = 0
        let run = Task { try await checkpoint.execute(event, expectedScope: scope, validate: { began = true }, action: { dispatches += 1; return JournalToolOutcome(intent: intent, kind: .returnedVerified) }) }
        while !began { await Task.yield() }
        checkpoint.stop(); try other.execute("ROLLBACK"); try other.close()
        await assertFailure(.dispatchRevoked) { _ = try await run.value }
        #expect(dispatches == 0)
        guard case let .result(outcome) = try await journal.page(expectedScope: scope).records.last?.event.payload else { Issue.record("Missing checkpoint"); return }
        #expect(outcome.kind == .notDispatched)
        try await journal.close()
    }
    @Test func stopAfterAdmissionKeepsFactualResultButNeverNewActions() async throws {
        let root = temporaryJournal(); defer { cleanup(root) }
        let journal = try await ConversationJournal.open(directory: root), scope = try await journal.scope()
        let (task, attempt) = try await start(journal, scope: scope), event = try intentEvent(journal, task: task, attempt: attempt)
        guard case let .intent(intent) = event.payload else { throw JournalError.invalidEvent }
        let checkpoint = JournalDispatchCheckpoint(journal: journal); var dispatches = 0
        let result = try await checkpoint.execute(event, expectedScope: scope, validate: {}, action: {
            dispatches += 1; checkpoint.stop(); return JournalToolOutcome(intent: intent, kind: .returnedVerified)
        })
        #expect(result.event.payload == .result(JournalToolOutcome(intent: intent, kind: .returnedVerified)))
        let newEvent = try intentEvent(journal, task: task, attempt: attempt)
        await assertFailure(.dispatchRevoked) { _ = try await checkpoint.execute(newEvent, expectedScope: scope, validate: {}, action: { dispatches += 1; return JournalToolOutcome(intent: intent, kind: .returnedVerified) }) }
        #expect(dispatches == 1); #expect(try await journal.page(expectedScope: scope).records.count == 4)
        try await journal.close()
    }
    @Test func concurrentExecutionCannotInterleaveAnotherIntent() async throws {
        let root = temporaryJournal(); defer { cleanup(root) }
        let journal = try await ConversationJournal.open(directory: root), scope = try await journal.scope()
        let (task, attempt) = try await start(journal, scope: scope), event = try intentEvent(journal, task: task, attempt: attempt)
        guard case let .intent(intent) = event.payload else { throw JournalError.invalidEvent }
        let checkpoint = JournalDispatchCheckpoint(journal: journal); var dispatches = 0
        _ = try await checkpoint.execute(event, expectedScope: scope, validate: {}, action: {
            let other = try intentEvent(journal, task: task, attempt: attempt)
            await assertFailure(.pendingResult) { _ = try await checkpoint.execute(other, expectedScope: scope, validate: {}, action: { dispatches += 1; return JournalToolOutcome(intent: intent, kind: .returnedVerified) }) }
            dispatches += 1; return JournalToolOutcome(intent: intent, kind: .returnedVerified)
        })
        #expect(dispatches == 1); #expect(try await journal.page(expectedScope: scope).records.count == 4)
        try await journal.close()
    }
}
