import Foundation

/// A current execution projection, never authority to dispatch/replay a step.
/// IDs belong to the application; model IDs and repeated titles are not identity.
nonisolated struct PlanStepProgress: Identifiable, Equatable, Sendable {
    enum State: String, Sendable {
        case planned, running, waitingForReview, reconciling
        case observationChecked, stepChecked, needsAttention, stopped, earlierRun
    }

    let id: UUID
    let title: String
    let role: AgentRole
    var state: State
    var attempt: Int

    var isInFlight: Bool {
        state == .running || state == .waitingForReview || state == .reconciling
    }

    var status: String {
        switch state {
        case .planned: "Planned"
        case .running: "In progress"
        case .waitingForReview: "Waiting for your review"
        case .reconciling: "Checking earlier effects"
        case .observationChecked: "Observation checked"
        case .stepChecked: "Step checked"
        case .needsAttention: "Step not verified"
        case .stopped: "Interrupted · inspect activity"
        case .earlierRun: "Earlier run · not rechecked"
        }
    }
}
