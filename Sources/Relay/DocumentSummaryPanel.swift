import AppKit
import SwiftUI

/// Opens readers without taking focus. A reader can subsequently become key
/// when the user clicks it to select text or use its ordinary window controls.
@MainActor
final class DocumentSummaryPanelController: NSObject, NSWindowDelegate {
    static let shared = DocumentSummaryPanelController()
    weak var store: AssistantStore?
    private struct Entry {
        let panel: NSPanel
        weak var coordinator: DocumentSummaryCoordinator?
    }
    private var entries: [UUID: Entry] = [:]

    func present(session: DocumentSummarySession, coordinator: DocumentSummaryCoordinator, store: AssistantStore? = nil, screen: NSScreen? = nil) {
        if let store { self.store = store }
        if let entry = entries[session.id] { entry.panel.orderFrontRegardless(); return }
        guard session.phase != .closed else { return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 580, height: 500),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Document summary"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .floating
        panel.minSize = NSSize(width: 440, height: 340)
        panel.appearance = RelayAppearanceMode.current.nsAppearance
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: DocumentSummaryView(session: session,
            store: self.store,
            cancel: { [weak coordinator] in coordinator?.cancel(id: session.id) },
            retry: { [weak coordinator] in _ = coordinator?.retry(id: session.id) },
            close: { [weak self] in self?.close(id: session.id) }))
        if let bounds = (screen ?? NSScreen.main)?.visibleFrame {
            let offset = CGFloat(entries.count) * 28
            let width = min(panel.frame.width, bounds.width - 32), height = min(panel.frame.height, bounds.height - 32)
            panel.setFrame(NSRect(x: min(bounds.maxX - width - 16, bounds.midX - width / 2 + offset),
                y: max(bounds.minY + 16, bounds.midY - height / 2 - offset), width: width, height: height), display: false)
        } else { panel.center() }
        entries[session.id] = Entry(panel: panel, coordinator: coordinator)
        panel.orderFrontRegardless()
    }

    /// Actual owned-panel witness only. A completed snapshot or a caller Bool
    /// is not evidence that its reader was presented.
    func isPresented(session: DocumentSummarySession, coordinator: DocumentSummaryCoordinator) -> Bool {
        guard session.phase == .ready, let entry = entries[session.id], entry.coordinator === coordinator else { return false }
        return entry.panel.isVisible
    }

    func close(id: UUID) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        entry.coordinator?.close(id: id)
        entry.panel.delegate = nil
        entry.panel.close()
    }

    func closeAll() { for id in Array(entries.keys) { close(id: id) } }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let id = entries.first(where: { $0.value.panel === window })?.key else { return }
        entries.removeValue(forKey: id)?.coordinator?.close(id: id)
    }
}

private struct DocumentSummaryView: View {
    let session: DocumentSummarySession
    let store: AssistantStore?
    let cancel: () -> Void
    let retry: () -> Void
    let close: () -> Void
    @ObservedObject private var themeManager = RelayThemeManager.shared
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var copyStatus: String?
    @State private var savedToVault = false

    private var provenanceLabel: String? {
        guard let source = session.source else { return nil }
        if source.isYouTubeTranscript { return "YouTube Transcript" }
        if source.windowImageJPEG != nil || source.visualSummaryContext != nil {
            return "\(sourceKindName(source.kind)) · Visual + Text"
        }
        return sourceKindName(source.kind)
    }

    private func sourceKindName(_ kind: DocumentSummarySource.Kind) -> String {
        switch kind {
        case .selection: "Selection"
        case .browser: "Web Page"
        case .pdf: "PDF Document"
        case .nativeDocument: "App Document"
        case .conversation: "Conversation Thread"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                RelayMark(size: 25)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("Document summary").font(.relayTitle)
                        if let badge = provenanceLabel {
                            RelayBadge(badge)
                        }
                    }
                    Text(session.source?.title ?? (session.phase == .capturing ? "Capturing your chosen source…" : "On this Mac"))
                        .font(.relayCaption).foregroundStyle(RelayColors.textSecondary).lineLimit(2)
                }
                Spacer()
                if [.capturing, .queued, .generating].contains(session.phase) {
                    Button("Stop", action: cancel)
                        .buttonStyle(RelaySecondaryButtonStyle())
                        .accessibilityIdentifier("documentSummary.stop")
                }
            }
            Divider().overlay(RelayTheme.line)
            if [.capturing, .queued, .generating].contains(session.phase) {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(session.phase == .capturing
                        ? "Reading the chosen source…"
                        : session.phase == .queued
                            ? "Waiting for the model…"
                            : (session.isStreaming ? "Streaming summary…" : "Summarizing…"))
                        .font(.relayBody)
                }
            }
            if let source = session.source {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Captured \(source.capturedAt.formatted(date: .abbreviated, time: .shortened)) · \(source.application)")
                        .font(.relayCaption).foregroundStyle(RelayColors.textSecondary)
                    if let location = source.location {
                        Text(location).font(.relayCaption).foregroundStyle(RelayColors.textSecondary).textSelection(.enabled).lineLimit(2)
                    }
                    Text(source.coverage).font(.relayCaption).foregroundStyle(RelayColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RelayColors.surface, in: RoundedRectangle(cornerRadius: RelayRadius.xs, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: RelayRadius.xs, style: .continuous)
                        .strokeBorder(RelayColors.borderSubtle, lineWidth: 1)
                )
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !session.resultText.isEmpty {
                        Text(session.resultText)
                            .font(.relayBody)
                            .lineSpacing(RelayTheme.messageLineSpacing)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("documentSummary.result")
                    }
                    if let error = session.errorMessage { Text(error).font(.relayBody).foregroundStyle(RelayColors.accentAmber) }
                    if session.phase == .stopped { Text("Summary stopped. Its source and result were cleared.").font(.relayBody) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.visible)
            Text(copyStatus ?? "Closing this window clears its text.")
                .font(.relayCaption)
                .foregroundStyle(RelayColors.textSecondary)
            HStack(spacing: 10) {
                Button("Close", action: close)
                    .buttonStyle(RelaySecondaryButtonStyle())
                    .accessibilityIdentifier("documentSummary.close")
                Spacer(minLength: 8)
                if session.canRetry && ![.capturing, .queued, .generating].contains(session.phase) {
                    Button("Retry", action: retry)
                        .buttonStyle(RelaySecondaryButtonStyle())
                        .accessibilityIdentifier("documentSummary.retry")
                }
                if !session.resultText.isEmpty {
                    Button("Ask Follow-Up") {
                        askFollowUpInRelay()
                    }
                    .buttonStyle(RelaySecondaryButtonStyle())
                    .accessibilityIdentifier("documentSummary.askFollowUp")
                    Button(savedToVault ? "Saved to Vault" : "Save to Vault") {
                        saveSummaryToVault()
                    }
                    .buttonStyle(RelaySecondaryButtonStyle())
                    .disabled(savedToVault)
                    .accessibilityIdentifier("documentSummary.saveToVault")
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        copyStatus = NSPasteboard.general.setString(session.resultText, forType: .string) ? "Copied." : "The clipboard could not be updated."
                    }
                    .buttonStyle(RelayPrimaryButtonStyle())
                    .accessibilityIdentifier("documentSummary.copy")
                }
            }
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RelayColors.canvas)
        .foregroundStyle(RelayTheme.ink)
        .preferredColorScheme(themeManager.appearanceMode.colorScheme)
        .relayPreferredAppearance()
        .onExitCommand(perform: close)
    }

    private func askFollowUpInRelay() {
        let rawTitle = session.source?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = rawTitle.isEmpty ? "Document Summary" : rawTitle
        (store ?? DocumentSummaryPanelController.shared.store)?.handoffToWorkspaceComposer(
            title: title,
            contextText: session.resultText
        )
        copyStatus = "Opened in Relay Workspace."
    }

    private func saveSummaryToVault() {
        let rawTitle = session.source?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let noteTitle = rawTitle.isEmpty ? "Document Summary" : "Summary — \(rawTitle)"
        do {
            _ = try KnowledgeVaultManager.shared.saveCapturedNote(title: noteTitle, body: session.resultText)
            savedToVault = true
            copyStatus = "Saved to Knowledge Vault."
        } catch {
            copyStatus = error.localizedDescription
        }
    }
}
