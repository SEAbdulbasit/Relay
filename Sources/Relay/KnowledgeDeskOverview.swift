import SwiftUI

/// A factual library landing. Rows are snapshots of existing graph nodes; opening
/// them still goes through KnowledgeView's guarded, exact-URL navigation.
struct KnowledgeDeskOverview: View {
    struct Item: Identifiable {
        let id: URL
        let title: String
        let detail: String
        let preview: String
        let icon: String
    }

    let noteCount: Int
    let sourceCount: Int
    let generatedCount: Int
    let notes: [Item]
    let generatedNotes: [Item]
    let collections: [Item]
    let onOpen: (URL) -> Void
    let onNewNote: () -> Void
    let onBrowseSources: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                VStack(alignment: .leading, spacing: 12) {
                    Label("YOUR RESEARCH DESK", systemImage: "books.vertical")
                        .font(.relayEyebrow)
                        .tracking(1.5)
                        .foregroundStyle(RelayColors.workbenchAccent)
                    Text("Your knowledge.")
                        .font(.relayWorkbenchHero)
                        .tracking(-1.1)
                        .accessibilityAddTraits(.isHeader)
                    Text("Notes you keep. Sources you choose.")
                        .font(.system(size: 16))
                        .foregroundStyle(RelayColors.textSecondary)
                    HStack(spacing: 18) {
                        metric(noteCount, label: noteCount == 1 ? "your note" : "your notes")
                        metric(sourceCount, label: sourceCount == 1 ? "source" : "sources")
                        metric(generatedCount, label: "generated")
                    }
                    .padding(.top, 8)
                }

                Rectangle().fill(RelayColors.borderSubtle).frame(height: 1)

                VStack(alignment: .leading, spacing: 14) {
                    sectionHeading("Your notes", detail: "A place for the parts worth keeping.")
                    if notes.isEmpty {
                        Text("Start with a thought, a plan, or a useful result from a conversation.")
                            .font(.relayBody)
                            .foregroundStyle(RelayColors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Write your first note", systemImage: "square.and.pencil", action: onNewNote)
                            .buttonStyle(RelayPrimaryButtonStyle())
                    } else {
                        ForEach(notes) { item in documentRow(item) }
                    }
                }

                if !generatedNotes.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        sectionHeading("From your sources", detail: "Generated highlights. Review them against the originals.")
                        ForEach(generatedNotes) { item in documentRow(item) }
                    }
                }

                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline) {
                        sectionHeading("Collections", detail: "Browse the material already in your library.")
                        Spacer(minLength: 12)
                        if sourceCount > 0 {
                            Button("Browse sources", action: onBrowseSources)
                                .buttonStyle(RelayGhostButtonStyle())
                        }
                    }
                    if collections.isEmpty {
                        Text("Folders and source collections appear here as you add material.")
                            .font(.relayCaption)
                            .foregroundStyle(RelayColors.textSecondary)
                    } else {
                        ForEach(collections) { item in documentRow(item) }
                    }
                }
            }
            .frame(maxWidth: 800, alignment: .leading)
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .accessibilityIdentifier("knowledge.deskOverview")
    }

    private func metric(_ value: Int, label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(value.formatted()).font(.system(size: 18, weight: .semibold, design: .rounded))
            Text(label).font(.relayCaption).foregroundStyle(RelayColors.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func sectionHeading(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 17, weight: .semibold)).accessibilityAddTraits(.isHeader)
            Text(detail).font(.relayCaption).foregroundStyle(RelayColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func documentRow(_ item: Item) -> some View {
        Button { onOpen(item.id) } label: {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: item.icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(RelayColors.workbenchAccent)
                    .frame(width: 22)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                    Text(item.detail).font(.relayEyebrow).foregroundStyle(RelayColors.textMuted)
                    if !item.preview.isEmpty {
                        Text(item.preview).font(.relayCaption).foregroundStyle(RelayColors.textSecondary)
                            .lineLimit(2).multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(RelayColors.textMuted)
                    .padding(.top, 4)
            }
            .foregroundStyle(RelayColors.textPrimary)
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RelayColors.workbenchTint, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(RelayPressStyle())
        .accessibilityElement(children: .combine)
    }
}
