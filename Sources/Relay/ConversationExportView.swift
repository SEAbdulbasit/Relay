import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ConversationExportView: View {
    @Bindable var store: AssistantStore
    @State private var includeActivity = false
    @State private var format = ConversationExport.Format.markdown
    @State private var status: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export conversation").font(.system(size: 20, weight: .semibold))
            Text("Export the visible messages as a local file. This includes private text and artifact paths in clear text. Source files are not copied. Hidden model context, model settings and approved memories are excluded.")
                .font(.system(size: 14)).lineSpacing(4)
            Picker("Export format", selection: $format) {
                Text("Markdown").tag(ConversationExport.Format.markdown)
                Text("JSON").tag(ConversationExport.Format.json)
            }.pickerStyle(.segmented).font(.system(size: 15))
            Toggle("Include Activity and action evidence", isOn: $includeActivity).font(.system(size: 15))
            Text("Activity can include source excerpts, filenames and tool arguments. Keep it off for a smaller messages-only export.").font(.system(size: 14)).lineSpacing(4)
            Text("Choose a private folder. A folder managed by a cloud provider may sync the exported file through macOS.").font(.system(size: 14)).lineSpacing(4)
            Button("Export conversation…") { export() }.buttonStyle(RelaySecondaryButtonStyle()).disabled(store.isRunning || store.voice.isBusy)
            if let status { Text(status).font(.system(size: 14)).textSelection(.enabled) }
        }.foregroundStyle(.white)
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
