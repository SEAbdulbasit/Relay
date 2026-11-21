import SwiftUI

struct NoteTrashSheet: View {
    let vault: KnowledgeVaultManager
    let onRestore: (LocalMarkdownNote) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [LocalNoteTrashEntry] = []
    @State private var error: String?
    @State private var status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Recently deleted notes").font(RelayPageStyle.dialogTitle).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(RelaySecondaryButtonStyle()).keyboardShortcut(.cancelAction)
            }
            Text("Restore a note to its original folder. Existing files are never replaced, and notes here are not automatically erased.")
                .font(RelayPageStyle.body).foregroundStyle(RelayColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).font(.relayCallout).foregroundStyle(RelayColors.error).textSelection(.enabled) }
            if let status { Text(status).font(.relayCallout).foregroundStyle(RelayColors.textSecondary) }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if entries.isEmpty { Text("No deleted notes.").foregroundStyle(RelayColors.textSecondary).padding(.vertical, 24) }
                    ForEach(entries) { entry in
                        HStack(spacing: 12) {
                            Image(systemName: "doc.text").font(RelayPageStyle.symbol).foregroundStyle(RelayColors.textSecondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.title).font(.relayBodyStrong).lineLimit(2)
                                Text(entry.deletedAt, style: .date).font(.relayCaption).foregroundStyle(RelayColors.textSecondary)
                            }
                            Spacer()
                            Button("Restore") {
                                do {
                                    let note = try vault.restoreNote(entry)
                                    error = nil
                                    status = "Restored “\(note.title)”."
                                    onRestore(note)
                                    reload()
                                } catch { self.error = error.localizedDescription }
                            }
                            .buttonStyle(RelaySecondaryButtonStyle())
                            .accessibilityLabel("Restore \(entry.title)")
                        }
                        .padding(.vertical, 14)
                        Divider()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24).frame(minWidth: 520, idealWidth: 600, minHeight: 360, idealHeight: 460)
        .relayPageBackground().foregroundStyle(RelayColors.textPrimary)
        .tint(RelayColors.workbenchAccent).relayPreferredAppearance()
        .onAppear { reload() }
    }

    private func reload() {
        do {
            let listing = try vault.noteTrashListing()
            entries = listing.entries
            error = listing.unreadableCount == 0 ? nil : "\(listing.unreadableCount) recovery \(listing.unreadableCount == 1 ? "entry could" : "entries could") not be read. Their files have been kept; other notes can still be restored."
        }
        catch { self.error = error.localizedDescription }
    }
}
