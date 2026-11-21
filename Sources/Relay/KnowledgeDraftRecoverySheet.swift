import SwiftUI

/// Recovery is explicit. An original changed elsewhere is never replaced here.
struct KnowledgeDraftRecoverySheet: View {
    let record: KnowledgeDraftStore.Record
    let drafts: KnowledgeDraftStore
    let vault: KnowledgeVaultManager
    let onRestore: (KnowledgeDraftStore.Record) -> Bool
    let onSavedCopy: (LocalMarkdownNote, String?) -> Void
    let onDiscard: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var bodyText: String
    @State private var sourceState: KnowledgeDraftStore.SourceState = .missing
    @State private var status: String?
    @State private var writesSuppressed = false

    init(record: KnowledgeDraftStore.Record, drafts: KnowledgeDraftStore, vault: KnowledgeVaultManager,
         onRestore: @escaping (KnowledgeDraftStore.Record) -> Bool,
         onSavedCopy: @escaping (LocalMarkdownNote, String?) -> Void, onDiscard: @escaping () -> Void) {
        self.record = record; self.drafts = drafts; self.vault = vault
        self.onRestore = onRestore; self.onSavedCopy = onSavedCopy; self.onDiscard = onDiscard
        _title = State(initialValue: record.title)
        _bodyText = State(initialValue: record.body)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Recover your draft").font(RelayPageStyle.dialogTitle).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Later") { dismiss() }.buttonStyle(RelaySecondaryButtonStyle()).keyboardShortcut(.cancelAction)
            }
            Text(sourceExplanation).font(.relayBody).foregroundStyle(RelayColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Draft title", text: Binding(get: { title }, set: { title = $0; checkpoint() }))
                .textFieldStyle(.plain).relayTextField()
                .accessibilityIdentifier("knowledge.recovery.title")
            TextEditor(text: Binding(get: { bodyText }, set: { bodyText = $0; checkpoint() }))
                .font(.relayMono).scrollContentBackground(.hidden)
                .padding(12).background(RelayColors.cardBG, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityIdentifier("knowledge.recovery.body")
            if let status {
                Text(status).font(.relayCaption).foregroundStyle(RelayColors.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("knowledge.recovery.status")
            }
            HStack(spacing: 10) {
                Button("Discard draft", role: .destructive) {
                    do { try drafts.discard(record); onDiscard(); dismiss() }
                    catch { status = "The draft could not be discarded: " + error.localizedDescription }
                }
                .buttonStyle(RelayGhostButtonStyle())
                Spacer()
                Button("Save as new note") { saveCopy() }.buttonStyle(RelaySecondaryButtonStyle())
                    .accessibilityIdentifier("knowledge.recovery.saveCopy")
                if sourceState == .unchanged {
                    Button("Restore draft") { restore() }.buttonStyle(RelayPrimaryButtonStyle())
                        .accessibilityIdentifier("knowledge.recovery.restore")
                }
            }
            Text("Saved notes stay unchanged until you explicitly save. Recovery drafts remain on this Mac when you close this window.")
                .font(.relayCaption).foregroundStyle(RelayColors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(minWidth: 560, idealWidth: 650, minHeight: 440, idealHeight: 560)
        .relayPageBackground().foregroundStyle(RelayColors.textPrimary)
        .relayPreferredAppearance()
        .onAppear { refreshSourceState() }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("relay.willEraseLocalData"))) { _ in
            writesSuppressed = true
            dismiss()
        }
    }

    private var sourceExplanation: String {
        switch sourceState {
        case .unchanged: "This unsaved draft belongs to “\(record.originalTitle)”. Restore it to continue editing, or save a separate copy."
        case .changed: "The original note changed since this draft was written. Save a new note to keep both versions."
        case .missing: "The original note is missing, moved, or in Trash. Save a new note to recover this text; the original will not be recreated automatically."
        }
    }

    private func refreshSourceState() {
        do { sourceState = drafts.sourceState(for: record, notes: try vault.loadNotes()) }
        catch { sourceState = .missing; status = "The original could not be checked: " + error.localizedDescription }
    }

    private func checkpoint() {
        guard !writesSuppressed else { return }
        do { _ = try drafts.update(record, title: title, body: bodyText); status = nil }
        catch { status = "The latest edit could not be checkpointed. Keep this window open: " + error.localizedDescription }
    }

    private func restore() {
        guard !writesSuppressed else { return }
        do {
            let updated = try drafts.update(record, title: title, body: bodyText)
            refreshSourceState()
            guard sourceState == .unchanged else { return }
            guard onRestore(updated) else {
                refreshSourceState()
                status = "The note could not be reopened safely. Your draft has been kept."
                return
            }
            dismiss()
        } catch { status = error.localizedDescription }
    }

    private func saveCopy() {
        guard !writesSuppressed else { return }
        do {
            let saved = try drafts.saveRecoveredCopy(record, title: title, body: bodyText, vault: vault)
            onSavedCopy(saved, nil); dismiss()
        } catch let cleanup as KnowledgeDraftStore.RecoveredCopyCleanupError {
            onSavedCopy(cleanup.savedNote, "The recovered copy was saved. The old recovery entry could not be cleared and remains available.")
            dismiss()
        } catch { status = "Could not save the recovered copy: " + error.localizedDescription }
    }
}
