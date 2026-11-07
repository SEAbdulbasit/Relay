import Foundation

/// Compact phase glue for the Store's owned local task. Provider selection and
/// the capture/result tool pair remain in Store. This never dispatches input.
@MainActor enum NativeWindowReadOnlyTaskPhase {
    typealias Complete = @MainActor (NativeWindowTaskAdapter.PlanningTurn) async throws -> ModelReply

    static func run(adapter: NativeWindowTaskAdapter, objective: String,
                    completeHistory: [ModelMessage], readQuestion: String? = nil, complete: Complete) async throws -> ModelReply {
        defer { adapter.releaseObservation() }
        let turn = try adapter.prepareTurn(objective: objective, completeHistory: completeHistory, readQuestion: readQuestion)
        let reply = try await complete(turn)
        try Task.checkCancellation()
        return try adapter.accept(reply, for: turn)
    }
}
