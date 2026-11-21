import SwiftUI
import AppKit
import ApplicationServices
import CoreGraphics
import UniformTypeIdentifiers

struct MainView: View {
    @Bindable var store: AssistantStore
    var onboarding: OnboardingCoordinator? = nil
    var onOpenSetup: (() -> Void)? = nil

    private enum SettingsDestination: String, Identifiable {
        case general = "General"
        case model = "Model"
        case access = "Access"
        case sources = "Sources"
        case knowledge = "Knowledge"
        var id: String { rawValue }
    }

    enum WorkspacePage: String {
        case workspace = "Workspace"
        case knowledge = "Knowledge"
    }

    @State private var workspaceWindow = WorkspaceWindowReference()
    @State private var computerAccessReady = AXIsProcessTrusted()
    @State private var screenCaptureReady = CGPreflightScreenCaptureAccess()
    @State private var viewportWidth: CGFloat = 1200
    @State private var workspacePageValue: WorkspacePage = .workspace
    @State private var knowledgeNavigationGuard = KnowledgeNavigationGuard()

    private var workspacePage: WorkspacePage {
        get { workspacePageValue }
        nonmutating set {
            let destination = newValue
            if workspacePageValue == .knowledge && destination != .knowledge {
                knowledgeNavigationGuard.request { workspacePageValue = destination }
            } else {
                workspacePageValue = destination
            }
        }
    }

    private func requestKnowledgeDeparture(_ action: @escaping @MainActor () -> Void) {
        if workspacePageValue == .knowledge { knowledgeNavigationGuard.request(action) }
        else { action() }
    }

    private func startNewWorkspaceThread() {
        requestKnowledgeDeparture {
            guard !store.isRunning, !store.isClearingConversation else { return }
            currentTurnsExpanded = false
            store.startNewThread()
            workspacePageValue = .workspace
            composerFocused = true
        }
    }

    private func selectWorkspaceThread(_ id: UUID) {
        requestKnowledgeDeparture {
            guard store.selectThread(id) else { return }
            currentTurnsExpanded = false
            workspacePageValue = .workspace
            atLatest = true
        }
    }
    @AppStorage("relay.workspace.canvas.historyVisible") private var showLeftSidebar = false
    @State private var showCompactSidebar = false
    @State private var historySearchQuery = ""
    @State private var currentTurnsExpanded = false
    @State private var showVoiceInput = false
    @State private var showAttachPopover = false
    @State private var showComposerModelPopover = false
    @State private var showMorningBrief = false
    @State private var showConversationSearch = false
    @State private var showCommandPalette = false
    @State private var knowledgeNoteDestination: KnowledgeNoteDestination?
    @State private var keyEventMonitor: Any?
    @State private var quoteMessage: ChatMessage?
    @State private var conversationJump: ChatMessage.ID?
    @State private var settingsDestination: SettingsDestination?
    @State private var atLatest = true
    @State private var userScrollInProgress = false
    @State private var latestGeometryNearBottom = true
    @State private var hoverHeaderMenu = false
    @State private var hoverSummarize = false
    @State private var showInlineImageImporter = false
    @State private var showImageInspectionSheet = false
    @State private var showClearHistoryConfirm = false
    @State private var showConversationTrash = false
    @State private var showClearConversationConfirm = false
    @State private var isComposerDropTargeted = false
    @State private var hoveredStarterSuggestion: String?
    @State private var selectedHomeFeaturePreview: HomeFeaturePreviewKind? = nil
    @State private var showcaseConstellationNoteIndex: Int = 0
    @AppStorage(RelayAppearanceMode.storageKey) private var appearanceModeRaw: String = RelayAppearanceMode.dark.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var composerFocused: Bool

    enum HomeFeaturePreviewKind: String, CaseIterable, Identifiable {
        case doubleTap
        case proactive
        case knowledge
        case sidekick

        var id: String { rawValue }

        var title: String {
            switch self {
            case .doubleTap: "Instant Draft · Right ⌘ × 2"
            case .proactive: "Morning Brief"
            case .knowledge: "Memory Graph"
            case .sidekick: "Desktop Autopilot"
            }
        }

        var subtitle: String {
            switch self {
            case .doubleTap: "Draft replies in any app."
            case .proactive: "Daily brief & follow-ups."
            case .knowledge: "Local notes in Markdown."
            case .sidekick: "Reviewed app automation."
            }
        }

        var icon: String {
            switch self {
            case .doubleTap: "command"
            case .proactive: "sun.horizon.fill"
            case .knowledge: "point.3.connected.trianglepath.dotted"
            case .sidekick: "cursorarrow.motionlines"
            }
        }
    }

    typealias ProseBlock = TranscriptMarkdownSegment.ProseBlock

    static func parseProseBlocks(_ proseText: String) -> [ProseBlock] {
        TranscriptMarkdownSegment.parseProseBlocks(proseText)
    }

    private let leftSidebarWidth: CGFloat = 240
    private let workspaceColumnWidth: CGFloat = 720

    private var currentAppearanceMode: RelayAppearanceMode {
        RelayAppearanceMode.fromStored(appearanceModeRaw)
    }

    private var showsLeftSidebarColumn: Bool {
        workspacePage == .workspace && showLeftSidebar && viewportWidth >= 860
    }

    private var compactComposerToolbar: Bool {
        viewportWidth < 1000
    }

    private var horizontalWorkspacePadding: CGFloat {
        viewportWidth >= 1280 ? 32 : 24
    }

    private var isUserTaskActive: Bool {
        [.thinking, .acting, .awaitingReview].contains(store.phase) || store.accessibilityCheckRunning || store.isAuxiliaryBusy
    }

    var body: some View {
        ZStack {
            RelayWorkspaceBackdrop().ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                        computerAccessReady = AXIsProcessTrusted()
                        screenCaptureReady = CGPreflightScreenCaptureAccess()
                    }
                    .onChange(of: settingsDestination) { _, _ in
                        computerAccessReady = AXIsProcessTrusted()
                        screenCaptureReady = CGPreflightScreenCaptureAccess()
                    }

                switch workspacePage {
                case .workspace:
                    HStack(spacing: 0) {
                        if showsLeftSidebarColumn {
                            leftSidebar
                                .frame(width: leftSidebarWidth)
                                .relayWorkspaceSidebarSurface()
                        }

                        VStack(spacing: 0) {
                            if let error = store.errorMessage { errorBanner(error) }
                            if let error = store.speech.errorMessage {
                                errorBanner("Read aloud: " + error, dismiss: { store.speech.errorMessage = nil })
                            }
                            if let notice = store.selectionNotice {
                                HStack(spacing: 12) {
                                    if notice.hasPrefix("Select calendars again") {
                                        DisclosureGroup {
                                            Text(notice).font(.relayCaption).textSelection(.enabled).padding(.top, 6)
                                        } label: {
                                            Text("Choose calendars again to use calendar context").font(.relayCallout.weight(.medium))
                                        }
                                        .disclosureGroupStyle(RelayDisclosureGroupStyle(accent: RelayColors.accentGold))
                                        Spacer()
                                        Button("Choose calendars") { settingsDestination = .sources }
                                            .buttonStyle(RelaySecondaryButtonStyle())
                                    } else {
                                        Text(notice).font(.relayCaption).textSelection(.enabled)
                                        Spacer()
                                    }
                                    RelayIconButton(icon: "xmark", label: "Dismiss selected-text notice", size: 32, iconSize: 11) {
                                        store.selectionNotice = nil
                                    }
                                }
                                .frame(maxWidth: workspaceColumnWidth)
                                .padding(.horizontal, horizontalWorkspacePadding)
                                .padding(.vertical, 10)
                                .frame(maxWidth: .infinity)
                            }

                            if store.messages.isEmpty {
                                GeometryReader { geometry in
                                    ScrollView {
                                        VStack(spacing: 12) {
                                            welcome
                                                .frame(maxWidth: workspaceColumnWidth, alignment: .leading)
                                                .padding(.horizontal, horizontalWorkspacePadding)
                                                .frame(maxWidth: .infinity)
                                            conversationDock
                                            WorkspaceDraftSuggestions(onStartDraft: fillExample)
                                                .frame(maxWidth: workspaceColumnWidth, alignment: .leading)
                                                .padding(.horizontal, horizontalWorkspacePadding)
                                                .frame(maxWidth: .infinity)
                                        }
                                        .padding(.top, max(28, geometry.size.height * 0.19))
                                        .padding(.bottom, 24)
                                        .frame(maxWidth: .infinity)
                                    }
                                }
                            } else {
                                conversation
                                conversationDock
                            }
                        }
                    }

                case .knowledge:
                    KnowledgeView(
                        store: store,
                        startInConstellation: false,
                        requestedNote: knowledgeNoteDestination,
                        navigationGuard: knowledgeNavigationGuard,
                        onOpenWorkspace: {
                            workspacePage = .workspace
                            composerFocused = true
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(WorkspaceWindowProbe(reference: workspaceWindow).frame(width: 0, height: 0))
        .disclosureGroupStyle(RelayDisclosureGroupStyle())
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
        .onChange(of: workspacePage) { _, page in
            if page != .workspace {
                composerFocused = false
                userScrollInProgress = false
                showAttachPopover = false
                showComposerModelPopover = false
            }
        }
        .onChange(of: store.pendingReview?.id) { _, reviewID in
            if reviewID != nil {
                store.showActivity = false
                workspacePage = .workspace
            }
        }
        .onChange(of: viewportWidth) { _, width in
            if width >= 860 { showCompactSidebar = false }
        }
        .onChange(of: store.activeThreadID) { _, _ in
            currentTurnsExpanded = false
            atLatest = true
            userScrollInProgress = false
            latestGeometryNearBottom = true
            showCompactSidebar = false
        }
        .sheet(isPresented: $store.showActivity) {
            activityPanel
                .frame(width: 600, height: 560)
                .background(RelayColors.canvas)
                .relayPreferredAppearance()
        }
        .tint(RelayColors.workbenchAccent)
        .foregroundStyle(RelayTheme.ink)
        .relayPreferredAppearance()
        .onReceive(NotificationCenter.default.publisher(for: .relayOpenMorningBrief)) { _ in
            if !store.isRunning && store.pendingReview == nil {
                showMorningBrief = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .relayOpenKnowledgeVault)) { _ in
            if store.pendingReview == nil {
                composerFocused = false
                _ = workspaceWindow.resignForNavigation()
                workspacePage = .knowledge
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("relay.newThread"))) { _ in
            guard workspaceWindow.window?.isMainWindow == true else { return }
            startNewWorkspaceThread()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("relay.switchToWorkspace"))) { _ in
            workspacePage = .workspace
            composerFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("relay.openCommandPalette"))) { _ in
            composerFocused = false
            showCommandPalette = true
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("relay.toggleSidebar"))) { _ in
            if workspacePage != .workspace {
                workspacePage = .workspace
            }
            toggleSidebar()
        }
        .sheet(isPresented: $showCommandPalette) {
            CommandPaletteView(
                store: store,
                onNewChat: {
                    showCommandPalette = false
                    startNewWorkspaceThread()
                },
                onMorningBrief: {
                    showCommandPalette = false
                    guard !store.isRunning, store.pendingReview == nil else { return }
                    showMorningBrief = true
                },
                onSummarizeDocument: {
                    showCommandPalette = false
                    triggerOneClickSummarize()
                },
                onToggleSidebar: {
                    showCommandPalette = false
                    if workspacePage != .workspace { workspacePage = .workspace }
                    toggleSidebar()
                },
                onOpenKnowledgeVault: {
                    showCommandPalette = false
                    guard store.pendingReview == nil else { return }
                    composerFocused = false
                    _ = workspaceWindow.resignForNavigation()
                    workspacePage = .knowledge
                },
                onOpenSettings: {
                    showCommandPalette = false
                    settingsDestination = .general
                },
                onOpenSetup: {
                    openSetupAndOnboardingTour()
                },
                onSelectThread: { threadID in
                    showCommandPalette = false
                    selectWorkspaceThread(threadID)
                },
                onSelectNote: { note in
                    showCommandPalette = false
                    guard store.pendingReview == nil else { return }
                    composerFocused = false
                    knowledgeNoteDestination = KnowledgeNoteDestination(note: note)
                    _ = workspaceWindow.resignForNavigation()
                    workspacePage = .knowledge
                }
            )
            .relayPreferredAppearance()
        }
        .sheet(item: $settingsDestination) { destination in
            SettingsView(store: store, onboarding: onboarding, onOpenSetup: { openSetupAndOnboardingTour() }, initialSection: destination.rawValue)
                .relayPreferredAppearance()
        }
        .sheet(isPresented: $showVoiceInput) {
            VoiceInputView(store: store)
                .relayPreferredAppearance()
        }
        .sheet(isPresented: $showMorningBrief) {
            MorningBriefView(store: store) { workspacePage = .workspace }
                .relayPreferredAppearance()
        }
        .sheet(isPresented: $showImageInspectionSheet) {
            ImageInspectionView(store: store)
                .relayPreferredAppearance()
        }
        .confirmationDialog(
            "Move all conversations to Trash?",
            isPresented: $showClearHistoryConfirm,
            titleVisibility: .visible
        ) {
            Button("Move all to Trash", role: .destructive) {
                store.clearThreadHistory()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Conversations leave History and stay in Trash until you restore them. This does not undo actions taken in those conversations.")
        }
        .confirmationDialog(
            "Clear this conversation?",
            isPresented: $showClearConversationConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear conversation", role: .destructive) {
                store.clearConversation()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears the active conversation transcript and resets the current task context.")
        }
        .sheet(isPresented: $showConversationTrash) {
            ConversationTrashView(store: store)
                .relayPreferredAppearance()
        }
        .sheet(isPresented: $showConversationSearch) {
            ConversationSearchView(messages: store.messages) { message in
                atLatest = false
                conversationJump = message.id
                showConversationSearch = false
            }
            .relayPreferredAppearance()
        }
        .sheet(item: $quoteMessage) { message in
            ConversationQuoteSheet(message: message) { range in
                let accepted = await store.prepareConversationReply(to: message.id, selectedRange: range)
                if accepted { workspacePage = .workspace; composerFocused = true }
                return accepted
            }
            .relayPreferredAppearance()
        }
        .onChange(of: store.showImageInspection) { _, show in
            if show {
                workspacePage = .workspace
                composerFocused = true
            }
        }
        .fileImporter(isPresented: $showInlineImageImporter, allowedContentTypes: [.image], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let files):
                if let file = files.first {
                    store.showImageInspection = true
                    store.imageInspection.loadFile(file)
                    composerFocused = true
                }
            case .failure(let error):
                store.errorMessage = error.localizedDescription
            }
        }
        .onAppear {
            if !store.messages.isEmpty {
                store.syncActiveThreadSnapshot()
            }
            if keyEventMonitor == nil {
                keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    handleLocalKeyDown(event)
                }
            }
        }
        .onDisappear {
            if let monitor = keyEventMonitor {
                NSEvent.removeMonitor(monitor)
                keyEventMonitor = nil
            }
        }
        .task {
            await store.preparation.waitForCurrentPreparation()
            guard !Task.isCancelled, !store.workspaceActionsReady else { return }
            let needsCatalogFallback = store.configuration.modelPath.isEmpty
                || (store.configuration.backend == .lmStudio && !store.configuration.hasConfiguredInferenceModel)
            if needsCatalogFallback,
               let installed = ModelManifest.catalog.first(where: { ModelManifest.resolveInstalledURL(for: $0) != nil }) {
                store.selectLocalProvider(.liteRTLM)
                await store.selectCatalogModel(installed)
            } else {
                await store.refreshModels()
            }
        }
    }

    private var activeModelDisplayName: String {
        if store.workspaceUsesClaude { return "Claude (\(store.claudeConfiguration.displayModelName))" }
        if store.workspaceUsesCodex || store.workspaceUsesCodexCLI { return "ChatGPT via Codex CLI" }
        if store.configuration.backend != .liteRTLM {
            if !store.configuration.hasConfiguredInferenceModel,
               let installed = ModelManifest.catalog.first(where: { ModelManifest.resolveInstalledURL(for: $0) != nil }) {
                return installed.displayName
            }
            return store.configuration.localModelDisplayName
        }
        let filename = URL(fileURLWithPath: store.configuration.modelPath).lastPathComponent
        if let match = ModelManifest.catalog.first(where: { $0.filename == filename }) {
            return match.displayName
        }
        if !filename.isEmpty {
            return filename.replacingOccurrences(of: ".litertlm", with: "")
        }
        return "Gemma 4"
    }

    // MARK: - Workspace header

    private var header: some View {
        HStack(spacing: 6) {
            if workspacePage == .workspace {
                WorkspaceHeaderButton(
                    title: (viewportWidth < 860 ? showCompactSidebar : showLeftSidebar) ? "Hide history" : "Show history",
                    icon: "sidebar.left",
                    selected: viewportWidth < 860 ? showCompactSidebar : showLeftSidebar,
                    iconOnly: true
                ) { toggleSidebar() }
                .popover(isPresented: $showCompactSidebar, arrowEdge: .bottom) {
                    leftSidebar
                        .frame(width: 280, height: 480)
                        .relayWorkspaceSidebarSurface()
                        .relayPreferredAppearance()
                }
                .accessibilityIdentifier("workspace.sidebarToggle")
                .accessibilityValue((viewportWidth < 860 ? showCompactSidebar : showLeftSidebar) ? "Shown" : "Hidden")

                WorkspaceHeaderButton(title: "New chat", icon: "square.and.pencil", iconOnly: true) {
                    startNewWorkspaceThread()
                }
                .disabled(store.isRunning || store.isClearingConversation)
                .accessibilityIdentifier("workspace.newThreadHeader")
                Text("Relay")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(RelayColors.textSecondary)
                    .padding(.leading, 5)
            } else {
                WorkspaceHeaderButton(title: "Back to chat", icon: "arrow.left", iconOnly: false) {
                    workspacePage = .workspace
                }
            }

            Spacer(minLength: 12)

            if store.isPreparingModel || isUserTaskActive || store.pendingReview != nil || store.voice.isBusy || store.speech.isActive || store.knowledgeSearch.isBusy || store.speechDiagnostic.isBusy {
                WorkspaceHeaderButton(title: "Stop", icon: "stop.fill") { store.stop() }
                    .help("Stop current actions (⌘.)")
            }
            if workspacePage == .workspace { composerModelPicker }

            WorkspaceHeaderButton(title: "Search", icon: "magnifyingglass", selected: showCommandPalette, iconOnly: true) {
                composerFocused = false
                showCommandPalette = true
            }
            .help("Search Relay (⌘K)")
            .accessibilityIdentifier("workspace.commandPalette")

            WorkspaceHeaderButton(title: "Morning Brief", icon: "sun.horizon", iconOnly: viewportWidth < 1100) {
                showMorningBrief = true
            }
            .disabled(store.isRunning || store.pendingReview != nil)
            .accessibilityIdentifier("workspace.morningBrief")

            WorkspaceHeaderButton(title: "Knowledge", icon: "books.vertical", selected: workspacePage == .knowledge, iconOnly: viewportWidth < 1100) {
                openKnowledgeWorkspace()
            }
            .disabled(store.pendingReview != nil)
            workspaceMenu
        }
        .padding(.leading, 88)
        .padding(.trailing, 14)
        .frame(height: 44)
        .background {
            Color.clear.contentShape(Rectangle()).gesture(WindowDragGesture())
        }
    }

    private var workspaceMenu: some View {
        Menu {
            Button("Open Settings…", systemImage: "gearshape") { settingsDestination = .general }
            Menu("Appearance", systemImage: "circle.lefthalf.filled") {
                ForEach(RelayAppearanceMode.allCases) { mode in
                    Button {
                        appearanceModeRaw = mode.rawValue
                        RelayThemeManager.shared.setMode(mode)
                    } label: {
                        Label(mode.displayName, systemImage: currentAppearanceMode == mode ? "checkmark" : mode.iconName)
                    }
                }
            }
            Button("Run Setup Assistant…", systemImage: "sparkles") { openSetupAndOnboardingTour() }
            if workspacePage == .workspace && !store.messages.isEmpty {
                Divider()
                Button("Find in conversation…", systemImage: "magnifyingglass") {
                    composerFocused = false
                    showConversationSearch = true
                }
                .keyboardShortcut("f", modifiers: .command)
                if currentThreadUserTurns.count > 1 {
                    Menu("Messages in this chat", systemImage: "text.bubble") {
                        ForEach(Array(currentThreadUserTurns.enumerated()), id: \.element.id) { index, turn in
                            Button("\(index + 1). \(String(turn.text.prefix(60)))") {
                                atLatest = false
                                conversationJump = turn.id
                            }
                        }
                    }
                }
                Button("Show activity…", systemImage: "list.bullet") { store.showActivity = true }
                    .disabled(store.pendingReview != nil)
                Button("Copy conversation as Markdown", systemImage: "doc.on.doc") {
                    copyThreadAsMarkdown(messages: store.messages, activity: store.activity)
                }
                Button("Export conversation…", systemImage: "square.and.arrow.up") {
                    exportThreadAsMarkdown(messages: store.messages, activity: store.activity,
                        title: store.threadArchive.thread(for: store.activeThreadID)?.title)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                Divider()
                Button("Clear conversation…", systemImage: "trash", role: .destructive) { showClearConversationConfirm = true }
                    .disabled(store.isRunning || store.isClearingConversation)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(RelayColors.textSecondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Workspace menu")
        .accessibilityIdentifier("workspace.menu")
        .tint(RelayColors.textSecondary)
        .help("Settings and workspace actions")
    }

    private func toggleSidebar() {
        if viewportWidth < 860 {
            showCompactSidebar.toggle()
        } else {
            showLeftSidebar.toggle()
        }
    }

    private func openSetupAndOnboardingTour() {
        showCommandPalette = false
        settingsDestination = nil
        requestKnowledgeDeparture {
            if let onOpenSetup {
                onOpenSetup()
            } else {
                store.stop()
                onboarding?.returnToSetup()
            }
        }
    }

    private static let starterPromptSuggestions = [
        "What can you do on my Mac?",
        "Summarize active window",
        "Draft a reply in my voice"
    ]

    private func openKnowledgeWorkspace() {
        guard workspacePage != .knowledge else { return }
        composerFocused = false
        guard workspaceWindow.resignForNavigation() else { return }
        workspacePage = .knowledge
    }

    private var welcome: some View {
        WorkspaceStartView(
            modelReady: store.workspaceActionsReady,
            modelName: activeModelDisplayName,
            computerAccessReady: computerAccessReady,
            onChooseModel: { settingsDestination = .model },
            onChooseAccess: { settingsDestination = .access },
            onStartDraft: fillExample,
            onOpenKnowledge: openKnowledgeWorkspace,
            onOpenBrief: { showMorningBrief = true }
        )
    }

    private var homeFeatureShowcaseDeck: some View {
        RelayHomeFeatureShowcaseDeck(
            selectedPreview: $selectedHomeFeaturePreview,
            selectedConstellationNoteIndex: $showcaseConstellationNoteIndex,
            onConfigureDoubleTap: { settingsDestination = .general },
            onOpenMorningBrief: { showMorningBrief = true },
            onOpenKnowledgeVault: { workspacePage = .knowledge },
            onTrySidekickPrompt: {
                selectedHomeFeaturePreview = nil
                fillExample("Prep me for my next meeting using my calendar and notes")
            }
        )
    }

    private func homeSetupPill(title: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Circle()
                    .fill(RelayColors.accentAmber)
                    .frame(width: 6, height: 6)
                Text(title)
                    .font(.relayCaptionStrong)
                    .foregroundStyle(RelayColors.textBright)
                Image(systemName: "arrow.right")
                    .font(.relayMicro)
                    .foregroundStyle(RelayColors.textSecondary)
            }
            .padding(.horizontal, 12)
            .frame(height: RelayControlHeight.pill)
            .background(RelayColors.cardBG, in: Capsule())
            .overlay(Capsule().strokeBorder(RelayColors.borderDefault, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(RelayPressStyle())
        .accessibilityIdentifier(identifier)
    }

    private func fillExample(_ prompt: String) {
        store.draft = prompt
        composerFocused = true
    }

    // MARK: - Conversation Stream

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(store.messages) { message in
                        messageRow(message)
                            .id(message.id)
                            .accessibilityElement(children: .contain)
                    }

                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: workspaceColumnWidth)
                .padding(.horizontal, horizontalWorkspacePadding)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.visible)
            .onAppear {
                if atLatest && !store.messages.isEmpty { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .defaultScrollAnchor(atLatest ? .bottom : nil, for: .initialOffset)
            .defaultScrollAnchor(atLatest ? .bottom : nil, for: .sizeChanges)
            .overlay(alignment: .bottom) {
                if !atLatest && !latestGeometryNearBottom && !store.messages.isEmpty {
                    Button {
                        proxy.scrollTo("bottom", anchor: .bottom)
                        atLatest = true
                    } label: {
                        Label("Latest message", systemImage: "arrow.down")
                            .font(.relayCallout.weight(.medium))
                            .padding(.horizontal, 13).padding(.vertical, 7)
                            .background(RelayTheme.surfaceElevated, in: Capsule())
                            .overlay(Capsule().strokeBorder(RelayTheme.line, lineWidth: 1))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(RelayPressStyle()).padding(.bottom, 8)
                }
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.visibleRect.maxY < 70
            } action: { _, value in
                latestGeometryNearBottom = value
                if userScrollInProgress { atLatest = value }
            }
            .onScrollPhaseChange { _, phase in
                if phase == .tracking || phase == .interacting || phase == .decelerating {
                    userScrollInProgress = true
                } else if phase == .idle && userScrollInProgress {
                    atLatest = latestGeometryNearBottom
                    userScrollInProgress = false
                }
            }
            .onChange(of: store.activeThreadID) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: conversationJump) { _, target in
                guard let target else { return }
                proxy.scrollTo(target, anchor: .center)
                conversationJump = nil
            }
            .onChange(of: store.messages.count) { _, _ in
                if atLatest || store.messages.last?.role == "user" {
                    proxy.scrollTo("bottom", anchor: .bottom)
                    atLatest = true
                }
            }
            .onChange(of: store.isRunning) { _, _ in
                if atLatest { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: store.pendingReview != nil) { _, _ in
                Task { @MainActor in
                    await Task.yield()
                    proxy.scrollTo("bottom", anchor: .bottom)
                    atLatest = true
                }
            }
            .onChange(of: store.showActivity) { _, _ in
                if atLatest {
                    Task { @MainActor in
                        await Task.yield()
                        proxy.scrollTo("bottom", anchor: .bottom)
                        atLatest = true
                    }
                }
            }
        }
    }

    private var inFlightStatus: some View {
        let currentStep = store.currentPlanProgress.first {
            $0.state == .running || $0.state == .reconciling || $0.state == .waitingForReview
        }
        return WorkspaceTaskStrip(
            status: store.isPreparingModel ? "Preparing your model…" : WorkspaceTaskPresentation(phase: store.phase).status,
            detail: currentStep?.title,
            isWorking: store.isRunning,
            inspect: { if store.pendingReview == nil { store.showActivity = true } }
        )
    }

    private func openSavedResponseNote(_ note: LocalMarkdownNote) {
        guard store.pendingReview == nil else { return }
        composerFocused = false
        guard workspaceWindow.resignForNavigation() else { return }
        requestKnowledgeDeparture {
            knowledgeNoteDestination = KnowledgeNoteDestination(note: note)
            workspacePageValue = .knowledge
        }
    }

    private func messageRow(_ message: ChatMessage) -> some View {
        let parsed = extractRoleAndContent(from: message.text, defaultRole: message.role)
        return TranscriptMessageRow(
            store: store,
            message: message,
            parsedRole: parsed.role,
            cleanText: parsed.cleanText,
            onJumpToReply: {
                guard let reference = message.reply else { return }
                atLatest = false
                conversationJump = AssistantConversationHistory.messageID(reference.eventID)
            },
            onReply: { target in
                Task { @MainActor in
                    if await store.prepareConversationReply(to: target.id) {
                        workspacePage = .workspace
                        composerFocused = true
                    }
                }
            },
            onQuote: { target in
                quoteMessage = target
            },
            onCopy: { target in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(target.text, forType: .string)
            },
            onEdit: { target in
                if store.editUserMessageAndBranch(id: target.id, newText: target.text, autoSubmit: false) {
                    workspacePage = .workspace
                    composerFocused = true
                }
            },
            onOpenSavedNote: openSavedResponseNote,
            onRegenerate: { target in
                if store.regenerateAssistantMessage(id: target.id) {
                    workspacePage = .workspace
                    if !store.workspaceActionsReady {
                        composerFocused = true
                    }
                }
            }
        )
    }

    private func handleLocalKeyDown(_ event: NSEvent) -> NSEvent? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if flags == [.command] && key == "v" {
            if composerFocused && workspacePage == .workspace && !showCommandPalette {
                let hasNoPlainString = NSPasteboard.general.string(forType: .string)?
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
                if hasNoPlainString && store.pasteClipboardImageIfAvailable() {
                    return nil
                }
            }
        } else if flags == [.command] && key == "k" {
            composerFocused = false
            showCommandPalette.toggle()
            return nil
        } else if flags == [.command, .shift] && key == "s" {
            if workspacePage != .workspace {
                workspacePage = .workspace
            }
            toggleSidebar()
            return nil
        } else if flags == [.command, .shift] && key == "m" {
            if workspacePage == .workspace {
                showComposerModelPopover.toggle()
                return nil
            }
        } else if flags == [.command] && key == "f" {
            if workspacePage == .workspace && !store.messages.isEmpty && !showCommandPalette {
                composerFocused = false
                showConversationSearch = true
                return nil
            }
        } else if flags == [.command, .shift] && key == "e" {
            if workspacePage == .workspace && !store.messages.isEmpty {
                exportThreadAsMarkdown(
                    messages: store.messages,
                    activity: store.activity,
                    title: store.threadArchive.thread(for: store.activeThreadID)?.title
                )
                return nil
            }
        }
        return event
    }

    private func copyThreadAsMarkdown(messages: [ChatMessage], activity: [ActivityEntry]) {
        do {
            let data = try ConversationExport.data(
                messages: messages,
                activity: activity,
                includeActivity: false,
                format: .markdown
            )
            if let markdown = String(data: data, encoding: .utf8) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(markdown, forType: .string)
                store.selectionNotice = "Copied thread to clipboard as Markdown."
            }
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }

    private func exportThreadAsMarkdown(messages: [ChatMessage], activity: [ActivityEntry], title: String? = nil) {
        do {
            let data = try ConversationExport.data(
                messages: messages,
                activity: activity,
                includeActivity: !activity.isEmpty,
                format: .markdown
            )
            let panel = NSSavePanel()
            panel.title = "Export Thread as Markdown"
            panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
            let rawTitle = (title ?? SavedConversationThread.makeTitle(from: messages))
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            panel.nameFieldStringValue = (rawTitle.isEmpty ? "Relay Conversation" : rawTitle) + ".md"
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            try LocalPrivateFileWriter.write(
                data: data,
                to: destination,
                maximumBytes: ConversationExport.maximumOutputBytes
            )
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }

    private func extractRoleAndContent(from text: String, defaultRole: String) -> (role: String?, cleanText: String) {
        let knownRoles = ["Planner", "Navigator", "Executor", "Critic", "Verifier"]
        for role in knownRoles {
            let prefix = "[\(role)]"
            if text.hasPrefix(prefix) {
                let clean = text.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
                return (role, clean)
            }
        }
        if ["planner", "navigator", "executor", "critic"].contains(defaultRole.lowercased()) {
            return (defaultRole.capitalized, text)
        }
        return (nil, text)
    }

    // MARK: - Conversation dock

    private var conversationDock: some View {
        VStack(spacing: 8) {
            if store.speech.isActive {
                HStack(spacing: 8) {
                    Image(systemName: "speaker.wave.2")
                    Text(store.speech.isSpeaking ? "Reading selected response aloud…" : "Preparing response audio…")
                        .font(.relayCallout)
                    Spacer()
                    Button("Stop audio") { store.speech.stop() }.buttonStyle(RelaySecondaryButtonStyle())
                }
                .foregroundStyle(RelayColors.textPrimary)
            }

            if store.isRunning && store.pendingReview == nil {
                inFlightStatus
            }

            if let review = store.pendingReview { reviewCard(review) }

            if store.phase == .needsInput || store.phase == .stopped || store.phase == .failed {
                taskRecoveryCard
            }

            if let notice = store.historyNotice {
                Text(notice)
                    .font(.relayCaption)
                    .foregroundStyle(RelayTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("conversation.storageStatus")
            }
            composer
        }
        .frame(maxWidth: workspaceColumnWidth)
        .padding(.horizontal, horizontalWorkspacePadding)
        .padding(.top, RelaySpace.sm)
        .padding(.bottom, RelaySpace.md)
        .frame(maxWidth: .infinity)
    }

    private var taskRecoveryCard: some View {
        HStack(spacing: 12) {
            Image(systemName: store.phase == .stopped ? "stop.circle" : "exclamationmark.circle")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(RelayColors.accentAmber)
                .accessibilityHidden(true)
            Text(store.phase == .stopped
                 ? "Task stopped. Changes remain."
                 : store.phase == .failed
                 ? "Task couldn’t finish."
                 : "Your input is needed.")
                .font(.system(size: 13))
                .foregroundStyle(RelayColors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Activity") { store.showActivity = true }
                .font(.system(size: 12.5))
                .foregroundStyle(RelayColors.textSecondary)
                .buttonStyle(.plain)
                .accessibilityLabel("Inspect activity")
            if store.canResumeCurrentTask {
                Button(store.phase == .stopped ? "Resume" : "Continue") { store.resume() }
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(RelayColors.canvas)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(RelayColors.textPrimary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .buttonStyle(.plain)
                    .disabled(store.isAuxiliaryBusy)
            } else {
                Button("New request") { composerFocused = true }
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(RelayColors.textPrimary)
                    .buttonStyle(.plain)
                    .accessibilityLabel("Write a new request")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RelayColors.cardBG, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(RelayColors.borderSubtle, lineWidth: 0.7))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("conversation.taskRecovery")
    }

    private var composer: some View {
        let hasText = !store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasAttachedVisual = store.imageInspection.image != nil
        let hasComposableInput = hasText || hasAttachedVisual
        let isSteering = store.phase == .thinking || store.phase == .acting
        let sendDisabled = store.isPreparingModel || store.checkingCodex || store.checkingClaude || store.isClearingConversation || store.isAuxiliaryBusy || store.voice.isBusy || !hasComposableInput
        return VStack(spacing: RelaySpace.xs) {
            if let reply = store.pendingReply {
                ConversationReplyChip(title: reply.title, preview: reply.preview, clear: store.clearConversationReply)
            }
            if store.imageInspection.image != nil || store.imageInspection.isBusy || hasVisualAttachmentNotice {
                inlineVisualContextBar
            }
            if let proofreadNotice = store.homeDraftProofreadNotice {
                HStack(spacing: RelaySpace.xs) {
                    Image(systemName: "wand.and.stars")
                        .font(.relayMicro)
                        .foregroundStyle(RelayColors.accentEmerald)
                    Text(proofreadNotice)
                        .font(.relayCaption)
                        .foregroundStyle(RelayColors.textSecondary)
                        .lineLimit(2)
                    Spacer()
                    RelayIconButton(icon: "xmark", label: "Dismiss proofread notice", size: 24, iconSize: 9) {
                        store.homeDraftProofreadNotice = nil
                    }
                }
                .padding(.horizontal, RelaySpace.sm)
                .padding(.vertical, 6)
                .background(RelayColors.cardBG, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(RelayColors.borderSubtle, lineWidth: 1)
                )
            }
            if store.voice.isBusy || !store.voice.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.voice.errorMessage != nil {
                inlineVoiceDictationBar
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 8) {
                    composerActions
                    TextField(
                        "Message Relay",
                        text: $store.draft,
                        prompt: Text(""),
                        axis: .vertical
                    )
                    .font(.system(size: 15))
                    .foregroundStyle(RelayColors.textPrimary)
                    .textFieldStyle(.plain)
                    .relayTextFieldPrompt(
                        isSteering ? "Steer the current task…" : "Message Relay…",
                        when: store.draft.isEmpty,
                        font: .system(size: 15)
                    )
                    .lineLimit(1...(store.pendingReview == nil ? 5 : 2))
                    .focused($composerFocused)
                    .onSubmit { submitMessage() }
                    .accessibilityLabel("Message Relay or steer current task")
                    .accessibilityIdentifier("home.composer.input")
                    .padding(.leading, 4)
                    .padding(.vertical, 6)

                    RelayIconButton(
                        icon: store.voice.isBusy ? "stop.circle.fill" : "mic",
                        label: store.voice.isBusy ? "Finish dictating into draft" : "Dictate into draft",
                        size: 36,
                        iconSize: 15,
                        tint: store.voice.isBusy ? RelayColors.accentCoral : RelayColors.textSecondary
                    ) {
                        toggleInlineVoiceDictation()
                    }
                    .disabled((store.isRunning && !store.voice.isBusy) || store.isClearingConversation)
                    .contextMenu {
                        Button("Voice Settings & Diagnostics…") {
                            store.speech.stop()
                            showVoiceInput = true
                        }
                    }
                    .accessibilityIdentifier("home.composer.mic")

                    if store.isRunning && !isSteering && !hasComposableInput {
                        NotchStopButton(diameter: 36) { store.stop() }
                    } else {
                        RelaySendButton(
                            canSend: !sendDisabled,
                            size: 36,
                            help: store.isPreparingModel ? "Model preparing" : isSteering ? "Send steering message" : "Send message",
                            showsHalo: false
                        ) {
                            submitMessage()
                        }
                    }
                }

            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .relayWorkspaceSurface(cornerRadius: 16)
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        isComposerDropTargeted
                            ? RelayColors.workbenchAccent
                            : (composerFocused ? RelayColors.textSecondary.opacity(0.40) : .clear),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            }
            .shadow(color: RelayColors.cardShadow.opacity(0.20), radius: 8, x: 0, y: 3)
            .onDrop(of: [.fileURL], isTargeted: $isComposerDropTargeted) { providers in
                handleComposerFileDrop(providers)
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: composerFocused)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isComposerDropTargeted)
        }
    }

    private var inlineVoiceDictationBar: some View {
        let trimmedTranscript = store.voice.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return HStack(spacing: 10) {
            Circle()
                .fill(store.voice.isBusy ? RelayColors.accentCoral : (store.voice.errorMessage != nil ? RelayColors.accentAmber : RelayColors.accentEmerald))
                .frame(width: 8, height: 8)
            Text(
                !trimmedTranscript.isEmpty
                    ? trimmedTranscript
                    : (store.voice.errorMessage ?? "Listening on-device… speak now, then click Finish & Insert.")
            )
            .font(.relayCaption)
            .foregroundStyle(store.voice.errorMessage != nil ? RelayColors.accentCoral : RelayColors.textBright)
            .lineLimit(2)
            Spacer()
            if store.voice.isBusy {
                Button("Finish & Insert") {
                    toggleInlineVoiceDictation()
                }
                .buttonStyle(RelaySecondaryButtonStyle())
            } else if !trimmedTranscript.isEmpty {
                Button("Insert") {
                    _ = store.useVoiceTranscript()
                    composerFocused = true
                }
                .buttonStyle(RelaySecondaryButtonStyle())
            }
            Button("Options…") {
                showVoiceInput = true
            }
            .buttonStyle(.plain)
            .font(.relayCaptionStrong)
            .foregroundStyle(RelayColors.textSecondary)
            RelayIconButton(icon: "xmark", label: "Cancel dictation", size: 26, iconSize: 10) {
                store.voice.cancel()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RelayColors.cardBG, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(RelayColors.borderSubtle, lineWidth: 1))
    }

    private func toggleInlineVoiceDictation() {
        store.speech.stop()
        if store.voice.isBusy {
            Task { @MainActor in
                _ = await store.voice.finishCapture()
                if store.useVoiceTranscript() {
                    composerFocused = true
                }
            }
        } else {
            Task { @MainActor in
                await store.voice.start()
            }
        }
    }

    private var hasVisualAttachmentNotice: Bool {
        guard store.showImageInspection, store.imageInspection.image == nil, !store.imageInspection.isBusy else { return false }
        // No placeholder mode panel. Retain actual picker/load feedback until dismissed.
        return !["Choose a file or select one window.", "Stopped.", "Window selection canceled."]
            .contains(store.imageInspection.status)
    }

    private var inlineVisualContextBar: some View {
        HStack(spacing: 10) {
            if let source = store.imageInspection.image {
                if let preview = NSImage(data: source.jpeg) {
                    Image(nsImage: preview).resizable().scaledToFill()
                        .frame(width: 32, height: 24)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .accessibilityHidden(true)
                }
                Text(source.label).font(.relayCaptionStrong).lineLimit(1)
                Spacer(minLength: 6)
                Button("Inspect…", systemImage: "viewfinder") { showImageInspectionSheet = true }
                    .buttonStyle(RelayGhostButtonStyle())
                    .disabled(store.imageInspection.isBusy || store.isRunning)
                    .accessibilityIdentifier("home.composer.inspectAndAsk")
                RelayIconButton(icon: "xmark", label: "Remove attached visual context", size: 26, iconSize: 10) {
                    store.clearAttachedInspectionImage()
                }
            } else if store.imageInspection.isBusy {
                ProgressView().controlSize(.small)
                Text(store.imageInspection.status).font(.relayCaption).lineLimit(2)
                Spacer(minLength: 6)
                RelayIconButton(icon: "xmark", label: "Cancel visual attachment", size: 26, iconSize: 10) {
                    store.clearAttachedInspectionImage()
                }
            } else if hasVisualAttachmentNotice {
                Text(store.imageInspection.status).font(.relayCaption).lineLimit(2)
                Spacer(minLength: 6)
                RelayIconButton(icon: "xmark", label: "Dismiss attachment notice", size: 26, iconSize: 10) {
                    store.clearAttachedInspectionImage()
                }
            }
        }
        .foregroundStyle(RelayColors.textSecondary)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(RelayColors.cardBG.opacity(0.8), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.composer.visualContextBar")
    }

    private func attachAppWindow() {
        // Attaching context never inherits a previous one-click execution callback.
        store.imageInspection.onImageReady = nil
        store.showImageInspection = true
        composerFocused = true
        store.imageInspection.chooseWindow()
    }

    private var composerActions: some View {
        Menu {
            Button("Attach files…", systemImage: "paperclip") { store.chooseFiles() }
            Button("Add folder…", systemImage: "folder.badge.plus") { store.chooseFolder() }
            Button("Calendar setup…", systemImage: "calendar") { settingsDestination = .sources }
            Button("Attach app window…", systemImage: "macwindow") { attachAppWindow() }
                .disabled(store.isRunning || store.voice.isBusy)
                .accessibilityIdentifier("home.composer.captureWindow")
            Button("Choose image…", systemImage: "photo") {
                store.imageInspection.onImageReady = nil
                showInlineImageImporter = true
            }
            Button("Paste image", systemImage: "doc.on.clipboard") {
                store.imageInspection.onImageReady = nil
                _ = store.pasteClipboardImageIfAvailable()
                composerFocused = true
            }
            .accessibilityIdentifier("home.composer.pasteClipboardImage")
            Divider()
            Button("Draft a reply in my voice", systemImage: "wand.and.stars") { triggerOneClickMagicReply() }
                .disabled(store.isRunning || store.voice.isBusy || MagicReplyCoordinator.shared.isDrafting)
            Button("Summarize current app or document", systemImage: "doc.text.magnifyingglass") { triggerOneClickSummarize() }
                .disabled(!store.canStartDocumentSummary)
                .accessibilityIdentifier("home.composer.summarize")
            Button("Summarize active browser page", systemImage: "safari") {
                do { try store.startBrowserSummary() } catch { store.errorMessage = error.localizedDescription }
            }
            .disabled(!store.canStartDocumentSummary)
            Button("Summarize PDF…", systemImage: "doc.richtext") { store.chooseSummaryPDF() }
                .disabled(!store.canStartDocumentSummary)
            if !store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Divider()
                Button(store.isProofreadingHomeDraft ? "Proofreading…" : "Proofread this draft", systemImage: "checkmark.bubble") {
                    let token = store.captureHomeComposerDraftForProofread()
                    Task { _ = await store.proofreadHomeDraft(handoffToken: token) }
                }
                .disabled(store.isRunning || store.voice.isBusy || store.isProofreadingHomeDraft)
                .accessibilityIdentifier("home.composer.proofread")
            }
        } label: {
            Image(systemName: "plus").font(.system(size: 15, weight: .regular))
                .foregroundStyle(RelayColors.textSecondary)
                .frame(width: 32, height: 32).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("Add context or use a tool")
        .accessibilityIdentifier("home.composer.attach")
        .tint(RelayColors.textSecondary)
        .help("Attach files, windows, images, or use a tool")
    }

    private var compactModelName: String {
        if store.isPreparingModel { return "Preparing…" }
        guard store.workspaceActionsReady else { return "Choose model" }
        if store.workspaceUsesCodex || store.workspaceUsesCodexCLI { return "Codex" }
        if store.workspaceUsesClaude { return "Claude" }
        return activeModelDisplayName
    }

    private var composerModelPicker: some View {
        Button { showComposerModelPopover.toggle() } label: {
            HStack(spacing: 5) {
                Text(compactModelName).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .medium))
            }
            .foregroundStyle(RelayColors.textSecondary)
            .padding(.horizontal, 8).frame(maxWidth: 144).frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Choose model. \(activeModelDisplayName)")
        .help(activeModelDisplayName)
        .popover(isPresented: $showComposerModelPopover, arrowEdge: .top) {
            WorkspaceModelOptions(store: store, modelName: activeModelDisplayName, close: {
                showComposerModelPopover = false
            }) { settingsDestination = .model }
        }
    }

    private var composerContext: some View {
        VStack(alignment: .leading, spacing: 4) {
            WorkspaceHeaderButton(title: "Attach files…", icon: "doc.badge.plus") {
                showAttachPopover = false
                store.chooseFiles()
            }
            WorkspaceHeaderButton(title: "Add folder…", icon: "folder.badge.plus") {
                showAttachPopover = false
                store.chooseFolder()
            }
            WorkspaceHeaderButton(title: "Inspect image or window…", icon: "macwindow") {
                showAttachPopover = false
                store.showImageInspection = true
                composerFocused = true
            }
            .disabled(store.isRunning)
        }
        .padding(8)
    }

    private func triggerOneClickTakeOver() {
        let hasText = !store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasText || store.imageInspection.image != nil {
            submitMessage()
            return
        }
        store.showImageInspection = true
        composerFocused = true
        store.imageInspection.onImageReady = { _ in
            submitMessage()
        }
        store.imageInspection.chooseWindow()
    }

    private func triggerOneClickSummarize() {
        guard store.canStartDocumentSummary else {
            fillExample("Summarize the active browser page and list the key takeaways.")
            return
        }
        do {
            try store.startCurrentDocumentSummary()
        } catch {
            do {
                try store.startBrowserSummary()
            } catch {
                store.chooseSummaryPDF()
            }
        }
    }

    private func handleComposerFileDrop(_ providers: [NSItemProvider]) -> Bool {
        let matching = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !matching.isEmpty else { return false }
        for provider in matching {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let resolvedURL: URL?
                if let url = item as? URL {
                    resolvedURL = url
                } else if let data = item as? Data {
                    resolvedURL = URL(dataRepresentation: data, relativeTo: nil)
                } else if let str = item as? String {
                    resolvedURL = URL(string: str)
                } else {
                    resolvedURL = nil
                }
                guard let resolvedURL else { return }
                Task { @MainActor in
                    store.handleDroppedFileURL(resolvedURL)
                    composerFocused = true
                }
            }
        }
        return true
    }

    private func triggerOneClickMagicReply() {
        let hasText = !store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if let externalApp = NotchOverlayController.shared.currentApp,
           !externalApp.isTerminated,
           externalApp.bundleIdentifier != Bundle.main.bundleIdentifier {
            MagicReplyCoordinator.shared.triggerFromNotch(
                store: store,
                inlineInstruction: hasText ? store.draft : "",
                originApp: externalApp
            )
        } else if hasText {
            _ = NotchOverlayController.shared.prepareGroundedReplyPrompt(store: store, incomingText: store.draft)
            composerFocused = true
        } else {
            fillExample("Draft a thoughtful reply in my voice to this message:\n")
        }
    }

    private func submitMessage() {
        guard !store.isClearingConversation, !store.isPreparingModel, !store.checkingCodex, !store.checkingClaude, !store.isAuxiliaryBusy else { return }
        let hasAttachedImage = store.imageInspection.image != nil
        guard store.workspaceActionsReady || store.isRunning || store.canRunWithoutModel(store.draft) || hasAttachedImage else {
            settingsDestination = .model
            return
        }
        store.submitComposerMessage()
    }

    // MARK: - Unified Left Sidebar (History + Activity)

    private var filteredThreads: [SavedConversationThread] {
        let query = historySearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.threadArchive.threads }
        return store.threadArchive.threads.filter { thread in
            thread.title.localizedStandardContains(query) ||
            thread.preview.localizedStandardContains(query) ||
            thread.messages.contains(where: { $0.text.localizedStandardContains(query) })
        }
    }

    private var groupedThreads: [(title: String, threads: [SavedConversationThread])] {
        let calendar = Calendar.current
        var pinned: [SavedConversationThread] = []
        var today: [SavedConversationThread] = []
        var yesterday: [SavedConversationThread] = []
        var earlier: [SavedConversationThread] = []
        for thread in filteredThreads {
            if thread.isPinned {
                pinned.append(thread)
            } else if calendar.isDateInToday(thread.updatedAt) {
                today.append(thread)
            } else if calendar.isDateInYesterday(thread.updatedAt) {
                yesterday.append(thread)
            } else {
                earlier.append(thread)
            }
        }
        var groups: [(title: String, threads: [SavedConversationThread])] = []
        if !pinned.isEmpty { groups.append(("Pinned", pinned)) }
        if !today.isEmpty { groups.append(("Today", today)) }
        if !yesterday.isEmpty { groups.append(("Yesterday", yesterday)) }
        if !earlier.isEmpty { groups.append(("Earlier", earlier)) }
        return groups
    }

    private var currentThreadUserTurns: [ChatMessage] {
        let userMessages = store.messages.filter { $0.role == "user" }
        let query = historySearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return userMessages }
        return userMessages.filter { $0.text.localizedStandardContains(query) }
    }

    private var leftSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Chats").font(.system(size: 13, weight: .semibold))
                Spacer()
                WorkspaceHeaderButton(title: "New chat", icon: "square.and.pencil", iconOnly: true) {
                    startNewWorkspaceThread()
                }
                .disabled(store.isRunning || store.isClearingConversation)
                .accessibilityIdentifier("workspace.sidebar.newThread")
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 8)
            historySidebarContent
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace.leftSidebar")
    }

    private var historySidebarContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.threadArchive.threads.count > 3 || !historySearchQuery.isEmpty {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(RelayColors.textMuted)
                    TextField("Filter history…", text: $historySearchQuery, prompt: Text(""))
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(RelayColors.textPrimary)
                        .relayTextFieldPrompt("Filter history…", when: historySearchQuery.isEmpty, font: .system(size: 13))
                        .accessibilityIdentifier("workspace.sidebar.filter")
                    if !historySearchQuery.isEmpty {
                        Button {
                            historySearchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(RelayColors.textMuted)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear history filter")
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(RelayColors.subtleFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .padding(.bottom, 6)
            }

            if store.isRunning && store.pendingReview == nil && !store.activity.isEmpty {
                Button {
                    store.showActivity = true
                } label: {
                    HStack(spacing: 8) {
                        RelayActivityMark(size: 13, fast: true)
                        Text("Task activity (\(store.activity.count))")
                            .font(.relayCaptionStrong)
                            .foregroundStyle(RelayColors.textPrimary)
                        Spacer()
                        Text("Inspect")
                            .font(.relayMicro)
                            .foregroundStyle(RelayColors.textSecondary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(RelayColors.textSecondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RelayColors.cardBG, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(RelayColors.borderSubtle, lineWidth: 1)
                    )
                }
                .buttonStyle(RelayPressStyle())
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if filteredThreads.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Text("Saved chats").font(.relayCaptionStrong).foregroundStyle(RelayColors.textSecondary)
                                Spacer()
                            }
                            .padding(.horizontal, 4)
                            emptyHistoryCard
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(groupedThreads, id: \.title) { group in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(group.title)
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(RelayColors.textMuted)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.top, 4)
                                    .padding(.bottom, 2)

                                    VStack(alignment: .leading, spacing: 2) {
                                        ForEach(group.threads) { thread in
                                            SidebarThreadRow(
                                                thread: thread,
                                                isSelected: store.activeThreadID == thread.id && !store.messages.isEmpty,
                                                isDisabled: store.isRunning || store.isClearingConversation,
                                                onSelect: {
                                                    selectWorkspaceThread(thread.id)
                                                },
                                                onRename: { newTitle in
                                                    _ = store.renameThread(id: thread.id, title: newTitle)
                                                },
                                                onTogglePin: {
                                                    _ = store.togglePinThread(id: thread.id)
                                                },
                                                onCopyMarkdown: {
                                                    copyThreadAsMarkdown(messages: thread.messages, activity: thread.activity)
                                                },
                                                onExportMarkdown: {
                                                    exportThreadAsMarkdown(messages: thread.messages, activity: thread.activity, title: thread.title)
                                                },
                                                onDelete: {
                                                    store.deleteThread(thread.id)
                                                }
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .frame(maxHeight: .infinity)
            .accessibilityIdentifier("workspace.sidebar.historyList")

            if !store.threadArchive.threads.isEmpty || !store.threadArchive.trashedThreads.isEmpty {
                Rectangle().fill(RelayColors.borderSubtle.opacity(0.75)).frame(height: 1)
                HStack(spacing: 8) {
                    Spacer(minLength: 4)
                    Button {
                        showConversationTrash = true
                    } label: {
                        Label(store.threadArchive.trashedThreads.isEmpty ? "Trash" : "Trash (\(store.threadArchive.trashedThreads.count))", systemImage: "trash")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(RelayPressStyle())
                    .accessibilityIdentifier("workspace.sidebar.trash")
                    Menu {
                        Button("Move all conversations to Trash…", systemImage: "trash") {
                            showClearHistoryConfirm = true
                        }
                        .disabled(store.threadArchive.threads.isEmpty || store.isRunning || store.isClearingConversation)
                        .accessibilityIdentifier("workspace.sidebar.clearHistory")
                    } label: {
                        Image(systemName: "ellipsis").font(.relayCaption).frame(width: 22, height: 24)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("History actions")
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
    }

    private var emptyHistoryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !historySearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("No threads matching \"\(historySearchQuery)\"")
                    .font(.relayCaptionStrong)
                    .foregroundStyle(RelayColors.textPrimary)
                Button("Clear Filter") {
                    historySearchQuery = ""
                }
                .buttonStyle(RelaySecondaryButtonStyle())
            } else {
                HStack(spacing: 8) {
                    RelayIconBadge(icon: "clock.arrow.circlepath", color: RelayColors.accentBlue, size: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Thread History")
                            .font(.relayCaptionStrong)
                            .foregroundStyle(RelayColors.textPrimary)
                        Text("Every prompt & session is saved automatically.")
                            .font(.relayMicro)
                            .foregroundStyle(RelayColors.textSecondary)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RelayColors.cardBG, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(RelayColors.borderSubtle, lineWidth: 1)
        )
    }

    // MARK: - Activity Panel (Full-Row Clickable DisclosureGroup)

    private func planProgressIcon(_ state: PlanStepProgress.State) -> String {
        switch state {
        case .planned: "circle.dotted"
        case .running: "arrow.triangle.2.circlepath"
        case .waitingForReview: "hand.raised"
        case .reconciling: "eye"
        case .observationChecked: "eye.circle"
        case .stepChecked: "checkmark.shield"
        case .needsAttention: "exclamationmark.triangle"
        case .stopped: "stop.circle"
        case .earlierRun: "clock.arrow.circlepath"
        }
    }

    private func planProgressColor(_ state: PlanStepProgress.State) -> Color {
        switch state {
        case .observationChecked, .stepChecked: RelayColors.success
        case .needsAttention, .waitingForReview: RelayColors.warning
        case .running, .reconciling: RelayColors.information
        default: RelayColors.textSecondary
        }
    }

    private var activityPanel: some View {
        VStack(alignment: .leading, spacing: RelaySpace.sm) {
            HStack {
                    HStack(spacing: 7) {
                        Circle().fill(RelayColors.textSecondary).frame(width: 6, height: 6)
                        Text("Activity").font(RelayPageStyle.dialogTitle)
                    }
                    Spacer()
                    if isUserTaskActive || store.isPreparingModel || store.voice.isBusy || store.speech.isActive {
                        Button("Stop", systemImage: "stop.fill") { store.stop() }
                            .font(.system(size: 12.5, weight: .medium))
                            .buttonStyle(RelaySecondaryButtonStyle())
                            .accessibilityIdentifier("activity.stop")
                    }
                    RelayIconButton(icon: "xmark", label: "Close activity", size: 32, iconSize: 14) {
                        store.showActivity = false
                    }
                }
            if store.phase != .idle {
                HStack(spacing: 8) {
                    if store.phase == .thinking || store.phase == .acting {
                        RelayActivityMark(size: 14, fast: true)
                    } else {
                        Image(systemName: store.phase == .awaitingReview ? "hand.raised" : "info.circle")
                            .foregroundStyle(RelayColors.textSecondary)
                    }
                    Text(WorkspaceTaskPresentation(phase: store.phase).status)
                        .font(.relayCaptionStrong)
                        .foregroundStyle(RelayColors.textPrimary)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RelayColors.workbenchTint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(RelayColors.borderSubtle, lineWidth: 1)
                )
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: RelaySpace.sm) {
                    if !store.currentPlanSteps.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Image(systemName: "list.bullet.clipboard")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(RelayColors.textSecondary)
                                Text("Task plan")
                                    .font(.relayCaptionStrong)
                                    .foregroundStyle(RelayColors.textPrimary)
                                Spacer()
                                if let activeRole = store.activeAgentRole {
                                    RelayRoleBadge(role: activeRole)
                                }
                            }
                            Text(store.currentPlanProgress.isEmpty
                                 ? "Planned steps · individual completion is not tracked"
                                 : "Checks describe each step, not completion of the whole request.")
                                .font(.relayCaption)
                                .foregroundStyle(RelayColors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if !store.currentPlanProgress.isEmpty {
                                ForEach(Array(store.currentPlanProgress.enumerated()), id: \.element.id) { index, step in
                                    HStack(alignment: .top, spacing: 7) {
                                        Image(systemName: planProgressIcon(step.state))
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(planProgressColor(step.state))
                                            .frame(width: 14)
                                            .padding(.top, 2)
                                            .accessibilityHidden(true)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text("\(index + 1). \(step.title)")
                                                .font(.relayCaption)
                                                .foregroundStyle(RelayColors.textBright)
                                                .fixedSize(horizontal: false, vertical: true)
                                            Text(step.status + (step.attempt > 1 ? " · Attempt \(step.attempt)" : ""))
                                                .font(.relayCaption)
                                                .foregroundStyle(RelayColors.textSecondary)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                    .accessibilityElement(children: .combine)
                                }
                            } else {
                                ForEach(Array(store.currentPlanSteps.enumerated()), id: \.offset) { index, step in
                                    HStack(alignment: .top, spacing: 7) {
                                        Image(systemName: "circle.dotted")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(RelayColors.textSecondary)
                                            .padding(.top, 1)
                                            .accessibilityHidden(true)
                                        Text("\(index + 1). \(step)")
                                            .font(.relayCaption)
                                            .foregroundStyle(RelayColors.textBright)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RelayColors.cardBG, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(RelayColors.borderSubtle, lineWidth: 1)
                        )
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("activity.planChecklist")
                    }

                    if store.activity.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            RelayIconBadge(icon: "cursorarrow.motionlines", color: RelayColors.accentBlue, size: 34)
                            Text(store.isRunning ? "Working on your request" : "Live Tool & Mac Activity")
                                .font(.relayBodyStrong)
                                .foregroundStyle(RelayColors.textPrimary)
                            Text("Actions, window inspections, and tool verifications appear here step-by-step as Relay works.")
                                .font(.relayCaption)
                                .lineSpacing(3)
                                .foregroundStyle(RelayColors.textSecondary)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RelayColors.cardBG, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(RelayColors.borderSubtle, lineWidth: 1)
                        )
                        .padding(.top, 4)
                    }
                    ForEach(store.activity.reversed()) { entry in
                        let presentation = ActivityPresentation(name: entry.name, status: entry.status)
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: presentation.icon)
                                    .foregroundStyle(presentation.verified ? RelayColors.accentEmerald : presentation.needsAttention ? RelayColors.accentAmber : RelayColors.textSecondary)
                                    .font(.relayBody).frame(width: 20).padding(.top, 2)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(presentation.title).font(.relayCallout.weight(.medium))
                                    if entry.name != "Response finished" || entry.status != "finished" {
                                        Text(presentation.status).font(.relayCaption).foregroundStyle(RelayColors.textSecondary)
                                    }
                                }
                                Spacer(minLength: 0)
                            }

                            DisclosureGroup("View details") {
                                Text(entry.detail).font(.relayCaption).lineSpacing(3)
                                    .foregroundStyle(RelayColors.textSecondary).textSelection(.enabled)
                                    .padding(.top, 2)
                            }
                            .disclosureGroupStyle(RelayTranscriptDisclosureGroupStyle())
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(RelayColors.borderSubtle).frame(height: 1)
                        }
                        .accessibilityElement(children: .contain)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
            .accessibilityIdentifier("activity.content")
        }
        .padding(12)
    }

    // MARK: - Review Card

    private func reviewCard(_ review: PendingReview) -> some View {
        VStack(alignment: .leading, spacing: RelaySpace.sm) {
            Text("YOUR DECISION")
                .font(.relayEyebrow)
                .tracking(1.5)
                .foregroundStyle(RelayColors.textSecondary)
            Label(review.title, systemImage: "hand.raised.fill")
                .font(.relayBodyStrong)
                .foregroundStyle(RelayColors.accentAmber)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let visual = review.visualPresentation {
                        NativeVisualReviewView(presentation: visual).id(visual.id)
                    }
                    Text(review.reason).font(.relayBody).foregroundStyle(RelayTheme.ink).textSelection(.enabled)
                    if !review.sharesWithOpenAI && !review.hasStructuredMailReview && review.visualPresentation == nil {
                        DisclosureGroup("Action details") {
                            Text(review.call.name).font(.relayMono)
                            Text(JSONValue.object(review.call.arguments).pretty)
                                .font(.relayMono).textSelection(.enabled)
                        }
                        .disclosureGroupStyle(RelayTranscriptDisclosureGroupStyle())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Keep the evidence readable before allocating spare height to the transcript.
            .frame(minHeight: review.visualPresentation != nil ? 180 : 120,
                   idealHeight: review.visualPresentation != nil ? 240 : 180,
                   maxHeight: review.visualPresentation != nil ? 340 : 260)
            .scrollIndicators(.visible)
            .accessibilityIdentifier("review.content")

            Text(review.sharesWithOpenAI ? "Sharing sends the entire excerpt above to ChatGPT, including any text you scroll to view." : review.hasStructuredMailReview ? "Review the entire message above, including text you scroll to view. Approval applies only to this action." : "Approval applies only to this action.")
                .font(.relayCaption).foregroundStyle(RelayColors.textSecondary)

            HStack {
                Spacer()
                Button(review.sharesWithOpenAI ? "Keep on This Mac" : "Decline") { store.denyReview() }.buttonStyle(RelaySecondaryButtonStyle())
                Button(review.approvalTitle) { store.approveReview() }.buttonStyle(RelayPrimaryButtonStyle()).disabled(!review.canApprove)
            }
        }
        .padding(RelaySpace.md)
        .relayLitCard(accent: RelayColors.accentAmber, cornerRadius: RelayRadius.md)
    }

    // MARK: - Error Banner

    private func errorBanner(_ message: String, dismiss: (() -> Void)? = nil) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(RelayColors.accentCoral)
            Text(message).font(.relayCallout).textSelection(.enabled)
            Spacer()
            RelayIconButton(icon: "xmark", label: "Dismiss error", size: 32, iconSize: 11) {
                if let dismiss { dismiss() } else { store.errorMessage = nil }
            }
        }
        .padding(12).background(RelayColors.accentCoral.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(RelayColors.accentCoral.opacity(0.24), lineWidth: 1))
        .frame(maxWidth: workspaceColumnWidth)
        .padding(.horizontal, horizontalWorkspacePadding).padding(.top, 8).padding(.bottom, 4)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Header & Suggestion Subcomponents (Antigravity Style)

struct WorkspaceModelOptions: View {
    @Bindable var store: AssistantStore
    let modelName: String
    let close: () -> Void
    let openSettings: () -> Void

    static func switchBackButtonTitle(for backend: LocalBackend) -> String {
        switch backend {
        case .openRouter: "Use OpenRouter"
        case .customResponses: "Use Responses API"
        case .lmStudio: "Use LM Studio"
        default: "Use Selected Model"
        }
    }

    static func showsSwitchBackButton(workspaceUsesCodex: Bool, workspaceUsesClaude: Bool, workspaceUsesCodexCLI: Bool = false) -> Bool {
        workspaceUsesCodex || workspaceUsesClaude || workspaceUsesCodexCLI
    }

    var body: some View {
        let claudeSelected = store.workspaceUsesClaude || (!store.workspaceUsesCodex && !store.workspaceUsesCodexCLI && store.configuration.backend == .claudeCLI)
        let codexSelected = store.workspaceUsesCodex || store.workspaceUsesCodexCLI || (!store.workspaceUsesClaude && store.configuration.backend == .codexCLI)
        VStack(alignment: .leading, spacing: 4) {
            ForEach(ModelManifest.catalog, id: \.filename) { manifest in
                if ModelManifest.resolveInstalledURL(for: manifest) != nil {
                    let selected = !store.workspaceUsesCodex && !store.workspaceUsesCodexCLI && !store.workspaceUsesClaude && store.configuration.backend == .liteRTLM && modelName == manifest.displayName
                    Button {
                        close()
                        store.selectWorkspaceLocal()
                        Task { await store.selectCatalogModel(manifest) }
                    } label: {
                        row(manifest.displayName, icon: selected ? "checkmark" : "cpu")
                    }
                    .buttonStyle(.plain)
                    .disabled(store.isRunning || store.checkingCodex || store.checkingClaude)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            if claudeSelected {
                row("Claude via Claude CLI", icon: "checkmark")
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isSelected)
            } else {
                Button {
                    close()
                    Task { await store.selectWorkspaceClaude() }
                } label: {
                    row("Claude via Claude CLI", icon: "sparkles")
                }
                .buttonStyle(.plain)
                .disabled(store.isRunning || store.checkingClaude)
            }
            if codexSelected {
                row("ChatGPT via Codex CLI", icon: "checkmark")
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isSelected)
            } else {
                Button {
                    close()
                    Task {
                        await store.selectWorkspaceCodexCLI()
                        if !store.workspaceUsesCodexCLI {
                            openSettings()
                        }
                    }
                } label: {
                    row("ChatGPT via Codex CLI", icon: "cloud")
                }
                .buttonStyle(.plain)
                .disabled(store.isRunning || store.checkingCodex)
            }
            if Self.showsSwitchBackButton(workspaceUsesCodex: store.workspaceUsesCodex, workspaceUsesClaude: store.workspaceUsesClaude, workspaceUsesCodexCLI: store.workspaceUsesCodexCLI) {
                Button {
                    close()
                    store.selectWorkspaceLocal()
                    if !store.actionsReady { openSettings() }
                } label: {
                    row(Self.switchBackButtonTitle(for: store.configuration.backend),
                        icon: store.configuration.usesCloudInference ? "cloud" : "cpu")
                }
                .buttonStyle(.plain)
                .disabled(store.isRunning || store.checkingCodex || store.checkingClaude)
            }
            Divider()
            Toggle(isOn: $store.multiAgentEnabled) {
                HStack(spacing: 8) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.relayMicro)
                        .frame(width: 14)
                        .accessibilityHidden(true)
                    Text("Multi-Agent Deep Plan")
                        .font(.relayCaptionStrong)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .disabled(store.isRunning)
            .accessibilityIdentifier("workspace.modelOptions.multiAgent")
            Divider()
            Button {
                close()
                openSettings()
            } label: {
                row("Model Settings…", icon: "slider.horizontal.3")
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .frame(width: 250)
    }

    private func row(_ title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.relayMicro)
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(title)
                .font(.relayCaptionStrong)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

private struct ComposerActionPillButton: View {
    let title: String
    let icon: String
    var iconOnly = false
    var trailingIcon: String? = nil
    let action: () -> Void

    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            if let trailingIcon, !iconOnly {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 11.5, weight: .medium))
                    Text(title)
                        .font(.relayCaptionStrong)
                        .lineLimit(1)
                    Image(systemName: trailingIcon)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(disabledColorOrSecondary)
                }
                .foregroundStyle(!enabled ? RelayColors.textDim : hovered ? RelayColors.textPrimary : RelayColors.textSecondary)
                .padding(.horizontal, RelaySpace.xs)
                .frame(minWidth: RelayControlHeight.pill)
                .frame(height: RelayControlHeight.pill)
                .background(hovered && enabled ? RelayColors.hoverFill : .clear,
                            in: RoundedRectangle(cornerRadius: RelayRadius.xs))
                .contentShape(Rectangle())
            } else {
                RelayToolbarPillLabel(
                    title: title,
                    icon: icon,
                    iconOnly: iconOnly,
                    hovered: hovered,
                    disabled: !enabled
                )
            }
        }
        .buttonStyle(RelayPressStyle())
        .onHover { hovered = $0 }
        .accessibilityLabel(title)
    }

    private var disabledColorOrSecondary: Color {
        !enabled ? RelayColors.textDim : (hovered ? RelayColors.textPrimary : RelayColors.textMuted)
    }
}

private struct WorkspaceHeaderButton: View {
    let title: String
    let icon: String
    var selected = false
    var iconOnly = false
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .regular))
                if !iconOnly {
                    Text(title)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, iconOnly ? 0 : RelaySpace.sm)
            .frame(width: iconOnly ? 32 : nil, height: 32)
            .foregroundStyle(hovered || selected ? RelayColors.textPrimary : RelayColors.textBright)
            .background(
                selected ? RelayColors.activeFill : (hovered ? RelayColors.hoverFill : .clear),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(RelayPressStyle())
        .onHover { hovered = $0 }
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(title)
    }
}

// MARK: - Rich Markdown Segment Parser & Code Block Card

struct TranscriptMarkdownSegment: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case prose(String)
        case codeBlock(language: String, code: String)
    }

    let kind: Kind

    static func prose(_ text: String) -> TranscriptMarkdownSegment {
        TranscriptMarkdownSegment(kind: .prose(text))
    }

    static func codeBlock(language: String, code: String) -> TranscriptMarkdownSegment {
        let normalized = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return TranscriptMarkdownSegment(
            kind: .codeBlock(
                language: normalized.isEmpty ? "code" : normalized,
                code: code
            )
        )
    }

    var isCodeBlock: Bool {
        if case .codeBlock = kind { return true }
        return false
    }

    var text: String {
        switch kind {
        case .prose(let prose):
            return prose
        case .codeBlock(_, let code):
            return code
        }
    }

    var language: String? {
        switch kind {
        case .prose:
            return nil
        case .codeBlock(let language, _):
            return language
        }
    }

    static func parse(_ text: String) -> [TranscriptMarkdownSegment] {
        guard !text.isEmpty else { return [] }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        var segments: [TranscriptMarkdownSegment] = []
        var proseLines: [String] = []
        var inCodeBlock = false
        var activeFenceLang = "code"
        var codeLines: [String] = []

        func flushProse() {
            guard !proseLines.isEmpty else { return }
            let joined = proseLines.joined(separator: "\n")
            let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                segments.append(.prose(trimmed))
            }
            proseLines.removeAll(keepingCapacity: true)
        }

        func flushCodeBlock() {
            var body = codeLines.joined(separator: "\n")
            while body.hasSuffix("\n") {
                body.removeLast()
            }
            segments.append(.codeBlock(language: activeFenceLang, code: body))
            codeLines.removeAll(keepingCapacity: true)
        }

        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine.hasPrefix("```") {
                let afterTicks = String(trimmedLine.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                if !inCodeBlock {
                    // Check if single-line ```code``` or ```lang code``` closed on the same line
                    if let closingRange = afterTicks.range(of: "```", options: .backwards),
                       closingRange.lowerBound > afterTicks.startIndex {
                        flushProse()
                        let inner = String(afterTicks[..<closingRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                        segments.append(.codeBlock(language: "code", code: inner))
                    } else {
                        flushProse()
                        inCodeBlock = true
                        let langToken = afterTicks
                            .split(whereSeparator: { $0.isWhitespace || $0 == "`" })
                            .first
                            .map(String.init)?
                            .lowercased() ?? ""
                        activeFenceLang = langToken.isEmpty ? "code" : langToken
                    }
                } else {
                    flushCodeBlock()
                    inCodeBlock = false
                    activeFenceLang = "code"
                }
            } else if inCodeBlock {
                codeLines.append(line)
            } else {
                proseLines.append(line)
            }
        }

        if inCodeBlock {
            flushCodeBlock()
        } else {
            flushProse()
        }

        if segments.isEmpty {
            let fallback = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
            if !fallback.isEmpty {
                return [.prose(fallback)]
            }
        }
        return segments
    }

    enum ProseBlock: Equatable, Sendable {
        case heading(level: Int, text: String)
        case blockquote(String)
        case bulletItem(indent: Int, text: String)
        case numberedItem(indent: Int, number: String, text: String)
        case table(headers: [String], rows: [[String]])
        case divider
        case paragraph(String)

        static func bulletItem(_ text: String) -> ProseBlock {
            .bulletItem(indent: 0, text: text)
        }

        static func numberedItem(number: String, text: String) -> ProseBlock {
            .numberedItem(indent: 0, number: number, text: text)
        }
    }

    private static func parseTableRow(_ line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return nil }
        var inner = trimmed
        if inner.hasPrefix("|") { inner.removeFirst() }
        if inner.hasSuffix("|") { inner.removeLast() }
        let cells = inner.components(separatedBy: "|").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard !cells.isEmpty else { return nil }
        if !trimmed.hasPrefix("|") && !trimmed.hasSuffix("|") && cells.count < 2 {
            return nil
        }
        return cells
    }

    private static func isTableSeparatorRow(_ line: String, expectedColumnCount: Int) -> Bool {
        guard let cells = parseTableRow(line), cells.count == expectedColumnCount, !cells.isEmpty else {
            return false
        }
        return cells.allSatisfy { cell in
            guard !cell.isEmpty else { return false }
            var stripped = cell
            if stripped.hasPrefix(":") { stripped.removeFirst() }
            if stripped.hasSuffix(":") { stripped.removeLast() }
            return stripped.count >= 3 && stripped.allSatisfy { $0 == "-" }
        }
    }

    static func parseProseBlocks(_ proseText: String) -> [ProseBlock] {
        let normalized = proseText.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var blocks: [ProseBlock] = []
        var paragraphLines: [String] = []
        var quoteLines: [String] = []

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            let joined = paragraphLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                blocks.append(.paragraph(joined))
            }
            paragraphLines.removeAll(keepingCapacity: true)
        }

        func flushQuote() {
            guard !quoteLines.isEmpty else { return }
            let joined = quoteLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                blocks.append(.blockquote(joined))
            }
            quoteLines.removeAll(keepingCapacity: true)
        }

        var index = 0
        while index < lines.count {
            let line = lines[index]
            var leadingWhitespaceCount = 0
            for ch in line {
                if ch == " " {
                    leadingWhitespaceCount += 1
                } else if ch == "\t" {
                    leadingWhitespaceCount += 2
                } else {
                    break
                }
            }
            let indentLevel = min(4, leadingWhitespaceCount / 2)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                flushQuote()
                index += 1
                continue
            }

            if index + 1 < lines.count,
               let headerCells = parseTableRow(line),
               isTableSeparatorRow(lines[index + 1], expectedColumnCount: headerCells.count) {
                flushParagraph()
                flushQuote()
                index += 2
                var tableRows: [[String]] = []
                while index < lines.count {
                    let rowLine = lines[index]
                    if rowLine.trimmingCharacters(in: .whitespaces).isEmpty {
                        break
                    }
                    guard let rowCells = parseTableRow(rowLine) else {
                        break
                    }
                    let normalizedRow: [String]
                    if rowCells.count < headerCells.count {
                        normalizedRow = rowCells + Array(repeating: "", count: headerCells.count - rowCells.count)
                    } else if rowCells.count > headerCells.count {
                        normalizedRow = Array(rowCells.prefix(headerCells.count))
                    } else {
                        normalizedRow = rowCells
                    }
                    tableRows.append(normalizedRow)
                    index += 1
                }
                blocks.append(.table(headers: headerCells, rows: tableRows))
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var content = String(trimmed.dropFirst())
                if content.hasPrefix(" ") {
                    content.removeFirst()
                }
                quoteLines.append(content)
                index += 1
                continue
            } else {
                flushQuote()
            }

            if trimmed == "---" || trimmed == "***" {
                flushParagraph()
                blocks.append(.divider)
                index += 1
                continue
            }

            if trimmed.hasPrefix("#### ") {
                flushParagraph()
                blocks.append(.heading(level: 4, text: String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)))
                index += 1
                continue
            } else if trimmed.hasPrefix("### ") {
                flushParagraph()
                blocks.append(.heading(level: 3, text: String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespaces)))
                index += 1
                continue
            } else if trimmed.hasPrefix("## ") {
                flushParagraph()
                blocks.append(.heading(level: 2, text: String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)))
                index += 1
                continue
            } else if trimmed.hasPrefix("# ") {
                flushParagraph()
                blocks.append(.heading(level: 1, text: String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)))
                index += 1
                continue
            }

            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") || trimmed.hasPrefix("+ ") {
                flushParagraph()
                let itemText = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                blocks.append(.bulletItem(indent: indentLevel, text: itemText))
                index += 1
                continue
            }

            if let dotIndex = trimmed.firstIndex(of: "."),
               dotIndex > trimmed.startIndex,
               trimmed[..<dotIndex].allSatisfy(\.isNumber) {
                let afterDot = trimmed.index(after: dotIndex)
                if afterDot < trimmed.endIndex && trimmed[afterDot] == " " {
                    flushParagraph()
                    let numberLabel = String(trimmed[...dotIndex])
                    let itemText = String(trimmed[trimmed.index(after: afterDot)...]).trimmingCharacters(in: .whitespaces)
                    blocks.append(.numberedItem(indent: indentLevel, number: numberLabel, text: itemText))
                    index += 1
                    continue
                }
            }

            paragraphLines.append(line)
            index += 1
        }

        flushParagraph()
        flushQuote()

        if blocks.isEmpty && !proseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [.paragraph(proseText.trimmingCharacters(in: .whitespacesAndNewlines))]
        }
        return blocks
    }
}

private struct TranscriptCodeBlockCard: View {
    let language: String
    let code: String

    @State private var didCopy = false
    @State private var hoverCopy = false

    private var badgeText: String {
        let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? "code" : trimmed
    }

    private func copyCodeToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        didCopy = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            didCopy = false
        }
    }

    var body: some View {
        let cardShape = RoundedRectangle(cornerRadius: RelayRadius.md, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: RelaySpace.xs) {
                Text(badgeText)
                    .font(.relayMonoSmall)
                    .foregroundStyle(RelayColors.textSecondary)
                    .lineLimit(1)

                Spacer(minLength: RelaySpace.xs)

                Button(action: copyCodeToPasteboard) {
                    HStack(spacing: 4) {
                        Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10, weight: .semibold))
                        Text(didCopy ? "Copied" : "Copy code")
                            .font(.relayMicro)
                    }
                    .foregroundStyle(
                        didCopy
                            ? RelayColors.accentEmerald
                            : (hoverCopy ? RelayColors.textPrimary : RelayColors.textSecondary)
                    )
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        (hoverCopy || didCopy) ? RelayColors.hoverFill : RelayColors.subtleFill,
                        in: Capsule(style: .continuous)
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(
                                didCopy ? RelayColors.accentEmerald.opacity(0.35) : RelayColors.borderSubtle,
                                lineWidth: 1
                            )
                    )
                    .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(RelayPressStyle())
                .onHover { hoverCopy = $0 }
                .accessibilityLabel(didCopy ? "Copied code" : "Copy code")
            }
            .padding(.horizontal, RelaySpace.sm)
            .frame(height: 28)
            .background(RelayColors.surface)

            Rectangle()
                .fill(RelayColors.borderSubtle)
                .frame(height: 1)

            ScrollView(.horizontal, showsIndicators: true) {
                Text(code)
                    .font(.relayMono)
                    .foregroundStyle(RelayColors.textPrimary)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, RelaySpace.sm)
                    .padding(.vertical, 10)
            }
            .background(RelayColors.pitch)
        }
        .background(RelayColors.pitch, in: cardShape)
        .clipShape(cardShape)
        .overlay(
            cardShape
                .strokeBorder(RelayColors.borderSubtle, lineWidth: 1)
        )
    }
}

private struct TranscriptMessageRow: View {
    @Bindable var store: AssistantStore
    let message: ChatMessage
    let parsedRole: String?
    let cleanText: String
    let onJumpToReply: () -> Void
    let onReply: (ChatMessage) -> Void
    let onQuote: (ChatMessage) -> Void
    let onCopy: (ChatMessage) -> Void
    var onEdit: (ChatMessage) -> Void = { _ in }
    var onOpenSavedNote: (LocalMarkdownNote) -> Void = { _ in }
    var onRegenerate: (ChatMessage) -> Void = { _ in }

    private enum CaptureState {
        case unsaved, saving, saved(LocalMarkdownNote), failed(String)
    }

    @State private var captureState: CaptureState = .unsaved
    @State private var resultActionError: String?
    @State private var resultActionNotice: String?
    @FocusState private var actionsFocused: Bool
    @State private var hovered = false
    @State private var hoveredInlineAction: String?
    @State private var didCopy = false

    private func performCopy() {
        onCopy(message)
        didCopy = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            didCopy = false
        }
    }

    private func saveAssistantResponseToVault(_ bodyText: String) {
        if case .saving = captureState { return }
        captureState = .saving
        resultActionError = nil
        resultActionNotice = nil
        let firstLine = bodyText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? "Saved response"
        // This bounded local write has no suspension point. A queued save must
        // not survive an intervening reset and recreate erased content.
        do {
            let note = try store.knowledgeVault.saveResponseNote(
                messageID: message.id, title: "Relay — \(firstLine)", body: bodyText
            )
            captureState = .saved(note)
        } catch {
            captureState = .failed(error.localizedDescription)
        }
    }

    private func currentSavedNote() -> LocalMarkdownNote? {
        do {
            guard let note = try store.knowledgeVault.savedResponseNote(messageID: message.id) else {
                resultActionError = "The saved note is no longer in Knowledge. If you moved it to Trash, restore it there."
                captureState = .unsaved
                return nil
            }
            captureState = .saved(note)
            resultActionError = nil
            return note
        } catch {
            resultActionError = "Couldn’t read the saved note: \(error.localizedDescription)"
            return nil
        }
    }

    private func exportSavedResponse() {
        guard let note = currentSavedNote() else { return }
        let panel = NSSavePanel()
        panel.title = "Export saved note"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        let filename = String(note.title.prefix(70)).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = filename + ".md"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        // The modal panel can outlive edits, moves, Trash, or a reset. Re-read
        // the exact saved capture after it closes rather than exporting its cache.
        guard let current = currentSavedNote() else { return }
        guard current.id == note.id, Data(current.sharingMarkdown.utf8) == Data(note.sharingMarkdown.utf8) else {
            resultActionNotice = nil
            resultActionError = "The saved note changed while you chose an export location. Review it in Knowledge, then export again."
            return
        }
        do {
            try LocalPrivateFileWriter.write(data: Data(current.sharingMarkdown.utf8), to: destination,
                                             maximumBytes: KnowledgeVaultManager.maximumNoteBytes)
            resultActionError = nil
            resultActionNotice = "Exported \(destination.lastPathComponent)."
        } catch {
            resultActionNotice = nil
            resultActionError = "Couldn’t export the note: \(error.localizedDescription)"
        }
    }

    private var showsCaptureControls: Bool {
        if case .unsaved = captureState { return false }
        return true
    }

    @ViewBuilder
    private func captureControls(bodyText: String) -> some View {
        switch captureState {
        case .unsaved:
            EmptyView()
        case .saving:
            ProgressView("Saving locally…").controlSize(.small).font(.relayCaption)
                .accessibilityIdentifier("conversation.result.saving")
        case .saved:
            Label("Saved", systemImage: "bookmark.fill")
                .font(.relayCaption).foregroundStyle(RelayColors.textSecondary)
                .padding(.horizontal, 7)
                .accessibilityLabel("Response saved to Knowledge")
            inlineActionButton(title: "Open note", icon: "arrow.up.right") {
                if let note = currentSavedNote() { onOpenSavedNote(note) }
            }
            .disabled(store.pendingReview != nil)
            .accessibilityIdentifier("conversation.result.openNote")
            inlineActionButton(title: "Export…", icon: "square.and.arrow.up") { exportSavedResponse() }
                .accessibilityLabel("Export saved note as Markdown")
                .accessibilityIdentifier("conversation.result.export")
        case .failed:
            inlineActionButton(title: "Retry save", icon: "arrow.clockwise") { saveAssistantResponseToVault(bodyText) }
                .accessibilityIdentifier("conversation.result.retrySave")
        }
    }

    @ViewBuilder
    private var captureFeedback: some View {
        if case .failed(let error) = captureState {
            VStack(alignment: .leading, spacing: 4) {
                Label("Couldn’t save this response", systemImage: "exclamationmark.circle")
                    .font(.relayCaptionStrong)
                Text(error).font(.relayCaption).textSelection(.enabled)
            }
            .foregroundStyle(RelayColors.error)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("conversation.result.saveError")
        }
        if let resultActionError {
            Text(resultActionError).font(.relayCaption).foregroundStyle(RelayColors.error)
                .textSelection(.enabled)
                .accessibilityIdentifier("conversation.result.actionError")
        }
        if let resultActionNotice {
            Text(resultActionNotice).font(.relayCaption).foregroundStyle(RelayColors.textSecondary)
                .accessibilityIdentifier("conversation.result.actionNotice")
        }
    }

    var body: some View {
        VStack(alignment: message.role == "user" ? .trailing : .leading, spacing: 8) {
            if let reference = message.reply {
                Button(action: onJumpToReply) {
                    ConversationReplyChip(
                        title: "Reply to an earlier message",
                        preview: reference.selectedText ?? "View original message"
                    )
                }
                .buttonStyle(.plain)
            }

            if message.role == "user" {
                HStack(alignment: .top, spacing: 8) {
                    Spacer(minLength: 24)
                    Text(message.text)
                        .font(.system(size: 15))
                        .lineSpacing(RelayTheme.messageLineSpacing)
                        .foregroundStyle(RelayColors.textPrimary)
                        .textSelection(.enabled)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 11)
                        .background(RelayColors.surface.opacity(0.86), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    messageActions(bodyText: message.text)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                let response = RelayResponseText(cleanText)
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 10) {
                        if let parsedRole {
                            RelayRoleBadge(role: parsedRole)
                        } else if message.role == "system" {
                            Text("System").font(.relayCaptionStrong).foregroundStyle(RelayColors.textSecondary)
                        }
                        let segments = TranscriptMarkdownSegment.parse(response.body)
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                                switch segment.kind {
                                case .prose(let proseText): proseSegmentView(proseText)
                                case .codeBlock(let language, let code): TranscriptCodeBlockCard(language: language, code: code)
                                }
                            }
                        }
                        if let evidence = response.evidence { RelayActionEvidence(text: evidence) }
                        if message.role == "assistant" && showsCaptureControls {
                            HStack(spacing: 3) {
                                captureControls(bodyText: response.body)
                                Spacer(minLength: 0)
                            }
                        }
                        captureFeedback
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    messageActions(bodyText: response.body)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !message.artifacts.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12)], spacing: 12) {
                    ForEach(message.artifacts, id: \.self) { path in
                        Button { store.revealArtifact(path, messageID: message.id) } label: {
                            HStack(spacing: 12) {
                                RelayIconBadge(
                                    icon: ["xlsx", "csv"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) ? "tablecells.fill" : "doc.richtext.fill",
                                    color: RelayColors.accentGold,
                                    size: 36
                                )
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(URL(fileURLWithPath: path).lastPathComponent).font(.relayBodyStrong).lineLimit(2)
                                    Text("Show in Finder").font(.relayCaption).foregroundStyle(RelayTheme.muted)
                                }
                                Spacer()
                                Image(systemName: "arrow.up.right").foregroundStyle(RelayTheme.muted).font(.relayCaption)
                            }
                            .padding(12)
                            .relayLitCard(accent: RelayColors.accentGold, cornerRadius: 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(RelayPressStyle()).help(path)
                        .accessibilityLabel("Show \(path) in Finder")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == "user" ? .trailing : .leading)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .accessibilityActions {
            Button("Copy message") { performCopy() }
            Button("Reply to message") { onReply(message) }
            if message.role == "user" {
                Button("Edit message") { onEdit(message) }.disabled(store.isRunning)
            } else if message.role == "assistant" {
                Button("Save response to Knowledge") { saveAssistantResponseToVault(RelayResponseText(cleanText).body) }
            }
        }
        .onAppear {
            guard message.role == "assistant", case .unsaved = captureState else { return }
            if let note = try? store.knowledgeVault.savedResponseNote(messageID: message.id) {
                captureState = .saved(note)
            }
        }
        .contextMenu {
            if message.role == "user" {
                Button("Edit message") { onEdit(message) }
                    .disabled(store.isRunning)
            }
            Button("Reply to message") { onReply(message) }
            Button("Quote a passage…") { onQuote(message) }
            Button("Copy message") { performCopy() }
            if message.role == "assistant" {
                Button("Regenerate") { onRegenerate(message) }
                    .disabled(store.isRunning)
                Button("Save to Knowledge") {
                    saveAssistantResponseToVault(RelayResponseText(cleanText).body)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func messageActions(bodyText: String) -> some View {
        Menu {
            Button(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc") { performCopy() }
            Button("Reply", systemImage: "arrowshape.turn.up.left") { onReply(message) }
            Button("Quote a passage…", systemImage: "text.quote") { onQuote(message) }
            if message.role == "user" {
                Button("Edit message", systemImage: "pencil") { onEdit(message) }.disabled(store.isRunning)
            } else if message.role == "assistant" {
                Divider()
                Button("Save to Knowledge", systemImage: "bookmark") { saveAssistantResponseToVault(bodyText) }
                    .accessibilityLabel("Save response to Knowledge")
                    .accessibilityIdentifier("conversation.result.save")
                if case .saved = captureState {
                    Button("Open saved note", systemImage: "arrow.up.right") {
                        if let note = currentSavedNote() { onOpenSavedNote(note) }
                    }
                    .disabled(store.pendingReview != nil)
                    Button("Export saved note…", systemImage: "square.and.arrow.up") { exportSavedResponse() }
                }
                Button("Regenerate", systemImage: "arrow.clockwise") { onRegenerate(message) }.disabled(store.isRunning)
                if store.speech.isEnabled {
                    let active = store.speech.activeMessageID == message.id
                    Button(active ? "Stop reading" : "Read aloud", systemImage: active ? "stop.circle" : "speaker.wave.2") {
                        if active { store.speech.stop() } else { store.readAloud(message) }
                    }
                    .disabled(store.isRunning || store.voice.isBusy)
                }
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 12, weight: .regular))
                .foregroundStyle(RelayColors.textSecondary)
                .frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .focused($actionsFocused)
        .opacity(hovered || actionsFocused ? 1 : 0)
        .accessibilityHidden(false)
        .accessibilityLabel(message.role == "user" ? "Message actions" : "More response actions")
        .help("Message actions · \(message.date.formatted(date: .abbreviated, time: .shortened))")
    }

    typealias ProseBlock = TranscriptMarkdownSegment.ProseBlock

    private func parseProseBlocks(_ proseText: String) -> [ProseBlock] {
        TranscriptMarkdownSegment.parseProseBlocks(proseText)
    }

    private func styledInlineAttributedString(_ raw: String) -> AttributedString? {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        guard var attributed = try? AttributedString(markdown: raw, options: options) else {
            return nil
        }
        for run in attributed.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                attributed[run.range].font = .relayMono
                attributed[run.range].foregroundColor = RelayColors.textBright
            }
        }
        return attributed
    }

    @ViewBuilder
    private func inlineMarkdownText(
        _ raw: String,
        font: Font = .relayConversation,
        color: Color = RelayColors.textPrimary,
        lineSpacing: CGFloat = 5
    ) -> some View {
        if let attributed = styledInlineAttributedString(raw) {
            Text(attributed)
                .font(font)
                .foregroundStyle(color)
                .lineSpacing(lineSpacing)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(raw)
                .font(font)
                .foregroundStyle(color)
                .lineSpacing(lineSpacing)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func markdownTableView(headers: [String], rows: [[String]]) -> some View {
        let tableShape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(headers.enumerated()), id: \.offset) { colIndex, header in
                    if colIndex > 0 {
                        Rectangle()
                            .fill(RelayColors.borderSubtle)
                            .frame(width: 1)
                    }
                    inlineMarkdownText(
                        header,
                        font: .relayCaptionStrong,
                        color: RelayColors.textPrimary,
                        lineSpacing: 2
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
            }
            .background(RelayColors.surface)

            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                Rectangle()
                    .fill(RelayColors.borderSubtle)
                    .frame(height: 1)

                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.offset) { colIndex, cell in
                        if colIndex > 0 {
                            Rectangle()
                                .fill(RelayColors.borderSubtle)
                                .frame(width: 1)
                        }
                        inlineMarkdownText(
                            cell,
                            font: .relayCallout,
                            color: RelayColors.textPrimary,
                            lineSpacing: 3
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                    }
                }
                .background(rowIndex.isMultiple(of: 2) ? RelayColors.cardBG : RelayColors.surface.opacity(0.55))
            }
        }
        .clipShape(tableShape)
        .overlay(
            tableShape
                .strokeBorder(RelayColors.borderSubtle, lineWidth: 1)
        )
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func proseSegmentView(_ proseText: String) -> some View {
        let blocks = parseProseBlocks(proseText)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                switch block {
                case .heading(let level, let headingText):
                    let headingFont: Font = switch level {
                    case 1: .relayTitle
                    case 2: .relayHeadline
                    default: .relayBodyStrong
                    }
                    inlineMarkdownText(
                        headingText,
                        font: headingFont,
                        color: RelayColors.textPrimary,
                        lineSpacing: 3
                    )
                    .padding(.top, index == 0 ? 0 : 4)

                case .blockquote(let quoteText):
                    inlineMarkdownText(
                        quoteText,
                        font: .relayConversation,
                        color: RelayColors.textSecondary
                    )
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RelayColors.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(RelayColors.borderSubtle, lineWidth: 1)
                    )
                    .padding(.vertical, 2)

                case .bulletItem(let indent, let itemText):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(indent == 0 ? "•" : (indent == 1 ? "◦" : "▪"))
                            .font(.relayConversation.weight(.semibold))
                            .foregroundStyle(RelayColors.textSecondary)
                        inlineMarkdownText(itemText)
                    }
                    .padding(.leading, 4 + CGFloat(indent) * 16)

                case .numberedItem(let indent, let number, let itemText):
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(number)
                            .font(.relayMonoSmall)
                            .foregroundStyle(RelayColors.textSecondary)
                            .frame(minWidth: 18, alignment: .trailing)
                        inlineMarkdownText(itemText)
                    }
                    .padding(.leading, 2 + CGFloat(indent) * 16)

                case .table(let headers, let rows):
                    markdownTableView(headers: headers, rows: rows)

                case .divider:
                    Rectangle()
                        .fill(RelayColors.borderSubtle)
                        .frame(height: 1)
                        .padding(.vertical, 2)

                case .paragraph(let paragraphText):
                    inlineMarkdownText(paragraphText)
                }
            }
        }
    }

    private func actionPillButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.relayMicro)
                .foregroundStyle(RelayColors.textSecondary)
                .frame(width: 26, height: 26)
                .background(RelayColors.surface, in: Circle())
                .overlay(Circle().strokeBorder(RelayColors.borderSubtle, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(RelayPressStyle())
        .help(label)
        .accessibilityLabel(label)
    }

    private func inlineActionButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        let isActionHovered = hoveredInlineAction == title
        return Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.relayMicro)
                Text(title)
                    .font(.relayCaptionStrong)
            }
            .foregroundStyle(isActionHovered ? RelayColors.textPrimary : RelayColors.textSecondary)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(isActionHovered ? RelayColors.hoverFill : Color.clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(RelayPressStyle())
        .onHover { isHovered in
            hoveredInlineAction = isHovered ? title : (hoveredInlineAction == title ? nil : hoveredInlineAction)
        }
    }
}

private struct ConversationSearchView: View {
    let messages: [ChatMessage]
    let select: (ChatMessage) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var focused: Bool

    private var matches: [ChatMessage] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        return Array(messages.reversed().lazy.filter { searchableText($0).localizedStandardContains(term) }.prefix(20))
    }

    private func searchableText(_ message: ChatMessage) -> String {
        message.role == "assistant" ? RelayResponseText(message.text).body : message.text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Find in conversation")
                    .font(RelayPageStyle.dialogTitle)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                RelayIconButton(icon: "xmark", label: "Close conversation search", size: 32) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            TextField("Search messages", text: $query)
                .font(.relayBody)
                .focused($focused)
                .textFieldStyle(.plain)
                .relayTextField()
                .accessibilityIdentifier("conversation.search")
                .onSubmit { if let match = matches.first { select(match) } }
            if matches.isEmpty {
                Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Search messages in this chat." : "No matching messages.")
                    .font(.relayCaption)
                    .foregroundStyle(RelayColors.textSecondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(matches) { message in
                            Button { select(message) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(message.role == "user" ? "You" : "Relay")
                                        .font(.relayCaptionStrong)
                                    Text(searchableText(message))
                                        .font(.relayBody)
                                        .foregroundStyle(RelayColors.textSecondary)
                                        .lineLimit(2)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(RelayColors.surface, in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(RelayPressStyle())
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
        }
        .padding(20)
        .frame(minHeight: 210, alignment: .topLeading)
        .frame(width: 430)
        .background(RelayColors.canvas)
        .task {
            await Task.yield()
            guard !Task.isCancelled else { return }
            focused = true
        }
    }
}

private struct SidebarTurnRow: View {
    let turnIndex: Int
    var isLast: Bool = false
    let message: ChatMessage
    let onSelect: () -> Void

    @State private var hovered = false

    private var summaryText: String {
        let line = message.text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? message.text
        return line
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Text("#\(turnIndex)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(hovered ? RelayColors.textPrimary : RelayColors.textMuted)

                Text(summaryText)
                    .font(.relayCaption)
                    .foregroundStyle(hovered ? RelayColors.textPrimary : RelayColors.textSecondary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(RelayColors.textMuted)
                    .opacity(hovered ? 1 : 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                hovered ? RelayColors.hoverFill : Color.clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(RelayPressStyle())
        .onHover { hovered = $0 }
        .help("Jump to turn #\(turnIndex): \(summaryText)")
    }
}

private struct CommandPaletteView: View {
    @Bindable var store: AssistantStore
    let onNewChat: () -> Void
    let onMorningBrief: () -> Void
    let onSummarizeDocument: () -> Void
    let onToggleSidebar: () -> Void
    let onOpenKnowledgeVault: () -> Void
    let onOpenSettings: () -> Void
    var onOpenSetup: (() -> Void)? = nil
    let onSelectThread: (UUID) -> Void
    let onSelectNote: (LocalMarkdownNote) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selectedIndex = 0
    @State private var vaultNotes: [LocalMarkdownNote] = []
    @State private var searchResult = CommandPaletteSearch.Result(threads: [], notes: [])
    @State private var searching = false

    private struct SearchRevision: Equatable {
        let query: String
        let threadIDs: [UUID]
        let updatedAt: [Date]
        let noteURLs: [URL]
    }

    private var searchRevision: SearchRevision {
        SearchRevision(query: query, threadIDs: store.threadArchive.threads.map(\.id),
                       updatedAt: store.threadArchive.threads.map(\.updatedAt), noteURLs: vaultNotes.map(\.url))
    }
    @FocusState private var focused: Bool

    private enum PaletteItemKind {
        case quickAction
        case thread
        case note
    }

    private struct PaletteItem: Identifiable {
        let id: String
        let section: String
        let kind: PaletteItemKind
        let title: String
        let subtitle: String?
        let icon: String
        let shortcut: String?
        let action: () -> Void
    }

    private var quickActionItems: [PaletteItem] {
        let all: [PaletteItem] = [
            PaletteItem(
                id: "action.newChat",
                section: "Quick Actions",
                kind: .quickAction,
                title: "New Chat",
                subtitle: "Start a fresh workspace conversation thread",
                icon: "square.and.pencil",
                shortcut: "⌘N",
                action: onNewChat
            ),
            PaletteItem(
                id: "action.morningBrief",
                section: "Quick Actions",
                kind: .quickAction,
                title: "Morning Brief",
                subtitle: "Open your proactive daily briefing and follow-ups",
                icon: "sun.horizon",
                shortcut: "⌘⇧B",
                action: onMorningBrief
            ),
            PaletteItem(
                id: "action.summarizeDocument",
                section: "Quick Actions",
                kind: .quickAction,
                title: "Summarize Active Document",
                subtitle: "Summarize the frontmost app, browser tab, or PDF",
                icon: "doc.text.magnifyingglass",
                shortcut: "⌘⇧D",
                action: onSummarizeDocument
            ),
            PaletteItem(
                id: "action.toggleSidebar",
                section: "Quick Actions",
                kind: .quickAction,
                title: "Toggle History",
                subtitle: "Show or hide your conversation history",
                icon: "sidebar.left",
                shortcut: "⌘⇧S",
                action: onToggleSidebar
            ),
            PaletteItem(
                id: "action.openKnowledgeVault",
                section: "Quick Actions",
                kind: .quickAction,
                title: "Open Knowledge Vault",
                subtitle: "Browse local Markdown notes, entities, and constellation graph",
                icon: "books.vertical",
                shortcut: "⌘2",
                action: onOpenKnowledgeVault
            ),
            PaletteItem(
                id: "action.openSettings",
                section: "Quick Actions",
                kind: .quickAction,
                title: "Open Settings",
                subtitle: "Configure models, permissions, sources, and knowledge",
                icon: "gearshape",
                shortcut: "⌘,",
                action: onOpenSettings
            ),
            PaletteItem(
                id: "action.openOnboardingTour",
                section: "Quick Actions",
                kind: .quickAction,
                title: "Run Setup & Onboarding Tour…",
                subtitle: "Revisit Relay’s setup and interactive examples",
                icon: "sparkles",
                shortcut: nil,
                action: { onOpenSetup?() }
            )
        ]
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return all }
        return all.filter {
            $0.title.localizedStandardContains(term) ||
            ($0.subtitle?.localizedStandardContains(term) == true)
        }
    }

    private var threadItems: [PaletteItem] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let threads = store.threadArchive.threads
        let matching = term.isEmpty ? Array(threads.prefix(8)) : searchResult.threads.compactMap { id in threads.first { $0.id == id } }
        return matching.prefix(8).map { thread in
            PaletteItem(
                id: "thread.\(thread.id.uuidString)",
                section: "Saved Chat Threads",
                kind: .thread,
                title: thread.title,
                subtitle: thread.preview,
                icon: thread.isPinned ? "pin.fill" : "bubble.left.and.bubble.right",
                shortcut: nil,
                action: { onSelectThread(thread.id) }
            )
        }
    }

    private var noteItems: [PaletteItem] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = term.isEmpty ? Array(vaultNotes.prefix(6)) : searchResult.notes.compactMap { id in vaultNotes.first { $0.id == id } }
        return matching.prefix(6).map { note in
            PaletteItem(
                id: "note.\(note.id)",
                section: "Knowledge Vault Notes",
                kind: .note,
                title: note.title,
                subtitle: note.folderName ?? "Notes",
                icon: "doc.text",
                shortcut: nil,
                action: { onSelectNote(note) }
            )
        }
    }

    private var allItems: [PaletteItem] {
        quickActionItems + threadItems + noteItems
    }

    var body: some View {
        let items = allItems
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(RelayColors.textSecondary)
                TextField("Type a command, thread, or Knowledge Vault note…", text: $query)
                    .font(.relayBody)
                    .focused($focused)
                    .textFieldStyle(.plain)
                    .relayTextField()
                    .accessibilityIdentifier("workspace.commandPalette.search")
                    .onSubmit {
                        if items.indices.contains(selectedIndex) {
                            items[selectedIndex].action()
                        } else if let first = items.first {
                            first.action()
                        }
                    }
                RelayIconButton(icon: "xmark", label: "Close command palette") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }

            if items.isEmpty {
                Text(searching ? "Searching conversations and notes…" : "No matching commands, threads, or Knowledge Vault notes.")
                    .font(.relayCaption)
                    .foregroundStyle(RelayColors.textSecondary)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(["Quick Actions", "Saved Chat Threads", "Knowledge Vault Notes"], id: \.self) { sectionTitle in
                            let sectionItems = items.enumerated().filter { $0.element.section == sectionTitle }
                            if !sectionItems.isEmpty {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(sectionTitle)
                                        .font(.relayCaptionStrong)
                                        .foregroundStyle(RelayColors.textMuted)
                                        .padding(.horizontal, 8)
                                        .padding(.top, 2)

                                    ForEach(sectionItems, id: \.element.id) { globalIndex, item in
                                        let isSelected = globalIndex == selectedIndex
                                        Button {
                                            selectedIndex = globalIndex
                                            item.action()
                                        } label: {
                                            HStack(spacing: 10) {
                                                Image(systemName: item.icon)
                                                    .font(.system(size: 12, weight: .semibold))
                                                    .foregroundStyle(isSelected ? RelayColors.textPrimary : RelayColors.textSecondary)
                                                    .frame(width: 18)

                                                VStack(alignment: .leading, spacing: 1) {
                                                    Text(item.title)
                                                        .font(.relayCallout.weight(.medium))
                                                        .foregroundStyle(RelayColors.textPrimary)
                                                        .lineLimit(1)
                                                    if let subtitle = item.subtitle, !subtitle.isEmpty {
                                                        Text(subtitle)
                                                            .font(.relayMicro)
                                                            .foregroundStyle(RelayColors.textSecondary)
                                                            .lineLimit(1)
                                                    }
                                                }

                                                Spacer(minLength: 8)

                                                if let shortcut = item.shortcut {
                                                    Text(shortcut)
                                                        .font(.relayMonoSmall)
                                                        .foregroundStyle(RelayColors.textMuted)
                                                        .padding(.horizontal, 6)
                                                        .padding(.vertical, 2)
                                                        .background(RelayColors.subtleFill, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                                                }
                                            }
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 7)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(
                                                isSelected ? RelayColors.activeFill : Color.clear,
                                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            )
                                            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                        }
                                        .buttonStyle(RelayPressStyle())
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
        }
        .padding(18)
        .frame(width: 520)
        .background(RelayColors.canvas)
        .onChange(of: query) { _, _ in
            selectedIndex = 0
            searchResult = .init(threads: [], notes: [])
            searching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        .task(id: searchRevision) {
            guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                searching = false
                return
            }
            searching = true
            do {
                try await Task.sleep(for: .milliseconds(120))
                let result = try await CommandPaletteSearch.search(
                    threads: store.threadArchive.threads,
                    notes: vaultNotes.map { .init(id: $0.url, title: $0.title, body: $0.body) }, query: query)
                try Task.checkCancellation()
                let previousItems = allItems
                let selectedID = previousItems.indices.contains(selectedIndex) ? previousItems[selectedIndex].id : nil
                searchResult = result
                selectedIndex = selectedID.flatMap { id in allItems.firstIndex { $0.id == id } } ?? 0
                searching = false
            } catch is CancellationError {
                // The replacement query owns the status and results.
            } catch {
                searching = false
            }
        }
        .onKeyPress(.downArrow) {
            guard !items.isEmpty else { return .ignored }
            selectedIndex = (selectedIndex + 1) % items.count
            return .handled
        }
        .onKeyPress(.upArrow) {
            guard !items.isEmpty else { return .ignored }
            selectedIndex = (selectedIndex - 1 + items.count) % items.count
            return .handled
        }
        .task {
            vaultNotes = (try? KnowledgeVaultManager.shared.loadNotes()) ?? []
            await Task.yield()
            guard !Task.isCancelled else { return }
            focused = true
        }
    }
}

private struct SidebarThreadRow: View {
    let thread: SavedConversationThread
    let isSelected: Bool
    let isDisabled: Bool
    let onSelect: () -> Void
    var onRename: (String) -> Void = { _ in }
    var onTogglePin: () -> Void = {}
    var onCopyMarkdown: () -> Void = {}
    var onExportMarkdown: () -> Void = {}
    let onDelete: () -> Void

    @State private var hovered = false
    @FocusState private var actionsFocused: Bool
    @State private var showRenameAlert = false
    @State private var renameDraft = ""

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private var relativeTimestamp: String {
        let interval = Date().timeIntervalSince(thread.updatedAt)
        if abs(interval) < 45 {
            return "now"
        }
        return Self.relativeFormatter.localizedString(for: thread.updatedAt, relativeTo: Date())
    }

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            Button(action: onSelect) {
                HStack(alignment: .center, spacing: 6) {
                    if thread.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(RelayColors.textMuted)
                            .accessibilityLabel("Pinned")
                    }
                    Text(thread.title)
                        .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                        .foregroundStyle(isSelected ? RelayColors.textPrimary : (hovered ? RelayColors.textPrimary : RelayColors.textSecondary))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .help("Updated \(relativeTimestamp) · \(thread.preview)")

            Menu {
                Button("Rename…", systemImage: "pencil") {
                    renameDraft = thread.title
                    showRenameAlert = true
                }
                .disabled(isDisabled)
                Button(thread.isPinned ? "Unpin" : "Pin", systemImage: "pin") { onTogglePin() }.disabled(isDisabled)
                Button("Copy as Markdown", systemImage: "doc.on.doc") { onCopyMarkdown() }
                Button("Export…", systemImage: "square.and.arrow.up") { onExportMarkdown() }
                Divider()
                Button("Move to Trash", systemImage: "trash", role: .destructive) { onDelete() }.disabled(isDisabled)
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 11, weight: .regular))
                    .foregroundStyle(RelayColors.textSecondary)
                    .frame(width: 22, height: 24).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .focused($actionsFocused)
            .opacity(hovered || isSelected || actionsFocused ? 1 : 0)
            .accessibilityHidden(false)
            .accessibilityLabel("Actions for \(thread.title)")

        }
        .padding(.horizontal, 10)
        .padding(.vertical, 0)
        .frame(height: 30)
        .background(
            isSelected ? RelayColors.activeFill : (hovered ? RelayColors.hoverFill : Color.clear),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Open Thread") { onSelect() }
                .disabled(isDisabled)
            Button("Rename Thread…") {
                renameDraft = thread.title
                showRenameAlert = true
            }
            .disabled(isDisabled)
            Button("Pin / Unpin Thread") {
                onTogglePin()
            }
            .disabled(isDisabled)
            Divider()
            Button("Copy Thread as Markdown") {
                onCopyMarkdown()
            }
            Button("Export as Markdown…") {
                onExportMarkdown()
            }
            Divider()
            Button("Move to Trash", role: .destructive) { onDelete() }
                .disabled(isDisabled)
        }
        .accessibilityActions {
            Button("Move conversation to Trash") { onDelete() }.disabled(isDisabled)
            Button("Rename conversation") { renameDraft = thread.title; showRenameAlert = true }.disabled(isDisabled)
        }
        .alert("Rename Thread", isPresented: $showRenameAlert) {
            TextField("Thread title", text: $renameDraft)
            Button("Save") {
                onRename(renameDraft)
            }
            .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace.sidebar.thread.\(thread.id.uuidString)")
    }
}

extension ImageInspectionView {
    init(store: AssistantStore) {
        self.init(
            inspection: store.imageInspection,
            configuration: store.configuration,
            textModelIsLoaded: store.textModelIsLoaded,
            otherWorkInProgress: store.isRunning || store.voice.isBusy,
            canStartTask: store.actionsReady,
            onStartTask: { request, description in
                try store.startWindowTask(request: request, reviewedDescription: description)
            }
        )
    }
}

// MARK: - Relay Architectural Home Feature Showcase Deck

struct RelayHomeFeatureShowcaseDeck: View {
    @Binding var selectedPreview: MainView.HomeFeaturePreviewKind?
    @Binding var selectedConstellationNoteIndex: Int
    var onConfigureDoubleTap: () -> Void
    var onOpenMorningBrief: () -> Void
    var onOpenKnowledgeVault: () -> Void
    var onTrySidekickPrompt: () -> Void

    @State private var doubleTapReplayCount = 0
    @State private var doubleTapDraftVisible = true
    @State private var doubleTapPressedKey = 0
    @State private var doubleTapToneIndex = 0
    @State private var autopilotStepIndex = 2
    @AppStorage(RelayAppearanceMode.storageKey) private var appearanceModeRaw: String = RelayAppearanceMode.dark.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isDarkAppearance: Bool {
        RelayAppearanceMode.fromStored(appearanceModeRaw) != .light
    }

    private var relayEmerald: Color {
        isDarkAppearance ? Color(red: 0.20, green: 0.83, blue: 0.60) : RelayColors.accentEmerald
    }

    private struct SampleConstellationNote {
        let shortTitle: String
        let title: String
        let domain: String
        let accent: Color
        let summary: String
        let backlinks: [String]
    }

    private static let constellationNotes: [SampleConstellationNote] = [
        SampleConstellationNote(
            shortTitle: "Northstar",
            title: "Northstar pilot",
            domain: "PROJECTS",
            accent: Color(red: 0.369, green: 0.416, blue: 0.824),
            summary: "Expanding pilot from 20 to 80 seats. SSO security checklist is the final gate before Friday’s rollout.",
            backlinks: ["[[Alex Chen]]", "[[Friday rollout]]"]
        ),
        SampleConstellationNote(
            shortTitle: "Alex",
            title: "Alex Chen",
            domain: "PEOPLE",
            accent: Color(red: 0.20, green: 0.83, blue: 0.60),
            summary: "VP of Engineering at Northstar. Requested the SSO identity provider checklist ahead of Thursday’s review.",
            backlinks: ["[[Northstar pilot]]", "[[SSO review]]"]
        ),
        SampleConstellationNote(
            shortTitle: "Friday",
            title: "Friday rollout",
            domain: "COMMITMENTS",
            accent: Color(red: 0.055, green: 0.647, blue: 0.914),
            summary: "Production rollout scheduled for Friday morning once Thursday’s 2:30 PM security review signs off.",
            backlinks: ["[[Northstar pilot]]", "[[Alex Chen]]"]
        )
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let active = selectedPreview {
                showcasePreviewCard(active)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)))
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(MainView.HomeFeaturePreviewKind.allCases) { item in
                    let isSelected = selectedPreview == item
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                            selectedPreview = isSelected ? nil : item
                        }
                    } label: {
                        HStack(alignment: .center, spacing: 10) {
                            Image(systemName: item.icon)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(isSelected ? RelayColors.accentBlue : RelayColors.textSecondary)
                                .frame(width: 30, height: 30)
                                .background(
                                    isDarkAppearance ? Color.white.opacity(0.05) : RelayColors.surface,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                )

                            VStack(alignment: .leading, spacing: 2.5) {
                                Text(item.title)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(RelayColors.textPrimary)
                                    .lineLimit(1)
                                Text(item.subtitle)
                                    .font(.system(size: 11))
                                    .foregroundStyle(RelayColors.textSecondary)
                                    .lineLimit(1)
                            }
                            .layoutPriority(1)

                            Spacer(minLength: 4)

                            Image(systemName: isSelected ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(isSelected ? RelayColors.textPrimary : RelayColors.textMuted)
                        }
                        .padding(.horizontal, 13)
                        .frame(maxWidth: .infinity, minHeight: 58, maxHeight: 58, alignment: .leading)
                        .background(
                            isDarkAppearance
                                ? Color.white.opacity(isSelected ? 0.065 : 0.03)
                                : (isSelected ? RelayColors.surfaceElevated : RelayColors.cardBG),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(
                                    isSelected
                                        ? (isDarkAppearance ? Color.white.opacity(0.18) : RelayColors.borderStrong)
                                        : (isDarkAppearance ? Color.white.opacity(0.08) : RelayColors.borderSubtle),
                                    lineWidth: 1
                                )
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(RelayPressStyle())
                    .accessibilityIdentifier("home.showcase.\(item.rawValue)")
                }
            }
        }
        .frame(maxWidth: 660)
    }

    @ViewBuilder
    private func showcasePreviewCard(_ kind: MainView.HomeFeaturePreviewKind) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                        selectedPreview = nil
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(RelayColors.textSecondary)
                        .frame(width: 24, height: 24)
                        .background(
                            isDarkAppearance ? Color.white.opacity(0.06) : RelayColors.surface,
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close \(kind.title) example")

                Text(kind.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(RelayColors.textPrimary)

                Spacer()

                Text("Example")
                    .font(.relayCaption)
                    .foregroundStyle(RelayColors.textMuted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Rectangle()
                .fill(isDarkAppearance ? Color.white.opacity(0.06) : RelayColors.borderSubtle)
                .frame(height: 1)

            Text("Illustrative content. These examples don’t read your apps or run a task.")
                .font(.relayCaption)
                .foregroundStyle(RelayColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.top, 12)

            Group {
                switch kind {
                case .doubleTap:
                    doubleTapShowcaseContent
                case .proactive:
                    proactiveShowcaseContent
                case .knowledge:
                    knowledgeShowcaseContent
                case .sidekick:
                    sidekickShowcaseContent
                }
            }
            .padding(14)
        }
        .background(
            isDarkAppearance ? Color(red: 0.055, green: 0.063, blue: 0.086) : RelayColors.cardBG,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isDarkAppearance ? Color.white.opacity(0.12) : RelayColors.borderDefault,
                    lineWidth: 1
                )
        )
    }

    private var doubleTapShowcaseContent: some View {
        let toneLabels = ["Concise", "Warm", "Executive"]
        let draftVariants = [
            "Hey Alex, yes, let’s expand the pilot. I’ll send the SSO checklist before Thursday’s review; we’re still on track for Friday.",
            "Hi Alex! Thrilled to expand the pilot to 80 seats. I’ll share the SSO checklist ahead of Thursday’s 2:30 PM sync so Friday’s launch goes smoothly.",
            "Alex — confirmed for 80 seats. I will deliver the SSO security checklist prior to Thursday’s 2:30 PM review to keep Friday’s rollout on schedule."
        ]
        let draftText = draftVariants[min(max(0, doubleTapToneIndex), draftVariants.count - 1)]
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("A")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(RelayColors.textPrimary)
                    .frame(width: 28, height: 28)
                    .background(
                        isDarkAppearance ? Color.white.opacity(0.07) : RelayColors.surface,
                        in: Circle()
                    )
                VStack(alignment: .leading, spacing: 1.5) {
                    Text("Alex Chen · Northstar rollout")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(RelayColors.textPrimary)
                    Text("Can we expand the pilot? What do you need from us before Friday?")
                        .font(.system(size: 11.5))
                        .foregroundStyle(RelayColors.textSecondary)
                }
                Spacer(minLength: 8)
                Button {
                    doubleTapReplayCount &+= 1
                } label: {
                    Label("Replay", systemImage: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            isDarkAppearance ? Color.white.opacity(0.06) : RelayColors.surface,
                            in: Capsule()
                        )
                }
                .buttonStyle(RelayPressStyle())

                Button("Configure Shortcut", action: onConfigureDoubleTap)
                    .buttonStyle(RelaySecondaryButtonStyle())
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Label("Instant Draft Reply", systemImage: "arrowshape.turn.up.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(RelayColors.textSecondary)

                    HStack(spacing: 4) {
                        ForEach(Array(toneLabels.enumerated()), id: \.offset) { idx, label in
                            let isSelected = doubleTapToneIndex == idx
                            Button {
                                doubleTapToneIndex = idx
                                doubleTapReplayCount &+= 1
                            } label: {
                                Text(label)
                                    .font(.system(size: 10, weight: isSelected ? .semibold : .medium))
                                    .foregroundStyle(isSelected ? RelayColors.textPrimary : RelayColors.textSecondary)
                                    .padding(.horizontal, 8)
                                    .frame(height: 20)
                                    .background(
                                        isSelected ? RelayColors.accentBlue.opacity(0.22) : Color.white.opacity(isDarkAppearance ? 0.04 : 0.08),
                                        in: Capsule()
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.leading, 4)

                    Spacer()
                    HStack(spacing: 4) {
                        doubleTapKeycap(index: 1)
                        doubleTapKeycap(index: 2)
                    }
                }

                ZStack(alignment: .topLeading) {
                    Text(draftText).hidden()
                    Text(doubleTapDraftVisible ? draftText : "Synthesizing draft from local notes…")
                        .foregroundStyle(doubleTapDraftVisible ? RelayColors.textPrimary : RelayColors.textMuted)
                }
                .font(.system(size: 12.5))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    RelayBadge("Pilot notes", icon: "doc.text.fill")
                    RelayBadge("Thursday review", icon: "calendar")
                    Spacer()
                    Text("Click any tone pill above to re-draft live.")
                        .font(.system(size: 11))
                        .foregroundStyle(RelayColors.textMuted)
                }
            }
            .padding(12)
            .background(
                isDarkAppearance ? Color.white.opacity(0.025) : RelayColors.surface,
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(
                        isDarkAppearance ? Color.white.opacity(0.08) : RelayColors.borderSubtle,
                        lineWidth: 1
                    )
            )
        }
        .task(id: doubleTapReplayCount) {
            guard doubleTapReplayCount > 0, !reduceMotion else { return }
            withAnimation(.easeOut(duration: 0.12)) {
                doubleTapDraftVisible = false
                doubleTapPressedKey = 1
            }
            try? await Task.sleep(for: .milliseconds(130))
            doubleTapPressedKey = 0
            try? await Task.sleep(for: .milliseconds(90))
            doubleTapPressedKey = 2
            try? await Task.sleep(for: .milliseconds(150))
            doubleTapPressedKey = 0
            withAnimation(.easeOut(duration: 0.22)) {
                doubleTapDraftVisible = true
            }
        }
    }

    private func doubleTapKeycap(index: Int) -> some View {
        let isPressed = doubleTapPressedKey == index
        return Text("Right ⌘")
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(isPressed ? RelayColors.textPrimary : RelayColors.textSecondary)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(
                isDarkAppearance
                    ? Color.white.opacity(isPressed ? 0.18 : 0.05)
                    : (isPressed ? RelayColors.activeFill : RelayColors.cardBG),
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(
                        isDarkAppearance ? Color.white.opacity(0.14) : RelayColors.borderSubtle,
                        lineWidth: 1
                    )
            )
    }

    private var proactiveShowcaseContent: some View {
        let coral = Color(red: 1.0, green: 0.42, blue: 0.45)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Prepared in Morning Brief", systemImage: "sun.horizon.fill")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(RelayColors.textPrimary)
                Text("2 ITEMS READY")
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .tracking(1.4)
                    .foregroundStyle(RelayColors.textMuted)
                Spacer()
                Button("Open Morning Brief", action: onOpenMorningBrief)
                    .buttonStyle(RelaySecondaryButtonStyle())
            }

            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("FOLLOW-UP · DRAFT READY")
                        .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                        .tracking(1.3)
                        .foregroundStyle(relayEmerald)
                    Text("Follow-up ready for Alex Chen")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(RelayColors.textPrimary)
                    Text("Synthesized from your pilot notes with the Thursday SSO security review checklist attached.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(RelayColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(
                    isDarkAppearance ? Color.white.opacity(0.025) : RelayColors.surface,
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(relayEmerald.opacity(0.28), lineWidth: 1)
                )

                VStack(alignment: .leading, spacing: 6) {
                    Text("RENEWAL ALERT · $149")
                        .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                        .tracking(1.3)
                        .foregroundStyle(coral)
                    Text("Pulse analytics trial renews tomorrow")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(RelayColors.textPrimary)
                    Text("Your evaluation note marked Pulse as out-of-scope. A cancellation checklist is queued for review.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(RelayColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(
                    isDarkAppearance ? Color.white.opacity(0.025) : RelayColors.surface,
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(coral.opacity(0.28), lineWidth: 1)
                )
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var knowledgeShowcaseContent: some View {
        let clampedIndex = min(max(0, selectedConstellationNoteIndex), Self.constellationNotes.count - 1)
        let activeNote = Self.constellationNotes[clampedIndex]

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Canvas { context, size in
                    let rect = CGRect(origin: .zero, size: size)
                    context.fill(Path(rect), with: .color(Color(red: 0.031, green: 0.035, blue: 0.051)))

                    let center = CGPoint(x: size.width * 0.48, y: size.height * 0.48)
                    let nodes: [(CGPoint, Color, String)] = [
                        (center, Color(red: 0.369, green: 0.416, blue: 0.824), "Northstar pilot"),
                        (CGPoint(x: size.width * 0.22, y: size.height * 0.28), Color(red: 0.20, green: 0.83, blue: 0.60), "Alex Chen"),
                        (CGPoint(x: size.width * 0.78, y: size.height * 0.34), Color(red: 0.055, green: 0.647, blue: 0.914), "Friday rollout"),
                        (CGPoint(x: size.width * 0.64, y: size.height * 0.78), Color(red: 0.55, green: 0.75, blue: 1.00), "SSO review")
                    ]

                    for idx in 1..<nodes.count {
                        var line = Path()
                        line.move(to: nodes[0].0)
                        line.addLine(to: nodes[idx].0)
                        context.stroke(
                            line,
                            with: .linearGradient(
                                Gradient(colors: [nodes[0].1.opacity(0.65), nodes[idx].1.opacity(0.45)]),
                                startPoint: nodes[0].0,
                                endPoint: nodes[idx].0
                            ),
                            lineWidth: 1.2
                        )
                    }

                    for (idx, node) in nodes.enumerated() {
                        let isFocused = idx == clampedIndex
                        let haloR: CGFloat = isFocused ? 14 : 9
                        let haloRect = CGRect(x: node.0.x - haloR, y: node.0.y - haloR, width: haloR * 2, height: haloR * 2)
                        context.fill(
                            Path(ellipseIn: haloRect),
                            with: .radialGradient(
                                Gradient(colors: [node.1.opacity(isFocused ? 0.55 : 0.28), .clear]),
                                center: node.0,
                                startRadius: 0,
                                endRadius: haloR
                            )
                        )
                        let coreR: CGFloat = isFocused ? 3.5 : 2.5
                        let coreRect = CGRect(x: node.0.x - coreR, y: node.0.y - coreR, width: coreR * 2, height: coreR * 2)
                        context.fill(Path(ellipseIn: coreRect), with: .color(.white))
                    }
                }
                .frame(width: 210, height: 108)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))

                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(activeNote.domain)
                            .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                            .tracking(1.6)
                            .foregroundStyle(activeNote.accent)
                        Spacer()
                        Text("57 NOTES · PLAIN MARKDOWN")
                            .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                            .tracking(1.2)
                            .foregroundStyle(RelayColors.textMuted)
                    }
                    Text(activeNote.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(RelayColors.textPrimary)
                    Text(activeNote.summary)
                        .font(.system(size: 11.5))
                        .foregroundStyle(RelayColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        ForEach(activeNote.backlinks, id: \.self) { link in
                            Text(link)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(RelayColors.accentBlue)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2.5)
                                .background(RelayColors.accentBlue.opacity(0.10), in: Capsule())
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 7) {
                Text("Inspect node")
                    .font(.system(size: 11))
                    .foregroundStyle(RelayColors.textSecondary)
                ForEach(Array(Self.constellationNotes.enumerated()), id: \.offset) { idx, note in
                    let isSelected = idx == clampedIndex
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                            selectedConstellationNoteIndex = idx
                        }
                    } label: {
                        Text(note.shortTitle)
                            .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected ? RelayColors.textPrimary : RelayColors.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                isSelected
                                    ? (isDarkAppearance ? Color.white.opacity(0.12) : RelayColors.surfaceElevated)
                                    : (isDarkAppearance ? Color.white.opacity(0.04) : RelayColors.surface),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(RelayPressStyle())
                }
                Spacer()
                Button("Open Knowledge Vault", action: onOpenKnowledgeVault)
                    .buttonStyle(RelaySecondaryButtonStyle())
            }
        }
    }

    private var sidekickShowcaseContent: some View {
        let stages = [
            ("1. Inspect Context", "Reads [[Northstar pilot]] & Calendar"),
            ("2. Verify Blocker", "Finds Thursday 2:30 PM SSO review"),
            ("3. Stage Call Brief", "3 talking points & checklist ready")
        ]
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 7) {
                    RelayMark(size: 16)
                    Text("Relay Autopilot")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(RelayColors.textSecondary)
                }
                Spacer()
                Text("“Prep me for tomorrow’s Northstar call.”")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(RelayColors.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        isDarkAppearance ? Color.white.opacity(0.065) : RelayColors.surface,
                        in: Capsule()
                    )
            }

            HStack(spacing: 8) {
                ForEach(Array(stages.enumerated()), id: \.offset) { idx, stage in
                    let isDone = idx <= autopilotStepIndex
                    Button {
                        withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.8)) {
                            autopilotStepIndex = idx
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(isDone ? relayEmerald : RelayColors.textMuted)
                                Text(stage.0)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(RelayColors.textPrimary)
                                    .lineLimit(1)
                            }
                            Text(stage.1)
                                .font(.system(size: 10))
                                .foregroundStyle(RelayColors.textSecondary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            isDone ? relayEmerald.opacity(0.10) : Color.white.opacity(isDarkAppearance ? 0.025 : 0.06),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(isDone ? relayEmerald.opacity(0.35) : RelayColors.borderSubtle, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Text("Alex wants to expand the pilot from 20 to 80 seats. SSO is the last blocker, and you committed to sending the security checklist before Thursday’s 2:30 PM review.")
                .font(.system(size: 12.5))
                .lineSpacing(2.5)
                .foregroundStyle(RelayColors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                RelayBadge("Pilot notes", icon: "doc.text.fill")
                RelayBadge("Alex’s email", icon: "envelope.fill")
                RelayBadge("3 talking points", icon: "sparkles", tint: RelayColors.accentBlue, prominent: true)
                Spacer()
                Button("Try in Composer", action: onTrySidekickPrompt)
                    .buttonStyle(RelaySecondaryButtonStyle())
            }
        }
    }
}
