import Foundation
import Testing
@testable import Relay

@Suite("Monotonic task run budgets")
@MainActor struct TaskRunBudgetTests {
    @Test func longHumanReviewDoesNotConsumeActiveBudget() throws {
        var time = 100.0
        let budget = TaskRunBudget(now: { time })
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
        let budget = TaskRunBudget(now: { time })
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
        }, runBudgetFactory: { TaskRunBudget(now: { time }) })
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
