import CryptoKit
import Dispatch
import Foundation
import Testing
@testable import Relay
@testable import RelayJournal

/// Pauses only an actual owned SQLite transaction. Never supplies a record,
/// receipt, saved status, anchor, source validator or action capability.
nonisolated private final class UserReceiptCommitBarrier: @unchecked Sendable {
    private let lock = NSLock(), semaphore = DispatchSemaphore(value: 0)
    private var began = false, ended = false, expired = false
    var entered: Bool { lock.withLock { began } }
    var timedOut: Bool { lock.withLock { expired } }
    func pause() {
        lock.withLock { began = true }
        if semaphore.wait(timeout: .now() + 5) == .timedOut { lock.withLock { expired = true } }
    }
    func release() {
        let signal = lock.withLock { let value = !ended; ended = true; return value }
        if signal { semaphore.signal() }
    }
}

nonisolated private final class UserReceiptBoundaryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func record() { lock.withLock { value += 1 } }
}

@MainActor private func userReceiptFlushFailure(_ history: AssistantConversationHistory) async throws -> JournalError? {
    do { _ = try await history.flush(); return nil }
    catch let error as JournalError { return error }
}

@MainActor private func waitForUserReceipt(_ condition: () -> Bool) async throws {
    let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(5))
    while !condition() {
        guard clock.now < deadline else { throw JournalError.writerBusy }
        try await Task.sleep(for: .milliseconds(2))
    }
}

@MainActor private func withUserReceiptHistory(
    _ body: @MainActor (AssistantConversationHistory) async throws -> Void
) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-user-receipt-" + UUID().uuidString)
    let history = AssistantConversationHistory(stateURL: root.appendingPathComponent("state.json"))
    do {
        try await body(history)
        try await history.close()
        try FileManager.default.removeItem(at: root)
    } catch {
        try? await history.close()
        try? FileManager.default.removeItem(at: root)
        throw error
    }
}

@MainActor private func userReceiptRecords(_ history: AssistantConversationHistory) async throws -> [JournalRecord] {
    let core = try await history.journalForTesting(), scope = try await core.scope()
    var records: [JournalRecord] = [], cursor: JournalCursor?
    repeat {
        let page = try await core.page(after: cursor, expectedScope: scope)
        records += page.records; cursor = page.hasLater ? page.cursor : nil
    } while cursor != nil
    return records
}

@MainActor private func userReceiptBinding(_ message: ChatMessage, _ run: AssistantConversationHistory.Run,
                                         literal: String = "exact unsent literal") -> NativeExactUnsentMessageBinding {
    NativeExactUnsentMessageBinding(messageID: message.id, logicalTaskID: run.relation.logicalTaskID,
        runID: run.taskID, attemptID: run.attemptID, anchorID: UUID(), originID: UUID(), originRevision: 7,
        exactRequestUTF8: Data(message.text.utf8), literalUTF8: Data(literal.utf8))
}

nonisolated enum UserReceiptChangedField: CaseIterable, Sendable, Equatable {
    case message, logicalTask, run, attempt, anchor, origin, revision, request, literal
    func changing(_ value: NativeExactUnsentMessageBinding) -> NativeExactUnsentMessageBinding {
        NativeExactUnsentMessageBinding(messageID: self == .message ? UUID() : value.messageID,
            logicalTaskID: self == .logicalTask ? UUID() : value.logicalTaskID,
            runID: self == .run ? UUID() : value.runID, attemptID: self == .attempt ? UUID() : value.attemptID,
            anchorID: self == .anchor ? UUID() : value.anchorID, originID: self == .origin ? UUID() : value.originID,
            originRevision: self == .revision ? value.originRevision + 1 : value.originRevision,
            exactRequestUTF8: self == .request ? Data("different request".utf8) : value.exactRequestUTF8,
            literalUTF8: self == .literal ? Data("different literal".utf8) : value.literalUTF8)
    }
}

/// Bound the test-only synchronous SQLite pauses to one within this suite.
/// The coalescing case still uses simultaneous real flush callers explicitly.
@MainActor @Suite(.serialized) struct SavedUserMessageReceiptTests {
    /// The actual shared synchronous orchestration is exercised with a token
    /// produced by real SQLite. No Store owner, ACK, process witness or AX
    /// source can be manufactured by this test.
    @Test(arguments: [false, true])
    func savedBindingRevocationInsideOneMetadataQueryCannotBeCaughtAndReused(_ stop: Bool) async throws {
        try await withUserReceiptHistory { history in
            let run = try AssistantConversationHistory.Run(logicalTaskID: UUID(), cause: .newRequest)
            let message = ChatMessage(role: "user", text: "one real saved metadata owner")
            let ticket = ConversationSubmission(messageID: message.id, text: message.text), binding = userReceiptBinding(message, run)
            var deposited: AssistantConversationHistory.SavedUserMessage?
            let staging = try history.stageUserMessageForSubmission(message, run: run, submission: ticket, binding: binding) { deposited = $0 }
            _ = try await history.flush()
            let saved = try #require(deposited)
            let validated = try saved.bindValidated(staging: staging, submission: ticket, run: run, binding: binding)
            let query = DesktopApplicationTarget.MetadataQueryScope()
            var escaped: DesktopApplicationTarget.MetadataQueryScope.Lifetime?
            var entry = 0, exit = 0, mutable = 0, later = 0
            do {
                try query.run(before: { entry += 1; try validated.validate() }, after: {
                    exit += 1; try validated.validate()
                }) { lifetime in
                    escaped = lifetime
                    for _ in 0..<3 { try lifetime.validate { mutable += 1; try validated.validate() } }
                    if stop { history.stop(run) } else { history.revokeUserMessage(staging) }
                    // Catching the immediate denial cannot let a later old R
                    // call or the current query return a successful verdict.
                    #expect(throws: (any Error).self) {
                        try lifetime.validate { mutable += 1; try validated.validate() }
                    }
                    #expect(throws: (any Error).self) { try lifetime.validate { later += 1 } }
                }
                Issue.record("A revoked genuine saved binding survived query exit")
            } catch { #expect(error is AssistantConversationHistory.UserMessageReceiptFailure) }
            #expect(entry == 1 && exit == 1 && mutable == 4 && later == 0)
            let retired = try #require(escaped)
            #expect(throws: DesktopApplicationTarget.MetadataQueryScope.Failure.expired) { try retired.check() }
            #expect(throws: (any Error).self) {
                try query.run(before: { later += 1 }, after: {}) { _ in later += 1 }
            }
            let rows = try await userReceiptRecords(history)
            #expect(later == 0 && rows.contains { $0.event.id.bytes == Data(message.id.uuidString.utf8) })
        }
    }

    @Test func genuineHistoryExitRevocationOverridesAnEarlierBodyErrorAndRetiresBeforeReturn() async throws {
        try await withUserReceiptHistory { history in
            let run = try AssistantConversationHistory.Run(logicalTaskID: UUID(), cause: .newRequest)
            let message = ChatMessage(role: "user", text: "saved exit-fence witness")
            let ticket = ConversationSubmission(messageID: message.id, text: message.text), binding = userReceiptBinding(message, run)
            var deposited: AssistantConversationHistory.SavedUserMessage?
            let staging = try history.stageUserMessageForSubmission(message, run: run, submission: ticket, binding: binding) { deposited = $0 }
            _ = try await history.flush()
            let saved = try #require(deposited)
            let validated = try saved.bindValidated(staging: staging, submission: ticket, run: run, binding: binding)
            let query = DesktopApplicationTarget.MetadataQueryScope()
            var escaped: DesktopApplicationTarget.MetadataQueryScope.Lifetime?, exits = 0
            do {
                try query.run(before: { try validated.validate() }, after: { exits += 1; try validated.validate() }) { lifetime in
                    escaped = lifetime
                    try lifetime.validate { try validated.validate() }
                    history.stop(run)
                    throw JournalError.writerBusy
                }
                Issue.record("A revoked result returned from the owner bracket")
            } catch {
                #expect(error is AssistantConversationHistory.UserMessageReceiptFailure)
                #expect((error as? JournalError) != .writerBusy)
            }
            #expect(exits == 1)
            let retired = try #require(escaped)
            #expect(throws: DesktopApplicationTarget.MetadataQueryScope.Failure.expired) { try retired.check() }
        }
    }

    @Test(arguments: ["\n  literal with spaces  \n", "caf\u{e9}", "cafe\u{301}", "opaque-ID: tool_123/header-like prose"])
    func actualAppendReturnsExactUserRecordWithoutAcknowledgingDelivery(_ exact: String) async throws {
        try await withUserReceiptHistory { history in
            let run = try AssistantConversationHistory.Run(logicalTaskID: UUID(), cause: .newRequest)
            let message = ChatMessage(role: "user", text: exact, date: Date(timeIntervalSince1970: 123.456))
            let ticket = ConversationSubmission(messageID: message.id, text: exact), binding = userReceiptBinding(message, run, literal: exact)
            var deposited: AssistantConversationHistory.SavedUserMessage?, count = 0
            let staging = try history.stageUserMessageForSubmission(message, run: run, submission: ticket, binding: binding) {
                count += 1; deposited = $0
            }
            #expect(deposited == nil)
            let saved = try await history.flush(), receipt = try #require(deposited)
            let records = try await userReceiptRecords(history)
            let row = try #require(records.first(where: { $0.event.id.bytes == Data(message.id.uuidString.utf8) }))
            guard case let .user(body) = row.event.payload else { Issue.record("Expected the actual user row."); return }
            #expect(Data(body.text.utf8) == Data(exact.utf8))
            #expect(body.origin == .user && body.artifacts.isEmpty && body.omissions.isEmpty && body.sourceRequirements.isEmpty)
            #expect(row.event.taskID == run.taskID && row.event.attemptID == run.attemptID)
            #expect(receipt.scope == row.scope && receipt.sequence == row.sequence && receipt.recordDigest == row.digest)
            #expect(receipt.eventID == row.event.id.bytes && row.digest.count == 32)
            #expect(saved == [message.id] && count == 1 && ticket.status == .pending)
            try receipt.validate(staging: staging, submission: ticket, run: run, binding: binding)
            ticket.resolve(.saved)
            try receipt.validate(staging: staging, submission: ticket, run: run, binding: binding)
            // Delivery saved still cannot replace the deliberately unavailable ACK bridge.
            #expect(throws: (any Error).self) { try NativeExactUnsentAcknowledgment.bindSavedMessage(ticket, run: run) }
            _ = try await history.flush(); #expect(count == 1)
        }
    }

    @Test(arguments: UserReceiptChangedField.allCases)
    func exactNamespaceCannotBeSubstitutedAfterRealSave(_ field: UserReceiptChangedField) async throws {
        try await withUserReceiptHistory { history in
            let run = try AssistantConversationHistory.Run(logicalTaskID: UUID(), cause: .newRequest)
            let message = ChatMessage(role: "user", text: "one saved request")
            let ticket = ConversationSubmission(messageID: message.id, text: message.text), binding = userReceiptBinding(message, run)
            var deposited: AssistantConversationHistory.SavedUserMessage?
            let staging = try history.stageUserMessageForSubmission(message, run: run, submission: ticket, binding: binding) { deposited = $0 }
            _ = try await history.flush(); let receipt = try #require(deposited)
            let wrong = field.changing(binding)
            #expect(throws: (any Error).self) { try receipt.validate(staging: staging, submission: ticket, run: run, binding: wrong) }
            try receipt.validate(staging: staging, submission: ticket, run: run, binding: binding)
        }
    }

    @Test func canonicalEquivalentBytesAndClonedTicketsAreNotTheOriginal() async throws {
        try await withUserReceiptHistory { history in
            let run = try AssistantConversationHistory.Run(logicalTaskID: UUID(), cause: .newRequest)
            let nfc = "caf\u{e9}", nfd = "cafe\u{301}", message = ChatMessage(role: "user", text: "caf\u{e9}")
            #expect(nfc == nfd && Data(nfc.utf8) != Data(nfd.utf8))
            let ticket = ConversationSubmission(messageID: message.id, text: nfc), binding = userReceiptBinding(message, run, literal: nfc)
            let wrongBytes = NativeExactUnsentMessageBinding(messageID: binding.messageID, logicalTaskID: binding.logicalTaskID,
                runID: binding.runID, attemptID: binding.attemptID, anchorID: binding.anchorID, originID: binding.originID,
                originRevision: binding.originRevision, exactRequestUTF8: Data(nfd.utf8), literalUTF8: Data(nfc.utf8))
            #expect(throws: (any Error).self) {
                try history.stageUserMessageForSubmission(message, run: run, submission: ticket, binding: wrongBytes) { _ in Issue.record("Wrong bytes saved.") }
            }
            var deposited: AssistantConversationHistory.SavedUserMessage?
            let staging = try history.stageUserMessageForSubmission(message, run: run, submission: ticket, binding: binding) { deposited = $0 }
            _ = try await history.flush(); let receipt = try #require(deposited)
            let clone = ConversationSubmission(messageID: message.id, text: nfc); clone.resolve(.saved)
            #expect(throws: (any Error).self) { try receipt.validate(staging: staging, submission: clone, run: run, binding: binding) }
            let wrongLiteral = NativeExactUnsentMessageBinding(messageID: binding.messageID, logicalTaskID: binding.logicalTaskID,
                runID: binding.runID, attemptID: binding.attemptID, anchorID: binding.anchorID, originID: binding.originID,
                originRevision: binding.originRevision, exactRequestUTF8: binding.exactRequestUTF8, literalUTF8: Data(nfd.utf8))
            #expect(throws: (any Error).self) { try receipt.validate(staging: staging, submission: ticket, run: run, binding: wrongLiteral) }
            #expect(throws: (any Error).self) {
                try history.stageUserMessageForSubmission(message, run: run, submission: clone, binding: binding) { _ in Issue.record("Clone saved.") }
            }
            try receipt.validate(staging: staging, submission: ticket, run: run, binding: binding)
        }
    }

    @Test func foreignStagingCannotBorrowAnotherHistoryReceipt() async throws {
        try await withUserReceiptHistory { first in
            try await withUserReceiptHistory { second in
                let run = try AssistantConversationHistory.Run(logicalTaskID: UUID(), cause: .newRequest)
                let message = ChatMessage(role: "user", text: "identical saved bytes in independent journals")
                let a = ConversationSubmission(messageID: message.id, text: message.text)
                let b = ConversationSubmission(messageID: message.id, text: message.text), binding = userReceiptBinding(message, run)
                var firstSaved: AssistantConversationHistory.SavedUserMessage?, secondSaved: AssistantConversationHistory.SavedUserMessage?
                let firstStage = try first.stageUserMessageForSubmission(message, run: run, submission: a, binding: binding) { firstSaved = $0 }
                let secondStage = try second.stageUserMessageForSubmission(message, run: run, submission: b, binding: binding) { secondSaved = $0 }
                _ = try await first.flush(); _ = try await second.flush()
                let one = try #require(firstSaved), two = try #require(secondSaved)
                #expect(one.scope.storeID != two.scope.storeID)
                #expect(throws: (any Error).self) { try one.validate(staging: secondStage, submission: b, run: run, binding: binding) }
                #expect(throws: (any Error).self) { try two.validate(staging: firstStage, submission: a, run: run, binding: binding) }
                try one.validate(staging: firstStage, submission: a, run: run, binding: binding)
                try two.validate(staging: secondStage, submission: b, run: run, binding: binding)
            }
        }
    }

    @Test func entryDepositSurvivesCoalescingAndIgnoredSavedIDs() async throws {
        try await withUserReceiptHistory { history in
            let core = try await history.journalForTesting(), barrier = UserReceiptCommitBarrier()
            let run = try AssistantConversationHistory.Run(logicalTaskID: UUID(), cause: .newRequest)
            try history.stage(ChatMessage(role: "assistant", text: "ordinary existing write"), run: run, grants: [])
            await core.atNextBoundary(.beforeCommit) { barrier.pause() }
            let first = Task { @MainActor in _ = try await history.flush() }
            var second: Task<Void, Error>?
            do {
                try await waitForUserReceipt { barrier.entered }
                let message = ChatMessage(role: "user", text: "deposited by the existing writer")
                let ticket = ConversationSubmission(messageID: message.id, text: message.text), binding = userReceiptBinding(message, run)
                var deposited: AssistantConversationHistory.SavedUserMessage?, count = 0
                let staging = try history.stageUserMessageForSubmission(message, run: run, submission: ticket, binding: binding) { count += 1; deposited = $0 }
                second = Task { @MainActor in _ = try await history.flush() }
                barrier.release(); try await first.value; try await second?.value
                let receipt = try #require(deposited)
                try receipt.validate(staging: staging, submission: ticket, run: run, binding: binding)
                let records = try await userReceiptRecords(history)
                #expect(records.filter { if case .user = $0.event.payload { return true }; return false }.count == 1)
                #expect(count == 1 && !barrier.timedOut && ticket.status == .pending)
            } catch {
                barrier.release(); _ = try? await first.value; _ = try? await second?.value; throw error
            }
        }
    }

    @Test(arguments: [JournalFault.beforeCommit, .afterCommit])
    func failedDeliveryCannotReactivateOnActualStorageRepair(_ fault: JournalFault) async throws {
        try await withUserReceiptHistory { history in
            let core = try await history.journalForTesting()
            let run = try AssistantConversationHistory.Run(logicalTaskID: UUID(), cause: .newRequest)
            let message = ChatMessage(role: "user", text: "save failure preserves the request")
            let ticket = ConversationSubmission(messageID: message.id, text: message.text), binding = userReceiptBinding(message, run)
            var count = 0
            _ = try history.stageUserMessageForSubmission(message, run: run, submission: ticket, binding: binding) { _ in count += 1 }
            await core.injectFault(fault)
            let beforeCommit: Bool
            if case .beforeCommit = fault { beforeCommit = true } else { beforeCommit = false }
            do { _ = try await history.flush(); Issue.record("Expected the real journal fault.") }
            catch let error as JournalError { #expect(error == (beforeCommit ? .injectedBeforeCommit : .acknowledgmentLost)) }
            #expect(count == 0)
            let before = try await userReceiptRecords(history).filter { if case .user = $0.event.payload { return true }; return false }
            #expect(before.count == (beforeCommit ? 0 : 1))
            ticket.resolve(.failed)
            _ = try await history.flush()
            let after = try await userReceiptRecords(history).filter { if case .user = $0.event.payload { return true }; return false }
            #expect(after.count == 1 && count == 0)
            #expect(throws: (any Error).self) {
                try history.stageUserMessageForSubmission(message, run: run, submission: ticket, binding: binding) { _ in Issue.record("Failed ticket reminted.") }
            }
        }
    }

    @Test func samePendingStageMayReceiveAnActualLostAcknowledgmentRepairOnlyOnce() async throws {
        try await withUserReceiptHistory { history in
            let core = try await history.journalForTesting()
            let run = try AssistantConversationHistory.Run(logicalTaskID: UUID(), cause: .newRequest)
            let message = ChatMessage(role: "user", text: "the original still-pending request")
            let ticket = ConversationSubmission(messageID: message.id, text: message.text), binding = userReceiptBinding(message, run)
            var deposited: AssistantConversationHistory.SavedUserMessage?, count = 0
            let staging = try history.stageUserMessageForSubmission(message, run: run, submission: ticket, binding: binding) { count += 1; deposited = $0 }
            await core.injectFault(.afterCommit)
            do { _ = try await history.flush(); Issue.record("Expected lost acknowledgment.") }
            catch let error as JournalError { #expect(error == .acknowledgmentLost) }
            let committedRows = try await userReceiptRecords(history)
            let committed = try #require(committedRows.first { if case .user = $0.event.payload { return true }; return false })
            #expect(count == 0 && ticket.status == .pending)
            _ = try await history.flush(); let receipt = try #require(deposited)
            #expect(receipt.sequence == committed.sequence && receipt.recordDigest == committed.digest && count == 1)
            try receipt.validate(staging: staging, submission: ticket, run: run, binding: binding)
            _ = try await history.flush(); #expect(count == 1)
        }
    }

    @Test func savedGenericRowAndRestoreDoNotReconstructAReceipt() async throws {
        try await withUserReceiptHistory { history in
            let run = try AssistantConversationHistory.Run(logicalTaskID: UUID(), cause: .newRequest)
            let message = ChatMessage(role: "user", text: "existing plain visible request")
            try history.stage(message, run: run, grants: []); _ = try await history.flush()
            let ticket = ConversationSubmission(messageID: message.id, text: message.text), binding = userReceiptBinding(message, run)
            var count = 0
            _ = try history.stageUserMessageForSubmission(message, run: run, submission: ticket, binding: binding) { _ in count += 1 }
            let refusal = try await userReceiptFlushFailure(history)
            #expect(refusal == .conflictingID)
            _ = try await history.restore()
            let rows = try await userReceiptRecords(history).filter { if case .user = $0.event.payload { return true }; return false }
            #expect(rows.count == 1 && count == 0 && ticket.status == .pending)
        }
    }

    @Test func stopDuringActualResultReturnRetainsTheRowWithoutDepositingAToken() async throws {
        try await withUserReceiptHistory { history in
            let core = try await history.journalForTesting(), barrier = UserReceiptCommitBarrier()
            let run = try AssistantConversationHistory.Run(logicalTaskID: UUID(), cause: .newRequest)
            let message = ChatMessage(role: "user", text: "Stop after COMMIT before acknowledgment")
            let ticket = ConversationSubmission(messageID: message.id, text: message.text), binding = userReceiptBinding(message, run)
            var count = 0
            _ = try history.stageUserMessageForSubmission(message, run: run, submission: ticket, binding: binding) { _ in count += 1 }
            await core.atNextBoundary(.afterCommit) { barrier.pause() }
            let write = Task { @MainActor in _ = try await history.flush() }
            do {
                try await waitForUserReceipt { barrier.entered }
                history.stop(run); ticket.resolve(.stopped)
                barrier.release(); try await write.value
                let rows = try await userReceiptRecords(history).filter { if case .user = $0.event.payload { return true }; return false }
                #expect(rows.count == 1 && count == 0 && !barrier.timedOut)
                let later = ChatMessage(role: "user", text: "new message under the stopped run")
                let laterTicket = ConversationSubmission(messageID: later.id, text: later.text)
                #expect(throws: (any Error).self) {
                    try history.stageUserMessageForSubmission(later, run: run, submission: laterTicket, binding: userReceiptBinding(later, run)) { _ in Issue.record("Stopped run reminted.") }
                }
            } catch { barrier.release(); _ = try? await write.value; throw error }
        }
    }

    @Test(arguments: [false, true])
    func closeAndClearRevokeBeforeAwaitingAnOwnedCommittedWrite(_ clear: Bool) async throws {
        try await withUserReceiptHistory { history in
            let core = try await history.journalForTesting(), barrier = UserReceiptCommitBarrier()
            let run = try AssistantConversationHistory.Run(logicalTaskID: UUID(), cause: .newRequest)
            let first = ChatMessage(role: "user", text: "first live receipt"), second = ChatMessage(role: "user", text: "blocked next request")
            let firstTicket = ConversationSubmission(messageID: first.id, text: first.text), firstBinding = userReceiptBinding(first, run)
            let secondTicket = ConversationSubmission(messageID: second.id, text: second.text)
            var deposited: AssistantConversationHistory.SavedUserMessage?, secondCount = 0
            let firstStage = try history.stageUserMessageForSubmission(first, run: run, submission: firstTicket, binding: firstBinding) { deposited = $0 }
            _ = try await history.flush(); let receipt = try #require(deposited)
            try receipt.validate(staging: firstStage, submission: firstTicket, run: run, binding: firstBinding)
            _ = try history.stageUserMessageForSubmission(second, run: run, submission: secondTicket, binding: userReceiptBinding(second, run)) { _ in secondCount += 1 }
            await core.atNextBoundary(.afterCommit) { barrier.pause() }
            let write = Task { @MainActor in _ = try await history.flush() }
            var retiring: Task<Void, Error>?, retirementEntered = false
            do {
                try await waitForUserReceipt { barrier.entered }
                retiring = Task { @MainActor in
                    retirementEntered = true
                    if clear { try await history.clear() } else { try await history.close() }
                }
                try await waitForUserReceipt { retirementEntered }
                #expect(throws: (any Error).self) { try receipt.validate(staging: firstStage, submission: firstTicket, run: run, binding: firstBinding) }
                barrier.release(); try await write.value; try await retiring?.value
                #expect(secondCount == 0 && !barrier.timedOut)
                if clear {
                    let retired = ChatMessage(role: "user", text: "old run in a cleared generation")
                    let retiredTicket = ConversationSubmission(messageID: retired.id, text: retired.text)
                    #expect(throws: (any Error).self) {
                        try history.stageUserMessageForSubmission(retired, run: run, submission: retiredTicket, binding: userReceiptBinding(retired, run)) { _ in Issue.record("Clear renewed the old run.") }
                    }
                    let freshRun = try AssistantConversationHistory.Run(logicalTaskID: UUID(), cause: .newRequest)
                    let next = ChatMessage(role: "user", text: "new generation"), ticket = ConversationSubmission(messageID: UUID(), text: "wrong ticket")
                    #expect(throws: (any Error).self) {
                        try history.stageUserMessageForSubmission(next, run: freshRun, submission: ticket, binding: userReceiptBinding(next, freshRun)) { _ in Issue.record("Wrong ticket saved.") }
                    }
                    let correct = ConversationSubmission(messageID: next.id, text: next.text), binding = userReceiptBinding(next, freshRun)
                    var nextSaved: AssistantConversationHistory.SavedUserMessage?
                    let stage = try history.stageUserMessageForSubmission(next, run: freshRun, submission: correct, binding: binding) { nextSaved = $0 }
                    _ = try await history.flush(); let newer = try #require(nextSaved)
                    #expect(newer.scope.storeID == receipt.scope.storeID && newer.scope.generation != receipt.scope.generation)
                    try newer.validate(staging: stage, submission: correct, run: freshRun, binding: binding)
                } else {
                    #expect(throws: (any Error).self) {
                        try history.stageUserMessageForSubmission(first, run: run, submission: firstTicket, binding: firstBinding) { _ in Issue.record("Closed issuer saved.") }
                    }
                }
            } catch {
                barrier.release(); _ = try? await write.value; _ = try? await retiring?.value; throw error
            }
        }
    }

    @Test func depositReentryCanRevokeButCannotRemintOrDuplicateDelivery() async throws {
        try await withUserReceiptHistory { history in
            let run = try AssistantConversationHistory.Run(logicalTaskID: UUID(), cause: .newRequest)
            let message = ChatMessage(role: "user", text: "one entry one deposit")
            let ticket = ConversationSubmission(messageID: message.id, text: message.text), binding = userReceiptBinding(message, run)
            var deposited: AssistantConversationHistory.SavedUserMessage?, count = 0
            let staging = try history.stageUserMessageForSubmission(message, run: run, submission: ticket, binding: binding) {
                count += 1; deposited = $0; history.stop(run)
            }
            _ = try await history.flush(); let receipt = try #require(deposited)
            #expect(throws: (any Error).self) { try receipt.validate(staging: staging, submission: ticket, run: run, binding: binding) }
            #expect(throws: (any Error).self) {
                try history.stageUserMessageForSubmission(message, run: run, submission: ticket, binding: binding) { _ in Issue.record("Reentry reminted.") }
            }
            _ = try await history.flush(); #expect(count == 1)
        }
    }

    @Test func explicitRevocationAndOriginalTicketLifetimeCannotBeReconstructed() async throws {
        try await withUserReceiptHistory { history in
            let run = try AssistantConversationHistory.Run(logicalTaskID: UUID(), cause: .newRequest)
            let revoked = ChatMessage(role: "user", text: "explicitly retired request")
            let ticket = ConversationSubmission(messageID: revoked.id, text: revoked.text), binding = userReceiptBinding(revoked, run)
            var count = 0
            let staging = try history.stageUserMessageForSubmission(revoked, run: run, submission: ticket, binding: binding) { _ in count += 1 }
            history.revokeUserMessage(staging)
            #expect(throws: (any Error).self) {
                try history.stageUserMessageForSubmission(revoked, run: run, submission: ticket, binding: binding) { _ in Issue.record("Revoked ID reminted.") }
            }
            let abandoned = ChatMessage(role: "user", text: "original ticket released")
            var original: ConversationSubmission? = ConversationSubmission(messageID: abandoned.id, text: abandoned.text)
            weak var weakOriginal = original
            do {
                let owned = try #require(original)
                _ = try history.stageUserMessageForSubmission(abandoned, run: run, submission: owned, binding: userReceiptBinding(abandoned, run)) { _ in count += 1 }
            }
            original = nil
            #expect(weakOriginal == nil)
            _ = try await history.flush()
            let rows = try await userReceiptRecords(history).filter { if case .user = $0.event.payload { return true }; return false }
            #expect(rows.count == 2 && count == 0)
        }
    }

    @Test func olderGenericRowCannotBeLaunderedByDuplicateCommitAcknowledgmentLoss() async throws {
        try await withUserReceiptHistory { history in
            let core = try await history.journalForTesting(), boundary = UserReceiptBoundaryCounter()
            let run = try AssistantConversationHistory.Run(logicalTaskID: UUID(), cause: .newRequest)
            let message = ChatMessage(role: "user", text: "older generic cafe\u{301} request", date: Date(timeIntervalSince1970: 654.321))
            try history.stage(message, run: run, grants: []); _ = try await history.flush()
            let originalRows = try await userReceiptRecords(history)
            let original = try #require(originalRows.first { $0.event.id.bytes == Data(message.id.uuidString.utf8) })
            let ticket = ConversationSubmission(messageID: message.id, text: message.text), binding = userReceiptBinding(message, run)
            var receipts = 0
            _ = try history.stageUserMessageForSubmission(message, run: run, submission: ticket, binding: binding) { _ in receipts += 1 }
            await core.atNextBoundary(.afterCommit) { boundary.record() }
            await core.injectFault(.afterCommit)
            // Do not stop on a misclassified first error: the second real flush
            // exposes the original producer's actual duplicate-row token mint.
            let first = try await userReceiptFlushFailure(history)
            let repair = try await userReceiptFlushFailure(history)
            #expect(first == .conflictingID && repair == .conflictingID)
            #expect(receipts == 0 && ticket.status == .pending && boundary.count == 0)
            let rows = try await userReceiptRecords(history)
            #expect(rows.count == originalRows.count)
            let retained = try #require(rows.first { $0.event.id.bytes == original.event.id.bytes })
            #expect(retained.sequence == original.sequence && retained.digest == original.digest)
            // Consume the STILL-ARMED fault through an unrelated genuine write,
            // not clear/reset or another retry of the rejected pending entry.
            let sentinel = JournalEvent(id: try JournalOpaqueID(UUID().uuidString), taskID: run.taskID,
                attemptID: run.attemptID, payload: .assistant(try JournalVisibleText("owned fault witness", origin: .assistant)))
            var sentinelFailure: JournalError?
            do { _ = try await core.appendBatch([sentinel], expectedScope: original.scope) }
            catch let error as JournalError { sentinelFailure = error }
            #expect(sentinelFailure == .acknowledgmentLost && boundary.count == 1)
            let witnessed = try await userReceiptRecords(history)
            #expect(witnessed.count == originalRows.count + 1)
            #expect(witnessed.contains { $0.event.id.bytes == sentinel.id.bytes })
            #expect(receipts == 0)
        }
    }

    @Test func reopenedHistoryCannotReissueAnOlderRowOrConsumeItsArmedFault() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-user-receipt-reopen-" + UUID().uuidString)
        let state = root.appendingPathComponent("state.json"), first = AssistantConversationHistory(stateURL: state)
        var reopened: AssistantConversationHistory?
        do {
            let run = try AssistantConversationHistory.Run(logicalTaskID: UUID(), cause: .newRequest)
            let message = ChatMessage(role: "user", text: "persisted before actual History reopen", date: Date(timeIntervalSince1970: 321.654))
            try first.stage(message, run: run, grants: []); _ = try await first.flush()
            let prior = try await userReceiptRecords(first)
            let original = try #require(prior.first { $0.event.id.bytes == Data(message.id.uuidString.utf8) })
            try await first.close()
            let second = AssistantConversationHistory(stateURL: state); reopened = second
            let restored = try await second.restore(), core = try await second.journalForTesting()
            #expect(restored.messages.contains { $0.id == message.id && Data($0.text.utf8) == Data(message.text.utf8) })
            let before = try await userReceiptRecords(second), boundary = UserReceiptBoundaryCounter()
            let ticket = ConversationSubmission(messageID: message.id, text: message.text), binding = userReceiptBinding(message, run)
            var receipts = 0
            _ = try second.stageUserMessageForSubmission(message, run: run, submission: ticket, binding: binding) { _ in receipts += 1 }
            await core.atNextBoundary(.afterCommit) { boundary.record() }
            await core.injectFault(.afterCommit)
            let failure = try await userReceiptFlushFailure(second)
            let repair = try await userReceiptFlushFailure(second)
            #expect(failure == .conflictingID && repair == .conflictingID)
            #expect(receipts == 0 && boundary.count == 0)
            let after = try await userReceiptRecords(second)
            #expect(after.count == before.count)
            let retained = try #require(after.first { $0.event.id.bytes == original.event.id.bytes })
            #expect(retained.sequence == original.sequence && retained.digest == original.digest)
            // Old producer also consumed a fault before rejecting its recreated
            // start record. The corrected atomic precondition must preserve it.
            let freshRun = try AssistantConversationHistory.Run(logicalTaskID: UUID(), cause: .newRequest)
            let sentinelID = try JournalOpaqueID(UUID().uuidString)
            var sentinelFailure: JournalError?
            do {
                _ = try await core.acceptRequest(id: sentinelID, taskID: freshRun.taskID, attemptID: freshRun.attemptID,
                    text: JournalVisibleText("owned fresh-run fault witness", origin: .user), relation: freshRun.relation,
                    expectedScope: original.scope)
            } catch let error as JournalError { sentinelFailure = error }
            #expect(sentinelFailure == .acknowledgmentLost && boundary.count == 1)
            let witnessed = try await userReceiptRecords(second)
            #expect(witnessed.count == before.count + 2 && witnessed.contains { $0.event.id == sentinelID })
            #expect(receipts == 0)
            try await second.close(); try FileManager.default.removeItem(at: root)
        } catch {
            try? await reopened?.close(); try? await first.close()
            try? FileManager.default.removeItem(at: root); throw error
        }
    }
}
