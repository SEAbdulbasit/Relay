import Foundation
import Observation

/// An unsaved edit buffer is distinct from a valid source-backed draft. Ordinary
/// content drift blocks saving while retaining edits; revoked access and Stop
/// clear source-derived content immediately.
@Observable @MainActor
final class ConsolidationReviewState {
    enum Phase: Equatable { case initial, ready, stale, cleared }
    private(set) var phase: Phase = .initial
    private(set) var sourceDraft: CrossSourceKnowledge.Draft?
    private(set) var message: String?
    var title = ""
    var body = ""
    var canCopy: Bool { (phase == .ready || phase == .stale) && !body.isEmpty }
    var canSave: Bool { phase == .ready && sourceDraft != nil }

    func receive(_ draft: CrossSourceKnowledge.Draft) {
        sourceDraft = draft
        title = draft.title
        body = draft.markdownBody
        message = nil
        phase = .ready
    }

    func invalidate(_ reason: GeneratedKnowledgeVault.ConsolidationInvalidation,
                    isAuthorized: (CrossSourceKnowledge.Revision) -> Bool) {
        if reason == .dismissed, phase == .initial { return }
        if reason == .sourcesChanged, let sourceDraft,
           sourceDraft.revisions.allSatisfy(isAuthorized) {
            phase = .stale
            message = "The sources changed. Your unsaved edits are retained, but Save is blocked. Copy your edits, reindex the sources, then rebuild. Rebuilding replaces this unsaved buffer."
            return
        }
        let message: String
        switch reason {
        case .sourcesChanged: message = "Source access changed or a source became unavailable. The unsaved source brief was cleared. Recheck your sources and build again."
        case .stopped: message = "Stopped. The unsaved source brief and edits were cleared. Build again when you are ready."
        case .dismissed: message = "The unsaved source brief was closed and cleared."
        case .saved: message = "The editable historical snapshot was saved."
        }
        clear(message: message)
    }

    func revalidateAuthorization(_ isAuthorized: (CrossSourceKnowledge.Revision) -> Bool) {
        guard let sourceDraft, !sourceDraft.revisions.allSatisfy(isAuthorized) else { return }
        clear(message: "Source access changed or a source became unavailable. The unsaved source brief was cleared. Recheck your sources and build again.")
    }

    private func clear(message: String) {
        sourceDraft = nil
        title = ""
        body = ""
        phase = .cleared
        self.message = message
    }
}
