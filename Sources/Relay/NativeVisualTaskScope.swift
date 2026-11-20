import Foundation
import RelayJournal

/// Process-local task/source authority. History and model arguments cannot
/// reconstruct this object or acknowledge a pending UI submission.
@MainActor final class NativeVisualTaskScope {
    enum ExecutionKind: Equatable, Sendable { case inference, directExactUnsent }
    let logicalTaskID: UUID
    let runRevision: Int
    let run: AssistantConversationHistory.Run
    let originalObjective: String
    let executionKind: ExecutionKind
    let inferenceIdentity: LocalInferenceIdentity?
    let readAuthority: NativeLocalTaskReadAuthority
    private let validateAcknowledgedStoreRun: @MainActor () throws -> Void
    private var revoked = false
    private(set) var metadataContext: AssistantStore.ExactUnsentSavedInvocation.MetadataContext?

    init(logicalTaskID: UUID, runRevision: Int, run: AssistantConversationHistory.Run,
         originalObjective: String, inferenceIdentity: LocalInferenceIdentity,
         readAuthority: NativeLocalTaskReadAuthority,
         validateAcknowledgedStoreRun: @escaping @MainActor () throws -> Void) throws {
        guard run.relation.logicalTaskID == logicalTaskID, readAuthority.taskID == logicalTaskID,
              !originalObjective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NativeVisualTaskFailure.staleTask
        }
        self.logicalTaskID = logicalTaskID; self.runRevision = runRevision; self.run = run
        self.originalObjective = originalObjective; self.inferenceIdentity = inferenceIdentity
        executionKind = .inference
        self.readAuthority = readAuthority; self.validateAcknowledgedStoreRun = validateAcknowledgedStoreRun
        try validate()
    }

    /// A genuine native direct task has no model identity or inference grant.
    /// The saved invocation supplies the same exact live Store/run fences.
    init(directExactUnsent logicalTaskID: UUID, runRevision: Int, run: AssistantConversationHistory.Run,
         originalObjective: String, readAuthority: NativeLocalTaskReadAuthority,
         validateAcknowledgedStoreRun: @escaping @MainActor () throws -> Void) throws {
        guard run.relation.logicalTaskID == logicalTaskID, readAuthority.taskID == logicalTaskID,
              !originalObjective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NativeVisualTaskFailure.staleTask
        }
        self.logicalTaskID = logicalTaskID; self.runRevision = runRevision; self.run = run
        self.originalObjective = originalObjective; self.readAuthority = readAuthority
        executionKind = .directExactUnsent; inferenceIdentity = nil
        self.validateAcknowledgedStoreRun = validateAcknowledgedStoreRun
        try validate()
    }

    func validate() throws {
        try Task.checkCancellation()
        guard !revoked else { throw NativeVisualTaskFailure.stopped }
        // Store checks acknowledgment, exact logical task/revision/provider,
        // interactive session and clear/reset state here, including after await.
        try validateAcknowledgedStoreRun()
    }

    /// The Store's typed direct initializer ties its original live callback to
    /// an actual saved invocation. Arbitrary callback scopes remain opaque.
    convenience init(directExactUnsent logicalTaskID: UUID, runRevision: Int, run: AssistantConversationHistory.Run,
         originalObjective: String, readAuthority: NativeLocalTaskReadAuthority,
         metadataContext: AssistantStore.ExactUnsentSavedInvocation.MetadataContext) throws {
        try self.init(directExactUnsent: logicalTaskID, runRevision: runRevision, run: run,
            originalObjective: originalObjective, readAuthority: readAuthority,
            validateAcknowledgedStoreRun: { try metadataContext.validateStoreRun() })
        self.metadataContext = metadataContext
    }

    func validateMetadataRevocation(context: AssistantStore.ExactUnsentSavedInvocation.MetadataContext) throws {
        try Task.checkCancellation()
        guard !revoked else { throw NativeVisualTaskFailure.stopped }
        guard executionKind == .directExactUnsent, metadataContext === context else { throw NativeVisualTaskFailure.staleTask }
    }
    func admitRead(_ bundle: String) throws -> NativeWindowTaskAdapter.ApplicationAdmission {
        try validate(); return try readAuthority.admit(bundle)
    }
    func stop() { revoked = true }
}

nonisolated enum NativeVisualTaskFailure: LocalizedError, Equatable {
    case stopped, staleTask, staleProposal, duplicateAttempt, reviewDeclined, protectedEffect
    case dedicatedWorkflow(String), unavailableDependency(String), noInput(String)
    var errorDescription: String? {
        switch self {
        case .stopped: "This native task was stopped. No new input is admitted."
        case .staleTask: "The acknowledged task, session, source or provider changed. Start from fresh task state."
        case .staleProposal: "The accepted visual proposal or its original source changed; it cannot be reused."
        case .duplicateAttempt: "This exact accepted visual operation was already attempted; it will not be replayed."
        case .reviewDeclined: "The exact ordinary gesture was declined. No equivalent input will be sent."
        case .protectedEffect: "Protected or secure interaction is unavailable through ordinary visual control."
        case .dedicatedWorkflow(let name): "Use the dedicated \(name) workflow; visual control cannot bypass its checks."
        case .unavailableDependency(let name): "Native control is not available until \(name) is qualified."
        case .noInput(let reason): "No gesture was dispatched: \(reason)"
        }
    }
}
