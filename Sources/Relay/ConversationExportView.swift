import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ConversationExportView: View {
    @Bindable var store: AssistantStore
    @State private var includeActivity = false
    @State private var format = ConversationExport.Format.markdown
    @State private var status: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            RelaySectionHeading(
                title: "Export Conversation",
                detail: "Export the visible messages as a local file. This includes private text and artifact paths in clear text. Source files are not copied.",
                icon: "square.and.arrow.up"
            )

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("Format")
                        .font(RelayPageStyle.caption.weight(.medium))
                        .foregroundStyle(RelayColors.textSecondary)
                    Picker("Export format", selection: $format) {
                        Text("Markdown").tag(ConversationExport.Format.markdown)
                        Text("JSON").tag(ConversationExport.Format.json)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                }

                Toggle("Include Activity & action evidence", isOn: $includeActivity)
                    .toggleStyle(.switch)
                    .font(RelayPageStyle.caption.weight(.medium))
                    .foregroundStyle(RelayColors.textPrimary)

            }
            Text("Activity can include source excerpts, filenames, and tool arguments. Choose a private folder; cloud-managed folders may sync exported files through macOS.")
                .font(RelayPageStyle.caption)
                .foregroundStyle(RelayColors.textMuted)

            Button("Export conversation…") { export() }
                .buttonStyle(RelaySecondaryButtonStyle())
                .disabled(store.isRunning || store.voice.isBusy)

            if let status {
                Text(status)
                    .font(RelayPageStyle.caption)
                    .foregroundStyle(RelayColors.textSecondary)
                    .textSelection(.enabled)
            }
        }
        .foregroundStyle(RelayColors.textPrimary)
    }
    private func export() {
        do {
            // Snapshot before the modal panel; never silently include later arriving messages.
            let data = try ConversationExport.data(messages: store.messages, activity: store.activity,
                                                   includeActivity: includeActivity, format: format)
            let panel = NSSavePanel()
            panel.title = "Export clear-text conversation"
            panel.message = "Choose where to save this private conversation snapshot. Existing-file replacement requires macOS confirmation."
            panel.nameFieldStringValue = format == .json ? "Relay conversation.json" : "Relay conversation.md"
            panel.allowedContentTypes = format == .json ? [.json] : [UTType(filenameExtension: "md") ?? .plainText]
            guard panel.runModal() == .OK, let url = panel.url else { status = "Export canceled. No file was written."; return }
            try ConversationExportWriter.write(data: data, to: url)
            status = "Exported and verified \(data.count.formatted()) bytes to \(url.lastPathComponent). Relay made no network request; folder sync, if configured, is managed by macOS."
        } catch { status = "Export could not be completed: " + error.localizedDescription }
    }
}
