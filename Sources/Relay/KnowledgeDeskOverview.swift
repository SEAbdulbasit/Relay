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
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Library overview")
                        .font(RelayPageStyle.sectionTitle)
                        .accessibilityAddTraits(.isHeader)
                    Text("Keep useful notes and explore the sources you choose.")
                        .font(RelayPageStyle.body)
                        .foregroundStyle(RelayColors.textSecondary)
                    HStack(spacing: 14) {
                        metric(noteCount, label: noteCount == 1 ? "note" : "notes")
                        metric(sourceCount, label: sourceCount == 1 ? "source" : "sources")
                        metric(generatedCount, label: "generated")
                    }
                    .padding(.top, 2)
                }

                Rectangle().fill(RelayColors.borderSubtle).frame(height: 1)

                VStack(alignment: .leading, spacing: 14) {
                    sectionHeading("Your notes", detail: "A place for the parts worth keeping.")
                    if notes.isEmpty {
                        Text("Start with a thought, a plan, or a useful result from a conversation.")
                            .font(RelayPageStyle.body)
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
                            .font(RelayPageStyle.caption)
                            .foregroundStyle(RelayColors.textSecondary)
                    } else {
                        ForEach(collections) { item in documentRow(item) }
                    }
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .accessibilityIdentifier("knowledge.deskOverview")
    }

    private func metric(_ value: Int, label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(value.formatted()).font(RelayPageStyle.caption).monospacedDigit()
            Text(label).font(RelayPageStyle.caption).foregroundStyle(RelayColors.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func sectionHeading(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(RelayPageStyle.sectionTitle).accessibilityAddTraits(.isHeader)
            Text(detail).font(RelayPageStyle.caption).foregroundStyle(RelayColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func documentRow(_ item: Item) -> some View {
        Button { onOpen(item.id) } label: {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: item.icon)
                    .font(RelayPageStyle.symbol)
                    .foregroundStyle(RelayColors.textSecondary)
                    .frame(width: 22)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                    Text(item.detail).font(RelayPageStyle.caption).foregroundStyle(RelayColors.textMuted)
                    if !item.preview.isEmpty {
                        Text(item.preview).font(RelayPageStyle.caption).foregroundStyle(RelayColors.textSecondary)
                            .lineLimit(1).multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(RelayColors.textMuted)
                    .padding(.top, 4)
            }
            .foregroundStyle(RelayColors.textPrimary)
            .padding(.vertical, 10)
            .padding(.horizontal, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) {
                Rectangle().fill(RelayColors.borderSubtle).frame(height: 0.7)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(RelayPressStyle())
        .accessibilityElement(children: .combine)
    }
}
