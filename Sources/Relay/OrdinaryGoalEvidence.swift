import Foundation

/// Read-only access to the actual retained original source. The owner creates
/// this from a controller OriginalSource; no old Observation/image, input grant,
/// current-window resolver or focus operation is retained by this value.
@MainActor final class NativeOriginalGoalReadTarget {
    let sourceID: UUID
    let connectionID: UUID
    let ownerID: UUID
    let application: DesktopApplicationIdentity
    private let validateSource: @MainActor () throws -> Void
    private let captureOriginal: @MainActor () async throws -> NativeWindowTaskAdapter.Capture
    init(sourceID: UUID, connectionID: UUID, ownerID: UUID, application: DesktopApplicationIdentity,
         validate: @escaping @MainActor () throws -> Void,
         capture: @escaping @MainActor () async throws -> NativeWindowTaskAdapter.Capture) {
        self.sourceID = sourceID; self.connectionID = connectionID; self.ownerID = ownerID; self.application = application
        validateSource = validate; captureOriginal = capture
    }
    func validate() throws { try Task.checkCancellation(); try validateSource(); try Task.checkCancellation() }
    func capture() async throws -> NativeWindowTaskAdapter.Capture {
        try validate()
        do { let result = try await captureOriginal(); try validate(); return result }
        catch { try validate(); throw error }
    }
}

/// Only an actual settled native effect can supply coverage. In this first cut,
/// unknown dispatch/focus-only/refused/no-effect/report outcomes cannot certify
/// an observable goal or a physical action/count from a preexisting state.
@MainActor struct NativeGoalEffectSeed {
    let id: UUID
    let outerProposalID: UUID
    let outerCallDigest: String
    let outerProviderID: Data
    let runID: UUID
    let attemptID: UUID
    let target: NativeOriginalGoalReadTarget
    init?(settled: NativeSettledVisualStep, outer: NativeVisualProposalIdentity,
          owner: NativeComputerTaskSession, scope: NativeVisualTaskScope) throws {
        try outer.validate(scope: scope, call: outer.call)
        try settled.identity.validate(scope: scope, call: settled.identity.call)
        guard owner.scope === scope, Self.canCover(settled.fact),
              case .controller(.readback(_, let observation, _)) = settled.fact else { return nil }
        // The capability derives from the actual settled outcome's original
        // target, not a separately supplied/lookalike target or old image.
        let target = try owner.originalGoalReadTarget(from: observation)
        try target.validate(); try scope.validate()
        id = settled.identity.proposalID; outerProposalID = outer.proposalID
        outerCallDigest = ToolPolicy.fingerprint(outer.call); outerProviderID = Data(outer.call.id.utf8)
        runID = scope.run.taskID; attemptID = scope.run.attemptID; self.target = target
    }
    static func canCover(_ fact: NativeVisualStepOutcome) -> Bool {
        guard case .controller(.readback(let native, _, let focus)) = fact, !native.isError else { return false }
        switch focus {
        case .notRequested, .alreadyFocused, .restored: return true
        case .refused, .uncertain: return false
        }
    }
}

/// This is not a replacement effect ledger. It accounts for EVERY unverified
/// result in this ordinary run, without clearing counters or imposing a task
/// count cap. A later B seed cannot hide an earlier A/legacy/report uncertainty.
@MainActor final class OrdinaryGoalCoverage {
    let logicalTaskID: UUID
    private struct Key: Hashable {
        let run: UUID, attempt: UUID, proposal: UUID
        let provider: Data, digest: String
        init(call: ToolCall, proposal: UUID, run: AssistantConversationHistory.Run) {
            self.run = run.taskID; attempt = run.attemptID; self.proposal = proposal
            provider = Data(call.id.utf8); digest = ToolPolicy.fingerprint(call)
        }
    }
    private struct Entry { var seed: NativeGoalEffectSeed? }
    private var epoch = UUID()
    private var attemptedEpoch: UUID?
    private var entries: [Key: Entry] = [:]
    var unverifiedCount: Int { entries.count }
    init(logicalTaskID: UUID) { self.logicalTaskID = logicalTaskID }
    /// Original-run callbacks may record an actual uncertain fact even after
    /// Stop. Only a settled live source seed can upgrade its data coverage.
    func recordUnverified(call: ToolCall, proposalID: UUID, run: AssistantConversationHistory.Run,
                          seed: NativeGoalEffectSeed? = nil) {
        guard run.relation.logicalTaskID == logicalTaskID else { return }
        let key = Key(call: call, proposal: proposalID, run: run)
        let qualified = seed.flatMap { candidate -> NativeGoalEffectSeed? in
            guard candidate.runID == run.taskID, candidate.attemptID == run.attemptID,
                  candidate.outerProposalID == proposalID, candidate.outerProviderID == key.provider,
                  candidate.outerCallDigest == key.digest, (try? candidate.target.validate()) != nil else { return nil }
            return candidate
        }
        if let existing = entries[key] {
            guard let qualified, existing.seed?.id != qualified.id else { return }
            // A different settled effect cannot replace an already covered
            // exact accepted operation. Keep an omission rather than alias it.
            if existing.seed != nil { entries[key] = Entry(seed: nil) }
            else { entries[key] = Entry(seed: qualified) }
        } else { entries[key] = Entry(seed: qualified) }
        epoch = UUID()
    }
    func revokeCapabilities() {
        epoch = UUID()
        for key in Array(entries.keys) { entries[key] = Entry(seed: nil) }
    }
    @MainActor struct Ticket {
        let seeds: [NativeGoalEffectSeed]
        let target: NativeOriginalGoalReadTarget
        let validate: @MainActor @Sendable () throws -> Void
    }
    func begin(unverifiedCount: Int, run: AssistantConversationHistory.Run) throws -> Ticket? {
        let seeds = entries.values.compactMap(\.seed).sorted { $0.id.uuidString < $1.id.uuidString }
        guard run.relation.logicalTaskID == logicalTaskID, unverifiedCount > 0,
              entries.count == unverifiedCount, seeds.count == unverifiedCount,
              attemptedEpoch != epoch, let first = seeds.first else { return nil }
        guard Set(seeds.map(\.id)).count == seeds.count,
              Set(seeds.map(\.outerProposalID)).count == seeds.count else { return nil }
        // Multi-original verification is a separate acceptance gate. Refuse
        // here rather than allow the latest window to certify an unseen one.
        guard seeds.allSatisfy({ $0.runID == run.taskID && $0.attemptID == run.attemptID
            && $0.target.sourceID == first.target.sourceID
            && $0.target.ownerID == first.target.ownerID
            && $0.target.connectionID == first.target.connectionID
            && $0.target.application == first.target.application }) else { return nil }
        for seed in seeds { try seed.target.validate() }
        let expected = epoch, captured = seeds
        attemptedEpoch = expected
        return Ticket(seeds: captured, target: first.target, validate: { [weak self] in
            guard let self, self.epoch == expected, self.attemptedEpoch == expected,
                  self.entries.count == unverifiedCount,
                  self.entries.values.allSatisfy({ $0.seed != nil }) else { throw NativeVisualTaskFailure.staleTask }
            for seed in captured { try seed.target.validate() }
        })
    }
}
