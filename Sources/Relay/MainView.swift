import SwiftUI
import AppKit
import ApplicationServices

struct MainView: View {
    @Bindable var store: AssistantStore
    var onOpenSetup: (() -> Void)? = nil

    private enum SettingsDestination: String, Identifiable {
        case model = "Model", access = "Access", knowledge = "Knowledge"
        var id: String { rawValue }
    }

    enum WorkspacePage: String {
        case workspace = "Workspace"
        case knowledge = "Knowledge"
    }

    @State private var computerAccessReady = AXIsProcessTrusted()
    @State private var viewportWidth: CGFloat = 1200
    @State private var workspacePage: WorkspacePage = .workspace
    @State private var showVoiceInput = false
    @State private var showAttachPopover = false
    @State private var showComposerModelPopover = false
    @State private var showMorningBrief = false
    @State private var showConversationSearch = false
    @State private var conversationJump: ChatMessage.ID?
    @State private var settingsDestination: SettingsDestination?
    @State private var atLatest = true
    @State private var userScrollInProgress = false
    @State private var latestGeometryNearBottom = true
    @FocusState private var composerFocused: Bool

    private let workspaceColumnWidth = RelayTheme.contentWidth

    private var isUserTaskActive: Bool {
        [.thinking, .acting, .awaitingReview].contains(store.phase) || store.accessibilityCheckRunning || store.isAuxiliaryBusy
    }

    private var reservedSidebarWidth: CGFloat {
        workspacePage == .workspace && store.showActivity && viewportWidth >= 1200 ? 311 : 0
    }

    var body: some View {
        ZStack {
            RelayAtmosphere()

            VStack(spacing: 0) {
                header
                    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                        computerAccessReady = AXIsProcessTrusted()
                    }
                    .onChange(of: settingsDestination) { _, _ in computerAccessReady = AXIsProcessTrusted() }
                Rectangle().fill(RelayTheme.line).frame(height: 1)
                if !computerAccessReady {
                    HStack(spacing: 12) {
                        Label("Mac control needs permission", systemImage: "cursorarrow.motionlines")
                            .font(.system(size: 13))
                        Spacer()
                        Button("Set up access") { settingsDestination = .access }
                            .buttonStyle(RelaySecondaryButtonStyle())
                    }
                    .frame(maxWidth: workspaceColumnWidth)
                    .padding(.horizontal, RelayTheme.inset).padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .padding(.trailing, reservedSidebarWidth)
                }

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
                                Text("Choose calendars again to use calendar context").font(.system(size: 13, weight: .medium))
                            }
                            .disclosureGroupStyle(RelayDisclosureGroupStyle(accent: RelayColors.accentGold))
                            Spacer()
                            Button("Choose calendars") { settingsDestination = .knowledge }
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
                    .padding(.horizontal, RelayTheme.inset)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .padding(.trailing, reservedSidebarWidth)
                }

                if workspacePage == .knowledge {
                    KnowledgeView(store: store, startInConstellation: false)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    HStack(spacing: 0) {
                        VStack(spacing: 0) {
                            if store.messages.isEmpty {
                                GeometryReader { geometry in
                                    ScrollView {
                                        VStack(spacing: 22) {
                                            Spacer(minLength: 24)
                                            welcome
                                            welcomeSuggestions
                                            Spacer(minLength: 24)
                                        }
                                        .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                                    }
                                }
                            } else {
                                conversation
                            }
                            conversationDock
                                .layoutPriority(1)
                        }
                        if store.showActivity && viewportWidth >= 1200 {
                            Divider().overlay(RelayTheme.line).frame(width: 1)
                            activityPanel
                                .frame(width: 310)
                                .background(RelayTheme.sidebar)
                        }
                    }
                }
            }
        }
        .disclosureGroupStyle(RelayDisclosureGroupStyle())
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
        .onChange(of: store.pendingReview?.id) { _, reviewID in
            if reviewID != nil { workspacePage = .workspace }
        }
        .tint(RelayColors.textPrimary)
        .foregroundStyle(RelayTheme.ink)
        .sheet(item: $settingsDestination) { destination in
            SettingsView(store: store, onOpenSetup: onOpenSetup, initialSection: destination.rawValue)
        }
        .sheet(isPresented: $showVoiceInput) { VoiceInputView(store: store) }
        .sheet(isPresented: $showMorningBrief) {
            MorningBriefView(store: store) { workspacePage = .workspace }
        }
        .sheet(isPresented: $showConversationSearch) {
            ConversationSearchView(messages: store.messages) { message in
                atLatest = false
                conversationJump = message.id
                showConversationSearch = false
            }
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $store.showImageInspection) {
            ImageInspectionView(inspection: store.imageInspection, configuration: store.configuration,
                textModelIsLoaded: store.textModelIsLoaded,
                otherWorkInProgress: (store.isRunning && !store.imageInspection.isBusy) || store.voice.isBusy,
                canStartTask: store.actionsReady) { request, description in
                    try store.startWindowTask(request: request, reviewedDescription: description)
                    workspacePage = .workspace
                }
        }
        .onAppear {
            if store.messages.isEmpty && !isUserTaskActive {
                store.showActivity = false
            }
        }
        .task {
            await store.preparation.waitForCurrentPreparation()
            guard !Task.isCancelled, !store.workspaceActionsReady else { return }
            if store.configuration.backend == .liteRTLM, store.configuration.modelPath.isEmpty,
               let installed = ModelManifest.catalog.first(where: { ModelManifest.resolveInstalledURL(for: $0) != nil }) {
                await store.selectCatalogModel(installed)
            } else {
                await store.refreshModels()
            }
        }
    }

    private var activeModelDisplayName: String {
        if store.workspaceUsesCodex { return "ChatGPT via Codex CLI" }
        if store.configuration.backend == .lmStudio { return store.configuration.localModelDisplayName }
        let filename = URL(fileURLWithPath: store.configuration.modelPath).lastPathComponent
        if let match = ModelManifest.catalog.first(where: { $0.filename == filename }) {
            return match.displayName
        }
        if !filename.isEmpty {
            return filename.replacingOccurrences(of: ".litertlm", with: "")
        }
        return "Gemma 4"
    }

    // MARK: - Minimal Matte Graphite Header (ChatGPT macOS & Antigravity Style)

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                workspacePage = .workspace
            } label: {
                HStack(spacing: 9) {
                    RelayMark(size: 23)
                    Text("Relay").font(.system(size: 16, weight: .semibold))
                }
                .frame(height: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(RelayPressStyle())
            .accessibilityLabel("Relay Home")
            .accessibilityAddTraits(workspacePage == .workspace ? .isSelected : [])

            Spacer(minLength: 12)

            if isUserTaskActive || store.pendingReview != nil || store.voice.isBusy || store.speech.isActive || store.knowledgeSearch.isBusy || store.speechDiagnostic.isBusy {
                WorkspaceHeaderButton(title: "Stop", icon: "stop.fill") { store.stop() }
                    .help("Stop current actions (⌘.)")
            }

            WorkspaceHeaderButton(title: "Morning Brief", icon: "sun.horizon") { showMorningBrief = true }
                .disabled(store.isRunning || store.pendingReview != nil)
                .accessibilityIdentifier("workspace.morningBrief")

            WorkspaceHeaderButton(title: "Knowledge", icon: "books.vertical", selected: workspacePage == .knowledge) {
                workspacePage = .knowledge
            }
            .disabled(store.pendingReview != nil)

            if workspacePage == .workspace {
                if !store.messages.isEmpty {
                    Menu {
                        Button("Find in conversation…", systemImage: "magnifyingglass") {
                            Task { @MainActor in
                                await Task.yield()
                                composerFocused = false
                                showConversationSearch = true
                            }
                        }
                        .keyboardShortcut("f", modifiers: .command)
                        Button("New chat", systemImage: "square.and.pencil") { store.clearConversation() }
                            .disabled(store.isRunning || store.isClearingConversation)
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 34, height: 34)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("Conversation actions")
                }

                WorkspaceHeaderButton(title: store.showActivity ? "Hide activity" : "Show activity",
                                      icon: "sidebar.right", selected: store.showActivity, iconOnly: true) {
                    store.showActivity.toggle()
                }
                .accessibilityValue(store.showActivity ? "Shown" : "Hidden")
            }

            WorkspaceHeaderButton(title: "Open settings", icon: "gearshape", iconOnly: true) {
                settingsDestination = .model
            }
        }
        .padding(.horizontal, RelayTheme.inset)
        .frame(height: 56)
        .background(RelayColors.pitch)
    }

    private var welcome: some View {
        VStack(spacing: 12) {
            RelayMark(size: 48, illuminated: false)
                .padding(.bottom, 6)

            Text("What can I help you with?")
                .font(.system(size: 30, weight: .semibold))
                .accessibilityAddTraits(.isHeader)

            Text(store.workspaceUsesCodex ? "Use ChatGPT to plan tasks you ask Relay to run." : "Ask Relay to work across your apps, find a file, or prepare a draft.")
                .font(.relayBody)
                .foregroundStyle(RelayColors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .padding(.horizontal, RelayTheme.inset)
    }

    private var welcomeSuggestions: some View {
        HStack(spacing: 8) {
            WelcomeTaskChip(title: "Open Calculator", icon: "plus.forwardslash.minus") {
                fillExample("Open Calculator")
            }
            if store.workspaceActionsReady {
                WelcomeTaskChip(title: "Read Safari page", icon: "safari") {
                    fillExample("Read the active page in Safari and summarize its key takeaways.")
                }
            }
            if store.workspaceUsesCodex || !store.workspaceActionsReady {
                WelcomeTaskChip(title: "Check a calculation", icon: "equal") {
                    fillExample("What is 48 × 37?")
                }
            } else {
                WelcomeTaskChip(title: "Find local files", icon: "folder") {
                    fillExample("What files are available in my connected folders?")
                }
            }
        }
        .padding(.horizontal, RelayTheme.inset)
        .disabled(!store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func fillExample(_ prompt: String) {
        store.draft = prompt
        composerFocused = true
    }

    // MARK: - Conversation Stream

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(store.messages) { message in
                        messageRow(message)
                            .id(message.id)
                            .accessibilityElement(children: .contain)
                    }

                    if store.isRunning {
                        inFlightStatus
                            .id("inFlight")
                    }

                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: workspaceColumnWidth)
                .padding(.horizontal, RelayTheme.inset).padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.visible)
            .onAppear {
                if !store.messages.isEmpty { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(atLatest ? .bottom : nil, for: .sizeChanges)
            .overlay(alignment: .bottom) {
                if !atLatest && !latestGeometryNearBottom && !store.messages.isEmpty {
                    Button {
                        proxy.scrollTo("bottom", anchor: .bottom)
                        atLatest = true
                    } label: {
                        Label("Latest message", systemImage: "arrow.down")
                            .font(.system(size: 13, weight: .medium))
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
            .onChange(of: conversationJump) { _, target in
                guard let target else { return }
                proxy.scrollTo(target, anchor: .center)
                conversationJump = nil
            }
            .onChange(of: store.messages.count) { _, _ in
                if atLatest || store.messages.last?.role == "user" { proxy.scrollTo("bottom", anchor: .bottom) }
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
        HStack(spacing: 10) {
            if let review = store.pendingReview {
                Image(systemName: "hand.raised.fill").foregroundStyle(RelayColors.accentAmber)
                Text(review.sharesWithOpenAI ? "Waiting for your decision to share" : "Waiting for your action review")
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(RelayColors.accentAmber)
            } else {
                SpinningLogo(size: 18, fast: true)
                if store.phase == .acting {
                    Text("Working with your Mac…").font(.system(size: 14)).foregroundStyle(RelayTheme.muted)
                } else if store.phase == .thinking {
                    Text("Planning the next step…").font(.system(size: 14)).foregroundStyle(RelayTheme.muted)
                } else {
                    Text(store.isPreparingModel ? "Preparing local model…" : store.accessibilityCheckRunning ? "Checking Mac controls…" : store.focusedDraft.isBusy ? "Drafting in the source app…" : store.isAuxiliaryBusy ? "Finishing current work…" : store.workspaceUsesCodex ? "Working on your request…" : store.configuration.backend == .lmStudio ? "Working with LM Studio…" : "Thinking on this Mac…")
                        .font(.system(size: 14)).foregroundStyle(RelayTheme.muted)
                }
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private func messageRow(_ message: ChatMessage) -> some View {
        VStack(alignment: message.role == "user" ? .trailing : .leading, spacing: 10) {
            if message.role == "user" {
                HStack {
                    Spacer(minLength: 96)
                    Text(message.text)
                        .font(.relayBody)
                        .foregroundStyle(RelayColors.textPrimary)
                        .textSelection(.enabled)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            RelayColors.surfaceElevated,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                        )
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    let parsed = extractRoleAndContent(from: message.text, defaultRole: message.role)
                    if let role = parsed.role {
                        RelayRoleBadge(role: role)
                    } else if message.role != "assistant" {
                        Text("System").font(.relayCaption).foregroundStyle(RelayTheme.muted)
                    }

                    let response = RelayResponseText(parsed.cleanText)
                    Text(.init(response.body))
                        .font(.relayBody)
                        .foregroundStyle(RelayColors.textPrimary)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                    if let evidence = response.evidence {
                        RelayActionEvidence(text: evidence)
                    }
                    if message.role == "assistant", store.speech.isEnabled {
                        RelayIconButton(
                            icon: store.speech.activeMessageID == message.id ? "stop.circle.fill" : "speaker.wave.2",
                            label: store.speech.activeMessageID == message.id ? "Stop reading response" : "Read this response aloud",
                            size: 28, iconSize: 12
                        ) {
                            if store.speech.activeMessageID == message.id { store.speech.stop() }
                            else { store.readAloud(message) }
                        }
                        .disabled(store.isRunning || store.voice.isBusy)
                    }
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
                                    Text(URL(fileURLWithPath: path).lastPathComponent).font(.system(size: 14, weight: .medium)).lineLimit(2)
                                    Text("Show in Finder").font(.relayCaption).foregroundStyle(RelayTheme.muted)
                                }
                                Spacer()
                                Image(systemName: "arrow.up.right").foregroundStyle(RelayTheme.muted).font(.system(size: 12))
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
        .padding(.vertical, 4)
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
                        .font(.system(size: 13))
                    Spacer()
                    Button("Stop audio") { store.speech.stop() }.buttonStyle(RelaySecondaryButtonStyle())
                }
                .foregroundStyle(.white)
            }

            if let review = store.pendingReview { reviewCard(review) }

            if store.phase == .needsInput {
                HStack(spacing: 12) {
                    Label("Review incomplete or uncertain results.", systemImage: "exclamationmark.circle")
                        .font(.relayCaption).foregroundStyle(RelayColors.accentAmber)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Inspect activity") { store.showActivity = true }.buttonStyle(.link)
                    if store.canResumeCurrentTask {
                        Button("Continue") { store.resume() }.buttonStyle(RelaySecondaryButtonStyle())
                            .disabled(store.isAuxiliaryBusy)
                    } else {
                        Button("New task") { composerFocused = true }.buttonStyle(RelaySecondaryButtonStyle())
                    }
                }
                .padding(.vertical, 8)
                .accessibilityElement(children: .contain)
            }

            if store.phase == .stopped {
                HStack(spacing: 12) {
                    Image(systemName: "pause.circle.fill").foregroundStyle(RelayColors.accentCoral)
                    Text(store.canResumeCurrentTask ? "Task stopped. Inspect activities or resume execution." : "The earlier task is no longer active. Start a fresh task to continue.")
                        .font(.system(size: 13)).foregroundStyle(RelayTheme.muted)
                    Spacer()
                    if store.canResumeCurrentTask {
                        Button("Inspect & resume") { store.resume() }.buttonStyle(RelaySecondaryButtonStyle())
                    } else {
                        Button("New task") { composerFocused = true }.buttonStyle(RelaySecondaryButtonStyle())
                    }
                }
                .padding(12)
                .relayLitCard(accent: RelayColors.accentCoral, cornerRadius: 12)
            }

            if store.showActivity && viewportWidth < 1200 && store.pendingReview == nil {
                // A maximum alone lets the dock compress its scroll content to zero.
                activityPanel.frame(minHeight: 160, idealHeight: 180, maxHeight: 220)
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
        .padding(.horizontal, RelayTheme.inset)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
    }

    private var composer: some View {
        let hasText = !store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let isSteering = store.phase == .thinking || store.phase == .acting
        return VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message Relay", text: $store.draft,
                          prompt: Text(""),
                          axis: .vertical)
                    .font(.relayBody)
                    .textFieldStyle(.plain)
                    .relayTextFieldPrompt(isSteering ? "Steer the current task…" : "Ask Relay…", when: store.draft.isEmpty)
                    .lineLimit(1...(store.pendingReview == nil ? 5 : 2))
                    .focused($composerFocused)
                    .onSubmit { submitMessage() }
                    .accessibilityLabel("Message Relay or steer current task")
                    .padding(.leading, 4)
                    .padding(.vertical, 9)

                RelayIconButton(icon: "mic", label: "Open local voice input", size: 36, iconSize: 14) {
                    store.speech.stop()
                    showVoiceInput = true
                }
                .disabled(store.isRunning || store.isClearingConversation)

                Button { submitMessage() } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(hasText ? RelayColors.buttonInk : RelayColors.textSecondary)
                        .frame(width: 36, height: 36)
                        .background(hasText ? RelayColors.buttonFace : RelayColors.surfaceElevated, in: Circle())
                }
                .buttonStyle(RelayPressStyle())
                .disabled(store.isPreparingModel || store.checkingCodex || store.isClearingConversation || store.isAuxiliaryBusy || !hasText)
                .accessibilityLabel(store.isPreparingModel ? "Model preparing" : store.isRunning ? "Send steering message" : "Send message")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RelayColors.surface, in: RoundedRectangle(cornerRadius: RelayTheme.radius))
            .overlay {
                RoundedRectangle(cornerRadius: RelayTheme.radius)
                    .strokeBorder(composerFocused ? RelayColors.borderFocus : RelayColors.borderDefault)
            }

            HStack(spacing: 4) {
                WorkspaceHeaderButton(title: store.workspaceUsesCodex ? "Tools" : "Add context",
                                      icon: store.workspaceUsesCodex ? "ellipsis" : "plus") {
                    showAttachPopover.toggle()
                }
                .accessibilityLabel(store.workspaceUsesCodex ? "Workspace tools" : "Add task context")
                .popover(isPresented: $showAttachPopover, arrowEdge: .top) {
                    composerContext
                }
                Spacer(minLength: 8)
                WorkspaceHeaderButton(title: store.isPreparingModel ? "Preparing model…" : store.workspaceActionsReady ? activeModelDisplayName : "Set up model",
                                      icon: store.workspaceUsesCodex ? "cloud" : "desktopcomputer") {
                    showComposerModelPopover.toggle()
                }
                .help(store.workspaceUsesCodex ? "ChatGPT receives the messages you send here." : "Choose the model for this workspace.")
                .popover(isPresented: $showComposerModelPopover, arrowEdge: .top) {
                    WorkspaceModelOptions(store: store, modelName: activeModelDisplayName, close: {
                        showComposerModelPopover = false
                    }) {
                        settingsDestination = .model
                    }
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private var composerContext: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !store.workspaceUsesCodex {
                WorkspaceHeaderButton(title: "Attach files…", icon: "doc.badge.plus") {
                    showAttachPopover = false
                    store.chooseFiles()
                }
                WorkspaceHeaderButton(title: "Add folder…", icon: "folder.badge.plus") {
                    showAttachPopover = false
                    store.chooseFolder()
                }
            }
            WorkspaceHeaderButton(title: "Inspect image or window…", icon: "macwindow") {
                showAttachPopover = false
                store.showImageInspection = true
            }
            .disabled(store.isRunning)
        }
        .padding(8)
    }

    private func submitMessage() {
        guard !store.isClearingConversation, !store.isPreparingModel, !store.checkingCodex, !store.isAuxiliaryBusy else { return }
        guard store.workspaceActionsReady || store.isRunning || store.canRunWithoutModel(store.draft) else {
            settingsDestination = .model
            return
        }
        store.send(useWorkspaceProvider: true)
    }

    // MARK: - Activity Panel (Full-Row Clickable DisclosureGroup)

    private var activityPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 7) {
                    Circle().fill(RelayColors.textSecondary).frame(width: 6, height: 6)
                    Text("Activity").font(.system(size: 14, weight: .semibold))
                }
                Spacer()
                RelayIconButton(icon: "xmark", label: "Close activity", size: 32, iconSize: 11.5) {
                    store.showActivity = false
                }
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if store.activity.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            RelayIconBadge(icon: "cursorarrow.motionlines", color: RelayColors.textBright, size: 38)
                            Text(store.isRunning ? "Working on your request" : "Follow along here").font(.system(size: 15, weight: .semibold))
                            Text("Actions and their results appear here as Relay works. You can stop a task at any time.").font(.system(size: 13)).lineSpacing(3).foregroundStyle(RelayColors.textSecondary)
                        }.padding(.vertical, 20)
                    }
                    ForEach(store.activity.reversed()) { entry in
                        let presentation = ActivityPresentation(name: entry.name, status: entry.status)
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: presentation.icon)
                                    .foregroundStyle(presentation.verified ? RelayColors.accentEmerald : presentation.failed ? RelayColors.accentAmber : RelayColors.textSecondary)
                                    .font(.system(size: 14)).frame(width: 20).padding(.top, 2)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(presentation.title).font(.system(size: 13, weight: .medium))
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
                        .padding(.vertical, 10).padding(.horizontal, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .bottom) { Rectangle().fill(RelayTheme.line).frame(height: 1) }
                        .accessibilityElement(children: .contain)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
            .accessibilityIdentifier("activity.content")
        }
        .padding(16)
    }

    // MARK: - Review Card

    private func reviewCard(_ review: PendingReview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(review.title, systemImage: "hand.raised.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(RelayColors.accentAmber)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let visual = review.visualPresentation {
                        NativeVisualReviewView(presentation: visual).id(visual.id)
                    }
                    Text(review.reason).font(.system(size: 14)).foregroundStyle(RelayTheme.ink).textSelection(.enabled)
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
                   idealHeight: review.visualPresentation != nil ? 240 : review.hasStructuredMailReview ? 200 : 150,
                   maxHeight: review.visualPresentation != nil ? 340 : review.hasStructuredMailReview ? 240 : 150)
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
        .padding(16)
        .relayLitCard(accent: RelayColors.accentAmber, cornerRadius: 16)
    }

    // MARK: - Error Banner

    private func errorBanner(_ message: String, dismiss: (() -> Void)? = nil) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(RelayColors.accentCoral)
            Text(message).font(.system(size: 13)).textSelection(.enabled)
            Spacer()
            RelayIconButton(icon: "xmark", label: "Dismiss error", size: 32, iconSize: 11) {
                if let dismiss { dismiss() } else { store.errorMessage = nil }
            }
        }
        .padding(12).background(RelayColors.accentCoral.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(RelayColors.accentCoral.opacity(0.24), lineWidth: 1))
        .frame(maxWidth: workspaceColumnWidth)
        .padding(.horizontal, RelayTheme.inset).padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .padding(.trailing, reservedSidebarWidth)
    }
}

// MARK: - Header & Suggestion Subcomponents (ChatGPT macOS & Antigravity Style)

private struct WorkspaceModelOptions: View {
    let store: AssistantStore
    let modelName: String
    let close: () -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(ModelManifest.catalog, id: \.filename) { manifest in
                if ModelManifest.resolveInstalledURL(for: manifest) != nil {
                    let selected = !store.workspaceUsesCodex && store.configuration.backend == .liteRTLM && modelName == manifest.displayName
                    Button {
                        close()
                        store.selectWorkspaceLocal()
                        Task { await store.selectCatalogModel(manifest) }
                    } label: {
                        row(manifest.displayName, icon: selected ? "checkmark" : "cpu")
                    }
                    .buttonStyle(.plain)
                    .disabled(store.isRunning || store.checkingCodex)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            if store.workspaceUsesCodex {
                row("ChatGPT via Codex CLI", icon: "checkmark")
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isSelected)
                Button {
                    close()
                    store.selectWorkspaceLocal()
                    if !store.actionsReady { openSettings() }
                } label: {
                    row("Use Local Model", icon: "cpu")
                }
                .buttonStyle(.plain)
                .disabled(store.isRunning || store.checkingCodex)
            } else {
                Button {
                    close()
                    openSettings()
                } label: {
                    row("ChatGPT via Codex CLI…", icon: "cloud")
                }
                .buttonStyle(.plain)
            }
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
        .frame(width: 240)
    }

    private func row(_ title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
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
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 13, weight: .medium))
                if !iconOnly {
                    Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                }
            }
            .padding(.horizontal, iconOnly ? 0 : 10)
            .frame(minWidth: 36, minHeight: 36)
            .foregroundStyle(hovered || selected ? RelayColors.textPrimary : RelayColors.textBright)
            .background(selected ? RelayColors.surfaceElevated : hovered ? RelayColors.surface : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(RelayPressStyle())
        .onHover { hovered = $0 }
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(title)
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
                    .font(.relayHeadline.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                RelayIconButton(icon: "xmark", label: "Close conversation search", size: 32) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            TextField("Search messages", text: $query)
                .font(.relayBody)
                .focused($focused)
                .textFieldStyle(.roundedBorder)
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
                                        .font(.relayCaption.weight(.semibold))
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
        .background(RelayColors.pitch)
        .task {
            await Task.yield()
            guard !Task.isCancelled else { return }
            focused = true
        }
    }
}

private struct WelcomeTaskChip: View {
    let title: String
    let icon: String
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6.5) {
                Image(systemName: icon)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(hovered ? RelayColors.textPrimary : RelayColors.textSecondary)
                Text(title)
                    .font(.system(size: 12.5, weight: .medium, design: .default))
                    .foregroundStyle(hovered ? RelayColors.textPrimary : RelayColors.textSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 7.5)
            .background(
                Capsule(style: .continuous)
                    .fill(hovered ? RelayColors.surfaceElevated : RelayColors.cardBG)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(hovered ? 0.14 : 0.07), lineWidth: 1)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(RelayPressStyle())
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.14), value: hovered)
    }
}
