import Foundation

/// Compact phase glue for the Store's owned local task. Provider selection and
/// the capture/result tool pair remain in Store. This never dispatches input.
@MainActor enum NativeWindowReadOnlyTaskPhase {
    typealias Complete = @MainActor (NativeWindowTaskAdapter.PlanningTurn) async throws -> ModelReply

    static func run(adapter: NativeWindowTaskAdapter, objective: String,
                    completeHistory: [ModelMessage], readQuestion: String? = nil, complete: Complete) async throws -> ModelReply {
        try await runWithSource(adapter: adapter, objective: objective, completeHistory: completeHistory,
            readQuestion: readQuestion, complete: complete).reply
    }

    struct Interpretation {
        let reply: ModelReply
        let source: NativeCurrentReadbackSource?
    }
    static func runWithSource(adapter: NativeWindowTaskAdapter, objective: String,
                             completeHistory: [ModelMessage], readQuestion: String? = nil,
                             inputProof: ModelInputSourceProof? = nil,
                             complete: Complete) async throws -> Interpretation {
        defer { adapter.releaseObservation() }
        try await inputProof?.validate()
        let turn = try adapter.prepareTurn(objective: objective, completeHistory: completeHistory, readQuestion: readQuestion,
            inputSourceProof: inputProof)
        let reply: ModelReply
        do { reply = try await complete(turn) }
        catch { try await inputProof?.validate(); throw error }
        try await inputProof?.validate()
        try Task.checkCancellation()
        let accepted = try adapter.accept(reply, for: turn)
        let source = try adapter.retainCurrentReadbackSource()
        try source?.validate()
        return Interpretation(reply: accepted, source: source)
    }
}
