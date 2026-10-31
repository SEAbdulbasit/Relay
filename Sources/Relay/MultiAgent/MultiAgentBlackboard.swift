import Foundation

/// Discrete status for an individual step in the multi-agent plan.
nonisolated enum StepStatus: String, Codable, Sendable {
    case pending
    case inProgress
    case verified
    case failed
    case skipped
}

/// A structured plan step decomposed by the Planner agent.
nonisolated struct PlanStep: Codable, Sendable, Identifiable, Equatable {
    var id: String
    var role: AgentRole
    var title: String
    var status: StepStatus

    init(
        id: String = UUID().uuidString,
        role: AgentRole = .executor,
        title: String,
        status: StepStatus = .pending
    ) {
        self.id = id
        self.role = role
        self.title = title
        self.status = status
    }
}

/// Thread-safe blackboard coordinating state across sequential agent turns.
/// Conforms to @MainActor ensuring strict turn-based sequential execution on Apple Silicon unified memory.
@MainActor
final class MultiAgentBlackboard {
    /// The high-level user goal or prompt.
    var userGoal: String

    /// Flat step descriptions for quick indexing and UI binding.
    var planSteps: [String] {
        didSet {
            // Keep structured plan in sync if modified directly as strings
            if planSteps.count != structuredPlan.count || zip(planSteps, structuredPlan).contains(where: { $0.0 != $0.1.title }) {
                structuredPlan = planSteps.enumerated().map { index, title in
                    PlanStep(id: "step_\(index + 1)", role: .executor, title: title)
                }
            }
        }
    }

    /// Completed step descriptions.
    var completedSteps: [String]

    /// Rich structured plan steps with explicit role assignments and statuses.
    var structuredPlan: [PlanStep]

    /// The agent role currently executing a turn.
    var currentRole: AgentRole

    /// Environment and UI observations gathered by the Navigator and actions.
    var observations: [String]

    /// Diagnostic feedback from the Critic when an action postcondition was unverified.
    var criticFeedback: String?

    /// Chronological stream of agent activity items for UI attribution.
    var history: [AgentActivityItem]

    /// Tool results independently verified during execution.
    var verifiedResults: [ToolResult]

    /// Whether all planned steps have been successfully completed or verified.
    var isComplete: Bool {
        if planSteps.isEmpty { return true }
        return completedSteps.count >= planSteps.count
    }

    init(
        userGoal: String = "",
        currentRole: AgentRole = .planner
    ) {
        self.userGoal = userGoal
        self.planSteps = []
        self.completedSteps = []
        self.structuredPlan = []
        self.currentRole = currentRole
        self.observations = []
        self.criticFeedback = nil
        self.history = []
        self.verifiedResults = []
    }

    /// Reset blackboard for a new user goal.
    func reset(with goal: String) {
        self.userGoal = goal
        self.planSteps = []
        self.completedSteps = []
        self.structuredPlan = []
        self.currentRole = .planner
        self.observations = []
        self.criticFeedback = nil
        self.history = []
        self.verifiedResults = []
    }

    /// Set structured plan steps and sync flat string descriptions.
    func setPlan(_ steps: [PlanStep]) {
        self.structuredPlan = steps
        self.planSteps = steps.map(\.title)
    }

    /// Add an observation gathered from Navigator inspection or action dispatch.
    func addObservation(_ observation: String) {
        self.observations.append(observation)
    }

    /// Mark a step as verified and completed.
    func completeStep(_ stepTitle: String) {
        if !completedSteps.contains(stepTitle) {
            completedSteps.append(stepTitle)
        }
        if let index = structuredPlan.firstIndex(where: { $0.title == stepTitle }) {
            structuredPlan[index].status = .verified
        }
    }

    /// Record an activity item in the blackboard history and return the item.
    @discardableResult
    func recordActivity(
        role: AgentRole,
        title: String,
        detail: String? = nil
    ) -> AgentActivityItem {
        let item = AgentActivityItem(role: role, title: title, detail: detail)
        self.history.append(item)
        return item
    }

    /// Transition to another agent role.
    func advanceRole(to role: AgentRole) {
        self.currentRole = role
    }
}
