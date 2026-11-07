import Foundation
import Testing
@testable import Relay

@Suite("AdversarialMultiAgentStressTests")
@MainActor
struct AdversarialMultiAgentStressTests {

    private func settle(_ store: AssistantStore) async {
        for _ in 0..<500 where store.isRunning { await Task.yield() }
        #expect(!store.isRunning)
    }

    // MARK: - 1. Outcome Verification

    @Test("An unverified action is not replayed or certified by the model")
    func uncertainActionCannotBeReplayedOrCertified() async throws {
        var executorRuns = 0
        var criticRuns = 0

        let store = AssistantStore(persistenceURL: nil, complete: { input, tools, config in
            let system = input.first?.content ?? ""
            if system.contains("ROLE: Planner") {
                return ModelReply(content: """
                {
                  "taskType": "automation",
                  "steps": [
                    {"id": "s1", "role": "Executor", "title": "Perform stubborn mutation"}
                  ]
                }
                """, toolCalls: [])
            } else if system.contains("ROLE: Executor") {
                executorRuns += 1
                return ModelReply(content: "", toolCalls: [
                    ToolCall(name: "open_app", arguments: ["app": .string("com.apple.Notes")])
                ])
            } else if system.contains("ROLE: Critic") {
                criticRuns += 1
                return ModelReply(content: "VERIFIED: The action succeeded.", toolCalls: [])
            }
            throw RelayError.message("Unexpected role turn")
        }, execute: { call in
            // Action reports not verified
            return ToolResult(summary: "Clicked button", evidence: "No state change", verified: false)
        }, multiAgent: true)

        store.draft = "Run stubborn task"
        store.send()
        await settle(store)

        #expect(executorRuns == 1)
        #expect(criticRuns == 1)
        #expect(store.phase == .needsInput, "Failed steps should leave store in .needsInput phase")
        #expect(store.activeAgentRole == nil, "Active agent role must be cleared after completion")
        #expect(store.messages.last?.text.contains("No action outcome was independently verified") == true)
        #expect(store.messages.last?.text.contains("No computer actions were executed") == false)
    }

    @Test("An unverified step cannot borrow a prior result or trigger dependent actions")
    func priorEvidenceDoesNotCertifyUnverifiedStep() async throws {
        var stepsAttempted: [String] = []

        let store = AssistantStore(persistenceURL: nil, complete: { input, tools, config in
            let system = input.first?.content ?? ""
            if system.contains("ROLE: Planner") {
                if stepsAttempted.isEmpty {
                    return ModelReply(content: """
                    {
                      "taskType": "automation",
                      "steps": [
                        {"id": "s1", "role": "Executor", "title": "Step 1 Verified"},
                        {"id": "s2", "role": "Executor", "title": "Step 2 Failing"},
                        {"id": "s3", "role": "Executor", "title": "Step 3 Should Never Run"},
                        {"id": "s4", "role": "Executor", "title": "Step 4 Should Never Run"}
                      ]
                    }
                    """, toolCalls: [])
                } else {
                    return ModelReply(content: "All steps completed successfully.", toolCalls: [])
                }
            } else if system.contains("ROLE: Executor") {
                let userPrompt = input.last?.content ?? ""
                if userPrompt.contains("Step 1 Verified") {
                    stepsAttempted.append("Step 1 Verified")
                } else if userPrompt.contains("Step 2 Failing") && !stepsAttempted.contains("Step 2 Failing") {
                    stepsAttempted.append("Step 2 Failing")
                } else if userPrompt.contains("Step 3") && !stepsAttempted.contains("Step 3") {
                    stepsAttempted.append("Step 3")
                }
                return ModelReply(content: "", toolCalls: [
                    ToolCall(name: "open_app", arguments: ["app": .string("com.apple.Notes")])
                ])
            } else if system.contains("ROLE: Critic") {
                return ModelReply(content: "Inspection complete.", toolCalls: [])
            }
            throw RelayError.message("Unexpected")
        }, execute: { _ in
            if stepsAttempted.count == 1 {
                return ToolResult(summary: "Opened Notes", evidence: "Notes process running", verified: true)
            }
            return ToolResult(summary: "Opening could not be confirmed", evidence: "No new app state", verified: false)
        }, multiAgent: true)

        store.draft = "Run cascading failure plan"
        store.send()
        await settle(store)

        #expect(stepsAttempted == ["Step 1 Verified", "Step 2 Failing"])
        #expect(store.phase == .needsInput)
        #expect(store.messages.last?.text.contains("Notes process running") == true)
        #expect(store.messages.last?.text.contains("Unfinished steps:\n• Step 2 Failing\n• Step 3 Should Never Run") == true)
        #expect(store.messages.last?.text.contains("All steps completed successfully") == false)
    }

    @Test("Declining review keeps completed evidence and prevents later dispatches")
    func declineStopsPlanWithoutReplayingAction() async throws {
        var dispatches: [String] = []
        var executorTurns = 0
        let store = AssistantStore(persistenceURL: nil, complete: { input, _, _ in
            let role = input.first?.content ?? ""
            if role.contains("ROLE: Planner") {
                return ModelReply(content: #"["Launch Notes", "Navigate to example.com", "Try another destination"]"#, toolCalls: [])
            }
            if role.contains("ROLE: Executor") {
                executorTurns += 1
                let call = if executorTurns == 1 {
                    ToolCall(name: "open_app", arguments: ["app": .string("com.apple.Notes")])
                } else {
                    ToolCall(name: "open_url", arguments: ["url": .string("https://example.com")])
                }
                return ModelReply(content: "", toolCalls: [call])
            }
            return ModelReply(content: "VERIFIED: Notes is running.", toolCalls: [])
        }, execute: { call in
            dispatches.append(call.name)
            return ToolResult(summary: "Opened Notes", evidence: "Notes process running", verified: true)
        }, multiAgent: true)

        store.draft = "Open Notes and visit example.com"
        store.send()
        for _ in 0..<500 where store.pendingReview == nil { await Task.yield() }
        #expect(store.pendingReview?.call.name == "browser_navigate")
        store.denyReview()
        await settle(store)

        #expect(store.phase == .needsInput)
        #expect(executorTurns == 2)
        #expect(dispatches == ["open_app"])
        #expect(store.messages.last?.text.contains("That action was declined") == true)
        #expect(store.messages.last?.text.contains("Notes process running") == true)
    }

    // MARK: - 2. Cancellation Semantics Stress Tests

    @Test("Immediate stop during planning phase prevents navigation and execution")
    func stopDuringPlannerTurnHaltsImmediately() async throws {
        var plannerCalled = false
        var releasePlanner: CheckedContinuation<Void, Never>?
        var executorCalled = false

        let store = AssistantStore(persistenceURL: nil, complete: { input, tools, config in
            let system = input.first?.content ?? ""
            if system.contains("ROLE: Planner") {
                plannerCalled = true
                await withCheckedContinuation { releasePlanner = $0 }
                return ModelReply(content: """
                {
                  "taskType": "automation",
                  "steps": [{"id": "s1", "role": "Executor", "title": "Should not run"}]
                }
                """, toolCalls: [])
            } else if system.contains("ROLE: Executor") {
                executorCalled = true
                return ModelReply(content: "", toolCalls: [])
            }
            throw RelayError.message("Unexpected")
        }, execute: { _ in
            return ToolResult(summary: "None", evidence: "None", verified: true)
        }, multiAgent: true)

        store.draft = "Task to be cancelled"
        store.send()
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while releasePlanner == nil, ContinuousClock.now < deadline { await Task.yield() }
        try #require(releasePlanner != nil)
        store.stop()
        releasePlanner?.resume(); releasePlanner = nil
        await settle(store)

        #expect(plannerCalled)
        #expect(!executorCalled, "Executor must NEVER be called after planner was stopped")
        #expect(store.phase == .stopped)
        #expect(store.activeAgentRole == nil)
    }

    @Test("Immediate stop during execution action halts before critic turn")
    func stopDuringExecutorActionHaltsBeforeCritic() async throws {
        var criticCalled = false
        var finishTool: CheckedContinuation<Void, Never>?

        let store = AssistantStore(persistenceURL: nil, complete: { input, tools, config in
            let system = input.first?.content ?? ""
            if system.contains("ROLE: Planner") {
                return ModelReply(content: """
                {
                  "taskType": "automation",
                  "steps": [{"id": "s1", "role": "Executor", "title": "Long execution"}]
                }
                """, toolCalls: [])
            } else if system.contains("ROLE: Executor") {
                return ModelReply(content: "", toolCalls: [
                    ToolCall(name: "open_app", arguments: ["app": .string("com.apple.Calculator")])
                ])
            } else if system.contains("ROLE: Critic") {
                criticCalled = true
                return ModelReply(content: "VERIFIED", toolCalls: [])
            }
            throw RelayError.message("Unexpected")
        }, execute: { _ in
            await withCheckedContinuation { finishTool = $0 }
            return ToolResult(summary: "Opened Calculator", evidence: "PID 123", verified: true)
        }, multiAgent: true)

        store.draft = "Run long execution"
        store.send()

        for _ in 0..<500 where finishTool == nil { await Task.yield() }
        let finish = try #require(finishTool)
        store.stop()
        finish.resume()
        await settle(store)
        for _ in 0..<500 where store.messages.last?.text.contains("PID 123") != true { await Task.yield() }

        #expect(!criticCalled, "Critic must NOT be called when stopped during executor turn")
        #expect(store.phase == .stopped)
        #expect(store.activeAgentRole == nil)
        #expect(store.messages.last?.text.contains("An in-flight action finished after interruption: Opened Calculator") == true)
        #expect(store.messages.last?.text.contains("PID 123") == true)
    }

    @Test("Rapid double-stop call does not crash or corrupt state")
    func rapidDoubleStopIdempotence() async throws {
        let store = AssistantStore(persistenceURL: nil, complete: { _, _, _ in
            try? await Task.sleep(nanoseconds: 100_000_000)
            return ModelReply(content: "done", toolCalls: [])
        }, execute: { _ in
            return ToolResult(summary: "ok", evidence: "ok", verified: true)
        }, multiAgent: true)

        store.draft = "Task for double stop"
        store.send()

        store.stop()
        store.stop() // second immediate call
        store.stop() // third immediate call
        await settle(store)

        #expect(store.phase == .stopped)
        #expect(store.activeAgentRole == nil)
    }

    @Test("GlobalStopShortcutController activates onStop handler only when enabled")
    func globalStopShortcutActivationSemantics() throws {
        var stopped = false
        var registered = false
        var unregistered = false

        let controller = GlobalStopShortcutController(
            onStop: { stopped = true },
            register: { registered = true },
            unregister: { unregistered = true }
        )

        #expect(!controller.enabled)
        #expect(controller.status == "Global Stop is off.")

        // Try activating when disabled -> must be ignored
        controller.activateFromRegisteredShortcut()
        #expect(!stopped, "Shortcut must not trigger when disabled")

        // Enable controller
        controller.setEnabled(true)
        #expect(controller.enabled)
        #expect(registered)
        #expect(controller.status.contains("⌘⇧Escape"))

        // Now activate -> must trigger onStop
        controller.activateFromRegisteredShortcut()
        #expect(stopped, "Shortcut must trigger onStop when enabled")

        // Disable controller
        controller.setEnabled(false)
        #expect(!controller.enabled)
        #expect(unregistered)
    }

    // MARK: - 3. Adversarial / Malformed Inputs to MultiAgentOrchestrator

    @Test("Malformed or corrupt JSON plan falls back safely to plain text parsing")
    func malformedJSONPlanFallback() async throws {
        var executorExecuted = false

        let store = AssistantStore(persistenceURL: nil, complete: { input, tools, config in
            let system = input.first?.content ?? ""
            if system.contains("ROLE: Planner") {
                if !executorExecuted {
                    // Truncated / malformed JSON followed by numbered list
                    return ModelReply(content: """
                    {
                      "taskType": "automation",
                      "steps": [{"broken_json
                    1. Open target application
                    2. Type hello world
                    """, toolCalls: [])
                } else {
                    return ModelReply(content: "Done with fallback plan.", toolCalls: [])
                }
            } else if system.contains("ROLE: Executor") {
                executorExecuted = true
                return ModelReply(content: "", toolCalls: [
                    ToolCall(name: "open_app", arguments: ["app": .string("com.apple.Notes")])
                ])
            } else if system.contains("ROLE: Critic") {
                return ModelReply(content: "VERIFIED", toolCalls: [])
            }
            throw RelayError.message("Unexpected")
        }, execute: { _ in
            return ToolResult(summary: "Opened", evidence: "Verified", verified: true)
        }, multiAgent: true)

        store.draft = "Task with malformed plan"
        store.send()
        await settle(store)

        #expect(executorExecuted, "Planner parser must recover steps from numbered lines when JSON is malformed")
        #expect(store.currentPlanSteps.count == 2)
        #expect(store.phase == .idle)
    }

    @Test("An empty planner response asks for input without claiming completion")
    func emptyPlannerOutputTreatedSafely() async throws {
        let store = AssistantStore(persistenceURL: nil, complete: { input, tools, config in
            let system = input.first?.content ?? ""
            if system.contains("ROLE: Planner") {
                return ModelReply(content: "   \n\t   ", toolCalls: [])
            }
            throw RelayError.message("Should not be called")
        }, execute: { _ in
            throw RelayError.message("Should not be called")
        }, multiAgent: true)

        store.draft = "Empty response test"
        store.send()
        await settle(store)

        #expect(store.phase == .needsInput)
        #expect(store.messages.last?.text.contains("The local model returned no answer") == true)
        #expect(store.currentPlanSteps.isEmpty)
        #expect(store.activeAgentRole == nil)
    }

    @Test("Unknown role in plan defaults safely to executor")
    func unknownRoleInPlanDefaultsToExecutor() async throws {
        var executorRan = false

        let store = AssistantStore(persistenceURL: nil, complete: { input, tools, config in
            let system = input.first?.content ?? ""
            if system.contains("ROLE: Planner") {
                if !executorRan {
                    return ModelReply(content: """
                    {
                      "taskType": "automation",
                      "steps": [
                        {"id": "s1", "role": "wizard_unknown_role", "title": "Cast magic spell"}
                      ]
                    }
                    """, toolCalls: [])
                } else {
                    return ModelReply(content: "Magic spell cast.", toolCalls: [])
                }
            } else if system.contains("ROLE: Executor") {
                executorRan = true
                return ModelReply(content: "", toolCalls: [
                    ToolCall(name: "open_app", arguments: ["app": .string("com.apple.Terminal")])
                ])
            } else if system.contains("ROLE: Critic") {
                return ModelReply(content: "VERIFIED", toolCalls: [])
            }
            throw RelayError.message("Unexpected")
        }, execute: { _ in
            return ToolResult(summary: "Ran", evidence: "Verified", verified: true)
        }, multiAgent: true)

        store.draft = "Test unknown role"
        store.send()
        await settle(store)

        #expect(executorRan, "Unknown role should fall back to executor safely")
        #expect(store.phase == .idle)
    }

    // MARK: - 4. Privilege Isolation & Tool Partitioning Invariants

    @Test("Role schema isolation: Navigator and Critic never receive mutation tools")
    func roleSchemaPrivilegeIsolation() async throws {
        var navigatorToolsSeen: [String] = []
        var criticToolsSeen: [String] = []
        var plannerToolsSeen: [String] = []

        let store = AssistantStore(persistenceURL: nil, complete: { input, tools, config in
            let system = input.first?.content ?? ""
            let toolNames = tools.map(\.name)
            if system.contains("ROLE: Planner") {
                plannerToolsSeen = toolNames
                return ModelReply(content: """
                {
                  "taskType": "automation",
                  "steps": [
                    {"id": "s1", "role": "Navigator", "title": "Inspect environment"},
                    {"id": "s2", "role": "Critic", "title": "Verify state"}
                  ]
                }
                """, toolCalls: [])
            } else if system.contains("ROLE: Navigator") {
                navigatorToolsSeen = toolNames
                return ModelReply(content: "", toolCalls: [ToolCall(name: "list_apps", arguments: [:])])
            } else if system.contains("ROLE: Critic") {
                criticToolsSeen = toolNames
                return ModelReply(content: "VERIFIED", toolCalls: [])
            }
            throw RelayError.message("Unexpected")
        }, execute: { _ in
            return ToolResult(summary: "ok", evidence: "ok", verified: true)
        }, multiAgent: true)

        store.draft = "Verify tool privileges"
        store.send()
        await settle(store)

        // Planner must have ZERO tools
        #expect(plannerToolsSeen.isEmpty, "Planner must have 0 tools")

        // Navigator must NOT have mutation tools
        let mutationTools = ["press_control", "set_value", "write_file", "move_file", "create_document", "create_spreadsheet"]
        for tool in mutationTools {
            #expect(!navigatorToolsSeen.contains(tool), "Navigator must not receive mutation tool: \(tool)")
            #expect(!criticToolsSeen.contains(tool), "Critic must not receive mutation tool: \(tool)")
        }

        // Critic must only have verification tools
        #expect(criticToolsSeen.allSatisfy { ["read_file", "observe_app", "read_browser_page"].contains($0) })
    }

    @Test("An unadvertised model tool cannot dispatch from the Navigator")
    func roleRejectsUnadvertisedToolBeforeDispatch() async throws {
        var dispatched = false
        let store = AssistantStore(persistenceURL: nil, complete: { input, _, _ in
            if input.first?.content.contains("ROLE: Planner") == true {
                return ModelReply(content: #"{"steps":[{"role":"Navigator","title":"Inspect open apps"}]}"#, toolCalls: [])
            }
            return ModelReply(content: "", toolCalls: [ToolCall(name: "open_app", arguments: ["app": .string("com.apple.Notes")])])
        }, execute: { _ in
            dispatched = true
            return ToolResult(summary: "Opened Notes", evidence: "Notes process running", verified: true)
        }, multiAgent: true)

        store.draft = "Inspect open apps"
        store.send()
        await settle(store)

        #expect(!dispatched)
        #expect(store.phase == .failed)
        #expect(store.errorMessage?.contains("Unsupported tool: open_app") == true)
    }

    // MARK: - 5. Cancellation on runMultiAgentTask

    @Test("store.stop() interrupts runMultiAgentTask cleanly")
    func storeStopInterruptsRunMultiAgentTask() async throws {
        let store = AssistantStore(persistenceURL: nil, complete: { input, tools, config in
            // Simulate slow inference
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
            return ModelReply(content: "Finished", toolCalls: [])
        }, execute: { _ in
            return ToolResult(summary: "ok", evidence: "ok", verified: true)
        })

        let task = Task {
            try await store.runMultiAgentTask(prompt: "Slow prompt")
        }

        // Interrupt via store.stop()
        try? await Task.sleep(nanoseconds: 20_000_000) // 20ms
        store.stop()

        _ = try? await task.value
        await settle(store)

        #expect(store.phase == .stopped)
        #expect(store.activeAgentRole == nil)
    }
}

