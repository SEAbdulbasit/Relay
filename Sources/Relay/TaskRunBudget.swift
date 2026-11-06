import Foundation

/// Monotonic run accounting. Human review consumes lifetime, never active work.
/// Main-actor confinement makes pause/resume atomic with review presentation.
@MainActor final class TaskRunBudget {
    enum Limit: Error, Equatable, LocalizedError {
        case activeWork, lifetime
        var errorDescription: String? {
            switch self {
            case .activeWork: "The task reached its four-minute active-work budget. Review waiting does not count. Verified work is preserved; continue explicitly."
            case .lifetime: "This task exceeded its 30-minute lifetime, including review waiting. Nothing further will be dispatched; inspect completed work before continuing."
            }
        }
    }
    private let now: () -> TimeInterval
    private let started: TimeInterval
    private let activeLimit: TimeInterval
    private let lifetimeLimit: TimeInterval
    private var pausedAt: TimeInterval?
    private var pausedDuration: TimeInterval = 0

    init(activeLimit: TimeInterval = 240, lifetimeLimit: TimeInterval = 1800,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
        self.started = now()
        self.activeLimit = max(0, activeLimit)
        self.lifetimeLimit = max(0, lifetimeLimit)
    }

    var remainingLifetime: TimeInterval { max(0, lifetimeLimit - max(0, now() - started)) }

    func pauseForReview() { if pausedAt == nil { pausedAt = now() } }
    func resumeAfterReview() {
        if let pausedAt { pausedDuration += max(0, now() - pausedAt) }
        pausedAt = nil
    }
    func check() throws {
        try Task.checkCancellation()
        let instant = now()
        let lifetime = max(0, instant - started)
        if lifetime >= lifetimeLimit { throw Limit.lifetime }
        let reviewTime = pausedAt.map { max(0, instant - $0) } ?? 0
        if lifetime - pausedDuration - reviewTime >= activeLimit { throw Limit.activeWork }
    }
}
