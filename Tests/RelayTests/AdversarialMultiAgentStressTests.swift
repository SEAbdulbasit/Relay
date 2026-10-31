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

    // MARK: - 1. Repetition Limit Stress Test (<= 3 attempts)

    @Test("Adversarial Critic: Strict enforcement of <= 3 attempts on unverified action")
    func repetitionLimitStrictEnforcement() async throws {
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
                // Critic hostile rejection on every turn
                return ModelReply(content: "UNVERIFIED: Control was not clicked or had no effect. Attempt \(criticRuns)", toolCalls: [])
            }
            throw RelayError.message("Unexpected role turn")
        }, execute: { call in
            // Action reports not verified
            return ToolResult(summary: "Clicked button", evidence: "No state change", verified: false)
        }, multiAgent: true)

        store.draft = "Run stubborn task"
        store.send()
        await settle(store)

        // Must execute exactly 3 times (attempt 1 + 2 retries) and then abort the step
        #expect(executorRuns == 3, "Executor must be capped at exactly 3 attempts (attempt 1 + 2 retries)")
        #expect(criticRuns == 3, "Critic must be capped at exactly 3 checks")
        #expect(store.phase == .needsInput, "Failed steps should leave store in .needsInput phase")
        #expect(store.activeAgentRole == nil, "Active agent role must be cleared after completion")
        #expect(store.messages.last?.text.contains("I couldn’t finish the remaining steps") == false, "Single step failure handles synthesis gracefully")
    }

    @Test("Circuit Breaker: Two consecutive step failures abort subsequent steps in the plan")
    func circuitBreakerAbortsAfterTwoConsecutiveFailures() async throws {
        var stepsAttempted: [String] = []

        let store = AssistantStore(persistenceURL: nil, complete: { input, tools, config in
            let system = input.first?.content ?? ""
            if system.contains("ROLE: Planner") {
                if stepsAttempted.isEmpty {
                    return ModelReply(content: """
                    {
                      "taskType": "automation",
                      "steps": [
                        {"id": "s1", "role": "Executor", "title": "Step 1 Failing"},
                        {"id": "s2", "role": "Executor", "title": "Step 2 Failing"},
                        {"id": "s3", "role": "Executor", "title": "Step 3 Should Never Run"},
                        {"id": "s4", "role": "Executor", "title": "Step 4 Should Never Run"}
                      ]
                    }
                    """, toolCalls: [])
                } else {
                    return ModelReply(content: "Aborted plan due to failure cascade.", toolCalls: [])
                }
            } else if system.contains("ROLE: Executor") {
                let userPrompt = input.last?.content ?? ""
                if userPrompt.contains("Step 1 Failing") && !stepsAttempted.contains("Step 1 Failing") {
                    stepsAttempted.append("Step 1 Failing")
                } else if userPrompt.contains("Step 2 Failing") && !stepsAttempted.contains("Step 2 Failing") {
                    stepsAttempted.append("Step 2 Failing")
                } else if userPrompt.contains("Step 3") && !stepsAttempted.contains("Step 3") {
                    stepsAttempted.append("Step 3")
                }
                return ModelReply(content: "", toolCalls: [
                    ToolCall(name: "open_app", arguments: ["app": .string("com.apple.Notes")])
                ])
            } else if system.contains("ROLE: Critic") {
                return ModelReply(content: "UNVERIFIED: Persistent failure", toolCalls: [])
            }
            throw RelayError.message("Unexpected")
        }, execute: { _ in
            return ToolResult(summary: "Failed", evidence: "None", verified: false)
        }, multiAgent: true)

        store.draft = "Run cascading failure plan"
        store.send()
        await settle(store)

        #expect(stepsAttempted.contains("Step 1 Failing"))
        #expect(stepsAttempted.contains("Step 2 Failing"))
        #expect(!stepsAttempted.contains("Step 3"), "Step 3 must never be executed after 2 consecutive step failures")
        #expect(store.phase == .needsInput)
    }

    // MARK: - 2. Cancellation Semantics Stress Tests

    @Test("Immediate stop during planning phase prevents navigation and execution")
    func stopDuringPlannerTurnHaltsImmediately() async throws {
        var plannerCalled = false
        var executorCalled = false

        let store = AssistantStore(persistenceURL: nil, complete: { input, tools, config in
            let system = input.first?.content ?? ""
            if system.contains("ROLE: Planner") {
                plannerCalled = true
                // Simulate delay in planner
                try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
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
        // Wait a tiny bit then trigger stop while planning
        try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        store.stop()
        await settle(store)

        #expect(plannerCalled)
        #expect(!executorCalled, "Executor must NEVER be called after planner was stopped")
        #expect(store.phase == .stopped)
        #expect(store.activeAgentRole == nil)
    }

    @Test("Immediate stop during execution action halts before critic turn")
    func stopDuringExecutorActionHaltsBeforeCritic() async throws {
        var criticCalled = false
        var executorStarted = false

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
                executorStarted = true
                return ModelReply(content: "", toolCalls: [
                    ToolCall(name: "open_app", arguments: ["app": .string("com.apple.Calculator")])
                ])
            } else if system.contains("ROLE: Critic") {
                criticCalled = true
                return ModelReply(content: "VERIFIED", toolCalls: [])
            }
            throw RelayError.message("Unexpected")
        }, execute: { call in
            // While executor tool is executing, trigger stop
            try? await Task.sleep(nanoseconds: 30_000_000)
            return ToolResult(summary: "Opened Calculator", evidence: "PID 123", verified: true)
        }, multiAgent: true)

        store.draft = "Run long execution"
        store.send()

        // Wait until executor starts, then stop
        for _ in 0..<100 where !executorStarted {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        store.stop()
        await settle(store)

        #expect(executorStarted)
        #expect(!criticCalled, "Critic must NOT be called when stopped during executor turn")
        #expect(store.phase == .stopped)
        #expect(store.activeAgentRole == nil)
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

    @Test("Completely empty or whitespace planner response treated as informational completion")
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

        #expect(store.phase == .idle)
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
                return ModelReply(content: "Found state", toolCalls: [])
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

