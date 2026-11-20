import SwiftUI
import AppKit

struct RelayMenuBarView: View {
    let store: AssistantStore
    var sidekickAvailable = true
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Open Relay") {
            openWindow(id: "main")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        if sidekickAvailable {
            Button("Open Sidekick") {
                Task { @MainActor in
                    await Task.yield()
                    NotchOverlayController.shared.open()
                }
            }
            Toggle("Open Sidekick on every display", isOn: Binding(
                get: { NotchOverlayController.shared.pinnedToNotch },
                set: { NotchOverlayController.shared.setPinned($0) }
            ))
        }
        Text(statusTitle)
        if store.focusedDraft.enabled { Text(store.focusedDraft.status) }
        Button("Stop current task or audio") { store.stop() }.disabled(!store.isRunning && !store.voice.isBusy && !store.speech.isActive && !store.knowledgeSearch.isBusy && !store.speechDiagnostic.isBusy)
        Divider()
        Button("Quit Relay") {
            store.stopForTermination()
            NSApplication.shared.terminate(nil)
        }
    }

    static func statusTitle(for store: AssistantStore) -> String {
        if store.isPreparingModel { return "Preparing local model" }
        if store.checkingClaude { return "Checking Claude CLI" }
        if store.checkingCodex { return "Checking Codex CLI" }
        if store.voice.isBusy {
            if store.voice.isRecording { return "Microphone on · local dictation" }
            if store.voice.phase == .finishing { return "Microphone off · finishing transcript" }
            return "Voice permission request"
        }
        if store.speechDiagnostic.isBusy { return "Checking local speech support" }
        if store.knowledgeSearch.isBusy { return "Local search in progress" }
        if store.speech.isActive { return "Reading a response aloud" }
        if store.isRunning { return "Task in progress" }
        if store.workspaceUsesCodexCLI { return "Workspace uses ChatGPT (Codex CLI)" }
        if store.workspaceUsesCodex { return "Workspace uses ChatGPT" }
        if store.workspaceUsesClaude { return "Workspace uses Claude (\(store.claudeConfiguration.displayModelName))" }
        if store.actionsReady {
            return store.configuration.usesCloudInference
                ? "Workspace uses \(store.configuration.localProviderName)"
                : "Local model ready"
        }
        return "Model not loaded"
    }

    private var statusTitle: String { Self.statusTitle(for: store) }
}
