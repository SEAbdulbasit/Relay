import Foundation
import Testing
@testable import RelayJournal

private final class RequireNewCommitCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func record() { lock.withLock { value += 1 } }
}

private func requiredUserBatch(_ journal: ConversationJournal, userID: JournalOpaqueID? = nil) throws -> [JournalEvent] {
    let task = UUID(), attempt = UUID()
    let selectedID: JournalOpaqueID
    if let userID { selectedID = userID } else { selectedID = try JournalOpaqueID(UUID().uuidString) }
    let start = JournalEvent(id: try JournalOpaqueID("start:" + task.uuidString), taskID: task, attemptID: attempt,
        payload: .started(producerEpoch: journal.producerEpoch, relation: try JournalRunRelation(logicalTaskID: task, cause: .newRequest)))
    let user = JournalEvent(id: selectedID, taskID: task, attemptID: attempt,
        createdAtMilliseconds: 123456, payload: .user(try JournalVisibleText("owned exact cafe\u{301} request", origin: .user)))
    return [start, user]
}

private func withRequiredUserJournal(_ body: (ConversationJournal, JournalScope) async throws -> Void) async throws {
    let root = temporaryJournal()
    var live: ConversationJournal?
    do {
        let journal = try await ConversationJournal.open(directory: root); live = journal
        let scope = try await journal.scope()
        try await body(journal, scope); try await journal.close(); cleanup(root)
    }
    catch { try? await live?.close(); cleanup(root); throw error }
}

private enum RequiredUserShape: Sendable { case missing, duplicateUser, startAlias, assistant, wrongOrigin }

@Suite(.serialized) struct JournalRequireNewUserEventTests {
    @Test func freshUserMayShareAnExistingStartAndDefaultAppendRemainsIdempotent() async throws {
        try await withRequiredUserJournal { journal, scope in
            let events = try requiredUserBatch(journal), start = try #require(events.first), user = try #require(events.last)
            _ = try await journal.appendBatch([start], expectedScope: scope)
            let appended = try await journal.appendBatch(events, expectedScope: scope, requiringNewUserEvent: user.id)
            #expect(appended.count == 2 && !appended[0].inserted && appended[1].inserted)
            let saved = try #require(appended.last).record
            #expect(saved.scope == scope && saved.event.id.bytes == user.id.bytes && saved.sequence > 0)
            let duplicate = try await journal.appendBatch(events, expectedScope: scope)
            #expect(duplicate.allSatisfy { !$0.inserted })
            #expect(duplicate.last?.record.sequence == saved.sequence && duplicate.last?.record.digest == saved.digest)
            await assertFailure(.conflictingID) {
                _ = try await journal.appendBatch(events, expectedScope: scope, requiringNewUserEvent: user.id)
            }
            let rows = try await journal.page(expectedScope: scope).records
            #expect(rows.count == 2)
        }
    }

    @Test(arguments: [false, true])
    func oldDuplicateRefusesWithoutConsumingAfterCommitFaultBeforeOrAfterReopen(_ reopen: Bool) async throws {
        let root = temporaryJournal()
        var live: ConversationJournal?
        do {
            live = try await ConversationJournal.open(directory: root)
            let first = try #require(live), scope = try await first.scope(), events = try requiredUserBatch(first)
            let user = try #require(events.last)
            let original = try await first.appendBatch(events, expectedScope: scope)
            if reopen { try await first.close(); live = try await ConversationJournal.open(directory: root) }
            let journal = try #require(live), currentScope = try await journal.scope(), counter = RequireNewCommitCounter()
            #expect(currentScope == scope)
            await journal.atNextBoundary(.afterCommit) { counter.record() }
            await journal.injectFault(.afterCommit)
            for _ in 0..<2 {
                await assertFailure(.conflictingID) {
                    _ = try await journal.appendBatch(events, expectedScope: scope, requiringNewUserEvent: user.id)
                }
            }
            let before = try await journal.page(expectedScope: scope).records
            #expect(before.count == 2 && before.last?.digest == original.last?.record.digest && counter.count == 0)
            // A real ordinary duplicate commit consumes the retained fault;
            // default nil remains compatible even in a reopened producer.
            await assertFailure(.acknowledgmentLost) { _ = try await journal.appendBatch(events, expectedScope: scope) }
            #expect(counter.count == 1)
            let repaired = try await journal.appendBatch(events, expectedScope: scope)
            #expect(repaired.allSatisfy { !$0.inserted })
            #expect(repaired.last?.record.sequence == original.last?.record.sequence)
            try await journal.close(); cleanup(root)
        } catch { try? await live?.close(); cleanup(root); throw error }
    }

    @Test(arguments: [RequiredUserShape.missing, .duplicateUser, .startAlias, .assistant, .wrongOrigin])
    private func invalidRequiredUserShapeWritesNothingAndLeavesFaultArmed(_ shape: RequiredUserShape) async throws {
        try await withRequiredUserJournal { journal, scope in
            let fresh = try requiredUserBatch(journal), start = try #require(fresh.first), user = try #require(fresh.last)
            var events = fresh, required = user.id
            switch shape {
            case .missing: required = try JournalOpaqueID(UUID().uuidString)
            case .duplicateUser: events.append(user)
            case .startAlias:
                events[0] = JournalEvent(id: user.id, taskID: start.taskID, attemptID: start.attemptID, payload: start.payload)
            case .assistant:
                events[1] = JournalEvent(id: user.id, taskID: user.taskID, attemptID: user.attemptID,
                    payload: .assistant(try JournalVisibleText("owned assistant, not a user event", origin: .assistant)))
            case .wrongOrigin:
                events[1] = JournalEvent(id: user.id, taskID: user.taskID, attemptID: user.attemptID,
                    payload: .user(try JournalVisibleText("source origin cannot meet the closed user precondition", origin: .source)))
            }
            let counter = RequireNewCommitCounter()
            await journal.atNextBoundary(.afterCommit) { counter.record() }; await journal.injectFault(.afterCommit)
            await assertFailure(.invalidEvent) { _ = try await journal.appendBatch(events, expectedScope: scope, requiringNewUserEvent: required) }
            let empty = try await journal.page(expectedScope: scope).records
            #expect(empty.isEmpty && counter.count == 0)
            await assertFailure(.acknowledgmentLost) { _ = try await journal.appendBatch(fresh, expectedScope: scope, requiringNewUserEvent: user.id) }
            let committed = try await journal.page(expectedScope: scope).records
            #expect(committed.count == 2 && counter.count == 1)
        }
    }

    @Test func wrongScopeDoesNotConsumeTheRequiredNewTransactionFault() async throws {
        try await withRequiredUserJournal { journal, scope in
            let events = try requiredUserBatch(journal), user = try #require(events.last), counter = RequireNewCommitCounter()
            let wrong = JournalScope(storeID: scope.storeID, generation: UUID())
            await journal.atNextBoundary(.afterCommit) { counter.record() }; await journal.injectFault(.afterCommit)
            await assertFailure(.wrongGeneration) { _ = try await journal.appendBatch(events, expectedScope: wrong, requiringNewUserEvent: user.id) }
            let empty = try await journal.page(expectedScope: scope).records
            #expect(empty.isEmpty && counter.count == 0)
            await assertFailure(.acknowledgmentLost) { _ = try await journal.appendBatch(events, expectedScope: scope, requiringNewUserEvent: user.id) }
            let committed = try await journal.page(expectedScope: scope).records
            #expect(committed.count == 2 && counter.count == 1)
        }
    }

    @Test func precommitFailureRollsBackStartAndUserThenStillRequiresANewUser() async throws {
        try await withRequiredUserJournal { journal, scope in
            let events = try requiredUserBatch(journal), user = try #require(events.last)
            await journal.injectFault(.beforeCommit)
            await assertFailure(.injectedBeforeCommit) { _ = try await journal.appendBatch(events, expectedScope: scope, requiringNewUserEvent: user.id) }
            let empty = try await journal.page(expectedScope: scope).records
            #expect(empty.isEmpty)
            let appended = try await journal.appendBatch(events, expectedScope: scope, requiringNewUserEvent: user.id)
            #expect(appended.count == 2 && appended.allSatisfy(\.inserted))
            let rows = try await journal.page(expectedScope: scope).records
            #expect(rows.count == 2)
        }
    }

    @Test func foreignInsertionBetweenRolledBackAttemptsBlocksBeforeAnyOriginalStartIsInserted() async throws {
        try await withRequiredUserJournal { journal, scope in
            let original = try requiredUserBatch(journal), user = try #require(original.last)
            await journal.injectFault(.beforeCommit)
            await assertFailure(.injectedBeforeCommit) { _ = try await journal.appendBatch(original, expectedScope: scope, requiringNewUserEvent: user.id) }
            let foreign = try requiredUserBatch(journal, userID: user.id)
            let saved = try await journal.appendBatch(foreign, expectedScope: scope)
            await assertFailure(.conflictingID) { _ = try await journal.appendBatch(original, expectedScope: scope, requiringNewUserEvent: user.id) }
            let rows = try await journal.page(expectedScope: scope).records
            #expect(rows.count == 2 && rows.allSatisfy { $0.event.taskID != user.taskID })
            #expect(rows.last?.digest == saved.last?.record.digest)
        }
    }

    @Test func genuineRequiredNewAfterCommitLossStillHasOneIdempotentStorageRepair() async throws {
        try await withRequiredUserJournal { journal, scope in
            let events = try requiredUserBatch(journal), user = try #require(events.last)
            await journal.injectFault(.afterCommit)
            await assertFailure(.acknowledgmentLost) { _ = try await journal.appendBatch(events, expectedScope: scope, requiringNewUserEvent: user.id) }
            let committed = try await journal.page(expectedScope: scope).records
            let repaired = try await journal.appendBatch(events, expectedScope: scope)
            #expect(repaired.count == 2 && repaired.allSatisfy { !$0.inserted })
            #expect(repaired.last?.record.sequence == committed.last?.sequence && repaired.last?.record.digest == committed.last?.digest)
            await assertFailure(.conflictingID) { _ = try await journal.appendBatch(events, expectedScope: scope, requiringNewUserEvent: user.id) }
            let retained = try await journal.page(expectedScope: scope).records
            #expect(retained.count == 2)
        }
    }

    @Test func oldRequiredUserRefusesBeforeOtherBatchEventsAreInserted() async throws {
        try await withRequiredUserJournal { journal, scope in
            let old = try requiredUserBatch(journal), oldUser = try #require(old.last)
            let original = try await journal.appendBatch(old, expectedScope: scope)
            let fresh = try requiredUserBatch(journal), batch = fresh + [oldUser], counter = RequireNewCommitCounter()
            await journal.atNextBoundary(.afterCommit) { counter.record() }; await journal.injectFault(.afterCommit)
            await assertFailure(.conflictingID) { _ = try await journal.appendBatch(batch, expectedScope: scope, requiringNewUserEvent: oldUser.id) }
            let before = try await journal.page(expectedScope: scope).records
            #expect(before.count == 2 && before.last?.digest == original.last?.record.digest && counter.count == 0)
            await assertFailure(.acknowledgmentLost) { _ = try await journal.appendBatch(fresh, expectedScope: scope) }
            let after = try await journal.page(expectedScope: scope).records
            #expect(after.count == 4 && counter.count == 1)
        }
    }
}
