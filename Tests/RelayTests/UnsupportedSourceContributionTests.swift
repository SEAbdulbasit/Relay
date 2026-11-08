import Foundation
import Testing
@testable import Relay

@MainActor private func taintContext(_ task: UUID, scope: UUID = UUID(), model: String = "caf\u{e9}", revision: Int = 0) -> MultiAgentContinuation.Context {
    .init(logicalTaskID: task, configuration: .init(model: model), scopeID: scope, sourceRevision: revision)
}
@MainActor private func taintPreparation(_ book: MultiAgentContinuation, _ call: ToolCall,
                                       context: MultiAgentContinuation.Context,
                                       run: AssistantConversationHistory.Run,
                                       proposal: UUID = UUID()) async throws -> MultiAgentContinuation.Preparation {
    try #require(try await book.prepare(call, proposalID: proposal, run: run, context: context, grants: { [] }))
}
@MainActor private func taintSnapshot(_ book: MultiAgentContinuation, context: MultiAgentContinuation.Context) async throws -> MultiAgentContinuation.Snapshot {
    try await book.snapshot(context: context, isCurrent: { true })
}

/// Metadata, synthetic DTOs and actual receipt-book code only. No Store task,
/// SQLite, provider, model, source body, UI, native input or tool is executed.
@MainActor @Suite(.serialized) struct UnsupportedSourceContributionTests {
    @Test func metadataThenActualUnsupportedResultCountsOnceAndTaintsLaterDerivedFacts() async throws {
        let task = UUID(), context = taintContext(task), book = MultiAgentContinuation()
        let run = try AssistantConversationHistory.Run(logicalTaskID: task, cause: .newRequest), proposal = UUID()
        book.startTask(task)
        let call = ToolCall(id: "original", name: "control_native_window", arguments: [:])
        let prepared = try await taintPreparation(book, call, context: context, run: run, proposal: proposal)
        #expect(!prepared.supported && book.markUnsupportedSourceContribution(prepared: prepared, currentContext: context))
        await book.record(.init(summary: "UNSUPPORTED_PRIVATE_DETAIL", evidence: "Synthetic native report", verified: true), prepared: prepared, grants: { [] })
        book.acknowledge(prepared)
        let repeatedPreparation = try await taintPreparation(book, call, context: context, run: run, proposal: proposal)
        #expect(book.markUnsupportedSourceContribution(prepared: repeatedPreparation, currentContext: context))
        let first = try await taintSnapshot(book, context: context)
        #expect(first.included == 0 && first.omitted == 1 && !first.modelContext.contains("UNSUPPORTED_PRIVATE_DETAIL"))
        let derived = try await taintPreparation(book, .init(id: "derived", name: "calculate", arguments: ["expression": .string("2+5")]), context: context, run: run)
        #expect(!derived.supported)
        await book.record(.init(summary: "DERIVED_PRIVATE_FACT", evidence: "Synthetic derived result", verified: true), prepared: derived, grants: { [] })
        book.acknowledge(derived)
        let after = try await taintSnapshot(book, context: context)
        #expect(after.included == 0 && after.omitted == 2 && !after.modelContext.contains("DERIVED_PRIVATE_FACT"))
    }

    @Test(arguments: ["same-task-new-epoch", "replacement-task", "scope", "configuration-unicode", "source-revision"])
    func staleMetadataCannotPoisonTheCurrentContext(_ change: String) async throws {
        let originalTask = UUID(), original = taintContext(originalTask), book = MultiAgentContinuation()
        book.startTask(originalTask)
        let run = try AssistantConversationHistory.Run(logicalTaskID: originalTask, cause: .newRequest)
        let stale = try await taintPreparation(book, .init(id: "old", name: "control_native_window", arguments: [:]), context: original, run: run)
        var current = original
        switch change {
        case "same-task-new-epoch": book.startTask(originalTask)
        case "replacement-task": current = taintContext(UUID()); book.startTask(current.logicalTaskID)
        case "scope": current = taintContext(originalTask, scope: UUID())
        case "configuration-unicode": current = taintContext(originalTask, scope: original.scopeID, model: "cafe\u{301}")
        default: current = taintContext(originalTask, scope: original.scopeID, revision: 1)
        }
        #expect(!book.markUnsupportedSourceContribution(prepared: stale, currentContext: current))
        let currentRun = try AssistantConversationHistory.Run(logicalTaskID: current.logicalTaskID, cause: .newRequest)
        let fresh = try await taintPreparation(book, .init(id: "new", name: "calculate", arguments: ["expression": .string("2+5")]), context: current, run: currentRun)
        #expect(fresh.supported)
        await book.record(.init(summary: "7", evidence: "Synthetic arithmetic", verified: true), prepared: fresh, grants: { [] })
        book.acknowledge(fresh)
        let snapshot = try await taintSnapshot(book, context: current)
        #expect(snapshot.included == 1 && snapshot.omitted == 0)
    }

    @Test func supportedDataCannotBeMarkedAsUnsupportedAndANewTaskStartsClean() async throws {
        let task = UUID(), context = taintContext(task), book = MultiAgentContinuation()
        book.startTask(task)
        let run = try AssistantConversationHistory.Run(logicalTaskID: task, cause: .newRequest)
        let supported = try await taintPreparation(book, .init(id: "safe", name: "calculate", arguments: ["expression": .string("7")]), context: context, run: run)
        #expect(!book.markUnsupportedSourceContribution(prepared: supported, currentContext: context))
        let unsupported = try await taintPreparation(book, .init(id: "private", name: "control_native_window", arguments: [:]), context: context, run: run)
        #expect(book.markUnsupportedSourceContribution(prepared: unsupported, currentContext: context))
        let next = taintContext(UUID()); book.startTask(next.logicalTaskID)
        let nextRun = try AssistantConversationHistory.Run(logicalTaskID: next.logicalTaskID, cause: .newRequest)
        let clean = try await taintPreparation(book, .init(id: "safe", name: "calculate", arguments: ["expression": .string("7")]), context: next, run: nextRun)
        #expect(clean.supported)
        await book.record(.init(summary: "7", evidence: "Synthetic arithmetic", verified: true), prepared: clean, grants: { [] })
        book.acknowledge(clean)
        let snapshot = try await taintSnapshot(book, context: next)
        #expect(snapshot.included == 1 && snapshot.omitted == 0)
    }

    @Test func oldRecordAndAcknowledgmentCannotSettleANewEpochEvenWithAnIdenticalReceiptKey() async throws {
        let task = UUID(), context = taintContext(task), book = MultiAgentContinuation(), proposal = UUID()
        book.startTask(task)
        let run = try AssistantConversationHistory.Run(logicalTaskID: task, cause: .newRequest)
        let call = ToolCall(id: "same-raw-id", name: "calculate", arguments: ["expression": .string("7")])
        let stale = try await taintPreparation(book, call, context: context, run: run, proposal: proposal)
        book.startTask(task)
        await book.record(.init(summary: "STALE_OLD_FACT", evidence: "Stale epoch", verified: true), prepared: stale, grants: { [] })
        let empty = try await taintSnapshot(book, context: context)
        #expect(empty.included == 0 && empty.omitted == 0)
        let fresh = try await taintPreparation(book, call, context: context, run: run, proposal: proposal)
        await book.record(.init(summary: "FRESH_FACT", evidence: "New epoch", verified: true), prepared: fresh, grants: { [] })
        book.acknowledge(stale)
        let pending = try await taintSnapshot(book, context: context)
        #expect(pending.included == 0 && pending.omitted == 1)
        book.acknowledge(fresh)
        let settled = try await taintSnapshot(book, context: context)
        #expect(settled.included == 1 && settled.omitted == 0 && !settled.modelContext.contains("STALE_OLD_FACT"))
    }

    @Test func byteDistinctIDsAndLaterAcceptedProposalsHaveSeparateOmissionIdentity() async throws {
        let task = UUID(), context = taintContext(task), book = MultiAgentContinuation(), proposal = UUID()
        book.startTask(task)
        let run = try AssistantConversationHistory.Run(logicalTaskID: task, cause: .newRequest)
        for (id, accepted) in [("caf\u{e9}", proposal), ("cafe\u{301}", proposal), ("caf\u{e9}", UUID())] {
            let prepared = try await taintPreparation(book, .init(id: id, name: "control_native_window", arguments: [:]), context: context, run: run, proposal: accepted)
            #expect(book.markUnsupportedSourceContribution(prepared: prepared, currentContext: context))
        }
        let snapshot = try await taintSnapshot(book, context: context)
        #expect(snapshot.included == 0 && snapshot.omitted == 3)
    }

    @Test func moreThan1024ContributionsHaveNoLifetimeRefusalAndUnsupportedWritesDoNoProofIO() async throws {
        let task = UUID(), context = taintContext(task), book = MultiAgentContinuation()
        book.startTask(task)
        let run = try AssistantConversationHistory.Run(logicalTaskID: task, cause: .newRequest)
        for _ in 0..<1_030 {
            let prepared = try await taintPreparation(book, .init(id: "reused-provider-id", name: "control_native_window", arguments: [:]), context: context, run: run)
            #expect(book.markUnsupportedSourceContribution(prepared: prepared, currentContext: context))
        }
        let snapshot = try await taintSnapshot(book, context: context)
        #expect(snapshot.included == 0 && snapshot.omitted == 1_030)
        let derived = try await taintPreparation(book, .init(id: "derived-write", name: "write_file", arguments: ["path": .string("/not-accessed/synthetic.txt")]), context: context, run: run)
        #expect(!derived.supported)
        var grantReads = 0
        await book.record(.init(summary: "Derived write report", evidence: "No physical write in this pure test", verified: true), prepared: derived, grants: { grantReads += 1; return [] })
        #expect(grantReads == 0, "An already unsupported receipt should not start file freshness IO.")
        let after = try await taintSnapshot(book, context: context)
        #expect(after.included == 0 && after.omitted == 1_031)
    }
}
