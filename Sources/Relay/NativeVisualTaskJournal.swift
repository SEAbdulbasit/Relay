import Foundation
import RelayJournal

@MainActor struct NativeVisualPreparedStep {
    let source: NativeVisualTaskSource
    let operation: NativeWindowControlPlanningPhase.Operation
    let identity: NativeVisualProposalIdentity
    let preparedAction: NativeControlSession.ReviewedProposal?
}

/// Minted only after the actual original-run effect checkpoint settled. This
/// token is ephemeral and cannot be decoded from history or a ToolResult.
@MainActor struct NativeSettledVisualStep {
    let fact: NativeVisualStepOutcome
    let identity: NativeVisualProposalIdentity
    fileprivate init(fact: NativeVisualStepOutcome, identity: NativeVisualProposalIdentity) {
        self.fact = fact; self.identity = identity
    }
}

/// Sequential checkpoints, not nested perform calls on an in-flight run.
/// This uses the journal lane's optional typed outcome seam; no action closure
/// or input authority is restored from its saved metadata/receipts.
@MainActor final class NativeVisualTaskJournal {
    private let history: AssistantConversationHistory
    private let scope: NativeVisualTaskScope
    private let unsavedFact: @MainActor (ToolResult) -> Void

    init(history: AssistantConversationHistory, scope: NativeVisualTaskScope,
         unsavedFact: @escaping @MainActor (ToolResult) -> Void) {
        self.history = history; self.scope = scope; self.unsavedFact = unsavedFact
    }

    func prepare(anchor: NativeVisualProposalIdentity, actualOriginalRead: Bool, inputProof: ModelInputSourceProof? = nil,
                 operation: @escaping @MainActor () async throws -> NativeVisualPreparedStep) async throws -> NativeVisualPreparedStep {
        try anchor.validate(scope: scope, call: anchor.call)
        // App-owned phase identity is deterministic for this accepted outer
        // proposal. Reprocessing cannot mint another preparation checkpoint.
        let phase = actualOriginalRead ? anchor.call : ToolCall(id: "app-prepare:" + anchor.controllerRequestID, name: "native_control_prepare",
            arguments: ["outer_call_digest": .string(anchor.callDigest.map { String(format: "%02x", $0) }.joined())])
        return try await history.perform(phase, proposalID: anchor.proposalID, run: scope.run, journalEffect: .readOnly,
            validate: { [scope] in try scope.validate() }, admitAction: inputProof?.validator, action: operation,
            result: { _ in ToolResult(summary: "Prepared a memory-only ordinary visual proposal.",
                evidence: "Read/planning checkpoint only. No gesture execution was requested by this stage.", verified: true) },
            unsavedResult: unsavedFact,
            journalOutcome: { _, intent in JournalToolOutcome(intent: intent, kind: .returnedVerified) },
            failureOutcome: { error, intent in
                // Preparation has no focus/input method. A decline exits the
                // run; other source/model failures still precede any input.
                return JournalToolOutcome(intent: intent,
                    kind: error as? NativeVisualTaskFailure == .reviewDeclined ? .notDispatched : .failedBeforeDispatch)
            })
    }

    /// A terminal report is a read-only data checkpoint. Every durable/unsaved
    /// callback sees only closed generic facts, even if storage fails after
    /// source revocation. Private detail is released only after settlement.
    func report(identity: NativeVisualProposalIdentity, report: NativeObservationReport,
                observationID: UUID, imageID: UUID, inputProof: ModelInputSourceProof? = nil,
                validateCurrent: @escaping @MainActor () throws -> Void) async throws -> ToolResult {
        let check: @MainActor () throws -> Void = { [scope] in
            try scope.validate(); try identity.validate(scope: scope, call: identity.call)
            try validateCurrent(); try scope.validate()
        }
        try check()
        guard identity.call.name == NativeWindowControlTools.observeName,
              identity.call.arguments["observation_id"]?.string?.utf8.elementsEqual(observationID.uuidString.utf8) == true,
              identity.call.arguments["image_id"]?.string?.utf8.elementsEqual(imageID.uuidString.utf8) == true,
              report.matches(kind: identity.call.arguments["disposition"]?.string,
                  detail: identity.call.arguments["detail"]?.string) else { throw NativeVisualTaskFailure.staleProposal }
        let retained = try await history.perform(identity.call, proposalID: identity.proposalID, run: scope.run,
            journalEffect: .readOnly, validate: check, admitAction: inputProof?.validator, action: {
                try check()
                return report
            }, result: { $0.genericFact }, unsavedResult: unsavedFact,
            journalOutcome: { value, intent in
                JournalToolOutcome(intent: intent, kind: .returnedUnverified,
                    evidence: try? JournalVisibleText(value.genericFact.summary + " No input was requested.", origin: .assistant))
            }, failureOutcome: { _, intent in
                // This closure has no focus, controller, provider or AX input
                // method. Failure cannot imply that an input was attempted.
                JournalToolOutcome(intent: intent, kind: .failedBeforeDispatch)
            })
        try await inputProof?.validate(); try check()
        return try retained.authorizedResult(validateCurrent: check)
    }

    func effect(identity: NativeVisualProposalIdentity, inputProof: ModelInputSourceProof? = nil,
                operation: @escaping @MainActor () async throws -> NativeVisualStepOutcome) async throws -> NativeVisualStepOutcome {
        try await settledEffect(identity: identity, inputProof: inputProof, operation: operation).fact
    }

    func settledEffect(identity: NativeVisualProposalIdentity, inputProof: ModelInputSourceProof? = nil,
                       operation: @escaping @MainActor () async throws -> NativeVisualStepOutcome) async throws -> NativeSettledVisualStep {
        try identity.validate(scope: scope, call: identity.call)
        let fact = try await history.perform(identity.call, proposalID: identity.proposalID, run: scope.run,
            validate: { [scope] in try scope.validate() }, admitAction: inputProof?.validator, action: operation, result: { $0.toolResult },
            unsavedResult: unsavedFact,
            journalOutcome: { output, intent in JournalToolOutcome(intent: intent, kind: output.journalKind) },
            failureOutcome: { error, intent in
                guard error is NativeVisualNoGesture else { return nil }
                return JournalToolOutcome(intent: intent, kind: .notDispatched)
            })
        // Crucially no post-action scope check runs inside the action closure:
        // original-run facts are saved even when Stop/revocation followed input.
        // The owner fences the returned value/error before replacement inference.
        return NativeSettledVisualStep(fact: fact, identity: identity)
    }
}
