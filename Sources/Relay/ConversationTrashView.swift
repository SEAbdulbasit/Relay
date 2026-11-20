import SwiftUI

/// Restoring history does not select, dispatch, or resume an archived request.
struct ConversationTrashView: View {
    @Bindable var store: AssistantStore
    @Environment(\.dismiss) private var dismiss
    @State private var feedback: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Conversation Trash").font(.relayWorkbenchTitle).accessibilityAddTraits(.isHeader)
                    Text("Restore messages and their saved activity to History. Restoring a conversation does not run it.")
                        .font(.relayBody).foregroundStyle(RelayColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                Button("Done") { dismiss() }.buttonStyle(RelaySecondaryButtonStyle()).keyboardShortcut(.cancelAction)
            }
            Divider()
            if let feedback {
                Text(feedback).font(.relayCaption).foregroundStyle(RelayColors.textSecondary)
                    .textSelection(.enabled).accessibilityIdentifier("history.trash.feedback")
            }
            if store.threadArchive.trashedThreads.isEmpty {
                ContentUnavailableView("Trash is empty", systemImage: "trash", description: Text("Conversations moved to Trash will stay available here to restore."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(store.threadArchive.trashedThreads) { thread in
                            HStack(alignment: .top, spacing: 16) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(thread.title).font(.relayBodyStrong).lineLimit(2)
                                    Text("\(thread.messages.count) saved messages").font(.relayCaption).foregroundStyle(RelayColors.textSecondary)
                                }
                                Spacer(minLength: 8)
                                Button("Restore") {
                                    if store.restoreThread(thread.id) {
                                        feedback = "Restored “\(thread.title)”. Find it in History."
                                    } else {
                                        feedback = store.errorMessage ?? "This conversation could not be restored. It remains in Trash."
                                    }
                                }
                                .buttonStyle(RelaySecondaryButtonStyle())
                                .disabled(store.isRunning || store.isClearingConversation || store.pendingReview != nil)
                                .accessibilityLabel("Restore conversation \(thread.title)")
                            }
                            .padding(.vertical, 14)
                            Divider()
                        }
                    }
                }
            }
        }
        .padding(28)
        .frame(minWidth: 540, idealWidth: 620, minHeight: 380, idealHeight: 500)
        .background(RelayColors.canvas)
        .foregroundStyle(RelayColors.textPrimary)
        .tint(RelayColors.workbenchAccent)
        .accessibilityIdentifier("history.trash")
    }
}
