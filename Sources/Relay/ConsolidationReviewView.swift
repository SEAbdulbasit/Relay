import AppKit
import SwiftUI

/// One explicit build and one reviewed, create-only save. Existing editable
/// Markdown notes are never destinations for this workflow.
struct ConsolidationReviewView: View {
    let entity: CrossSourceKnowledge.Entity
    @Bindable var vault: GeneratedKnowledgeVault
    let records: () -> [KnowledgeRecord]
    let isCurrent: (KnowledgeRecord) -> Bool
    let authorizationScopeIDs: [UUID]
    let isAuthorized: (CrossSourceKnowledge.Revision) -> Bool
    let canGenerate: () -> Bool
    let generate: () async -> Void
    let onSave: (LocalMarkdownNote) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var review = ConsolidationReviewState()
    @State private var errorMessage: String?
    @State private var copyStatus: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Linked source brief").font(.title2.weight(.semibold))
            if review.phase != .cleared { Text(entity.title).font(.headline) }
            Text("Review exact excerpts across explicitly linked documents. Relay does not infer facts or merge people with similar names.")
                .font(.callout).foregroundStyle(.secondary)
            if review.phase == .initial {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(entity.sourcePaths, id: \.self) { path in
                            let source = records().first { $0.sourcePath == path }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(source?.title ?? "Unavailable source").font(.callout.weight(.medium))
                                Text(source?.coverageNote ?? "Selected indexed extraction")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
                Text("First four eligible lines per linked source, up to 240 UTF-8 bytes each. Review coverage and citations in the resulting Markdown. Nothing is saved automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if review.phase == .ready || review.phase == .stale {
                TextField("Title", text: Binding(get: { review.title }, set: { review.title = $0 })).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("knowledge.consolidationTitle")
                TextEditor(text: Binding(get: { review.body }, set: { review.body = $0 })).font(.system(.body, design: .monospaced))
                    .frame(minHeight: 260).border(Color.secondary.opacity(0.3))
                    .accessibilityLabel("Reviewed source brief Markdown")
                    .accessibilityIdentifier("knowledge.consolidationBody")
                Text("Save creates an independent historical snapshot. Later source changes cannot overwrite your edits.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(errorMessage ?? review.message ?? vault.status).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let copyStatus { Text(copyStatus).font(.caption).foregroundStyle(.secondary) }
            HStack {
                if vault.isGenerating { ProgressView().controlSize(.small) }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                if review.canCopy {
                    Button("Copy edits") {
                        guard refreshAuthorization() else { return }
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        copyStatus = pasteboard.setString("# \(review.title)\n\n\(review.body)", forType: .string)
                            ? "Copied unsaved Markdown." : "The clipboard could not be updated."
                    }
                }
                if vault.isGenerating {
                    Button("Stop") { vault.cancel() }
                } else if review.canSave, let draft = review.sourceDraft {
                    Button("Save editable snapshot") { save(draft.id) }
                        .disabled(review.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vault.consolidationDraft?.id != draft.id)
                        .accessibilityIdentifier("knowledge.saveConsolidation")
                } else {
                    Button(review.phase == .stale ? "Rebuild and replace" : "Build source brief") {
                        guard refreshAuthorization() else { return }
                        errorMessage = nil
                        Task { await generate() }
                    }
                        .disabled(!canGenerate() || !(2...CrossSourceKnowledge.maximumSources).contains(entity.sourcePaths.count))
                        .accessibilityIdentifier("knowledge.buildConsolidation")
                }
            }
        }
        .padding(24)
        .frame(minWidth: 600, minHeight: 400)
        .onAppear { vault.dismissConsolidation() }
        .onChange(of: vault.consolidationDraft) { _, draft in
            if let draft, draft.entity.id == entity.id {
                errorMessage = nil
                copyStatus = nil
                review.receive(draft)
            }
        }
        .onChange(of: vault.consolidationInvalidation) { _, reason in
            if let reason {
                errorMessage = nil
                review.invalidate(reason, isAuthorized: isAuthorized)
            }
        }
        .onChange(of: authorizationScopeIDs) { _, _ in review.revalidateAuthorization(isAuthorized) }
        .onChange(of: review.phase) { _, phase in
            if phase == .stale || phase == .cleared { errorMessage = nil; copyStatus = nil }
        }
        .onChange(of: records()) { _, _ in review.revalidateAuthorization(isAuthorized) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            review.revalidateAuthorization(isAuthorized)
        }
        .onDisappear { vault.dismissConsolidation() }
    }

    private func save(_ id: UUID) {
        do {
            let note = try vault.saveConsolidationDraft(id: id, title: review.title, body: review.body,
                records: records(), isCurrent: isCurrent) {
                    try KnowledgeVaultManager.shared.saveNote(title: $0, body: $1)
                }
            onSave(note)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }

    private func refreshAuthorization() -> Bool {
        let hadBuffer = review.sourceDraft != nil
        review.revalidateAuthorization(isAuthorized)
        if hadBuffer, review.phase == .cleared {
            errorMessage = nil
            copyStatus = nil
            return false
        }
        return true
    }
}
