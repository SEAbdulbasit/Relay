import Foundation

/// Result emitted upon completion of a multi-agent orchestration task.
struct MultiAgentResult: Sendable {
    let content: String
    let verifiedResults: [ToolResult]
    let artifacts: [String]
    let isSuccess: Bool

    init(
        content: String,
        verifiedResults: [ToolResult] = [],
        artifacts: [String] = [],
        isSuccess: Bool = true
    ) {
        self.content = content
        self.verifiedResults = verifiedResults
        self.artifacts = artifacts
        self.isSuccess = isSuccess
    }
}

/// Orchestrates sequential, turn-based coordination across specialized agent roles:
/// Planner -> Navigator -> Executor -> Critic -> Synthesis.
/// Fully offline, deterministic, and bounded to Apple Silicon unified memory constraints.
@MainActor
final class MultiAgentOrchestrator {
    typealias CompleteHandler = ([ModelMessage], [ToolDefinition], ModelConfiguration) async throws -> ModelReply
    typealias ExecuteHandler = (ToolCall) async throws -> ToolResult
    typealias ReviewCheck = (ToolCall) -> String?
    typealias ReviewHandler = (ToolCall, String) async throws -> Bool
    typealias GateCheck = () throws -> Void

    let blackboard: MultiAgentBlackboard
    private let complete: CompleteHandler
    private let execute: ExecuteHandler
    private let reviewReason: ReviewCheck?
    private let requestReview: ReviewHandler?
    private let gate: GateCheck?
    private let allTools: [ToolDefinition]
    private let configuration: ModelConfiguration

    var onRoleChange: ((AgentRole) -> Void)?
    var onActivity: ((AgentActivityItem) -> Void)?
    var onPlanUpdate: (([String]) -> Void)?

    init(
        blackboard: MultiAgentBlackboard? = nil,
        allTools: [ToolDefinition] = MacTools.definitions,
        configuration: ModelConfiguration = ModelConfiguration(),
        complete: @escaping CompleteHandler,
        execute: @escaping ExecuteHandler,
        reviewReason: ReviewCheck? = nil,
        requestReview: ReviewHandler? = nil,
        gate: GateCheck? = nil
    ) {
        self.blackboard = blackboard ?? MultiAgentBlackboard()
        self.allTools = allTools
        self.configuration = configuration
        self.complete = complete
        self.execute = execute
        self.reviewReason = reviewReason
        self.requestReview = requestReview
        self.gate = gate
    }

    /// Executes the full multi-agent loop for the provided user goal.
    func executeTask(goal: String) async throws -> MultiAgentResult {
        try gate?()
        blackboard.reset(with: goal)

        // 1. Planner Turn: Goal Decomposition
        let planGenerated = try await runPlannerTurn(goal: goal)
        try gate?()

        // If the planner identified an informational query or produced no automation steps,
        // return the synthesized or informational reply immediately without spinning up navigation/execution.
        if !planGenerated || blackboard.structuredPlan.isEmpty {
            let directAnswer = blackboard.criticFeedback ?? "Task completed."
            return MultiAgentResult(
                content: directAnswer,
                verifiedResults: blackboard.verifiedResults,
                artifacts: blackboard.verifiedResults.compactMap(\.artifactPath),
                isSuccess: true
            )
        }

        // 2. Sequential Step Execution Loop
        var stepFailures = 0
        for step in blackboard.structuredPlan {
            try gate?()
            let stepSuccess = try await executePlanStepWithVerification(step: step, goal: goal)
            if !stepSuccess {
                stepFailures += 1
                if stepFailures >= 2 {
                    break
                }
            }
        }

        // 3. Synthesis Turn: Planner compiles final verified answer
        try gate?()
        let finalResponse = try await runSynthesisTurn(goal: goal)

        return MultiAgentResult(
            content: finalResponse,
            verifiedResults: blackboard.verifiedResults,
            artifacts: blackboard.verifiedResults.compactMap(\.artifactPath),
            isSuccess: stepFailures == 0
        )
    }

    // MARK: - Role Turns

    /// Runs the strategic Planner agent to decompose the user goal into discrete subtasks.
    private func runPlannerTurn(goal: String) async throws -> Bool {
        transition(to: .planner)
        recordActivity(
            role: .planner,
            title: "Planning task execution",
            detail: "Decomposing goal into discrete subtasks"
        )

        let system = ModelMessage(role: "system", content: AgentRole.planner.systemPrompt)
        let userMsg = ModelMessage(
            role: "user",
            content: "User objective: \(goal)\nDecompose this request into discrete subgoals with assigned roles (Navigator, Executor, Critic) or answer directly if purely informational."
        )
        let tools = ToolPartitioning.partitionedTools(for: .planner, from: allTools)

        let reply = try await complete([system, userMsg], tools, configuration)
        try gate?()

        // Parse plan from reply content
        let parsedSteps = parsePlan(from: reply.content)
        if !parsedSteps.isEmpty {
            blackboard.setPlan(parsedSteps)
            onPlanUpdate?(blackboard.planSteps)
            recordActivity(
                role: .planner,
                title: "Plan established",
                detail: "\(parsedSteps.count) discrete subtasks scheduled"
            )
            return true
        } else {
            // Informational answer or direct response
            blackboard.criticFeedback = reply.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return false
        }
    }

    /// Executes an individual plan step through the appropriate role sequence (Navigator -> Executor -> Critic).
    private func executePlanStepWithVerification(step: PlanStep, goal: String) async throws -> Bool {
        var retries = 0
        let maxRetries = 2

        while retries <= maxRetries {
            try gate?()

            switch step.role {
            case .navigator:
                let navResult = try await runNavigatorTurn(step: step, goal: goal)
                if navResult {
                    blackboard.completeStep(step.title)
                    return true
                } else {
                    return false
                }
            case .planner:
                blackboard.completeStep(step.title)
                return true
            case .critic:
                let verified = try await runCriticTurn(step: step, goal: goal, actionExecuted: false)
                if verified {
                    blackboard.completeStep(step.title)
                    return true
                } else {
                    return false
                }
            case .executor:
                // Executor Turn
                let actionExecuted = try await runExecutorTurn(step: step, goal: goal)
                try gate?()

                // Critic Turn
                let verified = try await runCriticTurn(step: step, goal: goal, actionExecuted: actionExecuted)
                try gate?()

                if verified {
                    blackboard.completeStep(step.title)
                    blackboard.criticFeedback = nil
                    recordActivity(
                        role: .critic,
                        title: "Step certified",
                        detail: "Verified: \(step.title)"
                    )
                    return true
                } else {
                    retries += 1
                    if retries <= maxRetries {
                        recordActivity(
                            role: .critic,
                            title: "Critic requested retry (\(retries)/\(maxRetries))",
                            detail: blackboard.criticFeedback ?? "Postconditions unverified"
                        )
                    }
                }
            }
        }

        recordActivity(
            role: .critic,
            title: "Step incomplete",
            detail: "Max retries reached for: \(step.title)"
        )
        return false
    }

    /// Runs the Navigator agent to inspect UI, applications, or files without mutations.
    private func runNavigatorTurn(step: PlanStep, goal: String) async throws -> Bool {
        transition(to: .navigator)
        recordActivity(
            role: .navigator,
            title: "Navigating & inspecting state",
            detail: step.title
        )

        let system = ModelMessage(role: "system", content: AgentRole.navigator.systemPrompt)
        var context = "User objective: \(goal)\nActive subtask: \(step.title)"
        if !blackboard.observations.isEmpty {
            context += "\nPrior observations:\n" + blackboard.observations.joined(separator: "\n")
        }
        if let feedback = blackboard.criticFeedback {
            context += "\nDiagnostic feedback from Critic: \(feedback)"
        }
        let userMsg = ModelMessage(role: "user", content: context)
        let tools = ToolPartitioning.partitionedTools(for: .navigator, from: allTools)

        let reply = try await complete([system, userMsg], tools, configuration)
        try gate?()

        if reply.toolCalls.isEmpty {
            if !reply.content.isEmpty {
                blackboard.addObservation(reply.content)
            }
            return true
        }

        for call in reply.toolCalls {
            try gate?()
            recordActivity(role: .navigator, title: "Dispatching inspection", detail: call.name)
            let result = try await execute(call)
            blackboard.addObservation("\(call.name): \(result.summary)")
            recordActivity(role: .navigator, title: "Observed \(call.name)", detail: result.summary)
            if result.verified {
                blackboard.verifiedResults.append(result)
            }
        }
        return true
    }

    /// Runs the Executor agent to perform the concrete action required by the step.
    private func runExecutorTurn(step: PlanStep, goal: String) async throws -> Bool {
        transition(to: .executor)
        recordActivity(
            role: .executor,
            title: "Executing action",
            detail: step.title
        )

        let system = ModelMessage(role: "system", content: AgentRole.executor.systemPrompt)
        var context = "User objective: \(goal)\nActive action step: \(step.title)"
        if !blackboard.observations.isEmpty {
            context += "\nFresh observations from Navigator:\n" + blackboard.observations.joined(separator: "\n")
        }
        if let feedback = blackboard.criticFeedback {
            context += "\nCritic postcondition feedback from previous attempt: \(feedback)\nAdjust your tool arguments to resolve this feedback."
        }
        let userMsg = ModelMessage(role: "user", content: context)
        let tools = ToolPartitioning.partitionedTools(for: .executor, from: allTools)

        let reply = try await complete([system, userMsg], tools, configuration)
        try gate?()

        if reply.toolCalls.isEmpty {
            // Model did not dispatch a tool (e.g. pure verbal action or fallback)
            return false
        }

        for call in reply.toolCalls {
            try gate?()
            // Check review requirement
            if let reason = reviewReason?(call), let requestReview {
                let approved = try await requestReview(call, reason)
                try gate?()
                guard approved else {
                    recordActivity(role: .executor, title: "Action declined by user", detail: call.name)
                    return false
                }
            }

            recordActivity(role: .executor, title: "Dispatching mutation", detail: call.name)
            let result = try await execute(call)
            recordActivity(role: .executor, title: "Executed \(call.name)", detail: result.summary)
            if result.verified {
                blackboard.verifiedResults.append(result)
            }
        }
        return true
    }

    /// Runs the Critic agent to independently verify whether the action's postconditions were fulfilled.
    private func runCriticTurn(step: PlanStep, goal: String, actionExecuted: Bool) async throws -> Bool {
        transition(to: .critic)
        recordActivity(
            role: .critic,
            title: "Verifying outcome",
            detail: "Evaluating postconditions for: \(step.title)"
        )

        let system = ModelMessage(role: "system", content: AgentRole.critic.systemPrompt)
        let recentResults = blackboard.verifiedResults.suffix(3)
        var context = "User objective: \(goal)\nEvaluated step: \(step.title)\nAction was dispatched: \(actionExecuted)"
        if !recentResults.isEmpty {
            context += "\nRecent tool evidence:\n" + recentResults.map { "• \($0.summary) — \($0.evidence) [verified=\($0.verified)]" }.joined(separator: "\n")
        }
        if !blackboard.observations.isEmpty {
            context += "\nLatest observations:\n" + blackboard.observations.suffix(3).joined(separator: "\n")
        }
        let userMsg = ModelMessage(
            role: "user",
            content: context + "\nIndependently evaluate if the intended postcondition is satisfied. Emit VERIFIED: <evidence> or UNVERIFIED: <diagnostic feedback>."
        )
        let tools = ToolPartitioning.partitionedTools(for: .critic, from: allTools)

        let reply = try await complete([system, userMsg], tools, configuration)
        try gate?()

        // If the Critic chooses to execute an independent inspection tool (e.g. read_file, observe_app)
        if !reply.toolCalls.isEmpty {
            for call in reply.toolCalls {
                try gate?()
                recordActivity(role: .critic, title: "Dispatching verification readback", detail: call.name)
                let result = try await execute(call)
                recordActivity(role: .critic, title: "Critic readback result", detail: result.summary)
                if result.verified {
                    blackboard.verifiedResults.append(result)
                }
            }
        }

        let contentUpper = reply.content.uppercased()
        if contentUpper.contains("VERIFIED") && !contentUpper.contains("UNVERIFIED") {
            return true
        }

        // If tool itself reported verified and critic did not explicitly dispute it
        let hasDirectVerifiedEvidence = blackboard.verifiedResults.last?.verified == true
        if hasDirectVerifiedEvidence && !contentUpper.contains("UNVERIFIED") && !contentUpper.contains("FAIL") {
            return true
        }

        // Store critic's diagnostic feedback for retry turn
        blackboard.criticFeedback = reply.content.isEmpty ? "Action postcondition could not be independently verified." : reply.content
        return false
    }

    /// Runs the final synthesis turn where the Planner summarizes all completed work and verified evidence.
    private func runSynthesisTurn(goal: String) async throws -> String {
        transition(to: .planner)
        recordActivity(
            role: .planner,
            title: "Synthesizing response",
            detail: "Compiling verified outcomes"
        )

        let system = ModelMessage(role: "system", content: AgentRole.planner.systemPrompt)
        var context = "User objective: \(goal)\nCompleted subtasks:\n"
        context += blackboard.completedSteps.map { "• \($0)" }.joined(separator: "\n")
        if !blackboard.verifiedResults.isEmpty {
            context += "\n\nVerified outcomes:\n" + blackboard.verifiedResults.map { "• \($0.summary) — \($0.evidence)" }.joined(separator: "\n")
        }
        let userMsg = ModelMessage(
            role: "user",
            content: context + "\n\nSynthesize a clear, concise final response to the user summarizing the completed work. Do not claim unverified actions."
        )
        let tools = ToolPartitioning.partitionedTools(for: .planner, from: allTools)

        let reply = try await complete([system, userMsg], tools, configuration)
        let summary = reply.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return summary.isEmpty ? "Task completed successfully." : summary
    }

    // MARK: - Helper Methods

    private func transition(to role: AgentRole) {
        blackboard.advanceRole(to: role)
        onRoleChange?(role)
    }

    @discardableResult
    private func recordActivity(role: AgentRole, title: String, detail: String? = nil) -> AgentActivityItem {
        let item = blackboard.recordActivity(role: role, title: title, detail: detail)
        onActivity?(item)
        return item
    }

    private func isAppInteractionStep(_ stepTitle: String) -> Bool {
        let lower = stepTitle.lowercased()
        return lower.contains("app") || lower.contains("window") || lower.contains("click") ||
               lower.contains("button") || lower.contains("press") || lower.contains("find")
    }

    /// Robust plan parser capable of decoding structured JSON objects, JSON string arrays, or markdown lists.
    private func parsePlan(from text: String) -> [PlanStep] {
        // Attempt 1: Extract and parse JSON
        if let jsonString = extractJSON(from: text), let data = jsonString.data(using: .utf8) {
            if let planDTO = try? JSONDecoder().decode(PlanDTO.self, from: data), let steps = planDTO.steps {
                return steps.enumerated().map { index, stepDTO in
                    switch stepDTO {
                    case .object(let id, let roleString, let title, let goal):
                        let role = parseRole(from: roleString)
                        let stepTitle = title ?? goal ?? "Subtask \(index + 1)"
                        return PlanStep(id: id ?? "s\(index + 1)", role: role, title: stepTitle)
                    case .string(let str):
                        return PlanStep(id: "s\(index + 1)", role: .executor, title: str)
                    }
                }
            }

            if let flatStrings = try? JSONDecoder().decode([String].self, from: data) {
                return flatStrings.enumerated().map { index, str in
                    PlanStep(id: "s\(index + 1)", role: .executor, title: str)
                }
            }
        }

        // Attempt 2: Parse numbered or bulleted lines
        var parsed: [PlanStep] = []
        let lines = text.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let match = parseNumberedLine(trimmed) {
                parsed.append(PlanStep(id: "s\(parsed.count + 1)", role: .executor, title: match))
            }
        }
        return parsed
    }

    private func parseRole(from string: String?) -> AgentRole {
        guard let string = string?.lowercased() else { return .executor }
        if string.contains("plan") { return .planner }
        if string.contains("nav") || string.contains("inspect") || string.contains("find") { return .navigator }
        if string.contains("critic") || string.contains("verif") { return .critic }
        return .executor
    }

    private func parseNumberedLine(_ line: String) -> String? {
        guard line.count > 3 else { return nil }
        // Match e.g. "1. Step description" or "1) Step description"
        let digits = line.prefix { $0.isNumber }
        if !digits.isEmpty {
            let rest = line.dropFirst(digits.count)
            if rest.hasPrefix(".") || rest.hasPrefix(")") {
                let candidate = rest.dropFirst().trimmingCharacters(in: .whitespaces)
                if !candidate.isEmpty { return candidate }
            }
        }
        if line.hasPrefix("- [ ] ") {
            return String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private func extractJSON(from text: String) -> String? {
        if let start = text.range(of: "```json"), let end = text.range(of: "```", range: start.upperBound..<text.endIndex) {
            return String(text[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let firstBrace = text.firstIndex(of: "{"), let lastBrace = text.lastIndex(of: "}") {
            return String(text[firstBrace...lastBrace])
        }
        if let firstBracket = text.firstIndex(of: "["), let lastBracket = text.lastIndex(of: "]") {
            return String(text[firstBracket...lastBracket])
        }
        return nil
    }
}

// MARK: - Internal DTOs for Plan Parsing

private struct PlanDTO: Decodable {
    var taskType: String?
    var steps: [StepDTO]?
    var explanation: String?
}

private enum StepDTO: Decodable {
    case object(id: String?, role: String?, title: String?, goal: String?)
    case string(String)

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let str = try? single.decode(String.self) {
            self = .string(str)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try? container.decode(String.self, forKey: .id)
        let role = try? container.decode(String.self, forKey: .role)
        let title = try? container.decode(String.self, forKey: .title)
        let goal = try? container.decode(String.self, forKey: .goal)
        self = .object(id: id, role: role, title: title, goal: goal)
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, title, goal
    }
}
