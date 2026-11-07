import AppKit
import SwiftUI

/// Opens readers without taking focus. A reader can subsequently become key
/// when the user clicks it to select text or use its ordinary window controls.
@MainActor
final class DocumentSummaryPanelController: NSObject, NSWindowDelegate {
    static let shared = DocumentSummaryPanelController()
    private struct Entry {
        let panel: NSPanel
        weak var coordinator: DocumentSummaryCoordinator?
    }
    private var entries: [UUID: Entry] = [:]

    func present(session: DocumentSummarySession, coordinator: DocumentSummaryCoordinator, screen: NSScreen? = nil) {
        if let entry = entries[session.id] { entry.panel.orderFrontRegardless(); return }
        guard session.phase != .closed else { return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Document summary"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .floating
        panel.minSize = NSSize(width: 440, height: 340)
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: DocumentSummaryView(session: session,
            cancel: { [weak coordinator] in coordinator?.cancel(id: session.id) },
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
    let cancel: () -> Void
    let close: () -> Void
    @State private var copyStatus: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                RelayMark(size: 25)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Document summary").font(.system(size: 20, weight: .semibold))
                    Text(session.source?.title ?? (session.phase == .capturing ? "Capturing your chosen source…" : "On this Mac"))
                        .font(.relayCaption).foregroundStyle(RelayColors.textSecondary).lineLimit(2)
                }
                Spacer()
                if [.capturing, .queued, .generating].contains(session.phase) {
                    Button("Stop", action: cancel).buttonStyle(RelaySecondaryButtonStyle())
                }
            }
            Divider().overlay(RelayTheme.line)
            if [.capturing, .queued, .generating].contains(session.phase) {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(session.phase == .capturing ? "Reading the chosen source…" : session.phase == .queued
                        ? "Waiting for the local model…" : "Summarizing on this Mac…").font(.relayBody)
                }
            }
            if let source = session.source {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Captured \(source.capturedAt.formatted(date: .abbreviated, time: .shortened)) · On this Mac")
                        .font(.relayCaption).foregroundStyle(RelayColors.textSecondary)
                    if let location = source.location {
                        Text(location).font(.relayCaption).foregroundStyle(RelayColors.textSecondary).textSelection(.enabled).lineLimit(2)
                    }
                    Text(source.coverage).font(.relayCaption).foregroundStyle(RelayColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !session.resultText.isEmpty {
                        Text(session.resultText).font(.system(size: 14)).textSelection(.enabled)
                            .accessibilityIdentifier("documentSummary.result")
                    }
                    if let error = session.errorMessage { Text(error).font(.relayBody).foregroundStyle(RelayColors.accentAmber) }
                    if session.phase == .stopped { Text("Summary stopped. Its source and result were cleared.").font(.relayBody) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.visible)
            HStack(spacing: 10) {
                Text(copyStatus ?? "Closing this window clears its text.").font(.relayCaption).foregroundStyle(RelayColors.textSecondary)
                Spacer(minLength: 8)
                Button("Close", action: close).buttonStyle(RelaySecondaryButtonStyle())
                if !session.resultText.isEmpty {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        copyStatus = NSPasteboard.general.setString(session.resultText, forType: .string) ? "Copied." : "The clipboard could not be updated."
                    }.buttonStyle(RelayPrimaryButtonStyle())
                }
            }
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RelayTheme.background).foregroundStyle(RelayTheme.ink).preferredColorScheme(.dark)
        .onExitCommand(perform: close)
    }
}
