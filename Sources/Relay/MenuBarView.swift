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
        Text(store.isPreparingModel ? "Preparing local model" : store.voice.isBusy ? (store.voice.isRecording ? "Microphone on · local dictation" : store.voice.phase == .finishing ? "Microphone off · finishing transcript" : "Voice permission request") : store.speechDiagnostic.isBusy ? "Checking local speech support" : store.knowledgeSearch.isBusy ? "Local search in progress" : store.speech.isActive ? "Reading a response aloud" : store.isRunning ? "Task in progress" : (store.workspaceUsesCodex ? "Workspace uses ChatGPT" : store.actionsReady ? "Local model ready" : "Model not loaded"))
        if store.focusedDraft.enabled { Text(store.focusedDraft.status) }
        Button("Stop current task or audio") { store.stop() }.disabled(!store.isRunning && !store.voice.isBusy && !store.speech.isActive && !store.knowledgeSearch.isBusy && !store.speechDiagnostic.isBusy)
        Divider()
        Button("Quit Relay") {
            store.stopForTermination()
            NSApplication.shared.terminate(nil)
        }
    }
}
