import Foundation

/// Task-owned read specialist. The Store retains the ordinary tool pair and
/// inference router; this object owns only native capture and its image phase.
@MainActor final class NativeWindowReadService {
    typealias MakeBackend = @MainActor (NativeWindowTaskAdapter.Ownership) async throws -> NativeWindowTaskAdapter.Backend
    typealias Complete = @MainActor (NativeWindowTaskAdapter.PlanningTurn) async throws -> ModelReply
    private let ownership: NativeWindowTaskAdapter.Ownership
    private let makeBackend: MakeBackend
    private let complete: Complete
    private var adapter: NativeWindowTaskAdapter?
    private var opening: Task<NativeWindowTaskAdapter.Backend, Error>?
    private var stopped = false
    private(set) var isBusy = false

    init(ownership: NativeWindowTaskAdapter.Ownership,
         makeBackend: @escaping MakeBackend = { try await .openReadOnly(ownership: $0) },
         complete: @escaping Complete) {
        self.ownership = ownership; self.makeBackend = makeBackend; self.complete = complete
    }

    func read(_ call: ToolCall, objective: String) async throws -> ToolResult {
        try await readWithSource(call, objective: objective).result
    }

    func readWithSource(_ call: ToolCall, objective: String, inputProof: ModelInputSourceProof? = nil) async throws -> NativeSourcedToolResult {
        try requireActive()
        guard !isBusy else { throw NativeWindowTaskAdapter.Failure.busy }
        try ToolPolicy.validate(call, against: [NativeWindowReadTool.definition])
        guard let bundle = call.arguments["bundle_id"]?.string, let question = call.arguments["question"]?.string,
              !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, question.utf8.count <= 1024 else {
            throw NativeWindowTaskAdapter.Failure.invalidProtocolHistory
        }
        // Refuse scope expansion before opening a connection or capturing.
        _ = try ownership.admitApplication(bundle)
        isBusy = true; defer { isBusy = false }
        try await inputProof?.validate(); try requireActive()
        let owned = try await ownedAdapter()
        try await inputProof?.validate(); try requireActive()
        do {
            let captured = try await owned.observe(bundleID: bundle)
            try requireActive()
            // This specialist has a new tool-free conversation. It does not replay
            // the main planner's pending request or copy unrelated source histories.
            // Store's complete ordinary protocol remains unchanged and receives one
            // result for this read after the phase returns.
            let returned = try await NativeWindowReadOnlyTaskPhase.runWithSource(adapter: owned, objective: objective,
                completeHistory: [], readQuestion: question, inputProof: inputProof, complete: complete)
            let interpretation = returned.reply
            try requireActive(); try returned.source?.validate()
            guard !interpretation.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  interpretation.content.utf8.count <= 3000 else {
                throw RelayError.message("The local visual read did not return a bounded answer. Ask a narrower read question; no input was performed.")
            }
            let result = ToolResult(summary: "Read-only model interpretation of the chosen native window (may be inaccurate):\n" + interpretation.content,
                evidence: captured.evidence + " The local model interpreted only that source. This verifies capture scope, not the interpretation's facts or any application effect. No input was performed.", verified: true)
            return NativeSourcedToolResult(result: result, source: returned.source)
        } catch {
            if let transport = error as? NativeReadTransportError, transport.needsFreshConnection {
                // Retire a definitely broken READ connection. Return this error
                // unchanged; only a later explicit model read opens another one.
                // No request or mutation is replayed inside this catch.
                owned.stop(); await owned.drain()
                if adapter === owned { adapter = nil }
            }
            throw error
        }
    }

    private func ownedAdapter() async throws -> NativeWindowTaskAdapter {
        try requireActive()
        if let adapter { return adapter }
        let factory = makeBackend, owner = ownership
        let pending = Task { try await factory(owner) }
        opening = pending
        defer { opening = nil }
        let backend = try await withTaskCancellationHandler { try await pending.value }
            onCancel: { pending.cancel() }
        do { try requireActive() }
        catch { backend.stop(); await backend.drain(); throw error }
        let created = NativeWindowTaskAdapter(ownership: ownership, backend: backend)
        adapter = created
        return created
    }

    func stop() {
        guard !stopped else { return }
        stopped = true; opening?.cancel(); adapter?.stop()
    }

    func drain() async { _ = try? await opening?.value; await adapter?.drain() }

    private func requireActive() throws {
        try Task.checkCancellation()
        guard !stopped else { throw NativeWindowTaskAdapter.Failure.stopped }
        guard ownership.isCurrent() else { stop(); throw NativeWindowTaskAdapter.Failure.inactiveTask }
    }
}
