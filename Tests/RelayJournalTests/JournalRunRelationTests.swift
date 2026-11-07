import Foundation
import Testing
@testable import RelayJournal

@Suite(.serialized) struct JournalRunRelationTests {
    @Test func steeringAndResumeKeepLogicalIdentityAndPriorFactualOutcomes() async throws {
        let root = temporaryJournal(); defer { cleanup(root) }
        let journal = try await ConversationJournal.open(directory: root), scope = try await journal.scope()
        let logical = UUID(), first = UUID(), second = UUID(), resumed = UUID(), a = UUID(), b = UUID(), c = UUID()
        let original = try JournalRunRelation(logicalTaskID: logical, cause: .newRequest)
        _ = try await journal.acceptRequest(id: JournalOpaqueID("original"), taskID: first, attemptID: a, text: JournalVisibleText("Original exact task", origin: .user), relation: original, expectedScope: scope)
        let oldCall = try intentEvent(journal, task: first, attempt: a)
        _ = try await journal.commitIntent(oldCall, expectedScope: scope)
        let steering = try JournalRunRelation(logicalTaskID: logical, predecessorRunID: first, cause: .steering)
        _ = try await journal.acceptRequest(id: JournalOpaqueID("steering"), taskID: second, attemptID: b, text: JournalVisibleText("Keep the draft unchanged", origin: .user), relation: steering, expectedScope: scope)
        _ = try await journal.finishTask(JournalEvent(id: JournalOpaqueID("old-stop"), taskID: first, attemptID: a, payload: .finished(.interrupted)), expectedScope: scope)
        _ = try await journal.commitResult(resultEvent(oldCall), expectedScope: scope)
        _ = try await journal.finishTask(JournalEvent(id: JournalOpaqueID("second-stop"), taskID: second, attemptID: b, payload: .finished(.stopped)), expectedScope: scope)
        let resume = try JournalRunRelation(logicalTaskID: logical, predecessorRunID: second, cause: .resume)
        _ = try await journal.acceptRequest(id: JournalOpaqueID("resume"), taskID: resumed, attemptID: c, text: JournalVisibleText("Continue after fresh observation", origin: .user), relation: resume, expectedScope: scope)
        let records = try await journal.page(expectedScope: scope).records
        let links = records.compactMap { record -> JournalRunRelation? in if case let .started(_, relation) = record.event.payload { return relation }; return nil }
        #expect(links == [original, steering, resume])
        #expect(records.contains(where: { $0.event.taskID == first && $0.event.payload.kind == 6 }))
        #expect(records.contains(where: { if case let .user(text) = $0.event.payload { return text.text == "Keep the draft unchanged" }; return false }))
        try await journal.close()
    }
    @Test func missingWrongLogicalOrSelfPredecessorsRefuse() async throws {
        let root = temporaryJournal(); defer { cleanup(root) }
        let journal = try await ConversationJournal.open(directory: root), scope = try await journal.scope()
        let first = UUID(), logical = UUID()
        _ = try await journal.acceptRequest(id: JournalOpaqueID("first"), taskID: first, attemptID: UUID(), text: JournalVisibleText("Task", origin: .user), relation: JournalRunRelation(logicalTaskID: logical, cause: .newRequest), expectedScope: scope)
        for predecessor in [first, UUID()] {
            let relation = try JournalRunRelation(logicalTaskID: UUID(), predecessorRunID: predecessor, cause: .steering)
            await assertFailure(.invalidTransition) { _ = try await journal.acceptRequest(id: JournalOpaqueID(UUID().uuidString), taskID: UUID(), attemptID: UUID(), text: JournalVisibleText("Invalid relation", origin: .user), relation: relation, expectedScope: scope) }
        }
        let own = UUID(), selfRelation = try JournalRunRelation(logicalTaskID: logical, predecessorRunID: own, cause: .resume)
        await assertFailure(.invalidEvent) { _ = try await journal.acceptRequest(id: JournalOpaqueID("self"), taskID: own, attemptID: UUID(), text: JournalVisibleText("Invalid self", origin: .user), relation: selfRelation, expectedScope: scope) }
        #expect(try await journal.page(expectedScope: scope).records.count == 2)
        try await journal.close()
    }
    @Test(arguments: [JournalTaskOutcome.responseDelivered, .needsInput]) func neutralDeliveryIsNeitherFailureNorGoalSuccess(_ outcome: JournalTaskOutcome) async throws {
        let root = temporaryJournal(); defer { cleanup(root) }
        let journal = try await ConversationJournal.open(directory: root), scope = try await journal.scope()
        let (task, attempt) = try await start(journal, scope: scope)
        let event = JournalEvent(id: try JournalOpaqueID("neutral"), taskID: task, attemptID: attempt, payload: .finished(outcome))
        _ = try await journal.finishTask(event, expectedScope: scope)
        var projection = JournalProjection(); try projection.apply(try await journal.page(expectedScope: scope).records)
        #expect(projection.taskOutcomes[task] == outcome)
        #expect(projection.taskOutcomes[task] != .success); #expect(projection.taskOutcomes[task] != .failed)
        try await journal.close()
    }
}
