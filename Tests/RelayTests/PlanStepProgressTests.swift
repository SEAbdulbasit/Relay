import Foundation
import Testing
@testable import Relay

/// Actual orchestrator transitions over inert tool results; no model/provider,
/// file mutation, source read, OS permission or task journal is used.
@MainActor
struct PlanStepProgressTests {
    @Test func duplicateProviderIDsAndTitlesKeepDistinctPositionsAndExplicitReviewTransitions() async throws {
        let rig = Rig()
        rig.requireReview = true
        let runner = rig.make()
        let result = try await runner.executeTask(goal: rig.goal)
        #expect(result.isSuccess)
        #expect(runner.planProgress.count == 2)
        #expect(Set(runner.planProgress.map(\.id)).count == 2)
        #expect(runner.planProgress.map(\.state) == [.stepChecked, .stepChecked])
        #expect(runner.planProgress.map(\.attempt) == [1, 1])
        #expect(rig.reviewSnapshots.count == 2)
        #expect(rig.reviewSnapshots[0].map(\.state) == [.waitingForReview, .planned])
        #expect(rig.reviewSnapshots[1].map(\.state) == [.stepChecked, .waitingForReview])
        #expect(rig.snapshots.contains { $0.map(\.state) == [.stepChecked, .planned] })
    }

    @Test func declinedReviewDoesNotCheckStepOrDispatchAndKeepsLaterStepsPlanned() async throws {
        let rig = Rig()
        rig.requireReview = true
        rig.approve = false
        let runner = rig.make()
        let result = try await runner.executeTask(goal: rig.goal)
        #expect(!result.isSuccess && rig.writes == 0)
        #expect(runner.planProgress.map(\.state) == [.needsAttention, .planned])
        #expect(!rig.snapshots.contains { $0.contains { $0.state == .stepChecked } })
        let ids = runner.planProgress.map(\.id)
        let resumed = rig.make()
        _ = try await resumed.executeTask(goal: rig.goal)
        #expect(resumed.planProgress.map(\.id) == ids)
        #expect(resumed.planProgress.map(\.state) == [.needsAttention, .planned])
        #expect(rig.writes == 0)
    }

    @Test func toolAcknowledgmentAndNarrativeAloneDoNotPromoteAnUnverifiedAction() async throws {
        let rig = Rig()
        rig.actionVerified = false
        let runner = rig.make()
        let result = try await runner.executeTask(goal: rig.goal)
        #expect(!result.isSuccess)
        #expect(runner.planProgress.map(\.state) == [.needsAttention, .planned])
        #expect(rig.writes == 1)
    }

    @Test func resumePreservesAppIDsAndAttemptCountsButEarlierCursorIsNotRenewedProof() async throws {
        let rig = Rig()
        rig.interruptWriteNumber = 2
        let first = rig.make()
        await #expect(throws: CancellationError.self) { try await first.executeTask(goal: rig.goal) }
        #expect(first.planProgress.map(\.state) == [.stepChecked, .stopped])
        let ids = first.planProgress.map(\.id)
        rig.interruptWriteNumber = nil
        rig.snapshots = []
        let resumed = rig.make()
        let result = try await resumed.executeTask(goal: rig.goal)
        #expect(result.isSuccess)
        #expect(resumed.planProgress.map(\.id) == ids)
        #expect(resumed.planProgress.map(\.state) == [.earlierRun, .stepChecked])
        #expect(resumed.planProgress.map(\.attempt) == [1, 2])
        #expect(rig.snapshots.contains { $0.map(\.state) == [.earlierRun, .reconciling] })
        #expect(rig.writes == 2 && rig.reads == 1, "Reconciliation must not replay the interrupted mutation")
    }

    @Test func navigatorCompletionOnlyChecksTheObservation() async throws {
        let rig = Rig()
        rig.plan = #"{"steps":[{"id":"same","role":"Navigator","title":"Inspect the owned source"}]}"#
        let runner = rig.make()
        _ = try await runner.executeTask(goal: rig.goal)
        #expect(runner.planProgress.map(\.state) == [.observationChecked])
        #expect(runner.planProgress.first?.status == "Observation checked")
        #expect(rig.writes == 0 && rig.reads == 1)
    }

    @MainActor private final class Rig {
        let task = UUID(), scope = UUID()
        let goal = "Perform the two owned steps, then inspect their outcomes."
        lazy var checkpoint = MultiAgentStepCheckpoint(logicalTaskID: task)
        var plan = #"{"steps":[{"id":"same","role":"Executor","title":"Owned output"},{"id":"same","role":"Executor","title":"Owned output"}]}"#
        var writes = 0, reads = 0
        var requireReview = false, approve = true, actionVerified = true
        var interruptWriteNumber: Int?
        var snapshots: [[PlanStepProgress]] = []
        var reviewSnapshots: [[PlanStepProgress]] = []

        func make() -> MultiAgentOrchestrator {
            let runner = MultiAgentOrchestrator(
                allTools: MacTools.definitions.filter { ["write_file", "read_file"].contains($0.name) },
                complete: { [self] messages, tools, _ in
                    let role = messages.first?.content ?? ""
                    if role.contains("ROLE: Planner") {
                        if messages.last?.content.contains("Synthesize") == true {
                            return .init(content: "Inspect the current checked results.", toolCalls: [])
                        }
                        return .init(content: plan, toolCalls: [])
                    }
                    if role.contains("ROLE: Executor") {
                        return .init(content: "", toolCalls: [.init(name: "write_file", arguments: [
                            "path": .string("/INERT/owned.txt"), "content": .string("Inert output")])])
                    }
                    if role.contains("ROLE: Navigator") || messages.last?.content.contains("This verification requires fresh read-only evidence") == true {
                        return .init(content: "Inspect current state.", toolCalls: [.init(name: "read_file", arguments: ["path": .string("/INERT/owned.txt")])])
                    }
                    return .init(content: "VERIFIED: The inert current postcondition matches.", toolCalls: [])
                }, execute: { [self] call in
                    if call.name == "write_file" {
                        writes += 1
                        if writes == interruptWriteNumber { throw CancellationError() }
                        return .init(summary: "Inert action response", evidence: "Owned fixture only", verified: actionVerified)
                    }
                    reads += 1
                    return .init(summary: "Current inert read", evidence: "Owned current fixture postcondition", verified: true)
                }, admitReadback: { _, _, _ in {} },
                reviewReason: { [self] _ in requireReview ? "Review this exact inert action" : nil },
                requestReview: { [self] _, _ in
                    reviewSnapshots.append(snapshots.last ?? [])
                    return approve
                }, stepCheckpoint: checkpoint,
                stepContext: .init(logicalTaskID: task, configuration: .init(), scopeID: scope, sourceRevision: 0))
            runner.onPlanProgress = { [weak self] in self?.snapshots.append($0) }
            return runner
        }
    }
}
