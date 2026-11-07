import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Relay

@MainActor struct AssistantApplicationLifetimeTests {
    @Test func terminationCancelsAnAppOwnedTaskWithoutAWorkspace() async {
        let center = NotificationCenter()
        var completion: CheckedContinuation<ModelReply, any Error>?
        var dispatches = 0
        let store = AssistantStore(persistenceURL: nil, complete: { _, _, _ in
            try await withCheckedThrowingContinuation { completion = $0 }
        }, execute: { _ in
            dispatches += 1
            return ToolResult(summary: "Unexpected", evidence: "Synthetic executor", verified: true)
        })
        let lifetime = AssistantApplicationLifetime(center: center) { [weak store] in store?.stopForTermination() }
        defer {
            completion?.resume(throwing: CancellationError())
            store.stop()
            withExtendedLifetime(lifetime) {}
        }
        store.draft = "Wait for this synthetic task."
        store.send()
        for _ in 0..<2_000 where completion == nil { await Task.yield() }
        #expect(store.isRunning && completion != nil)
        center.post(name: NSApplication.willTerminateNotification, object: nil)
        #expect(!store.isRunning && store.phase == .stopped)
        let pending = completion; completion = nil
        pending?.resume(returning: ModelReply(content: "", toolCalls: [ToolCall(name: "calculate", arguments: ["expression": .string("40+2")])]))
        for _ in 0..<100 { await Task.yield() }
        #expect(dispatches == 0 && store.pendingReview == nil)
    }

    @Test func observerIsRemovedWithItsOwner() {
        let center = NotificationCenter()
        var events = 0
        var lifetime: AssistantApplicationLifetime? = AssistantApplicationLifetime(center: center) { events += 1 }
        center.post(name: NSApplication.willTerminateNotification, object: nil)
        #expect(events == 1)
        lifetime = nil
        center.post(name: NSApplication.willTerminateNotification, object: nil)
        #expect(events == 1 && lifetime == nil)
    }

    /// Shows only an empty synthetic Relay workspace. No Accessibility access,
    /// model, microphone, user conversation or other application is used.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_RUN_WORKSPACE_LIFETIME_TEST"] == "1"))
    func closingTheWorkspaceDoesNotStopTheAppOwnedTask() async throws {
        _ = NSApplication.shared
        var completion: CheckedContinuation<ModelReply, any Error>?
        var turns = 0, appeared = false, disappeared = false
        let store = AssistantStore(persistenceURL: nil, complete: { _, _, _ in
            turns += 1
            if turns == 1 { return try await withCheckedThrowingContinuation { completion = $0 } }
            return ModelReply(content: "The local calculation returned 42.", toolCalls: [])
        })
        // Prevent the view's normal readiness task from loading an installed model.
        store.actionsReady = true
        let host = NSHostingView(rootView: AnyView(MainView(store: store)
            .onAppear { appeared = true }.onDisappear { disappeared = true }))
        let window = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 850, height: 650),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Relay synthetic workspace lifecycle"
        window.contentView = host
        defer {
            completion?.resume(throwing: CancellationError())
            store.stop()
            window.orderOut(nil); window.contentView = nil; window.close()
        }
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        try await wait { appeared }
        store.draft = "Calculate 40+2 locally after the workspace closes."
        store.send()
        try await wait { completion != nil }
        host.rootView = AnyView(EmptyView())
        host.layoutSubtreeIfNeeded()
        window.orderOut(nil)
        try await wait { disappeared }
        #expect(store.isRunning && store.phase == .thinking)
        let pending = completion; completion = nil
        pending?.resume(returning: ModelReply(content: "", toolCalls: [ToolCall(name: "calculate", arguments: ["expression": .string("40+2")])]))
        try await wait { !store.isRunning }
        #expect(store.phase == .idle && store.errorMessage == nil)
        #expect(store.activity.contains { $0.name == "calculate" && $0.status == "verified" && $0.detail.contains("42") })
        #expect(turns == 2)
    }

    private func wait(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition(), "Synthetic workspace lifecycle did not reach its expected boundary.")
    }
}
