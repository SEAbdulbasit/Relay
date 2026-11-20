import Foundation
import Testing
@testable import Relay
@testable import RelayJournal

/// Uses actual owned SQLite returns, never a SavedUserMessage/token/ACK maker.
@MainActor struct SavedUserMessageBindingLeaseTests {
    private typealias History = AssistantConversationHistory
    private struct Saved {
        let run: History.Run
        let message: ChatMessage
        let ticket: ConversationSubmission
        let binding: NativeExactUnsentMessageBinding
        let staging: History.UserMessageStaging
        let receipt: History.SavedUserMessage
        let bound: History.SavedUserMessage.ValidatedBinding
    }
    private func withHistory(_ body: @MainActor (History) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "relay-saved-binding-\(UUID().uuidString)")
        let history = History(stateURL: root.appending(path: "state.json"))
        do {
            try await body(history); try await history.close(); try FileManager.default.removeItem(at: root)
        } catch {
            try? await history.close(); try? FileManager.default.removeItem(at: root); throw error
        }
    }
    private func save(_ history: History, text: String = "A genuine saved request", lostAcknowledgment: Bool = false) async throws -> Saved {
        let run = try History.Run(logicalTaskID: UUID(), cause: .newRequest)
        let message = ChatMessage(role: "user", text: text)
        let ticket = ConversationSubmission(messageID: message.id, text: text)
        let binding = NativeExactUnsentMessageBinding(messageID: message.id, logicalTaskID: run.relation.logicalTaskID,
            runID: run.taskID, attemptID: run.attemptID, anchorID: UUID(), originID: UUID(), originRevision: 3,
            exactRequestUTF8: Data(text.utf8), literalUTF8: Data("unchanged exact literal".utf8))
        var deposited: History.SavedUserMessage?, deposits = 0
        let staging = try history.stageUserMessageForSubmission(message, run: run, submission: ticket, binding: binding) {
            deposits += 1; deposited = $0
        }
        if lostAcknowledgment {
            let core = try await history.journalForTesting()
            await core.injectFault(.afterCommit)
            do { _ = try await history.flush(); Issue.record("Expected the actual lost acknowledgment.") }
            catch let error as JournalError { #expect(error == .acknowledgmentLost) }
            #expect(deposited == nil && deposits == 0 && ticket.status == .pending)
        }
        _ = try await history.flush()
        let receipt = try #require(deposited)
        #expect(deposits == 1 && ticket.status == .pending)
        let bound = try receipt.bindValidated(staging: staging, submission: ticket, run: run, binding: binding)
        return Saved(run: run, message: message, ticket: ticket, binding: binding,
            staging: staging, receipt: receipt, bound: bound)
    }

    @Test func genuineBindingRemainsCurrentAcrossManyMetadataChecksWithoutAcknowledgingOrDuplicatingUserRows() async throws {
        try await withHistory { history in
            let exact = "\n\tCaf\u{00e9} literal\n" + String(repeating: "immutable original request 🌍 ", count: 700)
            let saved = try await save(history, text: exact)
            for _ in 0..<1_100 { try saved.bound.validate() }
            #expect(saved.ticket.status == .pending)
            #expect(throws: (any Error).self) {
                try NativeExactUnsentAcknowledgment.bindSavedMessage(saved.ticket, run: saved.run)
            }
            saved.ticket.resolve(.saved)
            for _ in 0..<1_100 { try saved.bound.validate() }
            // The original full API still checks the actual byte binding.
            try saved.receipt.validate(staging: saved.staging, submission: saved.ticket, run: saved.run, binding: saved.binding)
            let core = try await history.journalForTesting(), scope = try await core.scope()
            let rows = try await core.page(expectedScope: scope).records
            #expect(rows.filter { if case .user = $0.event.payload { return true }; return false }.count == 1)
            history.stop(saved.run)
            #expect(throws: History.UserMessageReceiptFailure.unavailable) { try saved.bound.validate() }
        }
    }

    @Test(arguments: UserReceiptChangedField.allCases)
    func sealedBindingCannotBeMintedForChangedImmutableNamespaceOrBytes(_ field: UserReceiptChangedField) async throws {
        try await withHistory { history in
            let saved = try await save(history)
            let wrong = field.changing(saved.binding)
            #expect(throws: History.UserMessageReceiptFailure.unavailable) {
                try saved.receipt.bindValidated(staging: saved.staging, submission: saved.ticket, run: saved.run, binding: wrong)
            }
            try saved.bound.validate()
        }
    }

    @Test func byteEquivalentCloneAndForeignStagingCannotBorrowTheActualSavedBinding() async throws {
        try await withHistory { first in
            try await withHistory { second in
                let saved = try await save(first, text: "Caf\u{00e9}")
                let clone = ConversationSubmission(messageID: saved.message.id, text: saved.message.text)
                clone.resolve(.saved)
                #expect(throws: History.UserMessageReceiptFailure.unavailable) {
                    try saved.receipt.bindValidated(staging: saved.staging, submission: clone, run: saved.run, binding: saved.binding)
                }
                let foreign = ConversationSubmission(messageID: saved.message.id, text: saved.message.text)
                var secondReceipt: History.SavedUserMessage?
                let stage = try second.stageUserMessageForSubmission(saved.message, run: saved.run,
                    submission: foreign, binding: saved.binding) { secondReceipt = $0 }
                _ = try await second.flush()
                #expect(secondReceipt != nil)
                #expect(throws: History.UserMessageReceiptFailure.unavailable) {
                    try saved.receipt.bindValidated(staging: stage, submission: foreign, run: saved.run, binding: saved.binding)
                }
                let alias = NativeExactUnsentMessageBinding(messageID: saved.binding.messageID,
                    logicalTaskID: saved.binding.logicalTaskID, runID: saved.binding.runID, attemptID: saved.binding.attemptID,
                    anchorID: saved.binding.anchorID, originID: saved.binding.originID, originRevision: saved.binding.originRevision,
                    exactRequestUTF8: Data("Cafe\u{0301}".utf8), literalUTF8: saved.binding.literalUTF8)
                #expect(throws: History.UserMessageReceiptFailure.unavailable) {
                    try saved.receipt.bindValidated(staging: saved.staging, submission: saved.ticket, run: saved.run, binding: alias)
                }
                try saved.bound.validate()
            }
        }
    }

    @Test(arguments: ["revoke", "stop", "failed", "stopped", "clear", "close"])
    func everyLiveHistoryAndDeliveryRevocationStillRefusesTheSealedBinding(_ change: String) async throws {
        try await withHistory { history in
            let saved = try await save(history)
            try saved.bound.validate()
            switch change {
            case "revoke": history.revokeUserMessage(saved.staging)
            case "stop": history.stop(saved.run)
            case "failed": saved.ticket.resolve(.failed)
            case "stopped": saved.ticket.resolve(.stopped)
            case "clear": try await history.clear()
            default: try await history.close()
            }
            #expect(throws: History.UserMessageReceiptFailure.unavailable) { try saved.bound.validate() }
            #expect(throws: History.UserMessageReceiptFailure.unavailable) {
                try saved.receipt.bindValidated(staging: saved.staging, submission: saved.ticket, run: saved.run, binding: saved.binding)
            }
        }
    }

    @Test func sameStageActualLostAcknowledgmentRepairCanBindOnceAndClearNeverRenewsTheOldBinding() async throws {
        try await withHistory { history in
            let saved = try await save(history, lostAcknowledgment: true)
            try saved.bound.validate()
            _ = try await history.flush()
            try saved.bound.validate()
            let oldScope = saved.receipt.scope
            try await history.clear()
            let fresh = try await save(history, text: "Fresh request in new generation")
            #expect(fresh.receipt.scope.storeID == oldScope.storeID)
            #expect(fresh.receipt.scope.generation != oldScope.generation)
            #expect(throws: History.UserMessageReceiptFailure.unavailable) { try saved.bound.validate() }
            try fresh.bound.validate()
        }
    }

    @Test func taskCancellationCannotBeHiddenByAnAlreadyValidatedImmutableBinding() async throws {
        try await withHistory { history in
            let saved = try await save(history)
            // MainActor cannot run this child before the synchronous cancel.
            // The actual binding validator, not a sleep, observes cancellation.
            let task = Task { @MainActor in try saved.bound.validate() }
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            // Cancellation of a caller does not fabricate history revocation.
            try saved.bound.validate()
        }
    }
}
