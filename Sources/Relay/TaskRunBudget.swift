import Foundation

/// Optional monotonic task limits. Ordinary tasks run until completion or Stop;
/// individual model and tool calls retain their own deadlines. A caller may impose
/// an explicit task limit, excluding human review from active work.
@MainActor final class TaskRunBudget {
    enum Limit: Error, Equatable, LocalizedError {
        case activeWork, lifetime
        var errorDescription: String? {
            switch self {
            case .activeWork: "The task reached its configured active-work limit. Review waiting does not count. Verified work is preserved."
            case .lifetime: "The task reached its configured lifetime, including review waiting. Verified work is preserved."
            }
        }
    }
    private let now: () -> TimeInterval
    private let started: TimeInterval
    private let activeLimit: TimeInterval?
    private let lifetimeLimit: TimeInterval?
    private var pausedAt: TimeInterval?
    private var pausedDuration: TimeInterval = 0

    init(activeLimit: TimeInterval? = nil, lifetimeLimit: TimeInterval? = nil,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
        self.started = now()
        self.activeLimit = activeLimit.map { $0.isFinite ? max(0, $0) : 0 }
        self.lifetimeLimit = lifetimeLimit.map { $0.isFinite ? max(0, $0) : 0 }
    }

    var remainingLifetime: TimeInterval? {
        lifetimeLimit.map { max(0, $0 - max(0, now() - started)) }
    }

    func pauseForReview() { if pausedAt == nil { pausedAt = now() } }
    func resumeAfterReview() {
        if let pausedAt { pausedDuration += max(0, now() - pausedAt) }
        pausedAt = nil
    }
    func check() throws {
        try Task.checkCancellation()
        let instant = now()
        let lifetime = max(0, instant - started)
        if let lifetimeLimit, lifetime >= lifetimeLimit { throw Limit.lifetime }
        let reviewTime = pausedAt.map { max(0, instant - $0) } ?? 0
        if let activeLimit, lifetime - pausedDuration - reviewTime >= activeLimit { throw Limit.activeWork }
    }
}
