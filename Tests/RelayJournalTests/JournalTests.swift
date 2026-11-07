import Testing
import Foundation
import SQLite3
import Darwin
@testable import RelayJournal

func temporaryJournal() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("relay-journal-tests-" + UUID().uuidString, isDirectory: true) }
func cleanup(_ url: URL) { try? FileManager.default.removeItem(at: url) }
func assertFailure(_ expected: JournalError? = nil, _ body: () async throws -> Void, isolation: isolated (any Actor)? = #isolation, sourceLocation: SourceLocation = #_sourceLocation) async {
    do { try await body(); Issue.record("Expected a failure", sourceLocation: sourceLocation) }
    catch { if let expected { #expect(error as? JournalError == expected, sourceLocation: sourceLocation) } }
}
func start(_ journal: ConversationJournal, scope: JournalScope, task: UUID = UUID(), attempt: UUID = UUID()) async throws -> (UUID, UUID) {
    _ = try await journal.acceptRequest(id: JournalOpaqueID("request:" + task.uuidString), taskID: task, attemptID: attempt,
        text: JournalVisibleText("Synthetic request", origin: .user), expectedScope: scope)
    return (task, attempt)
}
func intentEvent(_ journal: ConversationJournal, task: UUID, attempt: UUID, callID: String = "call", proposalID: UUID? = nil, eventID: String = UUID().uuidString) throws -> JournalEvent {
    let intent = try JournalIntent(proposalID: proposalID ?? task, producerEpoch: journal.producerEpoch, toolCallID: JournalOpaqueID(callID), toolName: "owned_action", callDigest: journalDigest(Data(callID.utf8)), effect: .mutation)
    return JournalEvent(id: try JournalOpaqueID(eventID), taskID: task, attemptID: attempt, payload: .intent(intent))
}
func resultEvent(_ event: JournalEvent, kind: JournalOutcomeKind = .returnedVerified, id: String = UUID().uuidString) throws -> JournalEvent {
    guard case let .intent(intent) = event.payload else { throw JournalError.invalidEvent }
    return JournalEvent(id: try JournalOpaqueID(id), taskID: event.taskID, attemptID: event.attemptID, payload: .result(JournalToolOutcome(intent: intent, kind: kind)))
}
func contents(_ root: URL) throws -> [String: Data] {
    var result: [String: Data] = [:]
    for name in ["Conversation.sqlite", "Conversation.sqlite-wal", "Conversation.sqlite-shm"] {
        let url = root.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { result[name] = try Data(contentsOf: url) }
    }
    return result
}

@Suite(.serialized) struct JournalStorageTests {
    @Test func exactUnicodeIDsAndPlainVisibleProse() async throws {
        let root = temporaryJournal(); defer { cleanup(root) }
        let journal = try await ConversationJournal.open(directory: root), scope = try await journal.scope()
        let (task, attempt) = try await start(journal, scope: scope)
        let nfc = try JournalOpaqueID("café"), nfd = try JournalOpaqueID("cafe\u{301}")
        #expect(nfc != nfd); #expect(Set([nfc,nfd]).count == 2)
        let prose = "Email me at person@example.test about desk-notes, task-notes and literal sk-example prose. 👩🏽‍💻 cafe\u{301}"
        let a = JournalEvent(id: nfc, taskID: task, attemptID: attempt, payload: .assistant(try JournalVisibleText(prose, origin: .assistant)))
        let b = JournalEvent(id: nfd, taskID: task, attemptID: attempt, payload: .assistant(try JournalVisibleText("Separate", origin: .assistant)))
        _ = try await journal.appendBatch([a,b], expectedScope: scope)
        let page = try await journal.page(expectedScope: scope)
        #expect(page.records.count == 4); #expect(page.records[2].event == a); #expect(page.records[3].event == b)
        try await journal.close()
    }
    @Test func duplicateIsImmutableAndBatchRollsBack() async throws {
        let root = temporaryJournal(); defer { cleanup(root) }
        let journal = try await ConversationJournal.open(directory: root), scope = try await journal.scope()
        let (task, attempt) = try await start(journal, scope: scope)
        let id = try JournalOpaqueID("same"), text = try JournalVisibleText("Exact", origin: .assistant)
        let event = JournalEvent(id: id, taskID: task, attemptID: attempt, payload: .assistant(text))
        let first = try await journal.appendBatch([event], expectedScope: scope)[0]
        let duplicate = try await journal.appendBatch([event], expectedScope: scope)[0]
        #expect(first.inserted); #expect(!duplicate.inserted); #expect(first.record == duplicate.record)
        let changed = JournalEvent(id: id, taskID: task, attemptID: attempt, payload: .assistant(try JournalVisibleText("Changed", origin: .assistant)))
        let preceding = JournalEvent(id: try JournalOpaqueID("rolled-back"), taskID: task, attemptID: attempt, payload: .assistant(text))
        await assertFailure(.conflictingID) { _ = try await journal.appendBatch([preceding,changed], expectedScope: scope) }
        #expect(try await journal.page(expectedScope: scope).records.count == 3)
        try await journal.close()
    }
    @Test(arguments: [JournalFault.beforeCommit, .afterCommit]) func realCommitFaults(_ fault: JournalFault) async throws {
        let root = temporaryJournal(); defer { cleanup(root) }
        let journal = try await ConversationJournal.open(directory: root), scope = try await journal.scope()
        let (task, attempt) = try await start(journal, scope: scope)
        let event = try intentEvent(journal, task: task, attempt: attempt)
        await journal.injectFault(fault)
        await assertFailure { _ = try await journal.commitIntent(event, expectedScope: scope) }
        let count = try await journal.page(expectedScope: scope).records.count
        switch fault {
        case .beforeCommit: #expect(count == 2)
        case .afterCommit:
            #expect(count == 3)
            let retry = try await journal.commitIntent(event, expectedScope: scope)
            guard case .alreadyRecorded = retry else { Issue.record("Lost acknowledgment reminted intent"); return }
        }
        try await journal.close()
    }
    @Test func resultInvocationAndByteIDsStayDistinct() async throws {
        let root = temporaryJournal(); defer { cleanup(root) }
        let journal = try await ConversationJournal.open(directory: root), scope = try await journal.scope()
        let (task, attempt) = try await start(journal, scope: scope)
        let a = try intentEvent(journal, task: task, attempt: attempt, callID: "café"), b = try intentEvent(journal, task: task, attempt: attempt, callID: "cafe\u{301}")
        _ = try await journal.commitIntent(a, expectedScope: scope); _ = try await journal.commitIntent(b, expectedScope: scope)
        _ = try await journal.commitResult(resultEvent(a, id: "result-a"), expectedScope: scope)
        let finish = JournalEvent(id: try JournalOpaqueID("finish"), taskID: task, attemptID: attempt, payload: .finished(.success))
        await assertFailure(.invalidTransition) { _ = try await journal.finishTask(finish, expectedScope: scope) }
        _ = try await journal.commitResult(resultEvent(b, id: "result-b"), expectedScope: scope)
        _ = try await journal.finishTask(finish, expectedScope: scope)
        #expect(try await journal.page(expectedScope: scope).records.count == 7)
        try await journal.close()
    }
    @Test func settledSameIDReusesCanonicalReceiptWithoutNewEligibility() async throws {
        let root = temporaryJournal(); defer { cleanup(root) }
        let journal = try await ConversationJournal.open(directory: root), scope = try await journal.scope()
        let (task, attempt) = try await start(journal, scope: scope)
        let event = try intentEvent(journal, task: task, attempt: attempt, callID: "same-provider-id")
        _ = try await journal.commitIntent(event, expectedScope: scope); _ = try await journal.commitResult(resultEvent(event), expectedScope: scope)
        let duplicate = try intentEvent(journal, task: task, attempt: attempt, callID: "same-provider-id")
        guard case let .alreadyRecorded(record) = try await journal.commitIntent(duplicate, expectedScope: scope) else { Issue.record("Settled ID reminted eligibility"); return }
        #expect(record.event == event); #expect(try await journal.page(expectedScope: scope).records.count == 4)
        // A distinct explicit task/attempt has its own namespace.
        let (nextTask, nextAttempt) = try await start(journal, scope: scope)
        guard case .inserted = try await journal.commitIntent(intentEvent(journal, task: nextTask, attempt: nextAttempt, callID: "same-provider-id"), expectedScope: scope) else { Issue.record("Distinct task incorrectly conflated"); return }
        try await journal.close()
    }
    @Test func questionRecoveryNeverRecreatesContinuation() async throws {
        let root = temporaryJournal(); defer { cleanup(root) }
        let journal = try await ConversationJournal.open(directory: root), scope = try await journal.scope()
        let (task, attempt) = try await start(journal, scope: scope)
        let question = JournalEvent(id: try JournalOpaqueID("question"), taskID: task, attemptID: attempt, payload: .question(try JournalVisibleText("Which synthetic choice?", origin: .assistant)))
        _ = try await journal.appendBatch([question], expectedScope: scope); try await journal.close()
        let reopened = try await ConversationJournal.open(directory: root)
        #expect(try await reopened.recoverInterrupted(expectedScope: scope).count == 1)
        #expect(try await reopened.recoverInterrupted(expectedScope: scope).isEmpty)
        let records = try await reopened.page(expectedScope: scope).records
        #expect(records[2].event == question)
        #expect(records.last?.event.payload == .finished(.interrupted))
        try await reopened.close()
    }
    @Test func resetRejectsOldWritersAndLeavesIndependentFiles() async throws {
        let root = temporaryJournal(); defer { cleanup(root) }
        let journal = try await ConversationJournal.open(directory: root), scope = try await journal.scope()
        let (task, attempt) = try await start(journal, scope: scope)
        let preferences = root.appendingPathComponent("independent-preferences.txt"); try Data("keep".utf8).write(to: preferences)
        let newScope = try await journal.reset(expectedScope: scope)
        #expect(newScope != scope); #expect(try await journal.page(expectedScope: newScope).records.isEmpty)
        await assertFailure(.wrongGeneration) { _ = try await journal.commitIntent(intentEvent(journal, task: task, attempt: attempt), expectedScope: scope) }
        #expect(try Data(contentsOf: preferences) == Data("keep".utf8))
        try await journal.close()
    }
    @Test func privateModesAndCooperativeWriterLease() async throws {
        let root = temporaryJournal(); defer { cleanup(root) }
        let journal = try await ConversationJournal.open(directory: root)
        await assertFailure(.writerBusy) { _ = try await ConversationJournal.open(directory: root) }
        for name in ["Conversation.sqlite", "Conversation.sqlite-wal", "Conversation.sqlite-shm", ".writer.lock"] {
            var metadata = stat(); let path = root.appendingPathComponent(name).path
            #expect(path.withCString { lstat($0, &metadata) } == 0); #expect(metadata.st_mode & 0o777 == 0o600)
        }
        try await journal.close()
        let reopened = try await ConversationJournal.open(directory: root); try await reopened.close()
    }
    @Test(arguments: ["foreign", "newer", "corrupt", "extra-table"]) func preserveRejectedStores(_ kind: String) async throws {
        let root = temporaryJournal(); defer { cleanup(root) }
        let journal = try await ConversationJournal.open(directory: root); try await journal.close()
        let path = try canonicalJournalDirectory(root) + "/Conversation.sqlite"
        if kind == "corrupt" { try Data("not sqlite".utf8).write(to: URL(fileURLWithPath: path)) }
        else {
            let sql = try JournalSQLite(path: path)
            switch kind {
            case "newer": try sql.execute("PRAGMA user_version=999")
            case "foreign": try sql.execute("PRAGMA application_id=1234")
            default: try sql.execute("CREATE TABLE unexpected(value TEXT)")
            }
            try sql.close()
        }
        let before = try contents(root)
        await assertFailure { _ = try await ConversationJournal.open(directory: root) }
        #expect(try contents(root) == before)
    }
    @Test(arguments: ["symlink", "hardlink", "sidecar-link"]) func rejectLinksWithoutTouchingTargets(_ kind: String) async throws {
        let root = temporaryJournal(), targetRoot = temporaryJournal(); defer { cleanup(root); cleanup(targetRoot) }
        let journal = try await ConversationJournal.open(directory: root); try await journal.close()
        try FileManager.default.createDirectory(at: targetRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let target = targetRoot.appendingPathComponent("target"), bytes = Data("untouched".utf8); try bytes.write(to: target)
        let destination = root.appendingPathComponent(kind == "sidecar-link" ? "Conversation.sqlite-wal" : "Conversation.sqlite")
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        if kind == "hardlink" { try FileManager.default.linkItem(at: target, to: destination) }
        else { try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: target) }
        await assertFailure(.unsafeLocation) { _ = try await ConversationJournal.open(directory: root) }
        #expect(try Data(contentsOf: target) == bytes)
    }
    @Test func boundedBusyAndFullPreservePriorCommit() async throws {
        let root = temporaryJournal(); defer { cleanup(root) }
        var limits = JournalLimits(); limits.databaseBytes = 262_144; limits.busyMilliseconds = 20
        let journal = try await ConversationJournal.open(directory: root, limits: limits), scope = try await journal.scope()
        let (task, attempt) = try await start(journal, scope: scope)
        let other = try JournalSQLite(path: canonicalJournalDirectory(root) + "/Conversation.sqlite")
        try other.execute("BEGIN IMMEDIATE")
        let clock = ContinuousClock(), began = clock.now
        await assertFailure(.sqlite(SQLITE_BUSY)) { _ = try await journal.appendBatch([JournalEvent(id: JournalOpaqueID("busy"), taskID: task, attemptID: attempt, payload: .assistant(JournalVisibleText("blocked", origin: .assistant)))], expectedScope: scope) }
        #expect(began.duration(to: clock.now) < .seconds(2))
        try other.execute("ROLLBACK"); try other.close()
        let large = JournalEvent(id: try JournalOpaqueID("full"), taskID: task, attemptID: attempt, payload: .assistant(try JournalVisibleText(String(repeating: "x", count: 230_000), origin: .assistant)))
        await assertFailure(.sqlite(SQLITE_FULL)) { _ = try await journal.appendBatch([large], expectedScope: scope) }
        #expect(try await journal.page(expectedScope: scope).records.count == 2)
        try await journal.close()
    }
    @Test func pageBudgetAndProjectionAreBoundedAndIdempotent() async throws {
        let root = temporaryJournal(); defer { cleanup(root) }
        let journal = try await ConversationJournal.open(directory: root), scope = try await journal.scope()
        _ = try await start(journal, scope: scope)
        let first = try await journal.page(limit: 1, expectedScope: scope), second = try await journal.page(after: first.cursor, expectedScope: scope)
        #expect(first.hasLater); #expect(!second.hasLater)
        var projection = JournalProjection(); try projection.apply(first.records + second.records)
        let original = projection; try projection.apply(first.records + second.records); #expect(projection == original)
        await assertFailure(.tooLarge) { _ = try await journal.page(byteBudget: 1, expectedScope: scope) }
        try await journal.close()
        await assertFailure(.closed) { _ = try await journal.scope() }
    }
    @Test func invalidDepthAndOversizedTypesRefuse() throws {
        #expect(throws: JournalError.tooLarge) { try validateJournalJSON(Data((String(repeating: "[", count: 33) + "0" + String(repeating: "]", count: 33)).utf8)) }
        #expect(throws: JournalError.invalidEvent) { try JournalOpaqueID(String(repeating: "a", count: 513)) }
        #expect(throws: JournalError.tooLarge) { try JournalVisibleText(String(repeating: "a", count: 250_000), origin: .user) }
    }
}

@Suite(.serialized) @MainActor struct JournalDispatchTests {
    @Test(arguments: [JournalFault.beforeCommit, .afterCommit]) func commitFailureNeverDispatches(_ fault: JournalFault) async throws {
        let root = temporaryJournal(); defer { cleanup(root) }
        let journal = try await ConversationJournal.open(directory: root), scope = try await journal.scope()
        let (task, attempt) = try await start(journal, scope: scope), event = try intentEvent(journal, task: task, attempt: attempt)
        guard case let .intent(intent) = event.payload else { throw JournalError.invalidEvent }
        let checkpoint = JournalDispatchCheckpoint(journal: journal); var dispatches = 0
        await journal.injectFault(fault)
        await assertFailure { _ = try await checkpoint.execute(event, expectedScope: scope, validate: {}, action: { dispatches += 1; return JournalToolOutcome(intent: intent, kind: .returnedVerified) }) }
        #expect(dispatches == 0)
        if case .afterCommit = fault {
            await assertFailure(.duplicateIntent) { _ = try await checkpoint.execute(event, expectedScope: scope, validate: {}, action: { dispatches += 1; return JournalToolOutcome(intent: intent, kind: .returnedVerified) }) }
            #expect(dispatches == 0)
        }
        try await journal.close()
    }
    @Test func committedBeforeEffectAndDuplicateCannotDispatch() async throws {
        let root = temporaryJournal(); defer { cleanup(root) }
        let journal = try await ConversationJournal.open(directory: root), scope = try await journal.scope()
        let (task, attempt) = try await start(journal, scope: scope), event = try intentEvent(journal, task: task, attempt: attempt)
        guard case let .intent(intent) = event.payload else { throw JournalError.invalidEvent }
        let checkpoint = JournalDispatchCheckpoint(journal: journal); var dispatches = 0
        _ = try await checkpoint.execute(event, expectedScope: scope, validate: {}, action: {
            let durable = try await journal.page(expectedScope: scope)
            #expect(durable.records.last?.event == event)
            dispatches += 1; return JournalToolOutcome(intent: intent, kind: .returnedVerified)
        })
        await assertFailure(.duplicateIntent) { _ = try await checkpoint.execute(event, expectedScope: scope, validate: {}, action: { dispatches += 1; return JournalToolOutcome(intent: intent, kind: .returnedVerified) }) }
        #expect(dispatches == 1); #expect(checkpoint.pendingResultCount == 0)
        try await journal.close()
    }
    @Test func resultSaveRetryNeverRepeatsEffect() async throws {
        let root = temporaryJournal(); defer { cleanup(root) }
        let journal = try await ConversationJournal.open(directory: root), scope = try await journal.scope()
        let (task, attempt) = try await start(journal, scope: scope), event = try intentEvent(journal, task: task, attempt: attempt)
        guard case let .intent(intent) = event.payload else { throw JournalError.invalidEvent }
        let checkpoint = JournalDispatchCheckpoint(journal: journal); var dispatches = 0
        await assertFailure(.injectedBeforeCommit) { _ = try await checkpoint.execute(event, expectedScope: scope, validate: {}, action: {
            dispatches += 1; await journal.injectFault(.beforeCommit); return JournalToolOutcome(intent: intent, kind: .returnedVerified)
        }) }
        #expect(dispatches == 1); #expect(checkpoint.pendingResultCount == 1)
        _ = try await checkpoint.savePendingResult(invocationID: intent.invocationID)
        #expect(dispatches == 1); #expect(checkpoint.pendingResultCount == 0)
        #expect(try await journal.page(expectedScope: scope).records.count == 4)
        try await journal.close()
    }
    @Test func freshValidationRevocationAfterCommitStopsEffect() async throws {
        let root = temporaryJournal(); defer { cleanup(root) }
        let journal = try await ConversationJournal.open(directory: root), scope = try await journal.scope()
        let (task, attempt) = try await start(journal, scope: scope), event = try intentEvent(journal, task: task, attempt: attempt)
        guard case let .intent(intent) = event.payload else { throw JournalError.invalidEvent }
        let checkpoint = JournalDispatchCheckpoint(journal: journal); var validations = 0, dispatches = 0
        await assertFailure(.dispatchRevoked) { _ = try await checkpoint.execute(event, expectedScope: scope, validate: {
            validations += 1; if validations == 2 { throw JournalError.dispatchRevoked }
        }, action: { dispatches += 1; return JournalToolOutcome(intent: intent, kind: .returnedVerified) }) }
        #expect(validations == 2); #expect(dispatches == 0)
        guard case let .result(result) = try await journal.page(expectedScope: scope).records.last?.event.payload else { Issue.record("Missing factual not-dispatched result"); return }
        #expect(result.kind == .notDispatched)
        try await journal.close()
    }
}

private final class JournalTestBundleMarker: NSObject {}

@Suite(.serialized) struct JournalCrashTests {
    @Test(arguments: ["before-intent", "after-intent", "after-effect", "after-result", "uncommitted"]) func abruptOwnedProcessRecovery(_ stage: String) async throws {
        let root = temporaryJournal(); defer { cleanup(root) }
        let testBundle = Bundle(for: JournalTestBundleMarker.self).bundleURL
        let executable = testBundle.deletingLastPathComponent().appendingPathComponent("JournalCrashFixture")
        try #require(FileManager.default.isExecutableFile(atPath: executable.path))
        let process = Process(); process.executableURL = executable; process.arguments = [root.path,stage]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit(); #expect(process.terminationStatus == 0)
        let effect = root.appendingPathComponent("independent-effect.txt")
        let expectedEffect = stage == "after-effect" || stage == "after-result"
        #expect(FileManager.default.fileExists(atPath: effect.path) == expectedEffect)
        let journal = try await ConversationJournal.open(directory: root), scope = try await journal.scope()
        let before = try await journal.page(expectedScope: scope).records
        #expect(before.count == (stage == "before-intent" || stage == "uncommitted" ? 2 : stage == "after-result" ? 4 : 3))
        if stage == "after-result" {
            guard case let .result(outcome) = before.last?.event.payload else { throw JournalError.corrupt }
            #expect(outcome.artifacts.map(\.visiblePath) == [effect.path])
        }
        let recovered = try await journal.recoverInterrupted(expectedScope: scope)
        #expect(recovered.count == 1); #expect(recovered[0].event.payload == .finished(.interrupted))
        #expect(try await journal.recoverInterrupted(expectedScope: scope).isEmpty)
        if expectedEffect { #expect(try Data(contentsOf: effect) == Data("one effect".utf8)) }
        try await journal.close()
    }
}
