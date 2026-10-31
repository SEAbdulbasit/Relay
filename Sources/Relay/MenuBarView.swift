import SwiftUI
import AppKit

struct RelayMenuBarView: View {
    let store: AssistantStore
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Open Relay") {
            openWindow(id: "main")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        Text(store.isPreparingModel ? "Preparing local model" : store.voice.isBusy ? (store.voice.isRecording ? "Microphone on · local dictation" : "Voice permission request") : store.speechDiagnostic.isBusy ? "Checking local speech support" : store.knowledgeSearch.isBusy ? "Local search in progress" : store.speech.isActive ? "Reading a response aloud" : store.isRunning ? "Task in progress" : (store.actionsReady ? "Local model ready" : "Model not loaded"))
        Button("Stop current task or audio") { store.stop() }.disabled(!store.isRunning && !store.voice.isBusy && !store.speech.isActive && !store.knowledgeSearch.isBusy && !store.speechDiagnostic.isBusy)
        Divider()
        Button("Quit Relay") { store.stop(); NSApplication.shared.terminate(nil) }
    }
}
