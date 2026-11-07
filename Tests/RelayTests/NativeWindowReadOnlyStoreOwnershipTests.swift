import Foundation
import Testing
@testable import Relay

/// Ignored draft, not compiled/executed. Uses the real current AssistantStore
/// scheduler/Stop/drain/protocol path with its existing trusted execute seam.
/// `observe_app` is only the test carrier for a future registered read tool;
/// production must register the new tool, not overload existing MacTools.
@MainActor
struct NativeWindowReadOnlyStoreOwnershipTests {
    @Test func stoppingStoreRejectsLateVisualAnswerAndLeavesNoLateTaskMessage() async throws {
        let fixture = NativeWindowStoreFixture()
        var waiter: CheckedContinuation<Void, Never>?
        var adapter: NativeWindowTaskAdapter?
        let owner = NativeWindowStoreOwner()
        var turns = 0
        let store = AssistantStore(persistenceURL: nil, complete: { _, _, _ in
            turns += 1
            if turns == 1 {
                return .init(content: "", toolCalls: [.init(name: "observe_app",
                    arguments: ["bundle_id": .string(fixture.application.bundleID)])])
            }
            return .init(content: "No additional action.", toolCalls: [])
        }, execute: { call in
            let owned = fixture.adapter(isCurrent: {
                owner.store?.isRunning == true && owner.store?.interactiveSessionActive == true
            })
            adapter = owned
            _ = try await owned.observe(bundleID: try #require(call.arguments["bundle_id"]?.string))
            let answer = try await NativeWindowReadOnlyTaskPhase.run(adapter: owned,
                objective: "Read the chosen window; do not change it.", completeHistory: [], complete: { _ in
                    await withCheckedContinuation { waiter = $0 }
                    // Deliberately uncooperative completion returns after Stop.
                    return .init(content: "LATE_PRIVATE_VISUAL_ANSWER", toolCalls: [])
                })
            return ToolResult(summary: answer.content, evidence: "Synthetic read phase", verified: true)
        })
        owner.store = store
        store.draft = "Read the chosen window; do not change it."
        store.send()
        for _ in 0..<2_000 where waiter == nil { await Task.yield() }
        try #require(waiter != nil)
        store.stop()
        #expect(store.phase == .stopped)
        waiter?.resume(); waiter = nil
        // A replacement Store run waits for the cancelled task to drain. Its
        // completion is a fence against asserting before the late return.
        store.draft = "Answer the next synthetic task without a device action."
        store.send()
        for _ in 0..<2_000 where store.isRunning { await Task.yield() }
        #expect(!store.isRunning && store.phase == .idle && turns == 2)
        #expect(!store.messages.contains { $0.text.contains("LATE_PRIVATE_VISUAL_ANSWER") })
        #expect(adapter?.hasCurrentObservation == false)
        adapter?.stop(); await adapter?.drain()
    }

    @Test func foreignAppRequestedByPlannerRefusesInsideActualStoreBeforeCapture() async throws {
        let fixture = NativeWindowStoreFixture()
        var turns = 0
        let store = AssistantStore(persistenceURL: nil, complete: { _, _, _ in
            turns += 1
            if turns == 1 {
                return .init(content: "", toolCalls: [.init(name: "observe_app",
                    arguments: ["bundle_id": .string("test.unadmitted.private.app")])])
            }
            return .init(content: "The requested app is outside this task's original scope.", toolCalls: [])
        }, execute: { call in
            let adapter = fixture.adapter(isCurrent: { true })
            defer { adapter.stop() }
            return try await adapter.observe(bundleID: try #require(call.arguments["bundle_id"]?.string))
        })
        store.draft = "Read the explicitly chosen synthetic window only."
        store.send()
        for _ in 0..<2_000 where store.isRunning { await Task.yield() }
        #expect(!store.isRunning && fixture.captures == 0)
        #expect(store.phase == .needsInput)
        #expect(store.activity.contains { $0.name == "observe_app" && $0.status.contains("failed") })
    }
}

@MainActor private final class NativeWindowStoreOwner {
    weak var store: AssistantStore?
}

@MainActor private final class NativeWindowStoreFixture {
    let application = DesktopApplicationIdentity(processID: 4545, launchedAt: Date(timeIntervalSince1970: 1000),
        bundleID: "test.original.task.window", bundleURL: URL(fileURLWithPath: "/Applications/Original Task.app"))
    var captures = 0

    func adapter(isCurrent: @escaping @MainActor () -> Bool) -> NativeWindowTaskAdapter {
        let observer = TargetBoundNativeObservation(backend: .init(capture: { [self] _, _ in
            captures += 1
            let text = """
                Computer Use state (CUA App Version: 1001824)
                <app_state>
                App=/Applications/Original Task.app/ (bundleID test.original.task.window, pid 4545)
                Window: "Original Task", App: Original Task.
                0 standard window Original Task, ID: original.window
                1 static text Original synthetic source
                </app_state>
                """
            let content: [JSONValue] = [.object(["type": .string("text"), "text": .string(text)])]
            return .init(raw: .object(["content": .array(content)]), content: content, isError: false)
        }, close: {}), sessionIsActive: isCurrent)
        return .init(ownership: .init(taskID: UUID(), isCurrent: isCurrent, admitApplication: { [self] bundle in
            guard bundle == application.bundleID else { throw NativeWindowTaskAdapter.Failure.unadmittedApplication }
            return .init(application: application, validate: {
                guard isCurrent() else { throw NativeWindowTaskAdapter.Failure.inactiveTask }
            })
        }), backend: .init(initial: { [self] admission in
            let preparation = TargetBoundNativeObservation.Preparation(application: admission.application,
                window: .init(title: "Original Task", role: "AXWindow", identifier: "original.window", document: "task://original",
                    url: "", x: 0, y: 0, width: 560, height: 300, minimized: false, hidden: false, modal: false),
                validate: admission.validate)
            let snapshot = try await observer.observe(observer.prepare(preparation))
            return .init(snapshot: snapshot, isCurrent: { observer.isCurrent(snapshot) }, refreshOriginal: nil)
        }, stop: { observer.stop() }, drain: { await observer.drain() }))
    }
}
