import Foundation
import Testing
@testable import Relay

struct TaskRecoveryBudgetTests {
    @Test func rotatingReferencesDoNotReplenishTheSameAction() throws {
        var budget = TaskRecoveryBudget()
        for attempt in 1...4 {
            let call = ToolCall(name: "set_value", arguments: ["bundle_id": .string("test.inert"),
                "element_id": .string(UUID().uuidString), "value": .string("Exact café")])
            let key = TaskRecoveryBudget.key(for: call, observedScope: "same-process-window-control")
            if attempt < 4 { try budget.recordFailure(key) }
            else { #expect(throws: TaskRecoveryBudget.Limit.self) { try budget.recordFailure(key) } }
        }
        #expect(budget.hasUnresolvedErrors)
    }

    @Test func onlyMatchingVerifiedOperationCanResolveAnIssue() throws {
        var budget = TaskRecoveryBudget()
        let action = ToolCall(name: "press_control", arguments: ["bundle_id": .string("test.inert"), "element_id": .string("old")])
        let original = TaskRecoveryBudget.key(for: action, observedScope: "window-A-control-apply")
        try budget.recordFailure(original)
        let read = ToolCall(name: "observe_app", arguments: ["bundle_id": .string("test.inert")])
        budget.recordVerifiedSuccess(TaskRecoveryBudget.key(for: read, observedScope: nil))
        budget.recordVerifiedSuccess(TaskRecoveryBudget.key(for: action, observedScope: "window-A-control-cancel"))
        budget.recordVerifiedSuccess(TaskRecoveryBudget.key(for: action, observedScope: "window-B-control-apply"))
        budget.recordVerifiedSuccess(TaskRecoveryBudget.key(for: action, observedScope: nil))
        #expect(budget.hasUnresolvedErrors)
        budget.recordVerifiedSuccess(original)
        #expect(!budget.hasUnresolvedErrors)
        try budget.recordFailure(original)
    }

    @Test func requestedValuesAndDocumentsRemainSeparate() throws {
        let base = ToolCall(name: "set_value", arguments: ["bundle_id": .string("test.inert"), "element_id": .string("one"), "value": .string("A")])
        let another = ToolCall(name: "set_value", arguments: ["bundle_id": .string("test.inert"), "element_id": .string("two"), "value": .string("B")])
        #expect(TaskRecoveryBudget.key(for: base, observedScope: "same") != TaskRecoveryBudget.key(for: another, observedScope: "same"))
        #expect(TaskRecoveryBudget.key(for: base, observedScope: "document-A") != TaskRecoveryBudget.key(for: base, observedScope: "document-B"))
        let text = "Private payload café"
        let key = TaskRecoveryBudget.key(for: ToolCall(name: "write_file", arguments: ["path": .string("/private/fixture"), "content": .string(text)]), observedScope: nil)
        #expect(key.fingerprint.count == 64 && !key.fingerprint.contains(text))
    }

    @Test func anUnboundMutationCannotBeResolvedByAnotherUnboundSuccess() throws {
        var budget = TaskRecoveryBudget()
        let failed = ToolCall(name: "press_control", arguments: ["bundle_id": .string("test.inert"), "element_id": .string("old-unknown")])
        let succeeded = ToolCall(name: "press_control", arguments: ["bundle_id": .string("test.inert"), "element_id": .string("different-unknown")])
        try budget.recordFailure(TaskRecoveryBudget.key(for: failed, observedScope: nil))
        budget.recordVerifiedSuccess(TaskRecoveryBudget.key(for: succeeded, observedScope: nil))
        #expect(budget.hasUnresolvedErrors)
    }

    @Test func unresolvedIssueStorageIsBoundedWithoutDroppingFailures() throws {
        var budget = TaskRecoveryBudget()
        for index in 0..<128 {
            let call = ToolCall(name: "observe_app", arguments: ["bundle_id": .string("test.inert.\(index)")])
            try budget.recordFailure(TaskRecoveryBudget.key(for: call, observedScope: nil))
        }
        let another = TaskRecoveryBudget.key(for: ToolCall(name: "observe_app", arguments: ["bundle_id": .string("test.inert.extra")]), observedScope: nil)
        #expect(throws: TaskRecoveryBudget.Limit.self) { try budget.recordFailure(another) }
    }
}

@MainActor struct TaskRecoveryStoreTests {
    @Test func repeatedSuccessfulAppObservationsAreNotCumulativeFailures() async {
        var turns = 0, dispatches = 0
        let store = AssistantStore(persistenceURL: nil, complete: { _, _, _ in
            turns += 1
            return turns <= 6 ? ModelReply(content: "", toolCalls: [ToolCall(name: "observe_app", arguments: ["bundle_id": .string("test.inert")])])
                : ModelReply(content: "Six synthetic observations checked.", toolCalls: [])
        }, execute: { _ in
            dispatches += 1
            return ToolResult(summary: "State \(dispatches)", evidence: "Synthetic exact-target observation", verified: true)
        })
        defer { store.stop() }
        store.draft = "Check six stages of the inert target."
        store.send()
        for _ in 0..<10_000 where store.isRunning { await Task.yield() }
        #expect(dispatches == 6 && turns == 7 && store.phase == .idle && store.errorMessage == nil)
    }

    @Test func recoveredIndependentErrorsDoNotEndTheTask() async {
        var turns = 0, attempts: [String: Int] = [:]
        let store = AssistantStore(persistenceURL: nil, complete: { _, _, _ in
            turns += 1
            if turns > 8 { return ModelReply(content: "All four synthetic targets recovered.", toolCalls: []) }
            let target = (turns - 1) / 2
            return ModelReply(content: "", toolCalls: [ToolCall(name: "observe_app", arguments: ["bundle_id": .string("test.inert.\(target)")])])
        }, execute: { call in
            let target = call.arguments["bundle_id"]?.string ?? ""
            attempts[target, default: 0] += 1
            if attempts[target] == 1 { throw RelayError.message("Synthetic transient read failure") }
            return ToolResult(summary: "State read", evidence: "Synthetic independent current read", verified: true)
        })
        defer { store.stop() }
        store.draft = "Inspect each synthetic target again after its transient read error."
        store.send()
        for _ in 0..<10_000 where store.isRunning { await Task.yield() }
        #expect(turns == 9 && attempts.count == 4 && attempts.values.allSatisfy { $0 == 2 })
        #expect(store.phase == .idle && store.errorMessage == nil)
        #expect(store.activity.filter { $0.status == "failed / inspect before retry" }.count == 4)
    }

    @Test func sameUnresolvedIssueStopsAfterThreeRecoveryOpportunities() async {
        var turns = 0, dispatches = 0
        let store = AssistantStore(persistenceURL: nil, complete: { _, _, _ in
            turns += 1
            return ModelReply(content: "", toolCalls: [ToolCall(name: "observe_app", arguments: ["bundle_id": .string("test.inert")])])
        }, execute: { _ in
            dispatches += 1
            throw RelayError.message("Synthetic target is unavailable")
        })
        defer { store.stop() }
        store.draft = "Inspect the same inert target, without opening a replacement app."
        store.send()
        for _ in 0..<10_000 where store.isRunning { await Task.yield() }
        #expect(dispatches == 4 && turns == 4 && store.phase == .failed)
        #expect(store.errorMessage?.contains("three recovery opportunities") == true)
        #expect(store.errorMessage?.contains("Synthetic target is unavailable") == true)
    }
}
