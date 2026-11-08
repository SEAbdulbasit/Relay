import CryptoKit
import Foundation

/// App-owned same-process scheduling state. It retains no observations, tool
/// calls/results, accepted proposals, action closures, or old source validators.
/// A completed cursor is not proof that the user's goal is currently satisfied.
@MainActor final class MultiAgentStepCheckpoint {
    enum Failure: LocalizedError, Equatable {
        case wrongTask, changedGoal, changedContext, staleRun, historicalPlannerContext, planBudget, invalidPlan, declined
        var errorDescription: String? {
            switch self {
            case .wrongTask, .staleRun: "This plan belongs to another task or an earlier run. No previous action was repeated."
            case .changedGoal: "The task instruction changed. Start a fresh task after reconciling earlier effects; the old plan will not be replayed."
            case .changedContext: "The model, grants, or original source scope changed. Start a fresh task; the prior plan cannot be continued safely."
            case .historicalPlannerContext: "The earlier plan depended on historical or omitted receipts. Its source binding cannot be restored safely; start a fresh task without replaying earlier effects."
            case .planBudget: "The entire original plan does not fit the bounded continuation cache. No partial plan or previous action will be replayed."
            case .invalidPlan: "The original plan cannot be restored safely. Inspect earlier effects before starting a fresh task."
            case .declined: "This step was explicitly declined. Continue cannot reoffer or dispatch its earlier action."
            }
        }
    }
    struct Entry {
        /// App-owned identity: neither model IDs nor duplicate titles identify a step.
        let token: UUID
        let step: PlanStep
    }
    struct Lease {
        fileprivate let owner: UUID
        fileprivate let run: UUID
        let entries: [Entry]?
        let startIndex: Int
        let requiresReconciliation: Bool
        let isResume: Bool
        let declined: Bool
    }
    private struct ContextKey: Equatable {
        let logicalTaskID: UUID
        let scopeID: UUID
        let sourceRevision: Int
        let configurationDigest: Data
        let configurationBytes: Int
        init(_ context: MultiAgentContinuation.Context) throws {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let configuration = try encoder.encode(context.configuration)
            logicalTaskID = context.logicalTaskID; scopeID = context.scopeID; sourceRevision = context.sourceRevision
            configurationBytes = configuration.count
            configurationDigest = Data(SHA256.hash(data: configuration))
        }
    }
    private struct Binding {
        let context: ContextKey
        let goalDigest: Data
        let goalBytes: Int
        init(context: MultiAgentContinuation.Context, goal: String) throws {
            self.context = try ContextKey(context)
            goalBytes = goal.utf8.count; goalDigest = Data(SHA256.hash(data: Data(goal.utf8)))
        }
        func validate(context other: MultiAgentContinuation.Context, goal otherGoal: String) throws {
            guard context.logicalTaskID == other.logicalTaskID else { throw Failure.wrongTask }
            let current = try ContextKey(other)
            guard context == current else { throw Failure.changedContext }
            guard goalBytes == otherGoal.utf8.count, goalDigest == Data(SHA256.hash(data: Data(otherGoal.utf8))) else { throw Failure.changedGoal }
        }
        var exceedsCacheBudget: Bool {
            goalBytes > MultiAgentStepCheckpoint.maximumRetainedPlanBytes - 512
                || context.configurationBytes > MultiAgentStepCheckpoint.maximumRetainedPlanBytes - 512 - min(goalBytes, MultiAgentStepCheckpoint.maximumRetainedPlanBytes - 512)
        }
    }
    private enum Stage: Equatable { case ready, readOnlyStarted, executorStarted, possiblyDispatched, reconciling, declinedBeforeDispatch, declinedAfterPossibleDispatch }
    private struct Record {
        let binding: Binding
        let entries: [Entry]
        var cursor = 0
        var stage = Stage.ready
    }
    private enum State {
        case unstarted
        case planning(Binding)
        case cached(Record)
        case unavailable(Binding, Failure)
    }
    static let maximumRetainedPlanBytes = 32 * 1_024
    private let owner = UUID()
    private let logicalTaskID: UUID
    private var state = State.unstarted
    private var activeRun: UUID?
    private var invalidation: Failure?

    init(logicalTaskID: UUID) { self.logicalTaskID = logicalTaskID }

    func invalidateForSteering() { invalidation = .changedGoal; activeRun = nil }

    func begin(goal: String, context: MultiAgentContinuation.Context) throws -> Lease {
        if let invalidation { throw invalidation }
        guard context.logicalTaskID == logicalTaskID else { throw Failure.wrongTask }
        let run = UUID()
        let result: Lease
        switch state {
        case .unstarted:
            let binding = try Binding(context: context, goal: goal)
            // A cache limit cannot become a new initial model/task limit. Keep
            // only bounded digests when the original goal/config is too large.
            state = binding.exceedsCacheBudget ? .unavailable(binding, .planBudget) : .planning(binding)
            result = Lease(owner: owner, run: run, entries: nil, startIndex: 0, requiresReconciliation: false, isResume: false, declined: false)
        case .planning(let binding):
            try binding.validate(context: context, goal: goal)
            // No accepted plan/action existed yet; a newly scoped Planner is safe.
            result = Lease(owner: owner, run: run, entries: nil, startIndex: 0, requiresReconciliation: false, isResume: true, declined: false)
        case .cached(let record):
            try record.binding.validate(context: context, goal: goal)
            guard !record.entries.isEmpty, record.cursor <= record.entries.count else { throw Failure.invalidPlan }
            let finished = record.cursor == record.entries.count
            let interruptedExecutor = record.stage == .possiblyDispatched || record.stage == .reconciling || record.stage == .declinedAfterPossibleDispatch
            let declined = record.stage == .declinedBeforeDispatch || record.stage == .declinedAfterPossibleDispatch
            result = Lease(owner: owner, run: run, entries: record.entries,
                startIndex: finished ? record.entries.count - 1 : record.cursor,
                requiresReconciliation: finished || interruptedExecutor, isResume: true, declined: declined)
        case .unavailable(let binding, let failure):
            try binding.validate(context: context, goal: goal)
            throw failure
        }
        activeRun = run
        return result
    }

    /// Whole plan only, admitted solely from a user-goal-only initial Planner
    /// context. Byte admission is a cache limit, never a turn/action-count cap.
    func install(_ steps: [PlanStep], lease: Lease, goalOnlyPlanner: Bool) throws {
        try validate(lease)
        if case .unavailable(_, .planBudget) = state { return } // Initial execution remains available.
        guard case .planning(let binding) = state else { throw Failure.staleRun }
        guard goalOnlyPlanner else { state = .unavailable(binding, .historicalPlannerContext); return }
        guard !steps.isEmpty, steps.allSatisfy({ !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            state = .unavailable(binding, .invalidPlan); return
        }
        let original = steps.map { PlanStep(id: $0.id, role: $0.role, title: $0.title) }
        let encoded = try JSONEncoder().encode(original)
        let (entryCost, multiplyOverflow) = original.count.multipliedReportingOverflow(by: 64)
        let (payloadCost, addOverflow) = encoded.count.addingReportingOverflow(entryCost)
        let (goalCost, goalOverflow) = payloadCost.addingReportingOverflow(binding.goalBytes)
        let (total, totalOverflow) = goalCost.addingReportingOverflow(binding.context.configurationBytes)
        guard !multiplyOverflow, !addOverflow, !goalOverflow, !totalOverflow,
              total <= Self.maximumRetainedPlanBytes - 512 else { state = .unavailable(binding, .planBudget); return }
        state = .cached(Record(binding: binding, entries: original.map { Entry(token: UUID(), step: $0) }))
    }

    func enterStep(at index: Int, lease: Lease) throws {
        try change(index: index, lease: lease) { record in
            guard record.stage != .declinedBeforeDispatch, record.stage != .declinedAfterPossibleDispatch else { throw Failure.declined }
            record.stage = record.entries[index].step.role == .executor ? .executorStarted : .readOnlyStarted
        }
    }
    /// Set before the actual dispatch wrapper, including its durable-intent wait.
    /// Any failure leaves this step reconciliation-only, even if no effect occurred.
    func willDispatchExecutor(at index: Int, lease: Lease) throws {
        try change(index: index, lease: lease) { record in
            guard record.entries[index].step.role == .executor else { throw Failure.invalidPlan }
            guard record.stage != .declinedBeforeDispatch, record.stage != .declinedAfterPossibleDispatch else { throw Failure.declined }
            record.stage = .possiblyDispatched
        }
    }
    func decline(at index: Int, lease: Lease) throws {
        try change(index: index, lease: lease) { record in
            let possible = record.stage == .possiblyDispatched || record.stage == .reconciling || record.stage == .declinedAfterPossibleDispatch
            record.stage = possible ? .declinedAfterPossibleDispatch : .declinedBeforeDispatch
        }
    }
    func beginReconciliation(at index: Int, lease: Lease) throws {
        try change(index: index, lease: lease) { record in
            if record.stage != .declinedBeforeDispatch, record.stage != .declinedAfterPossibleDispatch { record.stage = .reconciling }
        }
    }
    func complete(at index: Int, lease: Lease) throws {
        try change(index: index, lease: lease) { record in
            guard record.stage != .declinedBeforeDispatch, record.stage != .declinedAfterPossibleDispatch else { throw Failure.declined }
            // Rechecking the last already-settled step never rewinds the cursor.
            if index == record.cursor { record.cursor += 1 }
            record.stage = .ready
        }
    }
    func validate(_ lease: Lease) throws {
        if let invalidation { throw invalidation }
        guard lease.owner == owner, lease.run == activeRun else { throw Failure.staleRun }
    }
    private func change(index: Int, lease: Lease, _ body: (inout Record) throws -> Void) throws {
        try validate(lease)
        if case .unavailable = state { return } // The initial run may finish; reuse remains forbidden.
        guard case .cached(var record) = state, record.entries.indices.contains(index),
              index == record.cursor || (record.cursor == record.entries.count && index == record.entries.count - 1 && lease.requiresReconciliation) else {
            throw Failure.invalidPlan
        }
        try body(&record)
        state = .cached(record)
    }
}
