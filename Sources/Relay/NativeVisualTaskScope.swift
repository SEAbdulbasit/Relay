import Foundation
import RelayJournal

/// Process-local task/source authority. History and model arguments cannot
/// reconstruct this object or acknowledge a pending UI submission.
@MainActor final class NativeVisualTaskScope {
    let logicalTaskID: UUID
    let runRevision: Int
    let run: AssistantConversationHistory.Run
    let originalObjective: String
    let inferenceIdentity: LocalInferenceIdentity
    let readAuthority: NativeLocalTaskReadAuthority
    private let validateAcknowledgedStoreRun: @MainActor () throws -> Void
    private var revoked = false

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
        self.readAuthority = readAuthority; self.validateAcknowledgedStoreRun = validateAcknowledgedStoreRun
        try validate()
    }

    func validate() throws {
        try Task.checkCancellation()
        guard !revoked else { throw NativeVisualTaskFailure.stopped }
        // Store checks acknowledgment, exact logical task/revision/provider,
        // interactive session and clear/reset state here, including after await.
        try validateAcknowledgedStoreRun()
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
