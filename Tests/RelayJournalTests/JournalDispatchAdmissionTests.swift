import Foundation
import Testing
@testable import RelayJournal

private enum OwnedAdmissionFailure: Error, Equatable { case changedSource }

@MainActor private final class OwnedAdmissionPause {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { let value = continuation; continuation = nil; value?.resume() }
}

@MainActor private func waitForOwnedAdmission(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !condition() {
        guard ContinuousClock.now < deadline else { throw OwnedAdmissionFailure.changedSource }
        try await Task.sleep(for: .milliseconds(2))
    }
}

/// Real SQLite and the actual lexical checkpoint. The suspendable callback is
/// an inert admission predicate, never a substitute database or action result.
@MainActor @Suite(.serialized) struct JournalDispatchAdmissionTests {
    @Test func stopWhileAdmissionAwaitsSavesKnownNonDispatchWithAnEmptyCallerValidate() async throws {
        let root = temporaryJournal(); defer { cleanup(root) }
        let journal = try await ConversationJournal.open(directory: root), scope = try await journal.scope()
        let (task, attempt) = try await start(journal, scope: scope)
        let event = try intentEvent(journal, task: task, attempt: attempt)
        guard case let .intent(intent) = event.payload else { throw JournalError.invalidEvent }
        let checkpoint = JournalDispatchCheckpoint(journal: journal), pause = OwnedAdmissionPause()
        var effects = 0
        let pending = Task { @MainActor in
            try await checkpoint.execute(event, expectedScope: scope, validate: {}, admitAction: {
                await pause.wait()
            }, action: { effects += 1; return JournalToolOutcome(intent: intent, kind: .returnedVerified) })
        }
        do {
            try await waitForOwnedAdmission { pause.entered }
            #expect(try await journal.page(expectedScope: scope).records.count == 3)
            checkpoint.stop(); pause.release()
            await assertFailure(.dispatchRevoked) { _ = try await pending.value }
            #expect(effects == 0 && checkpoint.pendingResultCount == 0)
            guard case let .result(outcome) = try await journal.page(expectedScope: scope).records.last?.event.payload else { throw JournalError.invalidEvent }
            #expect(outcome.kind == .notDispatched && outcome.invocationID == intent.invocationID)
            try await journal.close()
        } catch {
            pending.cancel(); pause.release(); _ = await pending.result
            try? await journal.close(); throw error
        }
    }

    @Test(arguments: [false, true]) func cancellationOrChangedCallerGuardAfterAdmissionNeverStartsTheAction(_ cancel: Bool) async throws {
        let root = temporaryJournal(); defer { cleanup(root) }
        let journal = try await ConversationJournal.open(directory: root), scope = try await journal.scope()
        let (task, attempt) = try await start(journal, scope: scope)
        let event = try intentEvent(journal, task: task, attempt: attempt)
        guard case let .intent(intent) = event.payload else { throw JournalError.invalidEvent }
        let checkpoint = JournalDispatchCheckpoint(journal: journal), pause = OwnedAdmissionPause()
        var current = true, effects = 0
        let pending = Task { @MainActor in
            try await checkpoint.execute(event, expectedScope: scope, validate: {
                if !current { throw OwnedAdmissionFailure.changedSource }
            }, admitAction: { await pause.wait() }, action: {
                effects += 1; return JournalToolOutcome(intent: intent, kind: .returnedVerified)
            })
        }
        do {
            try await waitForOwnedAdmission { pause.entered }
            if cancel { pending.cancel() } else { current = false }
            pause.release()
            if cancel { await #expect(throws: CancellationError.self) { _ = try await pending.value } }
            else { await #expect(throws: OwnedAdmissionFailure.changedSource) { _ = try await pending.value } }
            #expect(effects == 0)
            guard case let .result(outcome) = try await journal.page(expectedScope: scope).records.last?.event.payload else { throw JournalError.invalidEvent }
            #expect(outcome.kind == .notDispatched)
            try await journal.close()
        } catch {
            pending.cancel(); pause.release(); _ = await pending.result
            try? await journal.close(); throw error
        }
    }

    @Test(arguments: ["none", "beforeCommit", "afterCommit"])
    func rejectedAdmissionUsesStorageOnlyResultRepairAndCannotRemintItsProposal(_ fault: String) async throws {
        let root = temporaryJournal(); defer { cleanup(root) }
        let journal = try await ConversationJournal.open(directory: root), scope = try await journal.scope()
        let (task, attempt) = try await start(journal, scope: scope)
        let event = try intentEvent(journal, task: task, attempt: attempt)
        guard case let .intent(intent) = event.payload else { throw JournalError.invalidEvent }
        let checkpoint = JournalDispatchCheckpoint(journal: journal)
        var admissions = 0, effects = 0
        do {
            _ = try await checkpoint.execute(event, expectedScope: scope, validate: {}, admitAction: {
                admissions += 1
                if fault == "beforeCommit" { await journal.injectFault(.beforeCommit) }
                if fault == "afterCommit" { await journal.injectFault(.afterCommit) }
                throw OwnedAdmissionFailure.changedSource
            }, action: { effects += 1; return JournalToolOutcome(intent: intent, kind: .returnedVerified) })
            Issue.record("The rejected admission unexpectedly returned a result.")
        } catch {
            if fault == "none" { #expect(error as? OwnedAdmissionFailure == .changedSource) }
            else { #expect(error as? JournalError == (fault == "beforeCommit" ? .injectedBeforeCommit : .acknowledgmentLost)) }
        }
        #expect(admissions == 1 && effects == 0)
        if fault != "none" {
            #expect(checkpoint.pendingResultCount == 1)
            _ = try await checkpoint.savePendingResult(invocationID: intent.invocationID)
        }
        #expect(checkpoint.pendingResultCount == 0)
        let reminted = try intentEvent(journal, task: task, attempt: attempt, callID: "call")
        await assertFailure(.duplicateIntent) {
            _ = try await checkpoint.execute(reminted, expectedScope: scope, validate: {}, admitAction: {
                admissions += 1
            }, action: { effects += 1; return JournalToolOutcome(intent: intent, kind: .returnedVerified) })
        }
        #expect(admissions == 1 && effects == 0)
        let records = try await journal.page(expectedScope: scope).records
        #expect(records.count == 4)
        guard case let .result(outcome) = records.last?.event.payload else { throw JournalError.invalidEvent }
        #expect(outcome.kind == .notDispatched)
        try await journal.close()
    }

    @Test func lostIntentAcknowledgmentNeverInvokesAdmissionOrActionAgain() async throws {
        let root = temporaryJournal(); defer { cleanup(root) }
        let journal = try await ConversationJournal.open(directory: root), scope = try await journal.scope()
        let (task, attempt) = try await start(journal, scope: scope)
        let event = try intentEvent(journal, task: task, attempt: attempt)
        guard case let .intent(intent) = event.payload else { throw JournalError.invalidEvent }
        let checkpoint = JournalDispatchCheckpoint(journal: journal)
        var admissions = 0, effects = 0
        await journal.injectIntentFault(.afterCommit)
        await assertFailure(.acknowledgmentLost) {
            _ = try await checkpoint.execute(event, expectedScope: scope, validate: {}, admitAction: {
                admissions += 1
            }, action: { effects += 1; return JournalToolOutcome(intent: intent, kind: .returnedVerified) })
        }
        let reminted = try intentEvent(journal, task: task, attempt: attempt)
        await assertFailure(.duplicateIntent) {
            _ = try await checkpoint.execute(reminted, expectedScope: scope, validate: {}, admitAction: {
                admissions += 1
            }, action: { effects += 1; return JournalToolOutcome(intent: intent, kind: .returnedVerified) })
        }
        #expect(admissions == 0 && effects == 0)
        #expect(try await journal.page(expectedScope: scope).records.count == 3)
        try await journal.close()
    }

    @Test func stopAfterTheActualActionStartsStillSavesTheOriginalFactualOutcome() async throws {
        let root = temporaryJournal(); defer { cleanup(root) }
        let journal = try await ConversationJournal.open(directory: root), scope = try await journal.scope()
        let (task, attempt) = try await start(journal, scope: scope)
        let event = try intentEvent(journal, task: task, attempt: attempt)
        guard case let .intent(intent) = event.payload else { throw JournalError.invalidEvent }
        let checkpoint = JournalDispatchCheckpoint(journal: journal), pause = OwnedAdmissionPause()
        var admissions = 0, effects = 0
        let pending = Task { @MainActor in
            try await checkpoint.execute(event, expectedScope: scope, validate: {}, admitAction: {
                admissions += 1
            }, action: {
                effects += 1; await pause.wait()
                return JournalToolOutcome(intent: intent, kind: .returnedVerified)
            })
        }
        do {
            try await waitForOwnedAdmission { pause.entered }
            checkpoint.stop(); pause.release()
            let result = try await pending.value
            guard case let .result(outcome) = result.event.payload else { throw JournalError.invalidEvent }
            #expect(admissions == 1 && effects == 1 && outcome.kind == .returnedVerified)
            try await journal.close()
        } catch {
            pending.cancel(); pause.release(); _ = await pending.result
            try? await journal.close(); throw error
        }
    }

    @Test(arguments: [false, true]) func extraPostAwaitValidationOccursOnlyWhenAdmissionExists(_ bound: Bool) async throws {
        let root = temporaryJournal(); defer { cleanup(root) }
        let journal = try await ConversationJournal.open(directory: root), scope = try await journal.scope()
        let (task, attempt) = try await start(journal, scope: scope)
        let event = try intentEvent(journal, task: task, attempt: attempt)
        guard case let .intent(intent) = event.payload else { throw JournalError.invalidEvent }
        let checkpoint = JournalDispatchCheckpoint(journal: journal)
        var validations = 0, admissions = 0, effects = 0
        let admit: (@MainActor @Sendable () async throws -> Void)? = bound ? { @MainActor in admissions += 1 } : nil
        _ = try await checkpoint.execute(event, expectedScope: scope, validate: { validations += 1 }, admitAction: admit,
            action: { effects += 1; return JournalToolOutcome(intent: intent, kind: .returnedVerified) })
        #expect(validations == (bound ? 3 : 2) && admissions == (bound ? 1 : 0) && effects == 1)
        try await journal.close()
    }
}
