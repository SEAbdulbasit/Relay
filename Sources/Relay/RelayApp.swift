import SwiftUI
import AppKit

@main
enum RelayEntry {
    @MainActor static func main() {
        if CommandLine.arguments.dropFirst().elementsEqual([ManagedPreparationWakeConfiguration.argument]) {
            ManagedPreparationWakeService.run()
            return
        }
        RelayApp.main()
    }
}

struct RelayApp: App {
    static let homeWindowID = "main"

    init() {
        if let iconURL = Bundle.main.url(forResource: "Relay", withExtension: "icns"),
           let iconImage = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = iconImage
        }
        RelayAppearanceMode.applyAppearance()
        NSApplication.shared.servicesProvider = RelayServicesProvider.shared
    }

    nonisolated static func isHomeWindow(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return MainActor.assumeIsolated {
            if let raw = window.identifier?.rawValue, !raw.isEmpty {
                let prefixes = ["main", "home", "workspace"]
                for prefix in prefixes {
                    if raw == prefix || raw.hasPrefix("\(prefix)-AppWindow-") {
                        return true
                    }
                }
                return false
            }
            return window.title == "Relay" && window.canBecomeMain
        }
    }

    @MainActor private static let sharedStore = AssistantStore(nativeTaskControl: NativeTaskControlDependencies.appControl)
    @MainActor private static let sharedOnboarding = OnboardingCoordinator()
    @MainActor private static let sharedOCRPreparation = DocumentOCRPreparation.startAppOwned()

    @State private var store = Self.sharedStore
    @State private var onboarding = Self.sharedOnboarding
    @ObservedObject private var themeManager = RelayThemeManager.shared
    private let hostedKnowledgeMirror = HostedKnowledgeMirror.shared
    @State private var documentOCRPreparation = Self.sharedOCRPreparation
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup("Relay", id: Self.homeWindowID) {
            Group {
                if onboarding.completed {
                    MainView(store: store, onboarding: onboarding, onOpenSetup: { store.stop(); onboarding.returnToSetup() })
                } else {
                    OnboardingView(coordinator: onboarding, store: store)
                }
            }
                .frame(minWidth: onboarding.completed ? 760 : 860, minHeight: 620)
                .preferredColorScheme(themeManager.appearanceMode.colorScheme)
                .relayPreferredAppearance()
                .onChange(of: onboarding.completed, initial: true) { _, completed in
                    NotchOverlayController.shared.connect(store: store, available: completed) {
                        if let workspace = NSApplication.shared.windows.first(where: { Self.isHomeWindow($0) }) {
                            workspace.makeKeyAndOrderFront(nil)
                        } else {
                            openWindow(id: Self.homeWindowID)
                        }
                        NSApplication.shared.activate(ignoringOtherApps: true)
                    }
                    RelayServicesProvider.shared.store = store
                }
                .onOpenURL { url in
                    Self.handleOpenURL(url, store: store)
                }
        }
        .defaultSize(width: 1180, height: 820)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Thread") {
                    if let home = NSApplication.shared.windows.first(where: { Self.isHomeWindow($0) && $0.isMainWindow })
                        ?? NSApplication.shared.windows.first(where: { Self.isHomeWindow($0) }) {
                        home.makeKeyAndOrderFront(nil)
                        NotificationCenter.default.post(name: Notification.Name("relay.newThread"), object: nil)
                    } else {
                        store.startNewThread()
                        openWindow(id: Self.homeWindowID)
                    }
                }
                    .keyboardShortcut("n", modifiers: [.command])
                    .disabled(store.isRunning || store.isClearingConversation)
            }
            CommandMenu("Task") {
                Button("Command Palette…") {
                    NotificationCenter.default.post(name: Notification.Name("relay.openCommandPalette"), object: nil)
                }
                    .keyboardShortcut("k", modifiers: [.command])
                    .disabled(!onboarding.completed)
                Button("Toggle Sidebar") {
                    NotificationCenter.default.post(name: Notification.Name("relay.toggleSidebar"), object: nil)
                }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(!onboarding.completed)
                Divider()
                Button("Workspace") {
                    NotificationCenter.default.post(name: Notification.Name("relay.switchToWorkspace"), object: nil)
                }
                    .keyboardShortcut("1", modifiers: [.command])
                    .disabled(!onboarding.completed)
                Button("Knowledge Vault") {
                    NotificationCenter.default.post(name: .relayOpenKnowledgeVault, object: nil)
                }
                    .keyboardShortcut("2", modifiers: [.command])
                    .disabled(!onboarding.completed || store.pendingReview != nil)
                Divider()
                Button("Open Sidekick") {
                    Task { @MainActor in
                        await Task.yield()
                        NotchOverlayController.shared.open()
                    }
                }
                    .disabled(!onboarding.completed)
                Button("Morning Brief…") {
                    NotificationCenter.default.post(name: .relayOpenMorningBrief, object: nil)
                }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                    .disabled(!onboarding.completed || store.isRunning || store.pendingReview != nil)
                Button("Summarize Document") {
                    do { try store.startCurrentDocumentSummary() }
                    catch { store.chooseSummaryPDF() }
                }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .disabled(!onboarding.completed || !store.canStartDocumentSummary)
                Button("Stop Task") { store.stop() }
                    .keyboardShortcut(".", modifiers: [.command])
                    .disabled(!store.isRunning && store.pendingReview == nil && !store.voice.isBusy && !store.speech.isActive && !store.knowledgeSearch.isBusy && !store.speechDiagnostic.isBusy)
                Button("Attach Files…") { store.chooseFiles() }
                    .keyboardShortcut("o", modifiers: [.command])
                Button("Add Folder…") { store.chooseFolder() }
                Button("Inspect Image or Window…") { store.showImageInspection = true }
                    .disabled(!onboarding.completed || store.isRunning)
                Menu("Summarize") {
                    Button("Current App or Document") {
                        do { try store.startCurrentDocumentSummary() }
                        catch { store.errorMessage = error.localizedDescription }
                    }
                    Divider()
                    ForEach(BrowserAutomation.Browser.allCases, id: \.self) { browser in
                        Button("\(browser.name) page") { store.summarizeBrowser(browser) }
                    }
                    Divider()
                    Button("Choose PDF…") { store.chooseSummaryPDF() }
                }
                .disabled(!onboarding.completed || !store.canStartDocumentSummary)
            }
        }
        Settings {
            SettingsView(store: store, onboarding: onboarding, onOpenSetup: { store.stop(); onboarding.returnToSetup() })
                .preferredColorScheme(themeManager.appearanceMode.colorScheme)
                .relayPreferredAppearance()
        }
        MenuBarExtra {
            RelayMenuBarView(store: store, sidekickAvailable: onboarding.completed)
        } label: {
            let isBusy = store.isRunning || store.voice.isBusy || store.speech.isActive || store.knowledgeSearch.isBusy || store.speechDiagnostic.isBusy
            Image(nsImage: RelayBrandMenuBarIcon.image(active: isBusy))
                .accessibilityLabel("Relay")
        }

    }

    @MainActor
    static func handleOpenURL(_ url: URL, store: AssistantStore) {
        guard url.scheme?.lowercased() == "relay" else { return }
        let host = (url.host() ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let promptParam = components?.queryItems?.first(where: { ["prompt", "text", "q"].contains($0.name.lowercased()) })?.value

        switch host {
        case "new", "new-thread", "thread":
            if !store.isRunning && !store.isClearingConversation {
                store.startNewThread()
            }
            if let promptParam, !promptParam.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                store.draft = promptParam
            }
        case "brief", "morning-brief":
            NotificationCenter.default.post(name: .relayOpenMorningBrief, object: nil)
        case "knowledge", "vault":
            NotificationCenter.default.post(name: .relayOpenKnowledgeVault, object: nil)
        case "sidekick", "notch":
            NotchOverlayController.shared.open()
        case "summarize", "summary":
            if store.canStartDocumentSummary {
                do { try store.startCurrentDocumentSummary() }
                catch { store.chooseSummaryPDF() }
            }
        case "ask", "prompt", "compose", "workspace", "":
            NotificationCenter.default.post(name: Notification.Name("relay.switchToWorkspace"), object: nil)
            if let promptParam, !promptParam.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                store.draft = promptParam
            }
        default:
            break
        }
    }
}

extension Notification.Name {
    static let relayOpenMorningBrief = Notification.Name("relay.openMorningBrief")
    static let relayOpenKnowledgeVault = Notification.Name("relay.openKnowledgeVault")
    static let relayOpenCommandPalette = Notification.Name("relay.openCommandPalette")
    static let relayToggleSidebar = Notification.Name("relay.toggleSidebar")
}

@MainActor
final class RelayServicesProvider: NSObject {
    static let shared = RelayServicesProvider()
    weak var store: AssistantStore?

    @objc func summarizeWithRelay(
        _ pboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        guard let text = pboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return }
        store?.handoffToWorkspaceComposer(title: "Selected Text", contextText: text, promptPrefix: "Summarize")
    }

    @objc func proofreadWithRelay(
        _ pboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        guard let text = pboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return }
        store?.handoffToWorkspaceComposer(title: "Selected Text", contextText: text, promptPrefix: "Proofread")
    }
}
