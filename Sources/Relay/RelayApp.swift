import SwiftUI
import AppKit

@main
struct RelayApp: App {
    @State private var store = AssistantStore()
    @State private var onboarding = OnboardingCoordinator()

    var body: some Scene {
        WindowGroup("Relay", id: "main") {
            Group {
                if onboarding.completed {
                    MainView(store: store, onOpenSetup: { store.stop(); onboarding.returnToSetup() })
                } else {
                    OnboardingView(coordinator: onboarding, store: store)
                }
            }
                .frame(minWidth: 800, minHeight: 620)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1080, height: 790)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Conversation") { store.clearConversation() }
                    .keyboardShortcut("n", modifiers: [.command])
                    .disabled(store.isRunning || store.isClearingConversation)
            }
            CommandMenu("Task") {
                Button("Stop Task") { store.stop() }
                    .keyboardShortcut(".", modifiers: [.command])
                    .disabled(!store.isRunning && store.pendingReview == nil && !store.voice.isBusy && !store.speech.isActive && !store.knowledgeSearch.isBusy && !store.speechDiagnostic.isBusy)
                Button("Attach Files…") { store.chooseFiles() }
                    .keyboardShortcut("o", modifiers: [.command])
                Button("Add Folder…") { store.chooseFolder() }
                Button("Inspect Image or Window…") { store.showImageInspection = true }
                    .disabled(!onboarding.completed || store.isRunning)
            }
        }
        Settings {
            SettingsView(store: store, onOpenSetup: { store.stop(); onboarding.returnToSetup() })
                .preferredColorScheme(.dark)
        }
        MenuBarExtra("Relay", systemImage: store.isRunning || store.voice.isBusy || store.speech.isActive || store.knowledgeSearch.isBusy || store.speechDiagnostic.isBusy ? "waveform.circle.fill" : "circle.hexagongrid.fill") {
            RelayMenuBarView(store: store)
        }

    }
}
