import Foundation
import Testing
@testable import Relay

@Suite("Monotonic task run budgets")
@MainActor struct TaskRunBudgetTests {
    @Test func ordinaryTaskHasNoArtificialActiveOrReviewLifetimeCutoff() throws {
        var time = 0.0
        let budget = TaskRunBudget(now: { time })
        time = 86_400
        try budget.check()
        budget.pauseForReview()
        time += 86_400
        try budget.check()
        budget.resumeAfterReview()
        time += 86_400
        try budget.check()
        #expect(budget.remainingLifetime == nil)
    }

    @Test func productiveTaskContinuesBeyondTwentyTurnsAndThirtyMinutes() async {
        var time = 0.0, turns = 0, dispatched: [Int] = []
        let store = AssistantStore(persistenceURL: nil, complete: { input, _, _ in
            turns += 1
            time += 120
            #expect(input.contains { $0.role == "user" && $0.content.contains("all 24 synthetic checks") })
            if turns > 24 { return ModelReply(content: "The 24 synthetic checks finished.", toolCalls: []) }
            return ModelReply(content: "", toolCalls: [ToolCall(name: "calculate", arguments: ["expression": .string("\(turns)+0")])])
        }, execute: { call in
            let ordinal = Int(call.arguments["expression"]?.string?.split(separator: "+").first ?? "") ?? -1
            dispatched.append(ordinal)
            return ToolResult(summary: "Check \(ordinal)", evidence: "Synthetic executor receipt \(ordinal)", verified: true)
        }, runBudgetFactory: { TaskRunBudget(now: { time }) })
        defer { store.stop() }
        store.draft = "Finish all 24 synthetic checks."
        store.send()
        for _ in 0..<20_000 where store.isRunning { await Task.yield() }
        #expect(!store.isRunning && store.phase == .idle, Comment(rawValue: store.errorMessage ?? "Task did not finish"))
        #expect(store.errorMessage == nil)
        #expect(turns == 25 && dispatched == Array(1...24))
        #expect(time > 1_800 && store.activity.filter { $0.name == "calculate" && $0.status == "verified" }.count == 24)
    }

    @Test func stopStillCancelsAProductiveTaskBeyondTwentyTurns() async {
        var turns = 0, dispatched = 0
        let store = AssistantStore(persistenceURL: nil, complete: { _, _, _ in
            turns += 1
            if turns > 24 {
                while !Task.isCancelled { try await Task.sleep(for: .milliseconds(50)) }
                throw CancellationError()
            }
            return ModelReply(content: "", toolCalls: [ToolCall(name: "calculate", arguments: ["expression": .string("\(turns)+0")])])
        }, execute: { _ in
            dispatched += 1
            return ToolResult(summary: "Checked", evidence: "Synthetic executor only", verified: true)
        })
        defer { store.stop() }
        store.draft = "Continue the synthetic checks until I stop."
        store.send()
        for _ in 0..<20_000 where turns < 25 && store.isRunning { await Task.yield() }
        #expect(turns == 25 && dispatched == 24 && store.isRunning)
        store.stop()
        for _ in 0..<2_000 where store.isRunning { await Task.yield() }
        #expect(!store.isRunning && store.phase == .stopped && store.pendingReview == nil)
        #expect(dispatched == 24)
    }

    @Test func longHumanReviewDoesNotConsumeActiveBudget() throws {
        var time = 100.0
        let budget = TaskRunBudget(activeLimit: 240, lifetimeLimit: 1800, now: { time })
        time += 200
        budget.pauseForReview()
        time += 900
        try budget.check()
        budget.resumeAfterReview()
        time += 39
        try budget.check()
        time += 1
        #expect(throws: TaskRunBudget.Limit.activeWork) { try budget.check() }
    }

    @Test func hardLifetimeStillExpiresDuringReview() {
        var time = 0.0
        let budget = TaskRunBudget(lifetimeLimit: 1800, now: { time })
        budget.pauseForReview()
        time = 1800
        #expect(budget.remainingLifetime == 0)
        #expect(throws: TaskRunBudget.Limit.lifetime) { try budget.check() }
        budget.resumeAfterReview()
        #expect(throws: TaskRunBudget.Limit.lifetime) { try budget.check() }
    }

    @Test func repeatedReviewAndRedundantPauseResumeDoNotDoubleCount() throws {
        var time = 0.0
        let budget = TaskRunBudget(activeLimit: 10, lifetimeLimit: 100, now: { time })
        budget.resumeAfterReview()
        time = 4
        budget.pauseForReview()
        time = 14
        budget.pauseForReview()
        time = 24
        budget.resumeAfterReview()
        budget.resumeAfterReview()
        time = 27
        budget.pauseForReview()
        time = 47
        budget.resumeAfterReview()
        time = 49
        try budget.check()
        time = 50
        #expect(throws: TaskRunBudget.Limit.activeWork) { try budget.check() }
    }

    @Test func cancellationWinsWhileReviewIsPaused() async {
        let budget = TaskRunBudget()
        budget.pauseForReview()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try budget.check()
        }
        do { try await task.value; Issue.record("Cancelled budget check must throw") }
        catch is CancellationError { }
        catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test(arguments: [900.0, 1800.0, -1.0])
    func lateApprovalDispatchesOnlyWithinTotalLifetime(reviewDuration: Double) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("budget-review.txt")
        try "Original".write(to: file, atomically: true, encoding: .utf8)
        var time = 0.0
        var turns = 0
        var dispatches = 0
        let store = AssistantStore(persistenceURL: nil, complete: { _, _, _ in
            turns += 1
            if turns == 1 {
                time = 200
                return ModelReply(content: "", toolCalls: [ToolCall(name: "write_file", arguments: ["path": .string(file.path), "content": .string("Replacement")])])
            }
            return ModelReply(content: "Done.", toolCalls: [])
        }, execute: { _ in
            dispatches += 1
            return ToolResult(summary: "Fixture write", evidence: "Scripted result; no real overwrite", verified: true)
        }, runBudgetFactory: { TaskRunBudget(activeLimit: 240, lifetimeLimit: 1800, now: { time }) })
        store.grants = [ScopeGrant(path: folder.path, writable: true)]
        store.draft = "Replace budget-review.txt"
        store.send()
        for _ in 0..<1000 where store.pendingReview == nil { await Task.yield() }
        #expect(store.pendingReview != nil)
        if reviewDuration < 0 { store.stop() }
        else {
            time += reviewDuration
            store.approveReview()
        }
        for _ in 0..<1000 where store.isRunning { await Task.yield() }
        let shouldDispatch = reviewDuration >= 0 && reviewDuration < 1800
        #expect(dispatches == (shouldDispatch ? 1 : 0))
        #expect(store.phase == (reviewDuration < 0 ? .stopped : shouldDispatch ? .idle : .failed))
        #expect(store.pendingReview == nil)
        #expect(try String(contentsOf: file, encoding: .utf8) == "Original")
    }
}
