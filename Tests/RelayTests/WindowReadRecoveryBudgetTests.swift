import ApplicationServices
import Foundation
import Testing
@testable import Relay

@MainActor
struct WindowReadRecoveryBudgetTests {
    private func scopes() throws -> (NativeRecoveryIdentityRegistry.WindowID, NativeRecoveryIdentityRegistry.WindowID) {
        let registry = NativeRecoveryIdentityRegistry()
        let target = DesktopApplicationIdentity(processID: 75_001, launchedAt: Date(timeIntervalSince1970: 1),
            bundleID: "org.example.inert-budget", bundleURL: URL(fileURLWithPath: "/inert/Fixture.app"))
        let first = try #require(registry.registerWindow(target: target, window: AXUIElementCreateApplication(75_001),
            documentFingerprint: "a", browser: nil))
        let second = try #require(registry.registerWindow(target: target, window: AXUIElementCreateApplication(75_002),
            documentFingerprint: "b", browser: nil))
        return (first, second)
    }

    @Test func onlyTheMatchingPreexistingWindowReadIssueCanBeClearedOnce() throws {
        let (window, other) = try scopes()
        var budget = TaskRecoveryBudget()
        let key = TaskRecoveryBudget.windowReadKey(window)
        try budget.recordFailure(key)
        budget.recordVerifiedSuccess(key)
        #expect(budget.hasUnresolvedErrors, "Generic success cannot clear a window-read issue.")
        let wrongID = UUID()
        let wrong = budget.captureWindowReadAttempt(for: wrongID)
        let windowReadResolved1 = budget.recordVerifiedWindowRead(wrong, window: other, attemptID: wrongID)
        #expect(!windowReadResolved1)
        #expect(budget.hasUnresolvedErrors)
        let id = UUID()
        let attempt = budget.captureWindowReadAttempt(for: id)
        let windowReadResolved2 = budget.recordVerifiedWindowRead(attempt, window: window, attemptID: id)
        #expect(windowReadResolved2)
        #expect(!budget.hasUnresolvedErrors)
        let windowReadResolved3 = budget.recordVerifiedWindowRead(attempt, window: window, attemptID: id)
        #expect(!windowReadResolved3)
    }

    @Test func aReadStartedBeforeTheFailureCannotClearIt() throws {
        let (window, _) = try scopes()
        var budget = TaskRecoveryBudget()
        let id = UUID()
        let early = budget.captureWindowReadAttempt(for: id)
        try budget.recordFailure(TaskRecoveryBudget.windowReadKey(window))
        let windowReadResolved4 = budget.recordVerifiedWindowRead(early, window: window, attemptID: id)
        #expect(!windowReadResolved4)
        #expect(budget.hasUnresolvedErrors)
    }

    @Test func aNewerFailureAndClearRecreateABARejectAnOlderRead() throws {
        let (window, _) = try scopes()
        let key = TaskRecoveryBudget.windowReadKey(window)
        var budget = TaskRecoveryBudget()
        try budget.recordFailure(key)
        let oldID = UUID()
        let old = budget.captureWindowReadAttempt(for: oldID)
        try budget.recordFailure(key)
        let windowReadResolved5 = budget.recordVerifiedWindowRead(old, window: window, attemptID: oldID)
        #expect(!windowReadResolved5)
        let olderID = UUID()
        let older = budget.captureWindowReadAttempt(for: olderID)
        let currentID = UUID()
        let current = budget.captureWindowReadAttempt(for: currentID)
        let windowReadResolved6 = budget.recordVerifiedWindowRead(current, window: window, attemptID: currentID)
        #expect(windowReadResolved6)
        try budget.recordFailure(key)
        let windowReadResolved7 = budget.recordVerifiedWindowRead(older, window: window, attemptID: olderID)
        #expect(!windowReadResolved7)
        #expect(budget.hasUnresolvedErrors)
    }

    @Test func aReadNeverClearsAMutationOrAnUnboundReadIssue() throws {
        let (window, _) = try scopes()
        var budget = TaskRecoveryBudget()
        let action = TaskRecoveryBudget.key(for: ToolCall(name: "set_value", arguments: ["bundle_id": .string("fixture"),
            "element_id": .string("rotating"), "value": .string("requested")]), observedScope: "qualified-control")
        try budget.recordFailure(action)
        try budget.recordFailure(TaskRecoveryBudget.windowReadKey(window))
        let unbound = TaskRecoveryBudget.unboundWindowReadKey(originalAction: action)
        try budget.recordFailure(unbound)
        let id = UUID()
        let attempt = budget.captureWindowReadAttempt(for: id)
        let windowReadResolved8 = budget.recordVerifiedWindowRead(attempt, window: window, attemptID: id)
        #expect(windowReadResolved8)
        #expect(budget.hasUnresolvedErrors)
        budget.recordVerifiedSuccess(action)
        budget.recordVerifiedSuccess(unbound)
        #expect(budget.hasUnresolvedErrors, "Unbound read issues have no positive resolving scope.")
        try budget.recordFailure(unbound)
        try budget.recordFailure(unbound)
        #expect(throws: TaskRecoveryBudget.Limit.self) { try budget.recordFailure(unbound) }
    }

    @Test func wrongAttemptOwnerNonceAndEvictedAttemptCannotClear() throws {
        let (window, _) = try scopes()
        var first = TaskRecoveryBudget()
        var other = TaskRecoveryBudget()
        try first.recordFailure(TaskRecoveryBudget.windowReadKey(window))
        try other.recordFailure(TaskRecoveryBudget.windowReadKey(window))
        let id = UUID()
        let attempt = first.captureWindowReadAttempt(for: id)
        let windowReadResolved9 = other.recordVerifiedWindowRead(attempt, window: window, attemptID: id)
        #expect(!windowReadResolved9)
        let windowReadResolved10 = first.recordVerifiedWindowRead(attempt, window: window, attemptID: UUID())
        #expect(!windowReadResolved10)
        let windowReadResolved11 = first.recordVerifiedWindowRead(attempt, window: window, attemptID: id)
        #expect(!windowReadResolved11, "Wrong nonce consumes the attempt.")
        let evictedID = UUID()
        let evicted = first.captureWindowReadAttempt(for: evictedID)
        for _ in 0..<128 { _ = first.captureWindowReadAttempt(for: UUID()) }
        let windowReadResolved12 = first.recordVerifiedWindowRead(evicted, window: window, attemptID: evictedID)
        #expect(!windowReadResolved12)
        #expect(first.hasUnresolvedErrors && other.hasUnresolvedErrors)
    }

    @Test func unboundReferenceKindsCannotCollideWithABroadRead() {
        func key(_ references: [String: JSONValue]) -> TaskRecoveryBudget.Key {
            TaskRecoveryBudget.key(for: ToolCall(name: "observe_app",
                arguments: references.merging(["bundle_id": .string("fixture")]) { first, _ in first }), observedScope: nil)
        }
        #expect(key(["window_id": .string("one")]) == key(["window_id": .string("two")]))
        #expect(key([:]) != key(["window_id": .string("one")]))
        #expect(key(["root_ref": .string("one")]) != key(["window_id": .string("one")]))
        #expect(key(["element_id": .string("one")]) != key(["root_ref": .string("one")]))
    }
}
