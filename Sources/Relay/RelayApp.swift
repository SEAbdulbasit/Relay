import SwiftUI
import AppKit

@main
struct RelayApp: App {
    @State private var store = AssistantStore()
    @State private var onboarding = OnboardingCoordinator()
    @Environment(\.openWindow) private var openWindow

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
                .onChange(of: onboarding.completed, initial: true) { _, completed in
                    NotchOverlayController.shared.connect(store: store, available: completed) {
                        if let workspace = NSApplication.shared.windows.first(where: { $0.title == "Relay" && $0.canBecomeMain }) {
                            workspace.makeKeyAndOrderFront(nil)
                        } else {
                            openWindow(id: "main")
                        }
                        NSApplication.shared.activate(ignoringOtherApps: true)
                    }
                }
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
                Button("Open Sidekick") {
                    Task { @MainActor in
                        await Task.yield()
                        NotchOverlayController.shared.open()
                    }
                }
                    .disabled(!onboarding.completed)
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
        MenuBarExtra {
            RelayMenuBarView(store: store, sidekickAvailable: onboarding.completed)
        } label: {
            Group {
                if store.isRunning || store.voice.isBusy || store.speech.isActive || store.knowledgeSearch.isBusy || store.speechDiagnostic.isBusy {
                    Image(systemName: "waveform.circle.fill")
                } else {
                    RelaySignalGlyph()
                        .stroke(.primary, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                        .frame(width: 17, height: 17)
                }
            }
            .accessibilityLabel("Relay")
        }

    }
}
