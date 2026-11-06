import SwiftUI
import AppKit

/// Five steps to choose a workspace model, understand app access, and start a request.
struct OnboardingView: View {
    @Bindable var coordinator: OnboardingCoordinator
    @Bindable var store: AssistantStore

    private enum ModelSetupTab: String, CaseIterable {
        case managed = "Gemma 4 E2B"
        case custom = "Custom .litertlm"
        case chatGPT = "ChatGPT"
    }

    @State private var chosenTask = "Open Calculator"
    @State private var modelTab: ModelSetupTab = .managed
    @Environment(\.scenePhase) private var scenePhase

    // Retained for accessibility labels and E2E lifecycle verification; never rendered as a "1/5" counter.
    private let steps = ["Welcome", "Privacy", "Model", "Mac Access", "Launchpad"]

    var body: some View {
        ZStack {
            RelayAtmosphere(focused: false)

            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 32)
                    .padding(.top, 20)

                ScrollView {
                    Group {
                        switch coordinator.step {
                        case 1:
                            privacyStep
                        case 2:
                            modelStep
                        case 3:
                            accessStep
                        case 4:
                            readyStep
                        default:
                            welcomeStep
                        }
                    }
                    .id(coordinator.step)
                    .transition(.opacity)
                    .frame(maxWidth: 640)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
                }

                trustFooter
                    .padding(.bottom, 22)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RelayColors.pitch)
        .foregroundStyle(RelayTheme.ink)
        .tint(RelayColors.accentBlue)
        .onAppear {
            coordinator.refreshPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            coordinator.refreshPermissions()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { coordinator.refreshPermissions() }
        }
    }

    // MARK: - Top Navigation Chrome (Sentient OS Back Pill + Quiet Step Dots + Skip)

    private var topBar: some View {
        ZStack {
            // Only completed steps are actionable. Keep current progress visible and readable.
            HStack(spacing: 8) {
                ForEach(0..<5, id: \.self) { index in
                    let isCurrent = coordinator.step == index
                    let isPast = coordinator.step > index
                    let marker = Capsule()
                        .fill(.white.opacity(isCurrent ? 0.88 : isPast ? 0.36 : 0.13))
                        .frame(width: isCurrent ? 20 : 6, height: 6)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 2)
                        .contentShape(Rectangle())
                    if isPast {
                        Button {
                            withAnimation(.easeInOut(duration: 0.24)) { coordinator.step = index }
                        } label: { marker }
                            .buttonStyle(.plain)
                            .accessibilityLabel(steps[index])
                            .disabled(coordinator.isPreparingModel || store.isPreparingModel || store.accessibilityCheckRunning)
                    } else {
                        marker
                            .accessibilityLabel(steps[index])
                            .accessibilityHidden(!isCurrent)
                            .accessibilityAddTraits(.isSelected)
                    }
                }
            }

            // Leading & Trailing controls
            HStack {
                if coordinator.step > 0 {
                    Button {
                        withAnimation(.easeInOut(duration: 0.24)) {
                            coordinator.step -= 1
                        }
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .buttonStyle(RelayBackButtonStyle())
                    .disabled(coordinator.isPreparingModel || store.isPreparingModel || store.accessibilityCheckRunning)
                } else {
                    HStack(spacing: 9) {
                        RelayMark(size: 19, illuminated: true)
                        Text("Relay")
                            .font(.system(size: 14.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.90))
                    }
                    .frame(height: 36)
                }

                Spacer()

                if coordinator.step < 4 {
                    Button("Skip setup") {
                        coordinator.finish()
                    }
                    .buttonStyle(RelayGhostButtonStyle())
                    .disabled(coordinator.download.isBusy || coordinator.isPreparingModel || store.isPreparingModel || store.accessibilityCheckRunning)
                }
            }
        }
        .frame(height: 36)
    }

    private var trustFooter: some View {
        HStack(spacing: 7) {
            Image(systemName: "lock.shield")
                .font(.system(size: 10.5))
            Text(store.workspaceUsesCodex ? "ChatGPT for workspace requests · Mac actions run locally" : "Local inference · Your model runs on this Mac")
                .font(.system(size: 12))
        }
        .foregroundStyle(RelayColors.textSecondary)
    }

    private var welcomeStep: some View {
        VStack(spacing: 20) {
            RelayMark(size: 60)
                .padding(.vertical, 12)
            setupHeading("Get started with Relay", detail: "Ask Relay to open apps, find files, or prepare work on this Mac.")
            if !coordinator.hardware.supported {
                inlineError(coordinator.hardware.summary)
            } else {
                Text("No Relay account needed.")
                    .font(.relayCaption)
                    .foregroundStyle(RelayColors.textSecondary)
            }
            Button("Get Started", systemImage: "arrow.right") { coordinator.step = 1 }
                .buttonStyle(RelayPrimaryButtonStyle())
                .disabled(!coordinator.hardware.supported)
        }
        .padding(.vertical, 40)
    }

    private var privacyStep: some View {
        VStack(spacing: 24) {
            setupHeading("You choose what Relay can use", detail: "Local models run on this Mac. Browser tasks can contact the sites you request.")
            VStack(spacing: 0) {
                privacyRow("You choose the files", detail: "Relay reads and indexes only sources you select.", icon: "folder")
                Divider()
                privacyRow("Review sensitive actions", detail: "Relay shows the target and details when a step needs your approval.", icon: "checkmark.shield")
                Divider()
                privacyRow("Stop from the workspace", detail: "Use ⌘. to stop new actions. An action already sent may finish.", icon: "stop.circle")
            }
            .padding(.horizontal, 18)
            .relayGlassCard(cornerRadius: RelayTheme.radius)
            Button("Continue", systemImage: "arrow.right") { coordinator.step = 2 }
                .buttonStyle(RelayPrimaryButtonStyle())
        }
    }

    private func setupHeading(_ title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.system(size: 30, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Text(detail)
                .font(.relayBody)
                .foregroundStyle(RelayColors.textSecondary)
                .lineSpacing(3)
                .frame(maxWidth: 470)
        }
        .multilineTextAlignment(.center)
    }

    private func privacyRow(_ title: String, detail: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(RelayColors.accentBlue)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.relayBody.weight(.semibold))
                Text(detail).font(.relayCaption).foregroundStyle(RelayColors.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 14)
    }

    // MARK: - Step 2: Local Model Engine (Sentient OS FrontierEnginePicker + GlowProgressBar)

    private var modelStep: some View {
        let hasE4B = ModelManifest.resolveInstalledURL(for: .gemma4E4B) != nil
        let hasInstalledModel = hasE4B || coordinator.download.installedURL != nil || coordinator.download.existingFileAvailable
        return VStack(spacing: 24) {
            VStack(spacing: 12) {
                OnboardingWhisper("WORKSPACE MODEL")

                Text("Choose your workspace model")
                    .display(28)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                Text("Run Gemma on this Mac, import a compatible model, or use your existing ChatGPT sign-in for workspace tasks.")
                    .font(.system(size: 14.5, weight: .regular))
                    .foregroundStyle(RelayColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .frame(maxWidth: 540)
            }

            HStack(spacing: 10) {
                RelayEngineTab(
                    label: "Gemma 4",
                    badge: "Default",
                    selected: modelTab == .managed,
                    active: store.actionsReady || hasInstalledModel
                ) {
                    store.selectWorkspaceLocal()
                    withAnimation(.easeInOut(duration: 0.2)) { modelTab = .managed }
                }

                RelayEngineTab(
                    label: "Custom file",
                    selected: modelTab == .custom,
                    active: !store.configuration.modelPath.isEmpty && store.actionsReady
                ) {
                    store.selectWorkspaceLocal()
                    withAnimation(.easeInOut(duration: 0.2)) { modelTab = .custom }
                }

                RelayEngineTab(label: "ChatGPT", badge: "Optional", selected: modelTab == .chatGPT,
                               active: store.workspaceUsesCodex, icon: "cloud") {
                    withAnimation(.easeInOut(duration: 0.2)) { modelTab = .chatGPT }
                }
            }
            .disabled(coordinator.download.isBusy || coordinator.isPreparingModel || store.isPreparingModel || store.checkingCodex)

            if modelTab == .chatGPT {
                WorkspaceCodexOption(store: store)
            } else {
                localModelCard(hasE4B: hasE4B, hasInstalledModel: hasInstalledModel)
            }

            RelayGlowButton(
                title: "Continue",
                icon: "arrow.right",
                enabled: !coordinator.download.isBusy && !coordinator.isPreparingModel && !store.checkingCodex,
                glowOpacity: store.workspaceActionsReady ? 0.45 : 0.25
            ) {
                withAnimation(.easeInOut(duration: 0.24)) { coordinator.step = 3 }
            }
        }
        .onAppear {
            if store.workspaceUsesCodex { modelTab = .chatGPT }
        }
    }

    private func localModelCard(hasE4B: Bool, hasInstalledModel: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if modelTab == .managed {
                HStack(alignment: .center, spacing: 12) {
                    RelayHealthDot(
                        color: store.actionsReady
                            ? RelayColors.accentEmerald
                            : (hasInstalledModel ? RelayHealthDot.warnAmber : RelayColors.accentAmethyst)
                    )
                    VStack(alignment: .leading, spacing: 3) {
                        Text(hasE4B ? "Gemma 4 E4B Instruct · 3.66 GB (plus E2B · 2.59 GB)" : "Gemma 4 E2B Instruct · 2.59 GB")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.white)
                        Text("LiteRT-LM package for Apple Silicon. SHA-256 is checked after download.")
                            .font(.system(size: 13))
                            .foregroundStyle(RelayColors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Text(store.actionsReady ? "ACTIVE" : (hasInstalledModel ? "DOWNLOADED" : "ON-DEVICE"))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .tracking(1.4)
                        .foregroundStyle(store.actionsReady ? RelayColors.accentEmerald : RelayColors.textBright)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.05), in: Capsule())
                }

                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)

                if coordinator.download.isBusy {
                    VStack(alignment: .leading, spacing: 10) {
                        RelayGlowProgressBar(value: coordinator.download.progress)
                        HStack {
                            Text(coordinator.download.status)
                                .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                                .foregroundStyle(.white.opacity(0.9))
                            Spacer()
                            Text(coordinator.download.progress, format: .percent.precision(.fractionLength(0)))
                                .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.white)
                        }
                    }
                    .padding(.vertical, 4)
                } else {
                    Text("Runs model inference on this Mac for document summaries and app tasks. Downloads and browser tasks you request can use the internet.")
                        .font(.system(size: 13.5))
                        .foregroundStyle(RelayColors.textMuted)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 12) {
                    if !coordinator.download.isBusy {
                        if hasInstalledModel {
                            Button(coordinator.isPreparingModel ? "Verifying…" : (store.actionsReady ? "Reload Model" : "Activate Model")) {
                                useDownloadedModel()
                            }
                            .buttonStyle(RelayPrimaryButtonStyle())
                            .disabled(coordinator.isPreparingModel || store.isRunning)

                            if ModelManifest.resolveInstalledURL(for: .gemma4E4B) != nil {
                                Button("Use Gemma 4 E4B (3.66 GB)") {
                                    Task { await store.selectCatalogModel(.gemma4E4B) }
                                }
                                .buttonStyle(RelaySecondaryButtonStyle())
                                .disabled(coordinator.isPreparingModel || store.isRunning)
                            }
                        } else {
                            Button(coordinator.download.phase == .cancelled || coordinator.download.phase == .failed ? "Resume Download" : "Download Model (2.59 GB)") {
                                coordinator.download.start()
                            }
                            .buttonStyle(RelayPrimaryButtonStyle())
                            .disabled(!coordinator.hardware.supported || coordinator.isPreparingModel || store.isRunning)
                        }
                    } else {
                        Button(coordinator.download.phase == .verifying ? "Cancel" : "Pause Download") {
                            coordinator.download.cancel()
                        }
                        .buttonStyle(RelaySecondaryButtonStyle())
                    }

                    if store.actionsReady {
                        HStack(spacing: 8) {
                            RelayHealthDot(color: RelayColors.accentEmerald)
                            Text("Verified and ready on this Mac")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(RelayColors.textStatus)
                        }
                    }
                    Spacer()
                }
            } else {
                HStack(alignment: .center, spacing: 12) {
                    RelayHealthDot(color: store.actionsReady ? RelayColors.accentEmerald : RelayColors.accentBlue)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Custom LiteRT-LM Package (.litertlm)")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.white)
                        Text(
                            store.configuration.modelPath.isEmpty
                                ? "Select an existing .litertlm model file stored on your Mac."
                                : URL(fileURLWithPath: store.configuration.modelPath).lastPathComponent
                        )
                        .font(.system(size: 13))
                        .foregroundStyle(RelayColors.textSecondary)
                        .lineLimit(1)
                    }
                    Spacer()
                }

                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)

                Text("Bring your own compatible LiteRT-LM model package from disk. Relay verifies the package before activating it as your local engine.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(RelayColors.textMuted)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button("Choose .litertlm File…") {
                        store.chooseModel()
                    }
                    .buttonStyle(RelayPrimaryButtonStyle())

                    if !store.configuration.modelPath.isEmpty && !store.actionsReady {
                        Button(coordinator.isPreparingModel ? "Loading…" : "Load & Verify") {
                            loadModel()
                        }
                        .buttonStyle(RelaySecondaryButtonStyle())
                        .disabled(coordinator.isPreparingModel || store.isRunning)
                    }
                    Spacer()
                }
            }

            if let error = coordinator.download.errorMessage ?? coordinator.modelSetupError ?? store.errorMessage {
                inlineError(error)
            }
        }
        .padding(22)
        .relayGlassCard(cornerRadius: 16, strokeColor: Color.white.opacity(0.11))
    }

    // MARK: - Step 3: Mac Access & Knowledge Sources (Sentient OS StatusLine + ChipFlow)

    private var accessStep: some View {
        VStack(spacing: 22) {
            VStack(spacing: 12) {
                Text("Connect your Mac")
                    .display(28)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                Text("Allow Accessibility so Relay can inspect windows and act when asked, and connect the local folders you want indexed.")
                    .font(.system(size: 14.5, weight: .regular))
                    .foregroundStyle(RelayColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .frame(maxWidth: 540)
            }

            // Group 1: System Permissions (Sentient OS StatusLine style)
            VStack(alignment: .leading, spacing: 14) {
                RelayMonoCaps("SYSTEM PERMISSIONS", size: 9.5, tracking: 2.0, color: .white.opacity(0.65))

                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        RelayHealthDot(color: coordinator.accessibilityGranted ? RelayColors.accentEmerald : RelayHealthDot.warnAmber)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Mac Accessibility")
                                .font(.system(size: 14.5, weight: .medium))
                                .foregroundStyle(.white)
                            Text("Lets Relay read UI elements, click controls, and enter text across your apps.")
                                .font(.system(size: 12.5))
                                .foregroundStyle(RelayColors.textSecondary)
                        }
                        Spacer(minLength: 12)
                        if coordinator.accessibilityGranted {
                            Text("Granted")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(RelayColors.accentEmerald)
                        } else {
                            Button("Grant Access") {
                                coordinator.requestAccessibility()
                            }
                            .buttonStyle(RelayPrimaryButtonStyle())
                        }
                    }

                    Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)

                    HStack(spacing: 12) {
                        RelayHealthDot(color: coordinator.accessibilityGranted ? RelayColors.accentBlue : RelayColors.textDim)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Accessibility Self-Test")
                                .font(.system(size: 14.5, weight: .medium))
                                .foregroundStyle(.white)
                            Text(store.accessibilityCheckRunning ? "Verifying in an isolated sandbox window…" : "Optional check in a harmless test window.")
                                .font(.system(size: 12.5))
                                .foregroundStyle(RelayColors.textSecondary)
                        }
                        Spacer(minLength: 12)
                        Button(store.accessibilityCheckRunning ? "Running…" : "Verify") {
                            Task { await store.runAccessibilityCheck() }
                        }
                        .buttonStyle(RelaySecondaryButtonStyle())
                        .disabled(!coordinator.accessibilityGranted || store.accessibilityCheckRunning)
                    }
                }
                .padding(18)
                .relayGlassCard(cornerRadius: 14, strokeColor: Color.white.opacity(0.10))
            }

            // Group 2: Folders on this Mac (Sentient OS ChipFlow + SettingsChip)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    RelayMonoCaps("FOLDERS ON THIS MAC", size: 9.5, tracking: 2.0, color: .white.opacity(0.65))
                    Spacer()
                    Text(store.grants.isEmpty ? "Optional · Add anytime" : "\(store.grants.count) connected")
                        .font(.system(size: 12))
                        .foregroundStyle(store.grants.isEmpty ? RelayColors.textMuted : RelayColors.accentEmerald)
                }

                VStack(alignment: .leading, spacing: 12) {
                    RelayChipFlow(spacing: 8) {
                        ForEach(store.grants) { grant in
                            RelaySourceChip(
                                label: URL(fileURLWithPath: grant.path).lastPathComponent,
                                detail: "Connected",
                                systemImage: "folder.fill",
                                on: true
                            ) {
                                store.removeGrant(grant.id)
                            }
                        }
                        RelaySourceChip(
                            label: "Add Folder…",
                            systemImage: "folder.badge.plus",
                            on: false,
                            isAction: true
                        ) {
                            store.chooseFolder()
                        }
                    }

                    Text("Relay reads only the folders you explicitly connect here. Everything is indexed locally on this Mac.")
                        .font(.system(size: 12))
                        .foregroundStyle(RelayColors.textMuted)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .relayGlassCard(cornerRadius: 14, strokeColor: Color.white.opacity(0.10))
            }

            RelayGlowButton(
                title: "Continue",
                icon: "arrow.right",
                enabled: !store.accessibilityCheckRunning,
                glowOpacity: 0.35
            ) {
                withAnimation(.easeInOut(duration: 0.24)) {
                    coordinator.step = 4
                }
            }
        }
    }

    // MARK: - Step 4: Launchpad (Clean Interactive First-Task Selector)

    private var readyStep: some View {
        VStack(spacing: 24) {
            VStack(spacing: 12) {
                Text("Where should we start?")
                    .display(28)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                Text("Choose a first request to pre-fill in your workspace, or open Relay with a clean conversation.")
                    .font(.system(size: 14.5, weight: .regular))
                    .foregroundStyle(RelayColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .frame(maxWidth: 520)
            }

            VStack(spacing: 10) {
                LaunchpadOptionCard(
                    title: "Open Calculator",
                    detail: "Launch Calculator and check that it is running.",
                    badge: "Computer Use",
                    icon: "plus.forwardslash.minus",
                    color: RelayColors.accentAmber,
                    selected: chosenTask == "Open Calculator"
                ) {
                    chosenTask = "Open Calculator"
                }

                LaunchpadOptionCard(
                    title: "What can you help me do?",
                    detail: "See how Relay works across your local folders, notes, and Mac applications.",
                    badge: "Guided Overview",
                    icon: "sparkles",
                    color: RelayColors.accentBlue,
                    selected: chosenTask == "What can you help me do?"
                ) {
                    chosenTask = "What can you help me do?"
                }

                LaunchpadOptionCard(
                    title: "Start with an empty workspace",
                    detail: "Open Relay directly to the home screen without pre-filling a prompt.",
                    badge: "Blank Slate",
                    icon: "square.dashed",
                    color: RelayColors.accentAmethyst,
                    selected: chosenTask == "Start with an empty workspace"
                ) {
                    chosenTask = "Start with an empty workspace"
                }
            }

            Button("Open Relay", systemImage: "arrow.right") {
                if chosenTask != "Start with an empty workspace" &&
                    store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    store.draft = chosenTask
                }
                coordinator.finish()
            }
            .buttonStyle(RelayPrimaryButtonStyle())
            .padding(.top, 2)
        }
    }

    private func useDownloadedModel() {
        Task { await coordinator.useInstalledModel(store: store) }
    }

    private func loadModel() {
        Task { await coordinator.loadModel(store: store) }
    }

    private func inlineError(_ message: String) -> some View {
        Label {
            Text(message).font(.system(size: 12.5)).lineSpacing(2).textSelection(.enabled)
        } icon: {
            Image(systemName: "exclamationmark.circle.fill")
        }
        .foregroundStyle(RelayColors.accentAmber)
    }
}

// MARK: - Interactive Launchpad Option Card

private struct LaunchpadOptionCard: View {
    let title: String
    let detail: String
    let badge: String
    let icon: String
    let color: Color
    let selected: Bool
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 16) {
                RelayIconBadge(icon: icon, color: selected ? RelayColors.accentEmerald : color, size: 40)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                        Text(badge)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(selected ? RelayColors.accentEmerald : RelayColors.textMuted)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(
                                (selected ? RelayColors.accentEmerald : Color.white).opacity(0.10),
                                in: Capsule()
                            )
                    }
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(RelayColors.textSecondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 12)

                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(selected ? RelayColors.accentEmerald : RelayColors.textSecondary)
                    .frame(width: 22, height: 22)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RelayColors.surface.opacity(selected ? 0.95 : hovered ? 0.76 : 0.48),
                        in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(selected ? RelayColors.accentEmerald.opacity(0.45) : RelayTheme.line)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(RelayPressStyle())
        .onHover { hovered = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
