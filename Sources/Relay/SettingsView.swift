import SwiftUI
import AppKit
import ApplicationServices
import CoreGraphics
import AVFoundation
@preconcurrency import Speech

struct SettingsView: View {
    @Bindable var store: AssistantStore
    var onboarding: OnboardingCoordinator? = nil
    var onOpenSetup: (() -> Void)? = nil
    var initialSection = "General"

    @Environment(\.dismiss) private var dismiss
    @AppStorage(RelayAppearanceMode.storageKey) private var appearanceModeRaw: String = RelayAppearanceMode.dark.rawValue
    @AppStorage(SidekickTaskContext.instructionsPreference) private var sidekickInstructions = ""
    @AppStorage(NativeTaskControlDependencies.enabledPreference) private var nativeWindowControlEnabled = true

    @State private var tab = SettingsTab.general
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool
    @State private var memoryText = ""
    @State private var accessibilityGranted = AXIsProcessTrusted()
    @State private var screenCaptureGranted = CGPreflightScreenCaptureAccess()
    @State private var accessibilityCheckRunning = false
    @State private var diagnosticProbeRunning = false
    @State private var agentDesktopStatus: AgentDesktopStatus?
    @State private var isUpdatingAgentDesktop = false
    @State private var agentDesktopUpdateMessage: String?
    @State private var showFactoryResetSheet = false
    @State private var showCleanUninstallSheet = false
    @State private var showClearHistoryConfirmation = false
    @State private var catalogRevision = 0
    @State private var modelDeletionError: String?
    @State private var microphoneAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var speechAuthorization = SFSpeechRecognizer.authorizationStatus()

    private enum SettingsTab: String, CaseIterable {
        case general = "General"
        case aiModels = "AI Models"
        case notchShortcuts = "Sidekick & Shortcuts"
        case magicReply = "Magic Reply"
        case sourcesConnectors = "Sources"
        case knowledgeSharing = "Knowledge & Memory"
        case schedule = "Automation"
        case systemPrivacy = "Permissions"
        case system = "System & Data"

        var title: String { rawValue }

        var subtitle: String {
            switch self {
            case .general: "Make Relay feel at home on your Mac."
            case .aiModels: "Choose the AI that powers your workspace."
            case .notchShortcuts: "Quick access, dictation, and the shortcuts you use every day."
            case .magicReply: "Create unsent replies with your preferred writing style."
            case .sourcesConnectors: "Choose the files, apps, and services Relay can use."
            case .knowledgeSharing: "Keep useful context and preferences close."
            case .schedule: "Decide when Relay prepares updates and morning briefs."
            case .systemPrivacy: "Control how Relay can interact with your Mac."
            case .system: "Updates, exports, diagnostics, and app maintenance."
            }
        }

        var keywords: String {
            switch self {
            case .general: "appearance theme dark light night startup launch login"
            case .aiModels: "provider account login sign in gemma download import litertlm claude chatgpt codex openrouter lm studio api engine"
            case .notchShortcuts: "voice microphone dictation speech read aloud keyboard command hotkey stop touch calibration proofread summarize instructions"
            case .magicReply: "draft double tap writing style tone examples reply"
            case .sourcesConnectors: "folder files calendar notes mail email messages imessage whatsapp gmail slack notion oauth mcp connector siyuan"
            case .knowledgeSharing: "vault memory remember index search semantic markdown sharing encrypted archive mirror export"
            case .schedule: "overnight morning brief wake battery plugged idle proactive suggestions schedule"
            case .systemPrivacy: "access accessibility screen recording microphone speech dictation computer control approval permission ocr test"
            case .system: "update version diagnostics logs conversation history clear export reset uninstall delete"
            }
        }

        func matches(_ query: String) -> Bool {
            let text = "\(title) \(subtitle) \(keywords)"
            return query.split(whereSeparator: { $0.isWhitespace }).allSatisfy {
                text.localizedStandardContains(String($0))
            }
        }

        var icon: String {
            switch self {
            case .general: return "paintbrush.pointed"
            case .aiModels: return "cpu"
            case .notchShortcuts: return "menubar.dock.rectangle"
            case .magicReply: return "wand.and.stars"
            case .sourcesConnectors: return "tray.full"
            case .knowledgeSharing: return "books.vertical"
            case .schedule: return "sparkles.rectangle.stack"
            case .systemPrivacy: return "hand.raised"
            case .system: return "gearshape"
            }
        }

        static func resolve(_ raw: String) -> SettingsTab? {
            if let exact = SettingsTab(rawValue: raw) { return exact }
            switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "general", "appearance", "theme", "general & appearance":
                return .general
            case "model", "models", "ai", "aimodels", "ai models":
                return .aiModels
            case "sidekick", "notch", "shortcuts", "voice", "notch & shortcuts", "voice & notch", "sidekick & shortcuts":
                return .notchShortcuts
            case "magicreply", "magic reply", "draft", "style":
                return .magicReply
            case "sources", "connectors", "sources & connectors":
                return .sourcesConnectors
            case "knowledge", "memory", "sharing", "vault", "knowledge & sharing", "knowledge & memory":
                return .knowledgeSharing
            case "schedule", "overnight", "plugged-in", "overnight & plugged-in", "automation", "automation & schedule":
                return .schedule
            case "access", "permissions", "privacy", "system & privacy", "privacy & system":
                return .systemPrivacy
            case "system", "reset", "uninstall", "system & data":
                return .system
            default:
                return nil
            }
        }
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var currentAppearance: RelayAppearanceMode {
        RelayAppearanceMode.fromStored(appearanceModeRaw)
    }

    var body: some View {
        ZStack {
            Color.clear.ignoresSafeArea()
            HStack(spacing: 0) {
                navigation
                VStack(spacing: 0) {
                    contentHeader

                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            if isSearching {
                                searchResults
                            } else {
                                sectionTitle(tab.title, detail: tab.subtitle)

                                switch tab {
                                case .general:
                                    generalAndAppearanceSettings
                                case .aiModels:
                                    modelSettings
                                case .notchShortcuts:
                                    notchAndShortcutsSettings
                                case .magicReply:
                                    magicReplySettings
                                case .sourcesConnectors:
                                    sourcesAndConnectorsSettings
                                case .knowledgeSharing:
                                    knowledgeAndSharingSettings
                                case .schedule:
                                    scheduleSettings
                                case .systemPrivacy:
                                    permissionSettings
                                case .system:
                                    systemAndPrivacySettings
                                }
                            }
                        }
                        .frame(maxWidth: 760, alignment: .topLeading)
                        .padding(.horizontal, 28)
                        .padding(.top, 20)
                        .padding(.bottom, 28)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .id(isSearching ? "search" : tab.rawValue)
                    .scrollIndicators(.visible)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 820, idealWidth: 980, minHeight: 620, idealHeight: 740)
        .relayPageBackground()
        .foregroundStyle(RelayTheme.ink)
        .font(RelayPageStyle.body)
        .tint(RelayColors.workbenchAccent)
        .relayPreferredAppearance()
        .disclosureGroupStyle(RelayDisclosureGroupStyle())
        .onAppear {
            if let requested = SettingsTab.resolve(initialSection) {
                tab = requested
            }
            refreshPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
        .task {
            agentDesktopStatus = await AgentDesktopBridge.queryStatus()
        }
        .sheet(isPresented: $showFactoryResetSheet) {
            FactoryResetSheetView(store: store, onboarding: onboarding)
        }
        .sheet(isPresented: $showCleanUninstallSheet) {
            CleanUninstallSheetView(store: store)
        }
        .confirmationDialog(
            "Clear conversation history?",
            isPresented: $showClearHistoryConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear Conversation", role: .destructive) {
                store.clearConversation()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the active conversation transcript from Relay. Created files and external changes are not undone.")
        }
    }

    // MARK: - Content Header Bar

    private var contentHeader: some View {
        HStack(spacing: 12) {
            Text(isSearching ? "Search settings" : "Settings")
                .font(RelayPageStyle.body.weight(.medium))
                .foregroundStyle(RelayColors.textSecondary)
            Spacer()
            RelayIconButton(icon: "xmark", label: "Close settings", size: 32, iconSize: 14, circular: false) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 28)
        .frame(height: 48)
    }

    // MARK: - Sidebar Navigation

    private var navigation: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                RelayMark(size: 18)
                Text("Relay")
                    .font(RelayPageStyle.body.weight(.medium))
                    .foregroundStyle(RelayColors.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 18)
            .frame(height: 48)


            HStack(spacing: 8) {
                Button { searchFocused = true } label: {
                    Image(systemName: "magnifyingglass").foregroundStyle(RelayColors.textMuted)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("f", modifiers: .command)
                .accessibilityLabel("Focus settings search")
                TextField("Search settings", text: $searchText)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("settings.search")
                    .accessibilityLabel("Search settings")
                    .focused($searchFocused)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear settings search")
                }
            }
            .font(RelayPageStyle.body)
            .padding(10)
            .background(RelayColors.surfaceElevated, in: RoundedRectangle(cornerRadius: 9))
            .padding(.horizontal, 12)
            .padding(.top, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    navigationGroup("App", tabs: [.general, .aiModels, .notchShortcuts, .magicReply])
                    navigationGroup("Personal", tabs: [.sourcesConnectors, .knowledgeSharing, .schedule])
                    navigationGroup("Mac", tabs: [.systemPrivacy, .system])
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 18)
            }
            .scrollIndicators(.hidden)

            if let onOpenSetup {
                Divider().overlay(RelayColors.borderSubtle.opacity(0.5))
                Button {
                    dismiss()
                    onOpenSetup()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(RelayPageStyle.symbol)
                            .foregroundStyle(RelayColors.textSecondary)
                        Text("Run Setup Assistant")
                            .font(RelayPageStyle.body.weight(.medium))
                            .foregroundStyle(RelayColors.textSecondary)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 46)
                    .contentShape(Rectangle())
                }
                .buttonStyle(RelayPressStyle())
                .accessibilityLabel("Run setup assistant")
            }
        }
        .frame(width: 216)
        .frame(maxHeight: .infinity)
        .background(RelayColors.pitch.opacity(0.78))
    }

    private func navigationGroup(_ title: String, tabs: [SettingsTab]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(RelayPageStyle.caption.weight(.medium))
                .foregroundStyle(RelayColors.textMuted)
                .padding(.leading, 10)
                .padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)
            ForEach(tabs, id: \.self) { item in
                SettingsSidebarTabButton(title: item == .knowledgeSharing ? "Knowledge" : item.title, icon: item.icon, isSelected: tab == item) {
                    searchText = ""
                    tab = item
                }
            }
        }
    }

    private var searchResults: some View {
        let matches = SettingsTab.allCases.filter { $0.matches(searchText) }
        return VStack(alignment: .leading, spacing: 18) {
            sectionTitle("Find a setting", detail: "Search by feature, app, or preference.")
            if matches.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Label("No matching settings", systemImage: "magnifyingglass").font(RelayPageStyle.sectionTitle)
                    Text("Try “voice”, “Calendar”, “model”, or “export”.")
                        .font(RelayPageStyle.body).foregroundStyle(RelayColors.textSecondary)
                    Button("Clear search") { searchText = "" }.buttonStyle(RelaySecondaryButtonStyle())
                }
                .padding(22)
            } else {
                Text("\(matches.count) \(matches.count == 1 ? "section" : "sections")")
                    .font(RelayPageStyle.caption).foregroundStyle(RelayColors.textSecondary)
                ForEach(matches, id: \.self) { result in
                    Button {
                        tab = result
                        searchText = ""
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: result.icon).frame(width: 24)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(result.title).font(RelayPageStyle.body.weight(.medium))
                                Text(result.subtitle).font(RelayPageStyle.caption).foregroundStyle(RelayColors.textSecondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(RelayColors.textMuted)
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RelayColors.cardBG, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(RelayColors.borderSubtle, lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Pane 0: General & Appearance

    private var generalAndAppearanceSettings: some View {
        VStack(alignment: .leading, spacing: 22) {
            appearanceThemeCard
            VStack(alignment: .leading, spacing: 18) {
                LaunchAtLoginView()
            }
            .relayFormSection()
        }
    }

    private var appearanceThemeCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                SettingsSectionIcon(icon: currentAppearance.iconName)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Appearance")
                        .font(RelayPageStyle.sectionTitle)
                        .foregroundStyle(RelayColors.textPrimary)
                    Text("Choose a look, or follow your Mac’s appearance.")
                        .font(RelayPageStyle.caption)
                        .foregroundStyle(RelayColors.textSecondary)
                        .lineSpacing(2)
                }
                Spacer()
            }

            HStack(spacing: 12) {
                ForEach(RelayAppearanceMode.allCases) { mode in
                    AppearanceModeOptionCard(
                        mode: mode,
                        isSelected: currentAppearance == mode
                    ) {
                        appearanceModeRaw = mode.rawValue
                        RelayThemeManager.shared.setMode(mode)
                    }
                }
            }
        }
        .relayFormSection()
    }

    // MARK: - Pane 1: AI Models & Accounts

    private var modelSettings: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    SettingsSectionIcon(icon: "cpu.fill")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Workspace model")
                            .font(RelayPageStyle.sectionTitle)
                            .foregroundStyle(RelayColors.textPrimary)
                        Text("Choose which provider powers Relay and Sidekick.")
                            .font(RelayPageStyle.caption)
                            .foregroundStyle(RelayColors.textSecondary)
                            .lineSpacing(2)
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        RelayHealthDot(color: store.workspaceActionsReady ? RelayColors.accentEmerald : RelayColors.accentAmber)
                        Text(store.workspaceActionsReady ? "Ready" : "Setup needed")
                            .font(RelayPageStyle.caption.weight(.medium))
                            .foregroundStyle(store.workspaceActionsReady ? RelayColors.accentEmerald : RelayColors.textSecondary)
                    }
                }

                VStack(spacing: RelaySpace.xxs) {
                    ForEach(WorkspaceProviderDescriptor.all, id: \.backend) { descriptor in
                        let isSelected = store.configuration.backend == descriptor.backend
                        WorkspaceProviderRow(
                            descriptor: descriptor,
                            isSelected: isSelected,
                            isReady: isSelected ? store.actionsReady : descriptor.isConfigured(in: store),
                            statusHint: descriptor.statusHint(in: store, isSelected: isSelected),
                            disabled: store.isRunning || store.isPreparingModel || store.checkingCodex
                        ) {
                            store.selectLocalProvider(descriptor.backend)
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("settings.modelProviderPicker")
            }

            if store.isRunning {
                note("Stop the current task before changing providers or model settings.", icon: "pause.circle")
            }

            switch store.configuration.backend {
            case .openRouter:
                OpenRouterSettingsView(store: store)
            case .customResponses:
                CustomResponsesSettingsView(store: store)
            case .lmStudio:
                LMStudioSettingsView(store: store)
            case .claudeCLI:
                ClaudeSettingsView(store: store)
            case .codexCLI:
                CodexProviderSettingsView(store: store)
            case .liteRTLM:
                onDeviceModelsCard
            }

            DisclosureGroup("Where requests go & how sign-in is stored") {
                note("Gemma runs on this Mac. LM Studio uses your configured server. Claude and ChatGPT use your existing CLI sign-in. API providers receive your requests; their keys are stored in macOS Keychain.", icon: "lock.shield")
                    .padding(.top, 12)
            }

            DisclosureGroup("Computer-use engine · advanced") {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 14) {
                        SettingsSectionIcon(icon: "macwindow.on.rectangle")
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text("Agent-Desktop Computer Use Engine")
                                    .font(RelayPageStyle.sectionTitle)
                                    .foregroundStyle(RelayColors.textPrimary)
                                if let status = agentDesktopStatus, status.available {
                                    RelayBadge("v\(status.version)", tint: RelayColors.accentEmerald, prominent: true)
                                }
                            }
                            Text("Built-in native CoreGraphics + Accessibility window driver paired with agent-desktop skeleton snapshots and @ref targeting.")
                                .font(RelayPageStyle.caption)
                                .foregroundStyle(RelayColors.textSecondary)
                        }
                        Spacer()
                        Button(isUpdatingAgentDesktop ? "Updating…" : "Update Engine") {
                            isUpdatingAgentDesktop = true
                            agentDesktopUpdateMessage = nil
                            Task {
                                do {
                                    let msg = try await AgentDesktopBridge.updateVendorBinaryIfPossible()
                                    agentDesktopStatus = await AgentDesktopBridge.queryStatus()
                                    agentDesktopUpdateMessage = msg.components(separatedBy: .newlines).last ?? "Updated to latest release."
                                } catch {
                                    agentDesktopUpdateMessage = error.localizedDescription
                                }
                                isUpdatingAgentDesktop = false
                            }
                        }
                        .buttonStyle(RelaySecondaryButtonStyle())
                        .disabled(isUpdatingAgentDesktop)
                    }

                    if let status = agentDesktopStatus {
                        HStack(spacing: 16) {
                            Label(
                                status.ffiLoaded ? "FFI ABI v\(status.ffiAbiMajor) Verified" : "FFI Library Not Loaded",
                                systemImage: status.ffiLoaded ? "checkmark.seal.fill" : "exclamationmark.triangle"
                            )
                            .font(RelayPageStyle.caption.weight(.medium))
                            .foregroundStyle(status.ffiLoaded ? RelayColors.accentEmerald : RelayColors.accentGold)

                            Label(
                                status.accessibilityGranted ? "AX Tree Ready" : "AX Permission Needed",
                                systemImage: status.accessibilityGranted ? "hand.tap.fill" : "lock.fill"
                            )
                            .font(RelayPageStyle.caption.weight(.medium))
                            .foregroundStyle(status.accessibilityGranted ? RelayColors.accentEmerald : RelayColors.textSecondary)

                            Spacer()
                            Text(status.target)
                                .font(.relayMono)
                                .foregroundStyle(RelayColors.textSecondary)
                        }
                    }

                    if let updateMsg = agentDesktopUpdateMessage {
                        Text(updateMsg)
                            .font(.relayMono)
                            .foregroundStyle(RelayColors.textSecondary)
                            .lineLimit(2)
                    }
                }
                .relayFormSection()
            }
            .font(RelayPageStyle.body.weight(.medium))
        }
    }

    private var onDeviceModelsCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                SettingsSectionIcon(icon: "cpu.fill")
                VStack(alignment: .leading, spacing: 4) {
                    Text("Installed on-device models")
                        .font(RelayPageStyle.sectionTitle)
                        .foregroundStyle(RelayColors.textPrimary)
                    Text("Apple Silicon · LiteRT-LM")
                        .font(RelayPageStyle.caption)
                        .foregroundStyle(RelayColors.textSecondary)
                    Text("Run Gemma 4 100% locally on your Mac GPU or CPU. Choose a catalog model below or import a custom `.litertlm` package from disk.")
                        .font(RelayPageStyle.caption)
                        .foregroundStyle(RelayColors.textSecondary)
                        .lineSpacing(2)
                }
                Spacer(minLength: 0)
            }
            Button("Import model…") { store.chooseModel() }
                .buttonStyle(RelaySecondaryButtonStyle())
                .disabled(store.isPreparingModel || store.isRunning)

            if let name = importedModelName {
                HStack(spacing: 12) {
                    SettingsSectionIcon(icon: "doc.zipper")
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(name)
                                .font(RelayPageStyle.body.weight(.medium))
                                .foregroundStyle(RelayColors.textPrimary)
                                .lineLimit(1)
                            RelayBadge("Custom Import", tint: RelayColors.accentBlue, prominent: true)
                        }
                        Text(store.configuration.modelPath)
                            .font(.relayMonoSmall)
                            .foregroundStyle(RelayColors.textMuted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    RelayBadge(
                        store.actionsReady ? "Active & Ready" : "Selected",
                        icon: store.actionsReady ? "checkmark.circle.fill" : "checkmark.circle",
                        tint: store.actionsReady ? RelayColors.accentEmerald : RelayColors.accentBlue,
                        prominent: true
                    )
                }
                .padding(14)
                .background(RelayColors.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(RelayColors.accentBlue.opacity(0.45), lineWidth: 1)
                )
                .accessibilityLabel("Selected imported model: " + name)
            }

            VStack(alignment: .leading, spacing: 10) {
                let _ = catalogRevision
                ForEach(ModelManifest.catalog, id: \.filename) { manifest in
                    let installedURL = ModelManifest.resolveInstalledURL(for: manifest)
                    let isSelected = installedURL?.path == store.configuration.modelPath
                    OnDeviceCatalogModelCard(
                        manifest: manifest,
                        installedURL: installedURL,
                        isSelected: isSelected,
                        isReady: isSelected && store.actionsReady,
                        disabled: store.isPreparingModel || store.isRunning,
                        onSelect: {
                            Task { await store.selectCatalogModel(manifest) }
                        },
                        onDelete: {
                            deleteCatalogModel(manifest)
                        }
                    )
                }
            }

            HStack(spacing: 12) {
                Button(store.isPreparingModel ? "Preparing…" : store.actionsReady ? "Reload model" : "Load model") {
                    saveAndRefresh()
                }
                .buttonStyle(RelayPrimaryButtonStyle())
                .disabled(store.configuration.modelPath.isEmpty || store.isRunning || store.isPreparingModel)

                Button("Unload") { store.unloadModel() }
                    .buttonStyle(RelaySecondaryButtonStyle())
                    .disabled(store.isRunning)

                Divider()
                    .frame(height: 20)
                    .overlay(RelayTheme.line)

                HStack(spacing: 8) {
                    Text("Compute")
                        .font(RelayPageStyle.caption.weight(.medium))
                        .foregroundStyle(RelayColors.textSecondary)
                        .fixedSize(horizontal: true, vertical: false)
                    Picker("Compute", selection: Binding(get: { store.configuration.computeBackend }, set: {
                        store.configuration.computeBackend = $0
                        store.saveConfiguration()
                    })) {
                        Text("GPU").tag("gpu")
                        Text("CPU").tag("cpu")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 110)
                    .disabled(store.isPreparingModel || store.isRunning)
                }

                if store.isPreparingModel {
                    ProgressView().controlSize(.small)
                    Button("Stop") { store.stop() }.buttonStyle(RelaySecondaryButtonStyle())
                }
                Spacer()
            }
            .padding(14)
            .background(RelayColors.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(RelayColors.borderSubtle, lineWidth: 1)
            )

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: store.actionsReady ? "checkmark.circle.fill" : "circle.dotted")
                    .foregroundStyle(store.actionsReady ? RelayColors.accentEmerald : RelayColors.textMuted)
                Text(store.modelStatus)
                    .font(RelayPageStyle.caption)
                    .foregroundStyle(RelayColors.textSecondary)
                    .textSelection(.enabled)
            }

            if let error = modelDeletionError ?? store.errorMessage {
                Text(error)
                    .font(RelayPageStyle.caption)
                    .foregroundStyle(RelayColors.accentCoral)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .relayFormSection()
    }

    private var importedModelName: String? {
        let path = store.configuration.modelPath
        guard !path.isEmpty, !ModelManifest.catalog.contains(where: { ModelManifest.resolveInstalledURL(for: $0)?.path == path }) else { return nil }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    // MARK: - Pane 2: Voice & Notch

    private var notchAndShortcutsSettings: some View {
        let shortcuts = store.focusedDraft
        let sidekick = NotchOverlayController.shared
        return VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    SettingsSectionIcon(icon: "menubar.dock.rectangle")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Sidekick Notch & Push-to-Talk")
                            .font(RelayPageStyle.sectionTitle)
                            .foregroundStyle(RelayColors.textPrimary)
                            .accessibilityAddTraits(.isHeader)
                        Text("Choose how to open Sidekick and dictate a request.")
                            .font(RelayPageStyle.caption)
                            .foregroundStyle(RelayColors.textSecondary)
                    }
                    Spacer()
                    Button("Open Sidekick") { sidekick.open() }
                        .buttonStyle(RelaySecondaryButtonStyle())
                }

                Divider().overlay(RelayTheme.line)

                VStack(spacing: 0) {
                    settingRow("Shared shortcut key", detail: "Use the same key to open Sidekick, hold to dictate, and double-tap for Magic Reply.") {
                        Picker("Shared shortcut key", selection: Binding(
                            get: { shortcuts.shortcutKey }, set: { sidekick.setShortcutKey($0) }
                        )) {
                            ForEach(SidekickModifierKey.allCases, id: \.self) { key in
                                Text(key.title).tag(key)
                            }
                        }
                        .labelsHidden()
                        .accessibilityIdentifier("settings.sidekickKey")
                        .disabled(shortcuts.isBusy || store.voice.isBusy)
                    }
                    Divider().overlay(RelayTheme.line)
                    sidekickToggle(
                        "Open Sidekick on every display",
                        detail: "Use the camera notch or top-edge handle on each display.",
                        identifier: "settings.pinSidekick",
                        value: Binding(get: { sidekick.pinnedToNotch }, set: { sidekick.setPinned($0) })
                    )
                    Divider().overlay(RelayTheme.line)
                    sidekickToggle(
                        "Show status beside the camera",
                        detail: "Show compact status while the notch is collapsed.",
                        identifier: "settings.compactSidekick",
                        value: Binding(get: { sidekick.compactStatusEnabled }, set: { sidekick.setCompactStatusEnabled($0) })
                    )
                    .disabled(!sidekick.pinnedToNotch)
                    Divider().overlay(RelayTheme.line)
                    sidekickToggle(
                        "Open Sidekick with one tap",
                        detail: shortcuts.sidekickStatus,
                        identifier: "settings.rightCommandSidekick",
                        value: Binding(get: { shortcuts.sidekickEnabled }, set: { store.setRightCommandSidekickEnabled($0) })
                    )
                    Divider().overlay(RelayTheme.line)
                    sidekickToggle(
                        "Hold to dictate (Push-to-Talk)",
                        detail: "Hold \(shortcuts.shortcutKey.title) or the notch handle (~250 ms) to dictate. Release to review your on-device transcript.",
                        identifier: "settings.sidekickHold",
                        value: Binding(get: { shortcuts.holdForVoiceEnabled }, set: { sidekick.setHoldForVoiceEnabled($0) })
                    )
                    Divider().overlay(RelayTheme.line)
                    sidekickToggle(
                        "Release handle to send",
                        detail: "Send a final on-device transcript on release. Edits and interruptions stay for review.",
                        identifier: "settings.sidekickReleaseVoice",
                        value: Binding(get: { sidekick.releaseVoiceToSend }, set: { sidekick.setReleaseVoiceToSend($0) })
                    )
                    .disabled(!shortcuts.holdForVoiceEnabled)
                }
            }
            .relayFormSection()

            quickAccessSettings
            globalStopCard
            QuickTextActionShortcutsView(shortcuts: store.textActionShortcuts)

            DisclosureGroup("Notch touch & calibration") {
                NotchTouchSettingsSection().padding(.top, 12)
            }
            DisclosureGroup("Instructions for Sidekick") {
                sidekickInstructionsSettings.padding(.top, 12)
            }
            DisclosureGroup("Read replies aloud") {
            SpeechOutputView(
                speech: store.speech,
                diagnostic: store.speechDiagnostic,
                taskBusy: store.isRunning || store.voice.isBusy || store.isClearingConversation || store.accessibilityCheckRunning
            ).padding(.top, 12)
            }
        }
    }

    private var globalStopCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                SettingsSectionIcon(icon: "hand.raised.fill")
                VStack(alignment: .leading, spacing: 4) {
                    Text("Global Stop Shortcut · ⌘⇧Esc")
                        .font(RelayPageStyle.sectionTitle)
                        .foregroundStyle(RelayColors.textPrimary)
                    Text("Stops new actions and cancels pending work immediately from any app. No keyboard recording.")
                        .font(RelayPageStyle.caption)
                        .foregroundStyle(RelayColors.textSecondary)
                        .lineSpacing(2)
                }
                Spacer()
                Toggle("Enable global Stop shortcut", isOn: Binding(get: { store.globalStop.enabled }, set: { store.setGlobalStopEnabled($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            Text(store.globalStop.status)
                .font(.relayMono)
                .foregroundStyle(RelayColors.textMuted)
            if let error = store.globalStop.errorMessage {
                Text(error)
                    .font(RelayPageStyle.caption)
                    .foregroundStyle(RelayColors.accentCoral)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .relayFormSection()
    }

    // MARK: - Pane 3: Magic Reply

    private var magicReplySettings: some View {
        VStack(alignment: .leading, spacing: 22) {
            MagicReplySettingsView(store: store)

            DisclosureGroup("Writing examples & tone preferences") {
                VStack(alignment: .leading, spacing: 18) {
                    writingStyleSnapshotCard

                    WritingProfileView(profile: store.writingProfile, canLearn: store.workspaceActionsReady && !store.isRunning) { samples in
                        let reply = try await store.auxiliaryText(WritingStyleSuggestion.prompt(samples: samples))
                        return try WritingStyleSuggestion.parse(reply.content)
                    }
                }
                .padding(.top, 12)
            }
        }
    }

    private var writingStyleSnapshotCard: some View {
        let collector = store.writingStyleCollector
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                SettingsSectionIcon(icon: "pencil.and.outline")
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("Saved writing examples")
                            .font(RelayPageStyle.sectionTitle)
                            .foregroundStyle(RelayColors.textPrimary)
                        if collector.hasSnapshot {
                            RelayBadge("Protected", tint: RelayColors.accentEmerald, prominent: true)
                        }
                    }
                    Text("Collected at most once from opted-in 1:1 outgoing messages and emails. Editable in Markdown and never overwritten automatically.")
                        .font(RelayPageStyle.caption)
                        .foregroundStyle(RelayColors.textSecondary)
                }
                Spacer()
            }

            Text(collector.status)
                .font(RelayPageStyle.caption)
                .foregroundStyle(RelayColors.textSecondary)
                .textSelection(.enabled)

            HStack(spacing: 10) {
                Button(collector.isCollecting ? "Collecting…" : (collector.hasSnapshot ? "Collected Once" : "Collect Sent Examples Once")) {
                    Task { await store.collectWritingStyleOnceNow() }
                }
                .buttonStyle(RelaySecondaryButtonStyle())
                .disabled(collector.isCollecting || collector.hasSnapshot || store.isRunning)
                .accessibilityIdentifier("magicReply.collectWritingStyleOnce")

                Button("Reveal writingstyle.md") {
                    KnowledgeVaultManager.shared.revealWritingStyleInFinder()
                }
                .buttonStyle(RelaySecondaryButtonStyle())

                Button("Refresh Status") {
                    collector.refreshStatus()
                }
                .buttonStyle(RelaySecondaryButtonStyle())

                if collector.isCollecting {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }
        }
        .relayFormSection()
    }

    // MARK: - Pane 4: Sources & Connectors

    private var sourcesAndConnectorsSettings: some View {
        VStack(alignment: .leading, spacing: 22) {
            authorizedFoldersCard

            calendarSourceCard

            NativeSourceConnectorsView(sources: store.nativeSources, busy: store.isRunning, store: store)

            DisclosureGroup("Connect another service · MCP") {
                DirectMCPConnectorView(connector: store.directMCP, busy: store.isRunning && !store.directMCP.isBusy, store: store)
                    .padding(.top, 12)
            }
            DisclosureGroup("Apple Mail sending access") {
                MailWorkflowAccessView(busy: store.isRunning).padding(.top, 12)
            }
        }
    }

    private var calendarSourceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                SettingsSectionIcon(icon: "calendar")
                VStack(alignment: .leading, spacing: 4) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Apple Calendar")
                            .font(RelayPageStyle.sectionTitle)
                            .foregroundStyle(RelayColors.textPrimary)
                        RelayBadge(
                            store.calendarSource.hasAccess ? "Calendar allowed" : "Permission needed",
                            icon: store.calendarSource.hasAccess ? "checkmark.shield.fill" : "lock.shield",
                            tint: store.calendarSource.hasAccess ? RelayColors.accentEmerald : RelayColors.accentAmber,
                            prominent: true
                        )
                    }
                    Text(CalendarSource.permissionExplanation)
                        .font(RelayPageStyle.caption)
                        .foregroundStyle(RelayColors.textSecondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack {
                if !store.calendarSource.hasAccess {
                    Button("Request Calendar Access") {
                        Task { await store.calendarSource.requestAccess() }
                    }
                    .buttonStyle(RelayPrimaryButtonStyle())
                    .disabled(store.calendarSource.isLoading || store.isRunning)
                    .accessibilityIdentifier("settings.calendar.requestAccess")
                } else {
                    Button(store.calendarSource.isLoading ? "Refreshing…" : "Refresh Calendars") {
                        Task { _ = await store.calendarSource.refresh() }
                    }
                    .buttonStyle(RelaySecondaryButtonStyle())
                    .disabled(store.calendarSource.isLoading || store.isRunning)
                    .accessibilityIdentifier("settings.calendar.refresh")
                }
            }

            Text(store.calendarSource.status)
                .font(RelayPageStyle.caption)
                .foregroundStyle(RelayColors.textSecondary)
                .textSelection(.enabled)

            if let calendarError = store.calendarSource.errorMessage {
                Text(calendarError)
                    .font(RelayPageStyle.caption)
                    .foregroundStyle(RelayColors.accentCoral)
                    .textSelection(.enabled)
            }

            if store.calendarSource.hasAccess {
                CalendarSelectionView(calendar: store.calendarSource, taskBusy: store.isRunning)
            }
        }
        .relayFormSection()
    }

    private var authorizedFoldersCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                SettingsSectionIcon(icon: "folder.badge.gearshape")
                VStack(alignment: .leading, spacing: 4) {
                    Text("Authorized Files & Folders")
                        .font(RelayPageStyle.sectionTitle)
                        .foregroundStyle(RelayColors.textPrimary)
                    Text("Grant read or write access only to specific folders and files for your tasks.")
                        .font(RelayPageStyle.caption)
                        .foregroundStyle(RelayColors.textSecondary)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Button("Add files…", systemImage: "doc.badge.plus") { store.chooseFiles() }
                Button("Add folder…", systemImage: "folder.badge.plus") { store.chooseFolder() }
            }
            .buttonStyle(RelaySecondaryButtonStyle())
            .controlSize(.regular)

            if store.grants.isEmpty {
                note("No files or folders selected yet. Add them above or use the attachment button in Home.", icon: "folder")
            } else {
                VStack(spacing: 0) {
                    ForEach($store.grants) { $grant in
                        HStack(alignment: .center, spacing: 12) {
                            SettingsSectionIcon(icon: "folder.fill")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(URL(fileURLWithPath: grant.path).lastPathComponent)
                                    .font(RelayPageStyle.body.weight(.medium))
                                    .foregroundStyle(RelayColors.textPrimary)
                                Text(grant.path)
                                    .font(RelayPageStyle.caption)
                                    .foregroundStyle(RelayColors.textSecondary)
                                    .lineLimit(2)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            Toggle("Write", isOn: $grant.writable)
                                .toggleStyle(.checkbox)
                                .font(RelayPageStyle.caption.weight(.medium))
                                .onChange(of: grant.writable) { _, _ in store.saveConfiguration() }
                            RelayIconButton(
                                icon: "xmark",
                                label: "Remove \(grant.path)",
                                size: 30
                            ) {
                                store.removeGrant(grant.id)
                            }
                        }
                        .padding(.vertical, 10)
                        Divider().overlay(RelayTheme.line)
                    }
                }
            }
        }
        .relayFormSection()
    }

    // MARK: - Pane 5: Knowledge & Memory

    private var knowledgeAndSharingSettings: some View {
        VStack(alignment: .leading, spacing: 22) {
            memorySettings
            semanticVaultSynthesisCard
            DisclosureGroup("Local index, search & sharing") {
                KnowledgeView(store: store, isSettingsPane: true).padding(.top, 12)
            }
        }
    }

    private var semanticVaultSynthesisCard: some View {
        let vault = store.semanticVault
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                SettingsSectionIcon(icon: "books.vertical.fill")
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("Semantic Knowledge Vault")
                            .font(RelayPageStyle.sectionTitle)
                            .foregroundStyle(RelayColors.textPrimary)
                        if vault.canResume {
                            RelayBadge("Resumable", tint: RelayColors.accentAmber, prominent: true)
                        } else if let report = vault.lastReport {
                            RelayBadge("\(report.noteCount) notes · \(report.wikilinksVerified) wikilinks", tint: RelayColors.accentEmerald, prominent: true)
                        }
                    }
                    Text("Organize your approved sources into linked Markdown notes about people, projects, plans, and preferences. Manual edits are preserved.")
                        .font(RelayPageStyle.caption)
                        .foregroundStyle(RelayColors.textSecondary)
                }
                Spacer()
            }

            if vault.isBuilding && vault.totalSlices > 0 {
                ProgressView(value: Double(vault.completedSlices), total: Double(max(1, vault.totalSlices)))
                    .tint(RelayColors.accentBlue)
            }

            Text(vault.status)
                .font(RelayPageStyle.caption)
                .foregroundStyle(RelayColors.textSecondary)
                .textSelection(.enabled)

            HStack(spacing: 10) {
                Button(vault.isBuilding ? "Synthesizing…" : (vault.canResume ? "Resume Vault Build" : "Build Knowledge Vault")) {
                    Task { await store.buildSemanticVaultNow() }
                }
                .buttonStyle(RelayPrimaryButtonStyle())
                .disabled(vault.isBuilding || store.isRunning)
                .accessibilityIdentifier("knowledge.buildSemanticVault")

                if vault.isBuilding {
                    Button("Stop") { vault.cancel() }
                        .buttonStyle(RelaySecondaryButtonStyle())
                }

                Button("Reveal Vault in Finder") {
                    KnowledgeVaultManager.shared.revealVaultInFinder()
                }
                .buttonStyle(RelaySecondaryButtonStyle())

                Spacer()
            }
        }
        .relayFormSection()
    }

    // MARK: - Pane 6: Automation & Schedule

    private var scheduleSettings: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    SettingsSectionIcon(icon: "sparkles.rectangle.stack.fill")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Morning Brief suggestions")
                            .font(RelayPageStyle.sectionTitle)
                            .foregroundStyle(RelayColors.textPrimary)
                        Text("Prepare follow-ups, meeting notes, and draft ideas for Morning Brief from your selected sources.")
                            .font(RelayPageStyle.caption)
                            .foregroundStyle(RelayColors.textSecondary)
                            .lineSpacing(2)
                    }
                    Spacer()
                    Toggle(
                        "Show Morning Brief suggestions",
                        isOn: Binding(
                            get: { store.proactiveEngine.enabled },
                            set: { store.setSuggestionsEnabled($0) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("schedule.proactiveCardsToggle")
                }

                Text(store.proactiveEngine.status)
                    .font(RelayPageStyle.caption)
                    .foregroundStyle(RelayColors.textSecondary)
                    .textSelection(.enabled)


            }
            .relayFormSection()

            PreparationScheduleView(
                scheduler: store.preparation,
                suggestionsEnabled: store.proactiveEngine.enabled,
                pluggedInScheduler: store.pluggedInAnalysis
            )
        }
    }

    // MARK: - Pane 7: Privacy & System

    private var screenRecordingSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                SettingsSectionIcon(icon: "rectangle.inset.filled")
                VStack(alignment: .leading, spacing: 4) {
                    Text("Screen Recording").font(RelayPageStyle.sectionTitle)
                    Text("Let Relay understand visual content in a selected window. macOS manages this permission.")
                        .font(RelayPageStyle.caption).foregroundStyle(RelayColors.textSecondary)
                }
                Spacer()
                Text(screenCaptureGranted ? "Allowed" : "Not enabled")
                    .font(RelayPageStyle.caption.weight(.medium))
                    .foregroundStyle(screenCaptureGranted ? RelayColors.accentEmerald : RelayColors.textSecondary)
            }
            HStack(spacing: 10) {
                Button("Open Screen Recording settings") {
                    NSWorkspace.shared.open(OnboardingCoordinator.screenCaptureSettingsURL)
                }
                Button("Check again") { screenCaptureGranted = CGPreflightScreenCaptureAccess() }
            }
            .buttonStyle(RelaySecondaryButtonStyle())
        }
        .relayFormSection()
        .onAppear { screenCaptureGranted = CGPreflightScreenCaptureAccess() }
    }

    private var voicePermissionSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Microphone & speech recognition", systemImage: "mic")
                .font(RelayPageStyle.sectionTitle)
                .accessibilityAddTraits(.isHeader)
            Text("Dictation needs both permissions. Relay asks when you first start recording; transcription uses on-device speech recognition when available for your language.")
                .font(RelayPageStyle.caption)
                .foregroundStyle(RelayColors.textSecondary)
            VStack(alignment: .leading, spacing: 10) {
                Label("Microphone: \(microphonePermissionDescription)", systemImage: microphoneAuthorization == .authorized ? "checkmark.circle" : "mic.slash")
                Label("Speech recognition: \(speechPermissionDescription)", systemImage: speechAuthorization == .authorized ? "checkmark.circle" : "waveform")
            }
            .font(RelayPageStyle.caption.weight(.medium))
            RelayChipFlow(spacing: 8, alignment: .leading) {
                Button("Microphone settings") { openPrivacySettings("Privacy_Microphone") }
                Button("Speech recognition settings") { openPrivacySettings("Privacy_SpeechRecognition") }
                Button("Check again") { refreshPermissions() }
            }
            .buttonStyle(RelaySecondaryButtonStyle())
        }
        .relayFormSection()
    }

    private var microphonePermissionDescription: String {
        switch microphoneAuthorization {
        case .authorized: "Allowed"
        case .notDetermined: "Not requested"
        case .denied: "Not allowed"
        case .restricted: "Restricted by this Mac"
        @unknown default: "Unknown"
        }
    }

    private var speechPermissionDescription: String {
        switch speechAuthorization {
        case .authorized: "Allowed"
        case .notDetermined: "Not requested"
        case .denied: "Not allowed"
        case .restricted: "Restricted by this Mac"
        @unknown default: "Unknown"
        }
    }

    private func refreshPermissions() {
        accessibilityGranted = AXIsProcessTrusted()
        screenCaptureGranted = CGPreflightScreenCaptureAccess()
        microphoneAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
        speechAuthorization = SFSpeechRecognizer.authorizationStatus()
    }

    private func openPrivacySettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane) else { return }
        NSWorkspace.shared.open(url)
    }

    private var permissionSettings: some View {
        VStack(alignment: .leading, spacing: 22) {
            screenRecordingSettings
            voicePermissionSettings
            accessibilityAndComputerUseCard
            DisclosureGroup("Text recognition · OCR") {
                OCRReadinessSettingsView().padding(.top, 12)
            }
        }
    }

    private var systemAndPrivacySettings: some View {
        VStack(alignment: .leading, spacing: 22) {
            AppUpdateView()
                .relayFormSection()
            VStack(alignment: .leading, spacing: 18) {
                ConversationExportView(store: store)

                Divider().overlay(RelayTheme.line)

                HStack(alignment: .center, spacing: 16) {
                    SettingsSectionIcon(icon: "clock.arrow.circlepath")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Conversation History")
                            .font(RelayPageStyle.sectionTitle)
                            .foregroundStyle(RelayColors.textPrimary)
                        Text("Clear active conversation history. This does not undo created files or external changes.")
                            .font(RelayPageStyle.caption)
                            .foregroundStyle(RelayColors.textSecondary)
                    }
                    Spacer()
                    Button("Clear conversation") { showClearHistoryConfirmation = true }
                        .buttonStyle(RelaySecondaryButtonStyle())
                        .disabled(store.isRunning || store.pendingReview != nil)
                }

                Divider().overlay(RelayTheme.line)

                DisclosureGroup("Diagnostics & troubleshooting") {
                    DiagnosticsView(store: store).padding(.top, 12)
                }
            }
            .relayFormSection()

            DisclosureGroup("Reset or uninstall Relay") {
                resetAndUninstallCard.padding(.top, 12)
            }
        }
    }

    private var accessibilityAndComputerUseCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                SettingsSectionIcon(icon: "cursorarrow.motionlines")
                VStack(alignment: .leading, spacing: 4) {
                    Text("Accessibility & app control")
                        .font(RelayPageStyle.sectionTitle)
                        .foregroundStyle(RelayColors.textPrimary)
                    Text("Read controls in your apps, enter text, and carry out reviewed actions. Secure fields and security dialogs are excluded.")
                        .font(RelayPageStyle.caption)
                        .foregroundStyle(RelayColors.textSecondary)
                        .lineSpacing(2)
                }
                Spacer()
                RelayBadge(
                    accessibilityGranted ? "Accessibility allowed" : "Permission needed",
                    icon: accessibilityGranted ? "checkmark.shield.fill" : "exclamationmark.triangle.fill",
                    tint: accessibilityGranted ? RelayColors.accentEmerald : RelayColors.accentAmber,
                    prominent: true
                )
            }

            HStack(spacing: 8) {
                Button("Request Accessibility") { requestAccessibility() }
                Button("Open System Settings") { openAccessibilitySettings() }
                Button("Check again") { accessibilityGranted = AXIsProcessTrusted() }
            }
            .buttonStyle(RelaySecondaryButtonStyle())
            .controlSize(.regular)
            .onAppear { accessibilityGranted = AXIsProcessTrusted() }

            Divider().overlay(RelayTheme.line).padding(.vertical, 2)

            Toggle("Enable App Window Control (Computer Use)", isOn: $nativeWindowControlEnabled)
                .toggleStyle(.switch)
                .font(RelayPageStyle.body.weight(.medium))
                .disabled(store.isRunning)
                .accessibilityIdentifier("nativeWindowControl.enabled")

            Text("Requires Accessibility permission and a ready workspace model. Actions follow the approval setting below; consequential changes still require review.")
                .font(RelayPageStyle.caption)
                .foregroundStyle(RelayColors.textSecondary)
                .lineSpacing(3)

            Toggle(
                "Auto-approve routine navigation & UI clicks",
                isOn: Binding(
                    get: { store.autoApproveRoutineActions },
                    set: { store.setAutoApproveRoutineActions($0) }
                )
            )
            .toggleStyle(.switch)
            .font(RelayPageStyle.body.weight(.medium))
            .disabled(store.isRunning || !nativeWindowControlEnabled)
            .accessibilityIdentifier("nativeWindowControl.autoApproveRoutine")

            Text("Skip confirmation prompts for ordinary browser navigation, tab switches, and routine UI clicks. Sends, calendar commits, file moves, overwrites, and sensitive fields still require approval.")
                .font(RelayPageStyle.caption)
                .foregroundStyle(RelayColors.textSecondary)
                .lineSpacing(3)

            Divider().overlay(RelayTheme.line).padding(.vertical, 2)

            DisclosureGroup("Self-Test & Diagnostic Probes") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Verifies synthetic pointer/text actuation and screen capture inside an isolated Relay test fixture window without touching other apps.")
                        .font(RelayPageStyle.caption)
                        .foregroundStyle(RelayColors.textSecondary)
                        .lineSpacing(2)

                    HStack(spacing: 10) {
                        Button {
                            accessibilityCheckRunning = true
                            Task {
                                await store.runAccessibilityCheck()
                                accessibilityGranted = AXIsProcessTrusted()
                                accessibilityCheckRunning = false
                            }
                        } label: {
                            Label(accessibilityCheckRunning ? "Checking…" : "Run accessibility check", systemImage: "checkmark.shield.fill")
                        }
                        .buttonStyle(RelaySecondaryButtonStyle())
                        .disabled(!accessibilityGranted || store.isRunning || accessibilityCheckRunning)

                        Button {
                            diagnosticProbeRunning = true
                            Task {
                                _ = await store.runComputerUseDiagnosticProbe()
                                accessibilityGranted = AXIsProcessTrusted()
                                diagnosticProbeRunning = false
                            }
                        } label: {
                            Label(diagnosticProbeRunning ? "Probing…" : "Quick diagnostic probe", systemImage: "stethoscope")
                        }
                        .buttonStyle(RelaySecondaryButtonStyle())
                        .disabled(store.isRunning || diagnosticProbeRunning)
                        .accessibilityIdentifier("settings.computerUseDiagnosticProbe")

                        Button("Run screen capture check", systemImage: "macwindow") {
                            Task { await store.runScreenCaptureCheck() }
                        }
                        .buttonStyle(RelaySecondaryButtonStyle())
                        .disabled(store.isRunning || store.voice.isBusy)
                        .accessibilityIdentifier("settings.screenCaptureCheck")

                        if accessibilityCheckRunning || diagnosticProbeRunning {
                            ProgressView().controlSize(.small)
                        }
                    }

                    Text(store.accessibilityCheckStatus)
                        .font(RelayPageStyle.caption)
                        .foregroundStyle(RelayColors.textSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Accessibility check status: \(store.accessibilityCheckStatus)")

                    Text(store.screenCaptureCheckStatus.summary)
                        .font(RelayPageStyle.caption)
                        .foregroundStyle(RelayColors.textSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.screenCaptureStatus")
                }
                .padding(.top, 8)
            }
            .font(RelayPageStyle.body.weight(.medium))
        }
        .relayFormSection()
    }

    private var resetAndUninstallCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                SettingsSectionIcon(icon: "trash.slash.fill")
                VStack(alignment: .leading, spacing: 4) {
                    Text("Factory Reset & Clean Uninstall")
                        .font(RelayPageStyle.sectionTitle)
                        .foregroundStyle(RelayColors.textPrimary)
                    Text("Reset Relay back to first-launch setup (optionally keeping downloaded multi-gigabyte Gemma models), or completely remove Relay, its Keychain items, Knowledge Vault, and scheduled wake helper from this Mac. External developer setups (`~/.codex`, `~/.claude`) and your personal files are never touched.")
                        .font(RelayPageStyle.caption)
                        .foregroundStyle(RelayColors.textSecondary)
                        .lineSpacing(2)
                }
                Spacer()
            }

            HStack(spacing: 12) {
                Button("Factory Reset Relay…") {
                    showFactoryResetSheet = true
                }
                .buttonStyle(RelaySecondaryButtonStyle())
                .disabled(store.isRunning)
                .accessibilityIdentifier("settings.factoryReset")

                Button(role: .destructive) {
                    showCleanUninstallSheet = true
                } label: {
                    Label("Clean Uninstall…", systemImage: "trash")
                }
                .buttonStyle(RelaySecondaryButtonStyle())
                .disabled(store.isRunning)
                .accessibilityIdentifier("settings.cleanUninstall")

                Spacer()
            }
        }
        .relayFormSection()
    }

    // MARK: - Shared Subsections

    private func sidekickToggle(_ title: String, detail: String, identifier: String, value: Binding<Bool>) -> some View {
        settingRow(title, detail: detail) {
            Toggle(title, isOn: value)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(RelayColors.accentBlue)
                .accessibilityIdentifier(identifier)
        }
    }

    private func settingRow<Control: View>(_ title: String, detail: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(RelayPageStyle.body.weight(.medium))
                    .foregroundStyle(RelayColors.textPrimary)
                Text(detail)
                    .font(RelayPageStyle.caption)
                    .foregroundStyle(RelayColors.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control()
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.vertical, 13)
    }

    private var sidekickInstructionsSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                SettingsSectionIcon(icon: "text.bubble.fill")
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sidekick Custom Instructions")
                        .font(RelayPageStyle.sectionTitle)
                        .foregroundStyle(RelayColors.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text("Tell Sidekick how you like to work. These preferences apply to tasks using your workspace model.")
                        .font(RelayPageStyle.caption)
                        .foregroundStyle(RelayColors.textSecondary)
                }
                Spacer()
            }

            TextEditor(text: $sidekickInstructions)
                .font(RelayPageStyle.body)
                .foregroundStyle(RelayColors.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(12)
                .frame(minHeight: 86)
                .background(RelayColors.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(RelayColors.borderDefault, lineWidth: 1)
                }
                .accessibilityLabel("Sidekick custom instructions")
                .accessibilityIdentifier("settings.sidekickInstructions")
                .onChange(of: sidekickInstructions) { _, value in
                    if value.utf8.count > SidekickTaskContext.instructionByteLimit {
                        sidekickInstructions = NativePersonalSources.bounded(value, maximumBytes: SidekickTaskContext.instructionByteLimit)
                    }
                }
            Text("Saved automatically · \(sidekickInstructions.utf8.count.formatted()) of \(SidekickTaskContext.instructionByteLimit.formatted()) bytes")
                .font(RelayPageStyle.caption)
                .foregroundStyle(RelayColors.textSecondary)
        }
        .relayFormSection()
    }

    private var quickAccessSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                SettingsSectionIcon(icon: "command.square.fill")
                VStack(alignment: .leading, spacing: 4) {
                    Text("Quick Access Shortcut")
                        .font(RelayPageStyle.sectionTitle)
                        .foregroundStyle(RelayColors.textPrimary)
                    Text("Brings Relay forward instantly from any application using ⌘⇧Space.")
                        .font(RelayPageStyle.caption)
                        .foregroundStyle(RelayColors.textSecondary)
                }
                Spacer()
                Toggle("Enable quick access shortcut", isOn: Binding(get: { store.quickAccess.enabled }, set: { store.setQuickAccessEnabled($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            Divider().overlay(RelayTheme.line)

            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Include selected text in reply draft")
                        .font(RelayPageStyle.body.weight(.medium))
                        .foregroundStyle(RelayColors.textPrimary)
                    Text("When triggered, copies selected text into a draft with the source app name. Password fields are automatically excluded.")
                        .font(RelayPageStyle.caption)
                        .foregroundStyle(RelayColors.textSecondary)
                }
                Spacer()
                Toggle("Include selected text in reply draft", isOn: $store.selectionCaptureEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!store.quickAccess.enabled)
            }

            Text(store.quickAccess.status)
                .font(.relayMono)
                .foregroundStyle(RelayColors.textMuted)
            if let error = store.quickAccess.errorMessage {
                Text(error)
                    .font(RelayPageStyle.caption)
                    .foregroundStyle(RelayColors.accentCoral)
            }
            if store.selectionCaptureEnabled {
                Text(store.selectionStatus)
                    .font(RelayPageStyle.caption)
                    .foregroundStyle(RelayColors.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .relayFormSection()
    }

    private var memorySettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                SettingsSectionIcon(icon: "brain.head.profile")
                VStack(alignment: .leading, spacing: 4) {
                    Text("Local Memory & Preferences")
                        .font(RelayPageStyle.sectionTitle)
                        .foregroundStyle(RelayColors.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text("Add preferences for future conversations. Existing memories save as you edit; approve a new preference below to add it.")
                        .font(RelayPageStyle.caption)
                        .foregroundStyle(RelayColors.textSecondary)
                }
                Spacer()
            }

            if store.memories.isEmpty {
                note("No memories saved yet. Add standing preferences below.", icon: "square.stack.3d.up")
            }

            ForEach($store.memories) { $memory in
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(RelayColors.accentEmerald)
                    TextField("Approved memory", text: $memory.text, axis: .vertical)
                        .font(RelayPageStyle.body)
                        .foregroundStyle(RelayColors.textPrimary)
                        .textFieldStyle(.plain)
                        .onChange(of: memory.text) { _, _ in store.approvedMemoryEdited() }
                    Spacer()
                    RelayIconButton(
                        icon: "trash",
                        label: "Delete memory: \(memory.text)",
                        size: 30,
                        tint: RelayColors.textSecondary
                    ) {
                        store.deleteMemory(memory.id)
                    }
                }
                .padding(12)
                .background(RelayColors.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(RelayColors.borderSubtle, lineWidth: 1)
                )
            }

            VStack(alignment: .leading, spacing: 10) {
                TextField(
                    "",
                    text: $memoryText,
                    prompt: Text(""),
                    axis: .vertical
                )
                .lineLimit(2...4)
                .textFieldStyle(.plain)
                .font(RelayPageStyle.body)
                .relayTextFieldPrompt("e.g. Always format terminal commands in code blocks", when: memoryText.isEmpty, font: .relayBody)
                .foregroundStyle(RelayColors.textPrimary)
                .accessibilityLabel("New memory instruction")
                .padding(12)
                .background(RelayColors.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(RelayColors.borderDefault, lineWidth: 1)
                )

                HStack {
                    Text("Saved strictly on your Mac.")
                        .font(RelayPageStyle.caption)
                        .foregroundStyle(RelayColors.textMuted)
                    Spacer()
                    Button("Approve & remember") {
                        store.addMemory(memoryText.trimmingCharacters(in: .whitespacesAndNewlines))
                        memoryText = ""
                    }
                    .buttonStyle(RelayPrimaryButtonStyle())
                    .disabled(memoryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .relayFormSection()
    }

    // MARK: - Helpers

    private func sectionTitle(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(RelayPageStyle.title)
                .foregroundStyle(RelayColors.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(detail)
                .font(RelayPageStyle.body)
                .foregroundStyle(RelayColors.textSecondary)
                .lineSpacing(3)
        }
    }

    private func note(_ text: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(RelayPageStyle.symbol)
                .foregroundStyle(RelayColors.textSecondary)
                .padding(.top, 1)
            Text(text)
                .font(RelayPageStyle.caption)
                .foregroundStyle(RelayColors.textSecondary)
                .lineSpacing(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func saveAndRefresh() {
        store.saveConfiguration()
        Task { await store.refreshModels() }
    }

    private func deleteCatalogModel(_ manifest: ModelManifest) {
        let modelDirectory = URL.applicationSupportDirectory.appending(path: "Relay/Models", directoryHint: .isDirectory)
        let candidate = modelDirectory.appendingPathComponent(manifest.filename)
        modelDeletionError = nil
        do {
            try FileManager.default.removeItem(at: candidate)
            if store.configuration.modelPath == candidate.path {
                store.unloadModel()
                store.configuration.modelPath = ""
                store.saveConfiguration()
            }
            catalogRevision &+= 1
        } catch {
            modelDeletionError = "Could not delete \(manifest.displayName): \(error.localizedDescription) Your model selection was kept."
        }
    }

    private func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        accessibilityGranted = AXIsProcessTrustedWithOptions(options)
    }

    private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Workspace providers and installed models

private struct WorkspaceProviderDescriptor {
    let backend: LocalBackend
    let title: String
    let badge: String
    let icon: String
    let subtitle: String

    static let all: [WorkspaceProviderDescriptor] = [
        WorkspaceProviderDescriptor(
            backend: .liteRTLM,
            title: "On this Mac (Gemma 4)",
            badge: "Local GPU",
            icon: "cpu.fill",
            subtitle: "Runs on your Mac using Apple Silicon"
        ),
        WorkspaceProviderDescriptor(
            backend: .claudeCLI,
            title: "Claude Code CLI",
            badge: "CLI Session",
            icon: "sparkles",
            subtitle: "Uses your Claude Code sign-in"
        ),
        WorkspaceProviderDescriptor(
            backend: .codexCLI,
            title: "ChatGPT (Codex CLI)",
            badge: "CLI Session",
            icon: "terminal.fill",
            subtitle: "Uses your Codex sign-in"
        ),
        WorkspaceProviderDescriptor(
            backend: .lmStudio,
            title: "LM Studio",
            badge: "Local Server",
            icon: "server.rack",
            subtitle: "Connects to your local LM Studio server"
        ),
        WorkspaceProviderDescriptor(
            backend: .openRouter,
            title: "OpenRouter",
            badge: "Cloud API",
            icon: "network",
            subtitle: "Connects to cloud models using your OpenRouter key"
        ),
        WorkspaceProviderDescriptor(
            backend: .customResponses,
            title: "Responses API",
            badge: "Custom API",
            icon: "bolt.horizontal.circle.fill",
            subtitle: "Connects to a Responses API endpoint"
        )
    ]

    @MainActor
    func isConfigured(in store: AssistantStore) -> Bool {
        switch backend {
        case .liteRTLM:
            return !store.configuration.modelPath.isEmpty
                || ModelManifest.catalog.contains(where: { ModelManifest.resolveInstalledURL(for: $0) != nil })
        case .claudeCLI:
            return store.configuration.claudeCLI != nil
        case .codexCLI:
            return store.configuration.codexCLI != nil || store.workspaceUsesCodex || store.workspaceUsesCodexCLI
        case .lmStudio:
            return !(store.configuration.lmStudio?.modelID.isEmpty ?? true)
        case .openRouter:
            return !(store.configuration.openRouter?.modelID.isEmpty ?? true)
        case .customResponses:
            return !(store.configuration.customResponses?.modelID.isEmpty ?? true)
        }
    }

    @MainActor
    func statusHint(in store: AssistantStore, isSelected: Bool) -> String {
        if isSelected {
            if store.actionsReady {
                return "Active · Ready for chat & actions"
            }
            return "Selected · Configure below"
        }
        switch backend {
        case .liteRTLM:
            if let installed = ModelManifest.catalog.first(where: { ModelManifest.resolveInstalledURL(for: $0) != nil }) {
                return "\(installed.displayName) installed"
            }
            return "Local .litertlm engine"
        case .claudeCLI:
            return "Local Claude subscription"
        case .codexCLI:
            return "Local ChatGPT sign-in"
        case .lmStudio:
            if let model = store.configuration.lmStudio?.modelID, !model.isEmpty {
                return model
            }
            return "127.0.0.1:\(store.configuration.lmStudio?.endpoint.port ?? 1234)"
        case .openRouter:
            if let model = store.configuration.openRouter?.modelID, !model.isEmpty {
                return model
            }
            return "Keychain-scoped API key"
        case .customResponses:
            if let model = store.configuration.customResponses?.modelID, !model.isEmpty {
                return model
            }
            return "Loopback HTTP or remote HTTPS"
        }
    }
}

private struct WorkspaceProviderRow: View {
    let descriptor: WorkspaceProviderDescriptor
    let isSelected: Bool
    let isReady: Bool
    let statusHint: String
    let disabled: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: RelaySpace.sm) {
                Image(systemName: descriptor.icon)
                    .font(RelayPageStyle.symbol)
                    .foregroundStyle(isSelected ? RelayColors.workbenchAccent : RelayColors.textSecondary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: RelaySpace.xxs) {
                    Text(descriptor.title)
                        .font(RelayPageStyle.body.weight(.medium))
                        .foregroundStyle(RelayColors.textPrimary)
                    if isSelected {
                        Text(descriptor.subtitle)
                            .font(RelayPageStyle.caption)
                            .foregroundStyle(RelayColors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        RelayHealthDot(color: isReady ? RelayColors.accentEmerald : RelayColors.textMuted)
                        Text(statusHint)
                            .font(RelayPageStyle.caption)
                            .foregroundStyle(RelayColors.textSecondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: RelaySpace.sm)

                Image(systemName: "checkmark")
                    .font(RelayPageStyle.caption.weight(.medium))
                    .foregroundStyle(RelayColors.workbenchAccent)
                    .opacity(isSelected ? 1 : 0)
                    .accessibilityHidden(true)
                    .frame(width: 16)
            }
            .padding(.horizontal, RelaySpace.sm)
            .padding(.vertical, RelaySpace.xs)
            .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
            .background(isSelected ? RelayColors.activeFill : isHovered ? RelayColors.hoverFill : .clear,
                        in: RoundedRectangle(cornerRadius: RelayRadius.xs))
            .contentShape(Rectangle())
        }
        .buttonStyle(RelayPressStyle())
        .disabled(disabled)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(descriptor.title), \(descriptor.badge), \(statusHint)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("settings.provider.\(descriptor.backend.rawValue)")
    }
}

private struct OnDeviceCatalogModelCard: View {
    let manifest: ModelManifest
    let installedURL: URL?
    let isSelected: Bool
    let isReady: Bool
    let disabled: Bool
    let onSelect: () -> Void
    var onDelete: (() -> Void)? = nil

    @State private var downloader: ModelDownload
    @State private var isHovered = false
    @State private var showDeleteConfirmation = false

    init(
        manifest: ModelManifest,
        installedURL: URL?,
        isSelected: Bool,
        isReady: Bool,
        disabled: Bool,
        onSelect: @escaping () -> Void,
        onDelete: (() -> Void)? = nil
    ) {
        self.manifest = manifest
        self.installedURL = installedURL
        self.isSelected = isSelected
        self.isReady = isReady
        self.disabled = disabled
        self.onSelect = onSelect
        self.onDelete = onDelete
        self._downloader = State(initialValue: ModelDownload(manifest: manifest))
    }

    private var effectiveInstalledURL: URL? {
        installedURL ?? downloader.installedURL ?? ModelManifest.resolveInstalledURL(for: manifest)
    }

    private var isE4B: Bool { manifest == .gemma4E4B }

    private var parameterSpec: String {
        isE4B ? "4B Params · 3.66 GB" : "2B Params · 2.59 GB"
    }

    private var summaryText: String {
        isE4B
            ? "Larger local model for multi-step tasks. Check the model after loading to verify action support."
            : "Smaller local model for everyday requests. Uses less storage than E4B; action support is checked after loading."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 14) {
                SettingsSectionIcon(icon: isE4B ? "memorychip" : "cpu")

                VStack(alignment: .leading, spacing: 5) {
                    Text(manifest.displayName)
                        .font(RelayPageStyle.body.weight(.medium))
                        .foregroundStyle(RelayColors.textPrimary)
                    Text(parameterSpec)
                        .font(RelayPageStyle.caption)
                        .foregroundStyle(RelayColors.textSecondary)

                    Text(summaryText)
                        .font(RelayPageStyle.caption)
                        .foregroundStyle(RelayColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        RelayHealthDot(
                            color: isReady
                                ? RelayColors.accentEmerald
                                : (effectiveInstalledURL != nil ? RelayColors.accentGold : RelayColors.textMuted)
                        )
                        Text(
                            downloader.isBusy
                                ? downloader.status
                                : (effectiveInstalledURL != nil
                                    ? "Installed · \(manifest.filename)"
                                    : "Not downloaded · \(manifest.filename)")
                        )
                        .font(.relayMonoSmall)
                        .foregroundStyle(RelayColors.textMuted)
                        .lineLimit(1)
                    }
                }

                Spacer(minLength: 10)

                if downloader.isBusy {
                    Button(downloader.phase == .verifying ? "Cancel" : "Pause") {
                        downloader.cancel()
                    }
                    .buttonStyle(RelaySecondaryButtonStyle())
                    .accessibilityIdentifier("settings.model.cancelDownload.\(manifest.filename)")
                } else if effectiveInstalledURL != nil {
                    HStack(spacing: 8) {
                        if isReady {
                            RelayBadge("Active & Ready", icon: "checkmark.circle.fill", tint: RelayColors.accentEmerald, prominent: true)
                        } else if isSelected {
                            RelayBadge("Selected", icon: "checkmark.circle", tint: RelayColors.accentBlue, prominent: true)
                        } else {
                            Button("Use") {
                                onSelect()
                            }
                            .buttonStyle(RelaySecondaryButtonStyle())
                            .disabled(disabled)
                            .accessibilityLabel("Use " + manifest.displayName)
                        }

                        Menu {
                            Button("Verify SHA-256 Checksum", systemImage: "checkmark.shield") {
                                Task { await downloader.verifyExisting() }
                            }
                            .disabled(disabled || downloader.isBusy)

                            if onDelete != nil {
                                Divider()
                                Button("Delete Model Package…", systemImage: "trash", role: .destructive) {
                                    showDeleteConfirmation = true
                                }
                                .disabled(disabled || downloader.isBusy)
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(RelayColors.textSecondary)
                                .frame(width: 28, height: 28)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .accessibilityLabel("Manage " + manifest.displayName)
                    }
                } else {
                    Button(downloader.phase == .cancelled || downloader.phase == .failed ? "Resume Download" : "Download") {
                        downloader.start()
                    }
                    .buttonStyle(RelayPrimaryButtonStyle())
                    .disabled(disabled)
                    .accessibilityIdentifier("settings.model.download.\(manifest.filename)")
                }
            }

            if downloader.isBusy {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: downloader.progress, total: 1.0)
                        .tint(RelayColors.accentEmerald)
                    HStack {
                        Text(
                            "\(ByteCountFormatter.string(fromByteCount: downloader.receivedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: downloader.totalBytes, countStyle: .file))"
                        )
                        .font(.relayMonoSmall)
                        .foregroundStyle(RelayColors.textSecondary)
                        Spacer()
                        Text(downloader.progress, format: .percent.precision(.fractionLength(0)))
                            .font(.relayMonoSmall)
                            .foregroundStyle(RelayColors.textPrimary)
                    }
                }
            }

            if let errorMessage = downloader.errorMessage {
                Text(errorMessage)
                    .font(RelayPageStyle.caption)
                    .foregroundStyle(RelayColors.accentCoral)
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? RelayColors.surfaceElevated : (isHovered ? RelayColors.surface : RelayColors.cardBG))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isSelected
                        ? RelayColors.accentEmerald.opacity(0.6)
                        : (isHovered ? RelayColors.borderDefault : RelayColors.borderSubtle),
                    lineWidth: isSelected ? 1.5 : 1
                )
        )
        .onHover { isHovered = $0 }
        .confirmationDialog(
            "Delete \(manifest.displayName)?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete \(manifest.displayName)", role: .destructive) {
                downloader.cancel()
                onDelete?()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes \(manifest.filename) (\(ByteCountFormatter.string(fromByteCount: manifest.size, countStyle: .file))) from this Mac. You can re-download it anytime.")
        }
    }
}

private struct AppearanceModeOptionCard: View {
    let mode: RelayAppearanceMode
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    private var previewBackground: Color {
        switch mode {
        case .dark: return Color(red: 0.055, green: 0.068, blue: 0.075)
        case .light: return Color(red: 0.969, green: 0.977, blue: 0.976)
        case .system: return Color(red: 0.16, green: 0.20, blue: 0.20)
        }
    }

    private var previewCard: Color {
        switch mode {
        case .dark: return Color(red: 0.10, green: 0.125, blue: 0.13)
        case .light: return Color.white
        case .system: return Color(red: 0.23, green: 0.28, blue: 0.28)
        }
    }

    private var previewInk: Color {
        switch mode {
        case .dark, .system: return Color(white: 0.94)
        case .light: return Color(white: 0.12)
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(previewBackground)
                        .frame(height: 54)
                        .overlay(
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 4) {
                                    Circle().fill(RelayColors.textPrimary).frame(width: 6, height: 6)
                                    Capsule().fill(previewInk.opacity(0.65)).frame(width: 48, height: 5)
                                    Spacer()
                                }
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(previewCard)
                                    .frame(height: 22)
                            }
                            .padding(8)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(RelayColors.borderSubtle, lineWidth: 1)
                        )
                }

                HStack(spacing: 6) {
                    Image(systemName: mode.iconName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isSelected ? RelayColors.textPrimary : RelayColors.textSecondary)
                    Text(mode.displayName)
                        .font(RelayPageStyle.body.weight(.medium))
                        .foregroundStyle(RelayColors.textPrimary)
                    Spacer()
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(isSelected ? RelayColors.textPrimary : RelayColors.textMuted)
                }

                Text(mode.subtitle)
                    .font(RelayPageStyle.caption)
                    .foregroundStyle(RelayColors.textSecondary)
                    .lineLimit(1)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? RelayColors.surfaceElevated : (isHovered ? RelayColors.surface : RelayColors.cardBG))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? RelayColors.borderStrong : RelayColors.borderSubtle, lineWidth: isSelected ? 1.5 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(RelayPressStyle())
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(mode.displayName) appearance, \(mode.subtitle)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SettingsSidebarTabButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(RelayPageStyle.symbol)
                    .foregroundStyle(isSelected ? RelayColors.textPrimary : (isHovered ? RelayColors.textPrimary : RelayColors.textSecondary))
                    .frame(width: 20)
                Text(title)
                    .font(RelayPageStyle.body.weight(isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? RelayColors.textPrimary : (isHovered ? RelayColors.textBright : RelayColors.textSecondary))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? RelayColors.workbenchTint : (isHovered ? RelayColors.hoverFill : .clear))
            )
            .overlay(alignment: .leading) {
                if isSelected {
                    Capsule().fill(RelayColors.workbenchAccent).frame(width: 2, height: 16)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(RelayPressStyle())
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SettingsSectionIcon: View {
    let icon: String

    private var outlineSymbol: String {
        switch icon {
        case "cpu.fill": "cpu"
        case "folder.fill": "folder"
        case "hand.raised.fill": "hand.raised"
        case "books.vertical.fill": "books.vertical"
        case "sparkles.rectangle.stack.fill": "rectangle.stack"
        case "trash.slash.fill": "trash"
        case "text.bubble.fill": "text.bubble"
        case "command.square.fill": "command"
        default: icon
        }
    }

    var body: some View {
        Image(systemName: outlineSymbol)
            .font(RelayPageStyle.symbol)
            .foregroundStyle(RelayColors.textSecondary)
            .frame(width: 24, height: 24)
            .accessibilityHidden(true)
    }
}
