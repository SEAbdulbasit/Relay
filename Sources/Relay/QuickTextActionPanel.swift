import AppKit
import SwiftUI

/// A separate, memory-only result window. Clicking its buttons leaves the source app active.
@MainActor
final class QuickTextActionPanelController: NSObject, NSWindowDelegate {
    static let shared = QuickTextActionPanelController()
    private var panel: NSPanel?
    private weak var session: QuickTextActionSession?

    func present(store: AssistantStore, kind: QuickTextActionSession.Kind, selection: BoundTextSelection) throws {
        guard !store.isRunning, !store.voice.isBusy, store.actionsReady else {
            throw RelayError.message("Load a local model and finish the current task before using text actions.")
        }
        close()
        let session = store.quickText
        try session.start(kind: kind, selection: selection)
        self.session = session
        let panel = PassiveTextResultPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = kind == .summarize ? "Selection summary" : "Proofread selection"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .floating
        panel.minSize = NSSize(width: 580, height: 400)
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: QuickTextActionView(session: session, kind: kind,
            stop: { [weak store] in store?.stop() }, close: { [weak self] in self?.close() }))
        panel.center()
        self.panel = panel
        panel.orderFrontRegardless()
    }

    func close() {
        session?.close()
        session = nil
        panel?.delegate = nil
        panel?.close()
        panel = nil
    }

    func windowWillClose(_ notification: Notification) {
        session?.close()
        session = nil
        panel = nil
    }
}

private final class PassiveTextResultPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct QuickTextActionView: View {
    let session: QuickTextActionSession
    let kind: QuickTextActionSession.Kind
    let stop: () -> Void
    let close: () -> Void
    @State private var actionStatus: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 12) {
                RelayMark(size: 25)
                VStack(alignment: .leading, spacing: 4) {
                    Text(kind == .summarize ? "Selection summary" : "Proofread selection")
                        .font(.system(size: 20, weight: .semibold))
                    Text(session.sourceAppName.isEmpty ? "On this Mac" : "\(session.sourceAppName) · On this Mac")
                        .font(.relayCaption).foregroundStyle(RelayColors.textSecondary)
                }
                Spacer()
                if session.isBusy {
                    Button("Stop", action: stop).buttonStyle(RelaySecondaryButtonStyle())
                }
            }
            Divider().overlay(RelayTheme.line)
            if session.isBusy {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(kind == .summarize ? "Summarizing your selection…" : "Checking your selection…")
                        .font(.relayBody)
                }
            }
            if let error = session.errorMessage, session.replacementOutcome == nil {
                Text(error).font(.relayBody).foregroundStyle(RelayColors.accentAmber)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !session.resultText.isEmpty {
                if kind == .proofread {
                    HStack(alignment: .top, spacing: 20) {
                        textColumn("Original", text: session.sourceText)
                        Rectangle().fill(RelayTheme.line).frame(width: 1)
                        textColumn("Corrected", text: session.resultText)
                    }
                } else {
                    textColumn("Summary", text: session.resultText)
                }
            } else {
                Spacer(minLength: 0)
            }
            if kind == .proofread, session.phase == .ready, !session.resultText.isEmpty,
               session.replacementOutcome == nil {
                if session.resultText.utf16.elementsEqual(session.sourceText.utf16) {
                    Text("No corrections needed.").font(.relayCaption).foregroundStyle(RelayColors.textSecondary)
                } else if !session.canReplace {
                    Text("This selection supports copying the correction. Replace it in the original app when you are ready.")
                        .font(.relayCaption).foregroundStyle(RelayColors.textSecondary)
                }
            }
            if let actionStatus {
                Text(actionStatus).font(.relayCaption).foregroundStyle(RelayColors.textSecondary)
                    .accessibilityIdentifier("quickText.status")
            }
            HStack(spacing: 10) {
                Text("This window is temporary. Closing it clears its text.")
                    .font(.relayCaption).foregroundStyle(RelayColors.textSecondary)
                Spacer(minLength: 8)
                Button("Close", action: close).buttonStyle(RelaySecondaryButtonStyle())
                if !session.resultText.isEmpty {
                    Button("Copy") {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        actionStatus = pasteboard.setString(session.resultText, forType: .string)
                            ? "Copied." : "The clipboard could not be updated."
                    }
                    .buttonStyle(RelaySecondaryButtonStyle())
                    .accessibilityIdentifier("quickText.copy")
                    if kind == .proofread {
                        Button("Replace selection") { replaceSelection() }
                            .buttonStyle(RelayPrimaryButtonStyle())
                            .disabled(!session.canReplace || session.isBusy)
                            .accessibilityIdentifier("quickText.replace")
                    }
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RelayTheme.background)
        .foregroundStyle(RelayTheme.ink)
        .preferredColorScheme(.dark)
    }

    private func textColumn(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(RelayColors.textSecondary)
            ScrollView {
                Text(text).font(.system(size: 14)).frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier(title == "Original" ? "quickText.original" : "quickText.result")
            }
            .scrollIndicators(.visible)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func replaceSelection() {
        do {
            switch try session.replaceReviewedSelection() {
            case .replaced: actionStatus = "Selection replaced and read back."
            case .unchanged: actionStatus = "The selected text already matches."
            case .copyOnly(let reason), .uncertain(let reason): actionStatus = reason
            }
        } catch { actionStatus = error.localizedDescription }
    }
}
