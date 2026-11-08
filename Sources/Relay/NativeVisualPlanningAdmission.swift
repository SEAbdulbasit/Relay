import Foundation

/// Existing task limits and trusted progress admission apply to every inner
/// read/plan round. There is no permissive production default or new turn cap.
@MainActor struct NativeVisualPlanningAdmission {
    struct Round {
        let ordinal: UInt64
        let previousSourceID: UUID?
        let previousObservationID: UUID?
    }
    private let budget: TaskRunBudget
    private let admitProgress: @MainActor (Round) throws -> Void
    init(budget: TaskRunBudget, admitProgress: @escaping @MainActor (Round) throws -> Void) {
        self.budget = budget; self.admitProgress = admitProgress
    }
    func validate() throws { try budget.check() }
    func admit(_ round: Round) throws {
        try validate(); try admitProgress(round); try validate()
    }
}
