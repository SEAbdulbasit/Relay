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
    @State private var settingsDestination: SettingsDestination?
    @State private var atLatest = true
    @State private var userScrollInProgress = false
    @State private var latestGeometryNearBottom = true
    @FocusState private var composerFocused: Bool

    private let workspaceColumnWidth: CGFloat = 720

    private var isUserTaskActive: Bool {
        [.thinking, .acting, .awaitingReview].contains(store.phase) || store.accessibilityCheckRunning || store.isAuxiliaryBusy
    }

    var body: some View {
        ZStack {
            RelayAtmosphere(focused: composerFocused)

            VStack(spacing: 0) {
                header
                    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                        computerAccessReady = AXIsProcessTrusted()
                    }
                    .onChange(of: settingsDestination) { _, _ in computerAccessReady = AXIsProcessTrusted() }
                Divider().overlay(RelayTheme.line)
                if !computerAccessReady {
                    HStack(spacing: 12) {
                        Label("Mac control needs permission", systemImage: "cursorarrow.motionlines")
                            .font(.system(size: 13))
                        Spacer()
                        Button("Set up access") { settingsDestination = .access }
                            .buttonStyle(RelaySecondaryButtonStyle())
                    }
                    .padding(.horizontal, 24).padding(.vertical, 8)
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
                    .padding(.horizontal, 28)
                    .padding(.vertical, 10)
                }

                if workspacePage == .knowledge {
                    KnowledgeView(store: store, startInConstellation: false)
                        .padding(24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    HStack(spacing: 0) {
                        VStack(spacing: 0) {
                            if store.messages.isEmpty {
                                GeometryReader { geo in
                                    ScrollView {
                                        VStack(spacing: 24) {
                                            Spacer(minLength: 16)
                                            welcome
                                            conversationDock
                                            welcomeSuggestions
                                            Spacer(minLength: 24)
                                        }
                                        .frame(maxWidth: .infinity, minHeight: geo.size.height)
                                    }
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            } else {
                                conversation
                                conversationDock
                            }
                        }
                        if store.showActivity && viewportWidth >= 1200 {
                            Divider().overlay(RelayTheme.line)
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
        .sheet(isPresented: $store.showImageInspection) {
            ImageInspectionView(inspection: store.imageInspection, configuration: store.configuration,
                textModelIsLoaded: store.textModelIsLoaded,
                otherWorkInProgress: (store.isRunning && !store.imageInspection.isBusy) || store.voice.isBusy)
        }
        .onAppear {
            if store.messages.isEmpty && !isUserTaskActive {
                store.showActivity = false
            }
        }
        .onDisappear { store.stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in store.stop() }
        .task {
            guard !store.workspaceActionsReady else { return }
            if store.configuration.modelPath.isEmpty,
               let installed = ModelManifest.catalog.first(where: { ModelManifest.resolveInstalledURL(for: $0) != nil }) {
                await store.selectCatalogModel(installed)
            } else {
                await store.refreshModels()
            }
        }
    }

    private var activeModelDisplayName: String {
        if store.workspaceUsesCodex { return "ChatGPT via Codex CLI" }
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
        ZStack {
            // Center Zone: Workspace | Knowledge Segmented Switcher
            HStack(spacing: 2) {
                HeaderWorkspaceTabButton(
                    title: "Workspace",
                    icon: "bubble.left.and.text.bubble.right",
                    accent: RelayColors.textPrimary,
                    active: workspacePage == .workspace
                ) {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        workspacePage = .workspace
                    }
                }
                HeaderWorkspaceTabButton(
                    title: "Knowledge",
                    icon: "books.vertical",
                    accent: RelayColors.textPrimary,
                    active: workspacePage == .knowledge
                ) {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        workspacePage = .knowledge
                    }
                }
                .disabled(store.pendingReview != nil)
            }
            .padding(3)
            .frame(height: 32)
            .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.07), lineWidth: 1))

            // Leading & Trailing Zones
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        workspacePage = .workspace
                    }
                } label: {
                    HStack(spacing: 8) {
                        SpinningLogo(size: 18, fast: isUserTaskActive)
                        Text("Relay")
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundStyle(RelayColors.textPrimary)
                    }
                    .frame(height: 32)
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(RelayPressStyle())

                if viewportWidth >= 980 {
                    HeaderModelSelectorMenu(
                        store: store,
                        modelName: activeModelDisplayName,
                        actionsReady: store.workspaceActionsReady,
                        isPreparing: store.isPreparingModel
                    ) {
                        settingsDestination = .model
                    }
                }

                Spacer()

                if isUserTaskActive || store.pendingReview != nil || store.voice.isBusy || store.speech.isActive || store.knowledgeSearch.isBusy || store.speechDiagnostic.isBusy {
                    Button { store.stop() } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .font(.system(size: 12.5, weight: .medium))
                    }
                    .buttonStyle(RelaySecondaryButtonStyle())
                    .help("Stop current actions (⌘.)")
                }

                if !store.messages.isEmpty && workspacePage == .workspace {
                    Button {
                        store.clearConversation()
                    } label: {
                        Label("New Chat", systemImage: "square.and.pencil")
                            .font(.system(size: 12.5, weight: .medium))
                    }
                    .buttonStyle(RelaySecondaryButtonStyle())
                    .disabled(store.isRunning || store.isClearingConversation)
                    .help("Clear this conversation and start a new chat")
                }

                if workspacePage == .workspace {
                    HeaderActivityToggleButton(isOpen: store.showActivity, compact: viewportWidth < 1040) {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            store.showActivity.toggle()
                        }
                    }
                }

                RelayIconButton(icon: "gearshape", label: "Open settings", size: 32, iconSize: 13) {
                    settingsDestination = .model
                }
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 48)
        .background(RelayColors.pitch)
    }

    // MARK: - Centered ChatGPT / Antigravity Empty State (`welcome` + `welcomeSuggestions`)

    private var welcome: some View {
        VStack(spacing: 12) {
            RelayMark(size: 32, illuminated: false)
                .padding(.bottom, 4)

            Text("What can I help with?")
                .font(.system(size: 28, weight: .medium, design: .default))
                .foregroundStyle(RelayColors.textPrimary)

            Text(store.workspaceUsesCodex ? "Plan with ChatGPT and run actions through Relay on this Mac." : "Work across your Mac apps, find local files, and inspect pages privately on this Mac.")
                .font(.system(size: 14, weight: .regular, design: .default))
                .foregroundStyle(RelayColors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
        }
        .padding(.horizontal, 32)
    }

    private var welcomeSuggestions: some View {
        VStack(spacing: 14) {
            RelayChipFlow(spacing: 8) {
                WelcomeTaskChip(title: "Open Calculator", icon: "plus.forwardslash.minus") {
                    store.draft = "Open Calculator"
                    composerFocused = true
                }
                WelcomeTaskChip(title: "Read Safari page", icon: "safari") {
                    store.draft = "Read the active page in Safari and summarize its key takeaways."
                    composerFocused = true
                }
                if store.workspaceUsesCodex {
                    WelcomeTaskChip(title: "Check a calculation", icon: "equal") {
                        store.draft = "What is 48 × 37?"
                        composerFocused = true
                    }
                } else {
                    WelcomeTaskChip(title: "Find local files", icon: "folder") {
                        store.draft = "What files are available in my connected folders?"
                        composerFocused = true
                    }
                    WelcomeTaskChip(title: "Prep next meeting", icon: "calendar") {
                        store.draft = "Read my upcoming calendar for the next 7 days and search my knowledge base for relevant notes."
                        composerFocused = true
                    }
                    WelcomeTaskChip(title: "Catch follow-ups", icon: "tray.full") {
                        store.draft = "Search my connected files and notes for open TODOs or pending follow-ups."
                        composerFocused = true
                    }
                    WelcomeTaskChip(title: "Create PDF brief", icon: "doc.richtext") {
                        store.draft = "Create a PDF summary document in my connected folder from my recent notes."
                        composerFocused = true
                    }
                }
                WelcomeTaskChip(title: "Explore capabilities", icon: "sparkles") {
                    store.draft = "What can you help me do?"
                    composerFocused = true
                }
            }
            .frame(maxWidth: workspaceColumnWidth - 48)
            .disabled(!store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 32)
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
                .padding(.horizontal, RelayTheme.inset).padding(.vertical, 24)
                .frame(maxWidth: RelayTheme.contentWidth)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.visible)
            .onAppear {
                if !store.messages.isEmpty { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(atLatest ? .bottom : nil, for: .sizeChanges)
            .overlay(alignment: .bottom) {
                if !atLatest && !store.messages.isEmpty {
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
                    RelayRoleBadge(role: "Executor")
                    Text("Working with your Mac…").font(.system(size: 14)).foregroundStyle(RelayTheme.muted)
                } else if store.phase == .thinking {
                    RelayRoleBadge(role: "Planner")
                    Text("Planning the next step…").font(.system(size: 14)).foregroundStyle(RelayTheme.muted)
                } else {
                    Text(store.isPreparingModel ? "Preparing local model…" : store.accessibilityCheckRunning ? "Checking Mac controls…" : store.focusedDraft.isBusy ? "Drafting in the source app…" : store.isAuxiliaryBusy ? "Finishing current work…" : store.workspaceUsesCodex ? "Working on your request…" : "Thinking on this Mac…")
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
                        .font(.system(size: 14.5, weight: .regular, design: .default))
                        .foregroundStyle(RelayColors.textPrimary)
                        .textSelection(.enabled)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10.5)
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
                    HStack(spacing: 8) {
                        if let role = parsed.role {
                            RelayRoleBadge(role: role)
                        } else {
                            SpinningLogo(size: 16, fast: false, paused: true)
                            Text(message.role == "assistant" ? "Relay" : "System")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(RelayColors.textBright)
                        }
                        Spacer()

                        if message.role == "assistant", store.speech.isEnabled {
                            RelayIconButton(
                                icon: store.speech.activeMessageID == message.id ? "stop.circle.fill" : "speaker.wave.2",
                                label: store.speech.activeMessageID == message.id ? "Stop reading response" : "Read this response aloud",
                                size: 30,
                                iconSize: 12
                            ) {
                                if store.speech.activeMessageID == message.id { store.speech.stop() }
                                else { store.readAloud(message) }
                            }
                            .disabled(store.isRunning || store.voice.isBusy)
                        }
                    }
                    .foregroundStyle(RelayTheme.muted)

                    let parts = parsed.cleanText.components(separatedBy: "\n\nChecked by Relay:\n")
                    let primaryProse = parts[0].replacingOccurrences(of: "\n\nNo computer actions were executed in this response.", with: "")

                    if parts.count > 1 {
                        DisclosureGroup {
                            Text(parts.dropFirst().joined(separator: "\n\nChecked by Relay:\n"))
                                .font(.system(size: 12, design: .monospaced))
                                .lineSpacing(3)
                                .textSelection(.enabled)
                                .foregroundStyle(RelayColors.textSecondary)
                                .padding(.top, 4)
                                .padding(.leading, 8)
                                .overlay(alignment: .leading) {
                                    Rectangle()
                                        .fill(Color.white.opacity(0.12))
                                        .frame(width: 1.5)
                                }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.shield.fill")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(RelayColors.accentEmerald)
                                Text("Action evidence")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(RelayColors.textSecondary)
                            }
                        }
                        .disclosureGroupStyle(RelayDisclosureGroupStyle(accent: RelayColors.textBright, verticalPadding: 5, horizontalPadding: 9, cornerRadius: 8))
                    }

                    Text(.init(primaryProse))
                        .font(.system(size: 15, weight: .regular, design: .default))
                        .foregroundStyle(RelayColors.textPrimary)
                        .lineSpacing(5)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !message.artifacts.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12)], spacing: 12) {
                    ForEach(message.artifacts, id: \.self) { path in
                        Button { store.revealArtifact(path) } label: {
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

    // MARK: - Conversation Dock & Elevated Two-Row Composer (ChatGPT macOS & Antigravity Style)

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

            if store.phase == .stopped {
                HStack(spacing: 12) {
                    Image(systemName: "pause.circle.fill").foregroundStyle(RelayColors.accentCoral)
                    Text("Task stopped. Inspect activities or resume execution.")
                        .font(.system(size: 13)).foregroundStyle(RelayTheme.muted)
                    Spacer()
                    Button("Inspect & resume") { store.resume() }
                        .buttonStyle(RelaySecondaryButtonStyle())
                }
                .padding(12)
                .relayLitCard(accent: RelayColors.accentCoral, cornerRadius: 12)
            }

            if store.showActivity && viewportWidth < 1200 && store.pendingReview == nil {
                activityPanel.frame(maxHeight: 160)
            }

            composer

            if !store.messages.isEmpty || store.workspaceUsesCodex {
                HStack(spacing: 6) {
                    Circle()
                        .fill(store.workspaceUsesCodex ? RelayColors.accentBlue : store.actionsReady ? RelayColors.accentEmerald : RelayColors.textMuted)
                        .frame(width: 4.5, height: 4.5)
                        .accessibilityHidden(true)
                    Text(store.workspaceUsesCodex ? "ChatGPT receives messages you send here" : "\(activeModelDisplayName) · Local inference on this Mac")
                        .font(.system(size: 11.5))
                        .foregroundStyle(RelayColors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .frame(maxWidth: workspaceColumnWidth)
        .padding(.horizontal, 24)
        .padding(.bottom, store.messages.isEmpty ? 4 : 16)
        .padding(.top, 4)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Two-Row Elevated Composer Card (ChatGPT macOS / Antigravity Style)

    private var composer: some View {
        let hasText = !store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: 12) {
            // Top Row: Multiline Prompt Field
            TextField("", text: $store.draft, axis: .vertical)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(RelayColors.textPrimary)
                .textFieldStyle(.plain)
                .lineLimit(1...(store.pendingReview == nil ? 5 : 2))
                .overlay(alignment: .leading) {
                    if store.draft.isEmpty {
                        if store.phase == .thinking || store.phase == .acting {
                            Text("Add a constraint or steer current task…")
                                .foregroundStyle(RelayColors.textSecondary)
                                .font(.system(size: 15))
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        } else {
                            Text(store.workspaceUsesCodex ? "Message Relay with ChatGPT…" : "Message Relay or ask it to work across your Mac…")
                                .foregroundStyle(RelayColors.textSecondary)
                                .font(.system(size: 15))
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .focused($composerFocused)
                .onSubmit { submitMessage() }
                .accessibilityLabel("Message Relay or steer current task")
                .padding(.horizontal, 4)
                .padding(.top, 2)

            // Bottom Row: Utility Controls (+ Attach, Model Picker, Folder Scope, Voice Mic, Send Button)
            HStack(alignment: .center, spacing: 8) {
                Button {
                    showAttachPopover.toggle()
                } label: {
                    Image(systemName: store.workspaceUsesCodex ? "ellipsis" : "plus")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(RelayColors.textSecondary)
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.06), in: Circle())
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
                        .contentShape(Circle())
                }
                .buttonStyle(RelayPressStyle())
                .help(store.workspaceUsesCodex ? "Workspace tools" : "Attach files or folders")
                .accessibilityLabel(store.workspaceUsesCodex ? "Workspace tools" : "Add task context")
                .popover(isPresented: $showAttachPopover, arrowEdge: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        if !store.workspaceUsesCodex {
                            Button {
                                showAttachPopover = false
                                store.chooseFiles()
                            } label: {
                                Label("Attach Files…", systemImage: "doc.badge.plus")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                            }
                            .buttonStyle(.plain)
                            Button {
                                showAttachPopover = false
                                store.chooseFolder()
                            } label: {
                                Label("Add Folder…", systemImage: "folder.badge.plus")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
                        Button {
                            showAttachPopover = false
                            store.showImageInspection = true
                        } label: {
                            Label(store.workspaceUsesCodex ? "Inspect Image or Window Locally…" : "Inspect Image or Window…", systemImage: "photo")
                                .font(.system(size: 12.5, weight: .medium))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        .disabled(store.isRunning)
                        Button {
                            showAttachPopover = false
                            store.showActivity.toggle()
                        } label: {
                            Label(store.showActivity ? "Hide Activity Log" : "Show Activity Log", systemImage: "waveform.path")
                                .font(.system(size: 12.5, weight: .medium))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(8)
                    .frame(width: store.workspaceUsesCodex ? 244 : 196)
                }

                // Inline Model Picker Pill (like ChatGPT / Antigravity)
                Button {
                    showComposerModelPopover.toggle()
                } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(store.workspaceUsesCodex ? RelayColors.accentBlue : store.workspaceActionsReady ? RelayColors.accentEmerald : RelayColors.accentAmber)
                            .frame(width: 5.5, height: 5.5)
                            .accessibilityHidden(true)
                        Text(activeModelDisplayName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(RelayColors.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 170)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(RelayColors.textMuted)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Color.white.opacity(0.045), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
                    .contentShape(Capsule())
                }
                .buttonStyle(RelayPressStyle())
                .help("Switch workspace model")
                .popover(isPresented: $showComposerModelPopover, arrowEdge: .top) {
                    WorkspaceModelOptions(store: store, modelName: activeModelDisplayName, close: {
                        showComposerModelPopover = false
                    }) {
                        settingsDestination = .model
                    }
                }

                // Folder Scope Pill
                if !store.workspaceUsesCodex {
                    Button {
                        store.chooseFolder()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: store.grants.isEmpty ? "folder.badge.plus" : "folder")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(RelayColors.textSecondary)
                            Text(store.grants.isEmpty ? "Connect folder" : "\(store.grants.count) folder\(store.grants.count == 1 ? "" : "s")")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(RelayColors.textSecondary)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(Color.white.opacity(0.045), in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(RelayPressStyle())
                    .help("Connect a local folder for file search")
                }

                Spacer()

                RelayIconButton(icon: "mic", label: "Open local voice input", size: 30, iconSize: 12.5) {
                    store.speech.stop()
                    showVoiceInput = true
                }
                .disabled(store.isRunning || store.isClearingConversation)
                .help("Local voice dictation")

                Button { submitMessage() } label: {
                    ZStack {
                        Circle()
                            .fill(hasText ? Color.white : Color.white.opacity(0.08))
                            .frame(width: 32, height: 32)
                        Image(systemName: store.workspaceActionsReady || store.isRunning ? "arrow.up" : "gearshape")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(hasText ? RelayColors.buttonInk : RelayColors.textMuted)
                    }
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
                }
                .buttonStyle(RelayPressStyle())
                .disabled(store.isPreparingModel || store.checkingCodex || store.isClearingConversation || store.isAuxiliaryBusy || !hasText)
                .accessibilityLabel(store.isPreparingModel ? "Model preparing" : !store.workspaceActionsReady && !store.isRunning ? "Setup model" : store.isRunning ? "Send steering message" : "Send message")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RelayColors.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(
                    Color.white.opacity(composerFocused ? 0.18 : 0.09),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(0.32), radius: 18, y: 6)
    }

    private func submitMessage() {
        guard !store.isClearingConversation, !store.isPreparingModel, !store.checkingCodex, !store.isAuxiliaryBusy else { return }
        guard store.workspaceActionsReady || store.isRunning else {
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
                                    Text(presentation.status).font(.system(size: 12)).foregroundStyle(RelayColors.textSecondary)
                                }
                                Spacer(minLength: 0)
                            }

                            DisclosureGroup("View details") {
                                Text(entry.detail).font(.system(size: 12.5, design: .monospaced)).lineSpacing(3)
                                    .foregroundStyle(RelayColors.textSecondary).textSelection(.enabled)
                                    .padding(.top, 2)
                            }
                            .disclosureGroupStyle(RelayDisclosureGroupStyle(accent: RelayColors.textBright, verticalPadding: 6, horizontalPadding: 8, cornerRadius: 8))
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
        }
        .padding(16)
        .background(RelayColors.cardBG, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Review Card

    private func reviewCard(_ review: PendingReview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(review.sharesWithOpenAI ? "Share this excerpt with OpenAI?" : "Action Approval Required", systemImage: "hand.raised.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(RelayColors.accentAmber)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(review.reason).font(.system(size: 14)).foregroundStyle(RelayTheme.ink).textSelection(.enabled)
                    if !review.sharesWithOpenAI {
                        Text(review.call.name).font(.relayMono).foregroundStyle(RelayColors.accentEmerald)
                        Text(JSONValue.object(review.call.arguments).pretty)
                            .font(.relayMono).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 150).scrollIndicators(.visible)

            Text(review.sharesWithOpenAI ? "Sharing sends the entire excerpt above to ChatGPT, including any text you scroll to view." : "Approval applies only to this action.")
                .font(.relayCaption).foregroundStyle(RelayColors.textSecondary)

            HStack {
                Spacer()
                Button(review.sharesWithOpenAI ? "Keep on This Mac" : "Decline") { store.denyReview() }.buttonStyle(RelaySecondaryButtonStyle())
                Button(review.sharesWithOpenAI ? "Share Excerpt" : "Approve Action") { store.approveReview() }.buttonStyle(RelayPrimaryButtonStyle())
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
        .padding(.horizontal, 40).padding(.bottom, 6)
    }
}

// MARK: - Header & Suggestion Subcomponents (ChatGPT macOS & Antigravity Style)

private struct HeaderModelSelectorMenu: View {
    let store: AssistantStore
    let modelName: String
    let actionsReady: Bool
    var isPreparing: Bool = false
    let openSettings: () -> Void
    @State private var hovered = false
    @State private var showPopover = false

    var body: some View {
        let dotColor = store.workspaceUsesCodex ? RelayColors.accentBlue : actionsReady ? RelayColors.accentEmerald : RelayColors.accentAmber
        Button {
            showPopover.toggle()
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                Text(isPreparing ? "Preparing model…" : (actionsReady ? modelName : "Set up model"))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(hovered ? RelayColors.textPrimary : RelayColors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 170)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(RelayColors.textMuted)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Color.white.opacity(hovered ? 0.07 : 0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(hovered ? 0.14 : 0.07), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(RelayPressStyle())
        .help("Switch workspace model")
        .onHover { hovered = $0 }
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            WorkspaceModelOptions(store: store, modelName: modelName, close: { showPopover = false }, openSettings: openSettings)
        }
    }
}

private struct WorkspaceModelOptions: View {
    let store: AssistantStore
    let modelName: String
    let close: () -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(ModelManifest.catalog, id: \.filename) { manifest in
                if ModelManifest.resolveInstalledURL(for: manifest) != nil {
                    let selected = !store.workspaceUsesCodex && modelName == manifest.displayName
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

private struct HeaderWorkspaceTabButton: View {
    let title: String
    let icon: String
    let accent: Color
    let active: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(active ? RelayColors.textPrimary : (hovered ? RelayColors.textBright : RelayColors.textSecondary))
                Text(title)
                    .font(.system(size: 12.5, weight: active ? .medium : .regular))
                    .foregroundStyle(active || hovered ? RelayColors.textPrimary : RelayColors.textSecondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(active ? RelayColors.surfaceElevated : (hovered ? Color.white.opacity(0.04) : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(RelayPressStyle())
        .onHover { hovered = $0 }
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

private struct HeaderActivityToggleButton: View {
    let isOpen: Bool
    var compact = false
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 11.5))
                    .foregroundStyle(isOpen ? RelayColors.textPrimary : RelayColors.textSecondary)
                if !compact {
                    Text(isOpen ? "Hide Activity" : "Activity")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(isOpen || hovered ? RelayColors.textPrimary : RelayColors.textSecondary)
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 32)
            .background(Color.white.opacity(isOpen ? 0.09 : (hovered ? 0.06 : 0.035)), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(hovered || isOpen ? 0.14 : 0.07), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(RelayPressStyle())
        .onHover { hovered = $0 }
        .accessibilityLabel(isOpen ? "Hide activity" : "Show activity")
        .help(isOpen ? "Hide activity" : "Show activity")
        .accessibilityValue(isOpen ? "Shown" : "Hidden")
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
