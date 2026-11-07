import Foundation
import Testing
@testable import Relay

@Suite("AgentRoleTests")
@MainActor
struct AgentRoleTests {

    @Test("Role decoding supports lowercase, uppercase, and titlecase")
    func roleDecodingIsCaseInsensitive() throws {
        let json = """
        ["planner", "Navigator", "EXECUTOR", "critic", "verifier"]
        """
        let roles = try JSONDecoder().decode([AgentRole].self, from: json.data(using: .utf8)!)
        #expect(roles == [.planner, .navigator, .executor, .critic, .critic])
    }

    @Test("Role display names, badges, and icon tokens are defined")
    func roleVisualAttributes() {
        #expect(AgentRole.planner.displayName == "Planner")
        #expect(AgentRole.planner.badgeText == "[Planner]")
        #expect(!AgentRole.planner.iconName.isEmpty)

        #expect(AgentRole.navigator.displayName == "Navigator")
        #expect(AgentRole.navigator.badgeText == "[Navigator]")
        #expect(!AgentRole.navigator.iconName.isEmpty)

        #expect(AgentRole.executor.displayName == "Executor")
        #expect(AgentRole.executor.badgeText == "[Executor]")
        #expect(!AgentRole.executor.iconName.isEmpty)

        #expect(AgentRole.critic.displayName == "Critic")
        #expect(AgentRole.critic.badgeText == "[Critic]")
        #expect(!AgentRole.critic.iconName.isEmpty)
    }

    @Test("Role system prompts include unambiguous turn attribution prefixes")
    func roleSystemPromptsContainRolePrefixes() {
        #expect(AgentRole.planner.systemPrompt.contains("ROLE: Planner"))
        #expect(AgentRole.planner.systemPrompt.contains("Gemma 4 E2B"))

        #expect(AgentRole.navigator.systemPrompt.contains("ROLE: Navigator"))
        #expect(AgentRole.navigator.systemPrompt.contains("NEVER modify system state"))

        #expect(AgentRole.executor.systemPrompt.contains("ROLE: Executor"))
        #expect(AgentRole.executor.systemPrompt.contains("concrete action execution"))

        #expect(AgentRole.critic.systemPrompt.contains("ROLE: Critic"))
        #expect(AgentRole.critic.systemPrompt.contains("independent verification"))
    }
}

@Suite("ToolPartitioningTests")
@MainActor
struct ToolPartitioningTests {

    @Test("Planner role has zero tools to prevent reasoning distraction")
    func plannerHasZeroTools() {
        let tools = ToolPartitioning.partitionedTools(for: .planner, from: MacTools.definitions)
        #expect(tools.isEmpty)
        #expect(ToolPartitioning.schemaByteSize(for: tools) == 0)
        #expect(ToolPartitioning.schemaByteReduction(for: .planner, against: MacTools.definitions) == 1.0)
    }

    @Test("Navigator receives only read-only inspection tools")
    func navigatorHasInspectionTools() {
        let tools = ToolPartitioning.partitionedTools(for: .navigator, from: MacTools.definitions)
        let toolNames = Set(tools.map(\.name))
        #expect(toolNames.contains("observe_app"))
        #expect(toolNames.contains("list_apps"))
        #expect(toolNames.contains("search_finder"))
        #expect(toolNames.contains("list_files"))
        #expect(!toolNames.contains("press_control"))
        #expect(!toolNames.contains("write_file"))
    }

    @Test("Executor receives targeted mutation tools")
    func executorHasMutationTools() {
        let tools = ToolPartitioning.partitionedTools(for: .executor, from: MacTools.definitions)
        let toolNames = Set(tools.map(\.name))
        #expect(toolNames.contains("open_app"))
        #expect(toolNames.contains("press_control"))
        #expect(toolNames.contains("set_value"))
        #expect(toolNames.contains("write_file"))
        #expect(toolNames.contains("create_document"))
        #expect(toolNames.contains("create_spreadsheet"))
    }

    @Test("Critic receives read-only verification tools")
    func criticHasVerificationTools() {
        let tools = ToolPartitioning.partitionedTools(for: .critic, from: MacTools.definitions)
        let toolNames = Set(tools.map(\.name))
        #expect(toolNames.contains("read_file"))
        #expect(toolNames.contains("observe_app"))
        #expect(toolNames.contains("read_browser_page"))
        #expect(!toolNames.contains("write_file"))
        #expect(!toolNames.contains("press_control"))
    }

    @Test("Tool partitioning reduces schema context overhead by 70-100% across individual roles")
    func toolPartitioningAchievesTargetReduction() {
        let fullTools = MacTools.definitions
        let fullBytes = ToolPartitioning.schemaByteSize(for: fullTools)
        #expect(fullBytes > 3_500, "Full tool definitions should consume ~4.5+ KB")

        let plannerReduction = ToolPartitioning.schemaByteReduction(for: .planner, against: fullTools)
        #expect(plannerReduction == 1.0, "Planner should have 100% reduction (0 bytes)")

        let criticReduction = ToolPartitioning.schemaByteReduction(for: .critic, against: fullTools)
        #expect(criticReduction >= 0.80, "Critic should have >= 80% reduction")

        let navReduction = ToolPartitioning.schemaByteReduction(for: .navigator, against: fullTools)
        #expect(navReduction >= 0.70, "Navigator should have >= 70% reduction")

        let averageBytes = ToolPartitioning.averagePartitionedSchemaBytes(from: fullTools)
        #expect(averageBytes < fullBytes, "Average schema bytes should be substantially reduced")
    }
}

@Suite("MultiAgentBlackboardTests")
@MainActor
struct MultiAgentBlackboardTests {

    @Test("Blackboard manages sequential coordination state")
    func blackboardStateManagement() {
        let blackboard = MultiAgentBlackboard(userGoal: "Open Notes and write meeting minutes")
        #expect(blackboard.userGoal == "Open Notes and write meeting minutes")
        #expect(blackboard.currentRole == .planner)
        #expect(blackboard.isComplete)

        blackboard.setPlan([
            PlanStep(id: "s1", role: .navigator, title: "Find Notes app"),
            PlanStep(id: "s2", role: .executor, title: "Launch Notes app"),
            PlanStep(id: "s3", role: .critic, title: "Verify Notes is active")
        ])

        #expect(blackboard.planSteps.count == 3)
        #expect(!blackboard.isComplete)

        blackboard.addObservation("Found Notes at /System/Applications/Notes.app")
        #expect(blackboard.observations.count == 1)

        blackboard.recordActivity(role: .navigator, title: "Observed Notes", detail: "com.apple.Notes")
        #expect(blackboard.history.count == 1)

        blackboard.completeStep("Find Notes app")
        #expect(blackboard.completedSteps.count == 1)
        #expect(!blackboard.isComplete)

        blackboard.completeStep("Launch Notes app")
        blackboard.completeStep("Verify Notes is active")
        #expect(blackboard.isComplete)

        blackboard.reset(with: "New goal")
        #expect(blackboard.userGoal == "New goal")
        #expect(blackboard.planSteps.isEmpty)
        #expect(blackboard.history.isEmpty)
    }
}

@Suite("MultiAgentOrchestrationTests")
@MainActor
struct MultiAgentOrchestrationTests {

    private func settle(_ store: AssistantStore) async {
        for _ in 0..<500 where store.isRunning { await Task.yield() }
        #expect(!store.isRunning)
    }

    @Test("Multi-agent Executor rejects a stale control batch before its first write")
    func executorBatchPreflightIsAtomicBeforeAnyDesktopEffect() async {
        var dispatched: [String] = [], roles: [String] = []
        let store = AssistantStore(persistenceURL: nil, complete: { messages, _, _ in
            let system = messages.first?.content ?? ""
            if system.contains("ROLE: Planner") {
                roles.append("planner")
                return ModelReply(content: """
                {"taskType":"automation","steps":[{"id":"only","role":"Executor","title":"Change one inert field"}]}
                """, toolCalls: [])
            }
            roles.append("executor")
            #expect(system.contains("ROLE: Executor"))
            return ModelReply(content: "", toolCalls: [
                ToolCall(name: "set_value", arguments: ["bundle_id": .string("test.inert.app"),
                    "element_id": .string("original-input"), "value": .string("Exact Café 🌍")]),
                ToolCall(name: "press_control", arguments: ["bundle_id": .string("test.inert.app"),
                    "element_id": .string("original-apply")])
            ])
        }, execute: { call in
            dispatched.append(call.name)
            Issue.record("The invalid Executor batch reached dispatch.")
            return ToolResult(summary: "Unexpected effect", evidence: "Synthetic executor", verified: true)
        }, multiAgent: true)
        store.draft = "Change only the inert field, then inspect its result."
        store.send()
        await settle(store)
        #expect(dispatched.isEmpty && roles == ["planner", "executor"])
        #expect(store.pendingReview == nil && store.phase == .failed)
        #expect(store.errorMessage?.contains("No action from that reply was dispatched") == true)
        store.stop()
    }

    @Test("Multi-agent Navigator cannot reuse a scoped reference after an earlier observation")
    func navigatorBatchPreflightRejectsStaleScopeBeforeAnyInspection() async {
        var dispatched: [String] = [], roles: [String] = []
        let store = AssistantStore(persistenceURL: nil, complete: { messages, _, _ in
            let system = messages.first?.content ?? ""
            if system.contains("ROLE: Planner") {
                roles.append("planner")
                return ModelReply(content: """
                {"taskType":"automation","steps":[{"id":"only","role":"Navigator","title":"Inspect one inert window"}]}
                """, toolCalls: [])
            }
            roles.append("navigator")
            #expect(system.contains("ROLE: Navigator"))
            return ModelReply(content: "", toolCalls: [
                ToolCall(name: "observe_app", arguments: ["bundle_id": .string("test.inert.app")]),
                ToolCall(name: "observe_app", arguments: ["bundle_id": .string("test.inert.app"),
                    "window_id": .string("already-expired-window")])
            ])
        }, execute: { call in
            dispatched.append(call.name)
            Issue.record("The invalid Navigator batch reached source inspection.")
            return ToolResult(summary: "Unexpected source", evidence: "Synthetic executor", verified: true)
        }, multiAgent: true)
        store.draft = "Inspect only the selected inert window."
        store.send()
        await settle(store)
        #expect(dispatched.isEmpty && roles == ["planner", "navigator"])
        #expect(store.pendingReview == nil && store.phase == .failed)
        #expect(store.errorMessage?.contains("No action from that reply was dispatched") == true)
        store.stop()
    }

    @Test("End-to-end multi-agent execution: Planner -> Navigator -> Executor -> Critic -> Synthesis")
    func endToEndMultiAgentHappyPath() async throws {
        var turns = 0
        var rolesInvoked: [AgentRole] = []
        var toolsDispatched: [String] = []

        let store = AssistantStore(persistenceURL: nil, complete: { input, tools, config in
            turns += 1
            let systemPrompt = input.first?.content ?? ""
            if systemPrompt.contains("ROLE: Planner") {
                rolesInvoked.append(.planner)
                if turns == 1 {
                    // Turn 1: Planner outputs structured step plan
                    return ModelReply(content: """
                    {
                      "taskType": "automation",
                      "steps": [
                        {"id": "s1", "role": "Navigator", "title": "Inspect Voice Memos installation"},
                        {"id": "s2", "role": "Executor", "title": "Launch Voice Memos application"}
                      ]
                    }
                    """, toolCalls: [])
                } else {
                    // Final turn: Synthesis
                    return ModelReply(content: "I have located Voice Memos and launched the application.", toolCalls: [])
                }
            } else if systemPrompt.contains("ROLE: Navigator") {
                rolesInvoked.append(.navigator)
                return ModelReply(content: "", toolCalls: [
                    ToolCall(name: "observe_app", arguments: ["bundle_id": .string("com.apple.VoiceMemos")])
                ])
            } else if systemPrompt.contains("ROLE: Executor") {
                rolesInvoked.append(.executor)
                return ModelReply(content: "", toolCalls: [
                    ToolCall(name: "open_app", arguments: [
                        "app": .string("com.apple.VoiceMemos")
                    ])
                ])
            } else if systemPrompt.contains("ROLE: Critic") {
                rolesInvoked.append(.critic)
                return ModelReply(content: "VERIFIED: Voice Memos is running and active.", toolCalls: [])
            }
            throw RelayError.message("Unexpected turn in multi-agent test: \(systemPrompt)")
        }, execute: { call in
            toolsDispatched.append(call.name)
            if call.name == "observe_app" {
                return ToolResult(
                    summary: "Observed Voice Memos: installed",
                    evidence: "AXUIElement tree fixture",
                    verified: true
                )
            } else if call.name == "open_app" {
                return ToolResult(
                    summary: "Opened Voice Memos",
                    evidence: "Process identifier running",
                    verified: true
                )
            }
            throw RelayError.message("Unexpected tool: \(call.name)")
        }, multiAgent: true)

        store.draft = "Record a quick voice memo"
        store.send()
        await settle(store)

        #expect(rolesInvoked.contains(.planner))
        #expect(rolesInvoked.contains(.navigator))
        #expect(rolesInvoked.contains(.executor))
        #expect(rolesInvoked.contains(.critic))
        #expect(toolsDispatched == ["observe_app", "open_app"])
        #expect(store.currentPlanSteps.count == 2)
        #expect(store.agentActivities.count >= 4)
        #expect(store.activeAgentRole == nil)
        #expect(store.phase == .idle)
        #expect(store.messages.last?.text.contains("launched the application") == true)
        #expect(store.messages.last?.text.contains("Checked by Relay:") == true)
    }

    @Test("Critic rejection preserves checked evidence without repeating the action")
    func criticRejectionPreservesVerifiedToolOutcomeWithoutRetry() async throws {
        var executorCalls = 0
        var criticChecks = 0

        let store = AssistantStore(persistenceURL: nil, complete: { input, tools, config in
            let systemPrompt = input.first?.content ?? ""
            if systemPrompt.contains("ROLE: Planner") {
                if executorCalls == 0 {
                    return ModelReply(content: """
                    {
                      "taskType": "automation",
                      "steps": [
                        {"id": "s1", "role": "Executor", "title": "Launch target app"}
                      ]
                    }
                    """, toolCalls: [])
                } else {
                    return ModelReply(content: "Completed with verified recovery.", toolCalls: [])
                }
            } else if systemPrompt.contains("ROLE: Executor") {
                executorCalls += 1
                return ModelReply(content: "", toolCalls: [
                    ToolCall(name: "open_app", arguments: ["app": .string("com.apple.Notes")])
                ])
            } else if systemPrompt.contains("ROLE: Critic") {
                criticChecks += 1
                return ModelReply(content: "UNVERIFIED: Application did not become frontmost.", toolCalls: [])
            }
            throw RelayError.message("Unexpected turn")
        }, execute: { call in
            return ToolResult(
                summary: "Opened Notes",
                evidence: "Process identifier running",
                verified: true
            )
        }, multiAgent: true)

        store.draft = "Launch Notes"
        store.send()
        await settle(store)

        #expect(executorCalls == 1)
        #expect(criticChecks == 1)
        #expect(store.phase == .needsInput)
        #expect(store.messages.last?.text.contains("Unfinished steps:\n• Launch target app") == true)
        #expect(store.messages.last?.text.contains("Process identifier running") == true)
        #expect(store.messages.last?.text.contains("Completed with verified recovery") == false)
    }

    @Test("Informational requests take direct fast-path without unnecessary actions")
    func informationalRequestFastPath() async throws {
        var actionsDispatched = 0
        var rolesInvoked: [AgentRole] = []

        let store = AssistantStore(persistenceURL: nil, complete: { input, tools, config in
            let systemPrompt = input.first?.content ?? ""
            if systemPrompt.contains("ROLE: Planner") {
                rolesInvoked.append(.planner)
                return ModelReply(content: """
                {
                  "taskType": "informational",
                  "steps": [],
                  "explanation": "Relay is a native macOS on-device assistant that operates 100% offline."
                }
                """, toolCalls: [])
            } else if systemPrompt.contains("ROLE: Navigator") {
                rolesInvoked.append(.navigator)
            } else if systemPrompt.contains("ROLE: Executor") {
                rolesInvoked.append(.executor)
            }
            throw RelayError.message("Only planner should be invoked for informational queries")
        }, execute: { call in
            actionsDispatched += 1
            return ToolResult(summary: "None", evidence: "None", verified: false)
        }, multiAgent: true)

        store.draft = "What is Relay?"
        store.send()
        await settle(store)

        #expect(rolesInvoked == [.planner])
        #expect(actionsDispatched == 0)
        #expect(store.messages.last?.text.contains("100% offline") == true)
        #expect(store.phase == .idle)
    }

    @Test("Global stop halts multi-agent coordination immediately across role boundaries")
    func globalStopHaltsMultiAgentCoordination() async throws {
        let store = AssistantStore(persistenceURL: nil, complete: { input, tools, config in
            let systemPrompt = input.first?.content ?? ""
            if systemPrompt.contains("ROLE: Planner") {
                return ModelReply(content: """
                {
                  "taskType": "automation",
                  "steps": [
                    {"id": "s1", "role": "Navigator", "title": "Inspect environment"},
                    {"id": "s2", "role": "Executor", "title": "Perform long action"}
                  ]
                }
                """, toolCalls: [])
            } else if systemPrompt.contains("ROLE: Navigator") {
                return ModelReply(content: "", toolCalls: [
                    ToolCall(name: "observe_app", arguments: ["bundle_id": .string("com.apple.finder")])
                ])
            }
            throw RelayError.message("Stopped before reaching later turns")
        }, execute: { call in
            return ToolResult(summary: "Observed Finder", evidence: "AX tree fixture", verified: true)
        }, multiAgent: true)

        store.draft = "Automate long task"
        store.send()
        // Issue stop while run is in progress
        store.stop()
        await settle(store)

        #expect(store.phase == .stopped)
        #expect(store.activeAgentRole == nil)
        #expect(store.messages.last?.text.contains("Stopped.") == true)
    }

    @Test("runMultiAgentTask direct method executes task and awaits completion")
    func directRunMultiAgentTaskMethod() async throws {
        let store = AssistantStore(persistenceURL: nil, complete: { input, tools, config in
            let systemPrompt = input.first?.content ?? ""
            if systemPrompt.contains("ROLE: Planner") {
                return ModelReply(content: """
                {
                  "taskType": "informational",
                  "steps": [],
                  "explanation": "Direct multi-agent task succeeded."
                }
                """, toolCalls: [])
            }
            throw RelayError.message("Unexpected turn")
        }, execute: { _ in
            throw RelayError.message("No tools")
        })

        try await store.runMultiAgentTask(prompt: "Explain offline privacy")
        #expect(store.phase == .idle)
        #expect(store.messages.last?.text.contains("Direct multi-agent task succeeded") == true)
    }

    @Test("User review gates destructive action during multi-agent execution")
    func reviewInterceptionInMultiAgentExecution() async throws {
        let tempFolder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempFolder) }
        let filePath = tempFolder.appendingPathComponent("output.txt").path

        let store = AssistantStore(persistenceURL: nil, complete: { input, tools, config in
            let systemPrompt = input.first?.content ?? ""
            if systemPrompt.contains("ROLE: Planner") {
                return ModelReply(content: """
                {
                  "taskType": "automation",
                  "steps": [
                    {"id": "s1", "role": "Executor", "title": "Write report file"}
                  ]
                }
                """, toolCalls: [])
            } else if systemPrompt.contains("ROLE: Executor") {
                return ModelReply(content: "", toolCalls: [
                    ToolCall(name: "write_file", arguments: [
                        "path": .string(filePath),
                        "content": .string("Multi-agent offline report.")
                    ])
                ])
            } else if systemPrompt.contains("ROLE: Critic") {
                return ModelReply(content: "VERIFIED: File was created with expected contents.", toolCalls: [])
            }
            throw RelayError.message("Unexpected turn")
        }, execute: { call in
            return ToolResult(
                summary: "Wrote \(filePath)",
                evidence: "27 bytes verified on disk",
                verified: true
            )
        }, multiAgent: true)

        // Add scope grant for the folder
        store.grants = [ScopeGrant(path: tempFolder.path, writable: true)]

        // Pre-create file so write_file requires review (existing file overwrite review)
        try "Prior contents".write(toFile: filePath, atomically: true, encoding: .utf8)

        store.draft = "Write file report"
        store.send()

        // Wait for store to reach awaitingReview
        for _ in 0..<500 where store.phase != .awaitingReview {
            await Task.yield()
        }
        #expect(store.phase == .awaitingReview)
        #expect(store.pendingReview != nil)

        // Approve review
        store.approveReview()
        await settle(store)

        #expect(store.phase == .idle)
        #expect(store.messages.last?.text.contains("Checked by Relay:") == true)
    }
}
