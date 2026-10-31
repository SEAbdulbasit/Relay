import SwiftUI
import AppKit

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

    @State private var viewportWidth: CGFloat = 1200
    @State private var workspacePage: WorkspacePage = .workspace
    @State private var showVoiceInput = false
    @State private var settingsDestination: SettingsDestination?
    @State private var atLatest = true
    @State private var userScrollInProgress = false
    @State private var latestGeometryNearBottom = true
    @FocusState private var composerFocused: Bool

    var body: some View {
        ZStack {
            RelayTheme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Divider().overlay(RelayTheme.line)

                if let error = store.errorMessage { errorBanner(error) }
                if let error = store.speech.errorMessage {
                    errorBanner("Read aloud: " + error, dismiss: { store.speech.errorMessage = nil })
                }
                if let notice = store.selectionNotice {
                    HStack {
                        if notice.hasPrefix("Select calendars again") {
                            DisclosureGroup {
                                Text(notice).font(.relayCaption).textSelection(.enabled).padding(.top, 6)
                            } label: {
                                Text("Choose calendars again to use calendar context").font(.system(size: 13))
                            }
                            Spacer()
                            Button("Choose calendars") { settingsDestination = .knowledge }
                                .buttonStyle(RelaySecondaryButtonStyle())
                        } else {
                            Text(notice).font(.relayCaption).textSelection(.enabled)
                            Spacer()
                        }
                        Button { store.selectionNotice = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).accessibilityLabel("Dismiss selected-text notice")
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
                                welcome
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            } else {
                                conversation
                            }
                            conversationDock
                        }
                        if store.showActivity && viewportWidth >= 960 {
                            Divider().overlay(RelayTheme.line)
                            activityPanel
                                .frame(width: 300)
                                .background(RelayTheme.sidebar)
                        }
                    }
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
        .tint(RelayColors.accentEmerald)
        .foregroundStyle(RelayTheme.ink)
        .sheet(item: $settingsDestination) { destination in
            SettingsView(store: store, onOpenSetup: onOpenSetup, initialSection: destination.rawValue)
        }
        .sheet(isPresented: $showVoiceInput) { VoiceInputView(store: store) }
        .onAppear {
            if store.messages.isEmpty && !store.isRunning {
                store.showActivity = false
            }
        }
        .onDisappear { store.stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in store.stop() }
        .onChange(of: store.isRunning) { _, running in if running { store.showActivity = true } }
        .task { if !store.actionsReady { await store.refreshModels() } }
    }

    // MARK: - Clean Navigation Header

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    workspacePage = .workspace
                }
            } label: {
                HStack(spacing: 9) {
                    RelayMark(size: 22)
                    Text("Relay")
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)

            // Model readiness pill
            Button {
                settingsDestination = .model
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(store.actionsReady ? RelayColors.accentEmerald : RelayColors.accentAmber)
                        .frame(width: 6, height: 6)
                    Text(store.actionsReady ? "Local model ready" : "Set up model")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(RelayColors.textSecondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.04), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
            }
            .buttonStyle(.plain)

            Spacer()

            if store.isRunning || store.pendingReview != nil || store.voice.isBusy || store.speech.isActive || store.knowledgeSearch.isBusy || store.speechDiagnostic.isBusy {
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
                    Text("New Chat")
                        .font(.system(size: 12.5, weight: .medium))
                }
                .buttonStyle(RelaySecondaryButtonStyle())
            }

            // Workspace / Knowledge segmented pill
            HStack(spacing: 2) {
                headerTabButton(.workspace, label: "Workspace", icon: "bubble.left")
                headerTabButton(.knowledge, label: "Knowledge", icon: "folder")
            }
            .padding(3)
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.07), lineWidth: 1))

            if workspacePage == .workspace {
                Button { store.showActivity.toggle() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "sidebar.right")
                            .font(.system(size: 11.5))
                        Text(store.showActivity ? "Hide Activity" : "Activity")
                            .font(.system(size: 12.5, weight: .medium))
                    }
                    .foregroundStyle(RelayColors.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(store.showActivity ? 0.09 : 0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityValue(store.showActivity ? "Shown" : "Hidden")
            }

            Button { settingsDestination = .model } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(RelayColors.textSecondary)
                    .frame(width: 32, height: 32)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open settings")
        }
        .padding(.horizontal, 24)
        .frame(height: 52)
    }

    private func headerTabButton(_ page: WorkspacePage, label: String, icon: String) -> some View {
        let active = workspacePage == page
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                workspacePage = page
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                Text(label)
                    .font(.system(size: 12.5, weight: active ? .semibold : .medium))
            }
            .foregroundStyle(active ? .white : RelayColors.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(active ? Color.white.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Clean Welcome Empty State (Matches Onboarding 560pt Geometry)

    private var welcome: some View {
        VStack(spacing: 24) {
            VStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                        .frame(width: 44, height: 44)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                        )
                    Image(systemName: "arrow.triangle.swap")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                }

                Text("How can I help on your Mac?")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)

                Text("Ask Relay to work across your Mac apps, search your connected folders, or summarize local documents.")
                    .font(.system(size: 14.5))
                    .foregroundStyle(RelayColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 480)
            }

            VStack(spacing: 10) {
                starterPromptRow(
                    icon: "plus.forwardslash.minus",
                    title: "Open Calculator",
                    detail: "Launch macOS Calculator and verify its window is ready.",
                    prompt: "Open Calculator"
                )
                starterPromptRow(
                    icon: "folder",
                    title: "Summarize my local files",
                    detail: "List and summarize documents in your connected folders.",
                    prompt: "What files are available in my connected folders?"
                )
                starterPromptRow(
                    icon: "sparkles",
                    title: "What can you help me do?",
                    detail: "Explore Mac automation, file search, and local tools.",
                    prompt: "What can you help me do?"
                )
            }
            .padding(18)
            .frame(width: 560)
            .background(RelayColors.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .padding(.horizontal, 32)
    }

    private func starterPromptRow(icon: String, title: String, detail: String, prompt: String) -> some View {
        Button {
            store.draft = prompt
            composerFocused = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(RelayColors.textSecondary)
                    .frame(width: 32, height: 32)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(detail)
                        .font(.system(size: 12.5))
                        .foregroundStyle(RelayColors.textSecondary)
                }

                Spacer()

                Image(systemName: "arrow.up.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(RelayColors.textMuted)
            }
            .padding(12)
            .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(RelayPressStyle())
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
            if store.pendingReview != nil {
                Image(systemName: "hand.raised.fill").foregroundStyle(RelayColors.accentAmber)
                Text("Waiting for your action review").font(.system(size: 14, weight: .medium)).foregroundStyle(RelayColors.accentAmber)
            } else {
                ProgressView().controlSize(.small)
                if store.phase == .acting {
                    RelayRoleBadge(role: "Executor")
                    Text("Working with your Mac…").font(.system(size: 14)).foregroundStyle(RelayTheme.muted)
                } else if store.phase == .thinking {
                    RelayRoleBadge(role: "Planner")
                    Text("Planning the next step…").font(.system(size: 14)).foregroundStyle(RelayTheme.muted)
                } else {
                    Text(store.isPreparingModel ? "Preparing local model…" : store.accessibilityCheckRunning ? "Checking Mac controls…" : "Thinking on this Mac…")
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
                    Spacer(minLength: 80)
                    Text(message.text)
                        .font(.relayBody)
                        .textSelection(.enabled)
                        .padding(.horizontal, 18).padding(.vertical, 12)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    let parsed = extractRoleAndContent(from: message.text, defaultRole: message.role)
                    HStack(spacing: 8) {
                        if let role = parsed.role {
                            RelayRoleBadge(role: role)
                        } else {
                            RelayMark(size: 18, illuminated: false)
                            Text(message.role == "assistant" ? "Relay" : "System")
                                .font(.system(size: 13, weight: .medium))
                        }
                        Spacer()

                        if message.role == "assistant", store.speech.isEnabled {
                            Button {
                                if store.speech.activeMessageID == message.id { store.speech.stop() }
                                else { store.readAloud(message) }
                            } label: {
                                Image(systemName: store.speech.activeMessageID == message.id ? "stop.circle.fill" : "speaker.wave.2")
                                    .frame(width: 32, height: 32)
                            }
                            .buttonStyle(.plain)
                            .disabled(store.isRunning || store.voice.isBusy)
                            .accessibilityLabel(store.speech.activeMessageID == message.id ? "Stop reading response" : "Read this response aloud")
                        }
                    }
                    .foregroundStyle(RelayTheme.muted)

                    let parts = parsed.cleanText.components(separatedBy: "\n\nChecked by Relay:\n")
                    Text(.init(parts[0]))
                        .font(.relayBody)
                        .lineSpacing(5)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                    if parts.count > 1 {
                        DisclosureGroup {
                            Text(parts.dropFirst().joined(separator: "\n\nChecked by Relay:\n"))
                                .font(.system(size: 12.5, design: .monospaced))
                                .lineSpacing(3)
                                .textSelection(.enabled)
                                .foregroundStyle(RelayTheme.muted)
                                .padding(.top, 8)
                        } label: {
                            Label("Action evidence", systemImage: "checkmark.shield")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(RelayColors.accentEmerald)
                        }
                        .padding(12)
                        .relayGlassCard(cornerRadius: 12)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !message.artifacts.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12)], spacing: 12) {
                    ForEach(message.artifacts, id: \.self) { path in
                        Button { store.revealArtifact(path) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: ["xlsx", "csv"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) ? "tablecells" : "doc.richtext")
                                    .font(.system(size: 18)).foregroundStyle(RelayTheme.ink)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(URL(fileURLWithPath: path).lastPathComponent).font(.system(size: 14, weight: .medium)).lineLimit(2)
                                    Text("Show in Finder").font(.relayCaption).foregroundStyle(RelayTheme.muted)
                                }
                                Spacer()
                                Image(systemName: "arrow.up.right").foregroundStyle(RelayTheme.muted).font(.system(size: 12))
                            }
                            .padding(12)
                            .relayGlassCard(cornerRadius: 12)
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

    // MARK: - Clean Conversation Dock

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
                    Image(systemName: "pause.circle").foregroundStyle(RelayColors.accentCoral)
                    Text("Task stopped. Inspect activities or resume execution.")
                        .font(.system(size: 13)).foregroundStyle(RelayTheme.muted)
                    Spacer()
                    Button("Inspect & resume") { store.resume() }
                        .buttonStyle(RelaySecondaryButtonStyle())
                }
                .padding(12)
                .relayGlassCard(cornerRadius: 12)
            }

            if store.showActivity && viewportWidth < 960 && store.pendingReview == nil {
                activityPanel.frame(maxHeight: 160)
            }

            composer

            Text("100% Offline · Runs locally on Apple Silicon")
                .font(.system(size: 11.5))
                .foregroundStyle(RelayColors.textDim)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: 720)
        .padding(.bottom, 16)
        .padding(.top, 4)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Message Composer

    private var composer: some View {
        HStack(alignment: .center, spacing: 10) {
            Menu {
                Button("Attach Files…", systemImage: "doc.badge.plus") { store.chooseFiles() }
                Button("Add Folder…", systemImage: "folder.badge.plus") { store.chooseFolder() }
                Divider()
                Button(store.showActivity ? "Hide Activity Log" : "Show Activity Log", systemImage: "waveform.path") {
                    store.showActivity.toggle()
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(RelayColors.textSecondary)
                    .frame(width: 30, height: 30)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .menuStyle(.borderlessButton)
            .tint(.white)
            .fixedSize()
            .help("Attach files or folders")
            .accessibilityLabel("Add task context")

            TextField("", text: $store.draft, axis: .vertical)
                .font(.system(size: 14))
                .textFieldStyle(.plain)
                .lineLimit(1...(store.pendingReview == nil ? 4 : 2))
                .overlay(alignment: .leading) {
                    if store.draft.isEmpty {
                        if store.phase == .thinking || store.phase == .acting {
                            Text("Add a constraint or steer current task…")
                                .foregroundStyle(RelayTheme.muted)
                                .font(.system(size: 14))
                                .allowsHitTesting(false)
                        } else {
                            Text("Message Relay or ask it to work with your Mac…")
                                .foregroundStyle(RelayColors.textMuted)
                                .font(.system(size: 14))
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .focused($composerFocused)
                .onSubmit { submitMessage() }
                .accessibilityLabel("Message Relay or steer current task")

            Button { store.speech.stop(); showVoiceInput = true } label: {
                Image(systemName: "mic")
                    .font(.system(size: 13))
                    .foregroundStyle(RelayTheme.muted)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(RelayPressStyle())
            .disabled(store.isRunning || store.isClearingConversation)
            .help("Local voice dictation")
            .accessibilityLabel("Open local voice input")

            let hasText = !store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            Button { submitMessage() } label: {
                Image(systemName: store.actionsReady || store.isRunning ? "arrow.up" : "gearshape")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(hasText ? RelayColors.buttonInk : RelayTheme.muted)
                    .frame(width: 30, height: 30)
                    .background(hasText ? Color.white : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(RelayPressStyle())
            .disabled(store.isPreparingModel || store.isClearingConversation || !hasText)
            .accessibilityLabel(store.isPreparingModel ? "Model preparing" : !store.actionsReady && !store.isRunning ? "Setup model" : store.isRunning ? "Send steering message" : "Send message")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RelayColors.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(composerFocused ? 0.22 : 0.09), lineWidth: 1)
        )
    }

    private func submitMessage() {
        guard !store.isClearingConversation, !store.isPreparingModel else { return }
        guard store.actionsReady || store.isRunning else {
            settingsDestination = .model
            return
        }
        store.send()
    }

    // MARK: - Activity Panel

    private var activityPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Activity").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button { store.showActivity = false } label: {
                    Image(systemName: "xmark").frame(width: 28, height: 28)
                }.buttonStyle(.plain).accessibilityLabel("Close activity")
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if store.activity.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Image(systemName: "cursorarrow.motionlines").font(.system(size: 24)).foregroundStyle(RelayColors.textSecondary)
                            Text(store.isRunning ? "Working on your request" : "Follow along here").font(.system(size: 16, weight: .semibold))
                            Text("Actions and their results appear here as Relay works. You can stop a task at any time.").font(.system(size: 13)).lineSpacing(3).foregroundStyle(RelayColors.textSecondary)
                        }.padding(.vertical, 20)
                    }
                    ForEach(store.activity.reversed()) { entry in
                        let presentation = ActivityPresentation(name: entry.name, status: entry.status)
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: presentation.icon)
                                .foregroundStyle(presentation.verified ? RelayColors.accentEmerald : presentation.failed ? RelayColors.accentAmber : RelayColors.textSecondary)
                                .font(.system(size: 14)).frame(width: 20).padding(.top, 2)

                            VStack(alignment: .leading, spacing: 2) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(presentation.title).font(.system(size: 13, weight: .medium))
                                    Text(presentation.status).font(.system(size: 12)).foregroundStyle(RelayColors.textSecondary)
                                }
                                DisclosureGroup("View details") {
                                    Text(entry.detail).font(.system(size: 13)).lineSpacing(3)
                                        .foregroundStyle(RelayColors.textSecondary).textSelection(.enabled)
                                        .padding(.top, 6)
                                }.font(.system(size: 12)).padding(.top, 6)
                            }
                        }
                        .padding(.vertical, 12).padding(.horizontal, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .bottom) { Rectangle().fill(RelayTheme.line).frame(height: 1).padding(.leading, 30) }
                        .accessibilityElement(children: .contain)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(16)
        .background(RelayColors.cardBG, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Review Card

    private func reviewCard(_ review: PendingReview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Action Approval Required", systemImage: "hand.raised.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(RelayColors.accentAmber)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(review.reason).font(.system(size: 14)).foregroundStyle(RelayTheme.ink).textSelection(.enabled)
                    Text(review.call.name).font(.relayMono).foregroundStyle(RelayColors.accentEmerald)
                    Text(JSONValue.object(review.call.arguments).pretty)
                        .font(.relayMono).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 150).scrollIndicators(.visible)

            Text("Approval applies exclusively to this single action invocation.")
                .font(.relayCaption).foregroundStyle(RelayTheme.muted)

            HStack {
                Spacer()
                Button("Decline") { store.denyReview() }.buttonStyle(RelaySecondaryButtonStyle())
                Button("Approve Action") { store.approveReview() }.buttonStyle(RelayPrimaryButtonStyle())
            }
        }
        .padding(16)
        .background(RelayColors.accentAmber.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(RelayColors.accentAmber.opacity(0.35), lineWidth: 1))
    }

    // MARK: - Error Banner

    private func errorBanner(_ message: String, dismiss: (() -> Void)? = nil) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(RelayColors.accentCoral)
            Text(message).font(.system(size: 13)).textSelection(.enabled)
            Spacer()
            Button { if let dismiss { dismiss() } else { store.errorMessage = nil } } label: {
                Image(systemName: "xmark").font(.system(size: 12))
            }
            .buttonStyle(.plain).accessibilityLabel("Dismiss error")
        }
        .padding(12).background(RelayColors.accentCoral.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(RelayColors.accentCoral.opacity(0.3), lineWidth: 1))
        .padding(.horizontal, 40).padding(.bottom, 6)
    }
}
