import AppKit
import CoreGraphics
import SwiftUI

/// Resumable setup with optional access and an isolated, fictional shortcut lesson.
struct OnboardingView: View {
    @Bindable var coordinator: OnboardingCoordinator
    @Bindable var store: AssistantStore

    @State private var chosenTask = "Start with an empty workspace"
    @State private var calculatorExpression = "(18 + 24) * 3"
    @State private var showCalendarSourceSheet = false
    @State private var screenCaptureGranted = CGPreflightScreenCaptureAccess()
    @State private var selectedWelcomeTourTab = 0
    @State private var showWelcomeExamples = false
    @State private var showPermissionExample = false
    @State private var showSourceMap = false
    @State private var showAnalysisTimingSheet = false
    @State private var showMCPSharingSheet = false
    @State private var showPrivacyPolicySheet = false
    @State private var showTelemetryPopover = false
    @State private var selectedMCPClientTab: MCPClientGuideTab = .claude
    @State private var copiedMCPCommand = false
    @State private var viewportHeight: CGFloat = 820
    @State private var loginItem = LaunchAtLogin()
    @State private var openRouterKeyDraft = ""
    @State private var openRouterModelDraft = "anthropic/claude-sonnet-4"
    @State private var lmStudioPortDraft = "1234"

    // Interactive state for Steps 3, 4, 5
    @State private var selectedPermissionPreview: Int = 0
    @State private var permissionSimulationPulse: Int = 0
    @State private var permissionReviewApproved: Bool = false
    @State private var cloudRoutingPreviewHybrid: Bool = true
    @State private var vaultLastToggledSource: String = "Apple Mail"

    @AppStorage(RelayAppearanceMode.storageKey) private var appearanceModeRaw: String = RelayAppearanceMode.dark.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private enum MCPClientGuideTab: String, CaseIterable, Identifiable {
        case claude = "Claude"
        case chatgpt = "ChatGPT"
        case other = "Other AIs"
        var id: String { rawValue }
    }

    // Keep persisted step IDs stable while teaching the shortcut before account setup.
    private let stepOrder = [0, 3, 1, 2, 4]
    private let steps = ["Welcome", "Instant Draft", "AI Engine", "Permissions", "Memory Vault"]
    private let stepPills = ["Welcome", "Instant Draft", "AI Engine", "Permissions", "Memory Vault"]
    private var pageIndex: Int { stepOrder.firstIndex(of: coordinator.step) ?? 0 }

    private var isDarkAppearance: Bool {
        RelayAppearanceMode.fromStored(appearanceModeRaw) != .light
    }

    private var isCompactViewport: Bool {
        viewportHeight < 710
    }

    // CRITICAL TEST CONTRACTS: Preserve exact property declarations
    private var welcomeStep: some View { welcomeStepView(compact: isCompactViewport) }
    private var privacyStep: some View { magicReplyStep(compact: isCompactViewport) }

    private var activeBackgroundDownload: ModelDownload? {
        if coordinator.e4bDownload.isBusy { return coordinator.e4bDownload }
        if coordinator.download.isBusy { return coordinator.download }
        return nil
    }

    private var isNavigationBlocked: Bool {
        coordinator.isPreparingModel || store.isPreparingModel || store.checkingCodex || store.checkingClaude || store.accessibilityCheckRunning
    }

    private var relayEmerald: Color {
        isDarkAppearance ? Color(red: 0.20, green: 0.83, blue: 0.60) : RelayColors.accentEmerald
    }

    private var relayIndigo: Color {
        RelayColors.workbenchAccent
    }

    var body: some View {
        ZStack {
            RelayOnboardingStageAtmosphere(isDark: isDarkAppearance)

            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 32)
                    .padding(.top, 14)
                    .padding(.bottom, 8)

                if let activeDownload = activeBackgroundDownload, coordinator.step != 1 {
                    liveBackgroundDownloadBanner(activeDownload)
                        .padding(.horizontal, 32)
                        .padding(.top, 4)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                GeometryReader { viewport in
                    ScrollView {
                        Group {
                            switch coordinator.step {
                            case 1:
                                modelStep
                            case 2:
                                accessStep
                            case 3:
                                privacyStep
                            case 4:
                                readyStep
                            default:
                                welcomeStep
                            }
                        }
                        .transition(.opacity)
                        .frame(maxWidth: 840)
                        .padding(.horizontal, 32)
                        .padding(.vertical, isCompactViewport ? 6 : 10)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: viewport.size.height, alignment: .center)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .id(coordinator.step)
                }

                pinnedActionFooter
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RelayColors.canvas)
        .foregroundStyle(RelayTheme.ink)
        .tint(RelayColors.workbenchAccent)
        .relayPreferredAppearance()
        .disclosureGroupStyle(RelayDisclosureGroupStyle())
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
        .transaction { if reduceMotion { $0.animation = nil } }
        .sheet(isPresented: $showPrivacyPolicySheet) {
            privacyConstitutionSheet
        }
        .onAppear {
            coordinator.refreshPermissions()
            screenCaptureGranted = coordinator.screenCaptureGranted
            syncProviderSelectionFromStore()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            coordinator.refreshPermissions()
            screenCaptureGranted = coordinator.screenCaptureGranted
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                coordinator.refreshPermissions()
                screenCaptureGranted = coordinator.screenCaptureGranted
            }
        }
        .onChange(of: coordinator.download.installedURL) { _, newURL in
            guard newURL != nil,
                  coordinator.selectedProvider == .onDeviceGemma,
                  !store.actionsReady,
                  !coordinator.isPreparingModel,
                  !store.isPreparingModel else { return }
            Task { await coordinator.activateModel(.gemma4E2B, store: store) }
        }
        .onChange(of: coordinator.e4bDownload.installedURL) { _, newURL in
            guard newURL != nil,
                  coordinator.selectedProvider == .onDeviceGemma,
                  !store.actionsReady,
                  !coordinator.isPreparingModel,
                  !store.isPreparingModel else { return }
            Task { await coordinator.activateModel(.gemma4E4B, store: store) }
        }
    }

    // MARK: - Top Navigation Chrome (Mathematically Centered via ZStack)

    private var topBar: some View {
        VStack(spacing: 10) {
            // Window controls and progress occupy separate rows so they cannot overlap.
            HStack(alignment: .center, spacing: 12) {
                if pageIndex > 0 {
                    Button {
                        move(to: stepOrder[pageIndex - 1])
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 10.5, weight: .semibold))
                            Text("Back")
                                .font(.system(size: 12.5, weight: .medium))
                        }
                        .foregroundStyle(RelayColors.textPrimary)
                        .padding(.horizontal, 13)
                        .frame(height: 32)
                        .background(
                            isDarkAppearance ? Color.white.opacity(0.06) : RelayColors.surface,
                            in: Capsule()
                        )
                        .overlay(
                            Capsule().strokeBorder(
                                isDarkAppearance ? Color.white.opacity(0.12) : RelayColors.borderSubtle,
                                lineWidth: 1
                            )
                        )
                        .contentShape(Capsule())
                    }
                    .buttonStyle(RelayPressStyle())
                    .disabled(isNavigationBlocked)
                } else {
                    HStack(spacing: 9) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [relayIndigo.opacity(0.28), RelayColors.accentCyan.opacity(0.16)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 26, height: 26)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .strokeBorder(Color.white.opacity(isDarkAppearance ? 0.14 : 0.25), lineWidth: 1)
                                )
                            RelayMark(size: 16)
                        }
                        Text("Relay")
                            .font(.system(size: 14, weight: .semibold))
                            .tracking(-0.2)
                            .foregroundStyle(RelayColors.textPrimary)
                    }
                    .padding(.leading, 2)
                }

                Spacer(minLength: 16)

                HStack(spacing: 8) {
                    if coordinator.step != 4 {
                        Button("Finish later") { coordinator.finish() }
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .foregroundStyle(RelayColors.textSecondary)
                            .padding(.horizontal, 12)
                            .frame(height: 32)
                            .background(
                                isDarkAppearance ? Color.white.opacity(0.04) : RelayColors.subtleFill,
                                in: Capsule()
                            )
                            .overlay(
                                Capsule().strokeBorder(
                                    isDarkAppearance ? Color.white.opacity(0.10) : RelayColors.borderSubtle,
                                    lineWidth: 1
                                )
                            )
                            .buttonStyle(RelayPressStyle())
                            .disabled(activeBackgroundDownload != nil || isNavigationBlocked)
                    }
                    RelayAppearanceToggleButton(showsLabel: false)
                }
            }

            HStack(spacing: 3) {
                ForEach(Array(stepPills.enumerated()), id: \.offset) { idx, title in
                    stepPill(index: idx, title: title)
                }
            }
            .padding(.vertical, 4)
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    @ViewBuilder
    private func stepPill(index: Int, title: String) -> some View {
        let isCurrent = index == pageIndex
        let isEarlier = index < pageIndex
        Button {
            guard !isNavigationBlocked else { return }
            move(to: stepOrder[index])
        } label: {
            HStack(spacing: 7) {
                Text(String(format: "%02d", index + 1))
                    .font(.relayEyebrow)
                    .foregroundStyle(isCurrent ? RelayColors.workbenchAccent : RelayColors.textMuted)
                Text(title)
                    .font(.system(size: 12, weight: isCurrent ? .semibold : .medium))
                    .foregroundStyle(isCurrent ? RelayColors.textPrimary : RelayColors.textSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 11)
            .frame(height: 34)
            .fixedSize(horizontal: true, vertical: false)
            .background(isCurrent ? RelayColors.workbenchTint : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(RelayPressStyle())
        .disabled(isNavigationBlocked)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Step \(index + 1) of \(steps.count): \(steps[index])")
        .accessibilityValue(isCurrent ? "Current step" : isEarlier ? "Earlier step" : "Upcoming")
        .accessibilityRemoveTraits(isCurrent ? [] : .isSelected)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    private var continueTitle: String {
        switch coordinator.step {
        case 0: "Get started"
        case 3: "Continue to AI Engine"
        case 1:
            activeBackgroundDownload != nil ? "Continue downloading" : (store.workspaceActionsReady ? "Continue" : "Continue without AI")
        case 2: "Continue to Memory Vault"
        default: activeBackgroundDownload != nil ? "Waiting for download…" : "Launch Relay"
        }
    }

    private var canContinue: Bool {
        guard !isNavigationBlocked else { return false }
        if coordinator.step == 4 { return activeBackgroundDownload == nil }
        return true
    }

    private func move(to step: Int) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
            coordinator.step = step
        }
    }

    private func continueSetup() {
        if pageIndex < stepOrder.count - 1 {
            move(to: stepOrder[pageIndex + 1])
        } else {
            if chosenTask != "Start with an empty workspace" && store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                store.draft = chosenTask
            }
            coordinator.finish()
        }
    }

    // MARK: - Architectural Pinned Action Footer (Mathematically Centered via ZStack)

    private var pinnedActionFooter: some View {
        VStack(spacing: 16) {
            Rectangle().fill(RelayColors.borderDefault).frame(height: 1)
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(footerSummaryText)
                        .font(.relayCaption)
                        .foregroundStyle(RelayColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 14) {
                        Button("Privacy & local storage") { showPrivacyPolicySheet = true }
                        Button("No background analytics") { showTelemetryPopover.toggle() }
                            .popover(isPresented: $showTelemetryPopover, arrowEdge: .top) {
                                telemetryGuaranteesPopover
                            }
                    }
                    .font(.relayCaption)
                    .buttonStyle(.plain)
                    .foregroundStyle(RelayColors.workbenchAccent)
                }
                Spacer(minLength: 8)
                continueSetupButton
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 10)
        .padding(.bottom, 18)
    }

    private var continueSetupButton: some View {
        Button(action: continueSetup) {
            HStack(spacing: 14) {
                Text(continueTitle)
                    .font(.system(size: 14, weight: .semibold))
                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .semibold))
            }
            .frame(minWidth: 158, minHeight: 30)
        }
        .buttonStyle(RelayPrimaryButtonStyle())
        .disabled(!canContinue)
        .keyboardShortcut(.defaultAction)
        .accessibilityHint(coordinator.step == 4 && activeBackgroundDownload != nil
            ? "Wait for the download to finish, or cancel it using the download banner." : "")
    }

    private var telemetryGuaranteesPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("LOCAL-FIRST ARCHITECTURE")
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .tracking(1.8)
                .foregroundStyle(RelayColors.textMuted)

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(relayEmerald)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Zero background telemetry")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(RelayColors.textPrimary)
                    Text("Relay never uploads analytics, keystrokes, or personal files to any Relay server.")
                        .font(.system(size: 11))
                        .foregroundStyle(RelayColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider().overlay(RelayColors.borderSubtle)

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "folder.fill.badge.person.crop")
                    .font(.system(size: 14))
                    .foregroundStyle(RelayColors.accentBlue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Plain-text Markdown Vault on your Mac")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(RelayColors.textPrimary)
                    Text("Your Knowledge Vault lives in Application Support as standard Markdown files that you inspect and own.")
                        .font(.system(size: 11))
                        .foregroundStyle(RelayColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .frame(width: 320)
        .background(RelayColors.cardBG)
        .relayPreferredAppearance()
    }

    private var privacyConstitutionSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("PRIVACY & SECURITY ARCHITECTURE")
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .tracking(1.8)
                        .foregroundStyle(RelayColors.accentBlue)
                    Text("Local-first by design.")
                        .font(.system(size: 24, weight: .semibold))
                        .tracking(-0.4)
                        .foregroundStyle(RelayColors.textPrimary)
                }
                Spacer()
                Button("Done") {
                    showPrivacyPolicySheet = false
                }
                .buttonStyle(RelaySecondaryButtonStyle())
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("On-device execution & plain-text storage")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(RelayColors.textPrimary)
                Text("Relay runs inference locally with Gemma 4 on Apple Silicon wherever possible, keeps your Knowledge Vault in a plain-text Markdown folder on your Mac, and gives you full control over which model engine handles your tasks.")
                    .font(.system(size: 13))
                    .lineSpacing(3)
                    .foregroundStyle(RelayColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Explicit source opt-in")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(RelayColors.textPrimary)
                Text("Relay indexes only the local sources you explicitly enable—including selected folders, Apple Notes, iMessage, WhatsApp, Apple Mail, and Apple Calendar. If you connect a cloud or CLI provider, only the context required for your active prompt is sent under your own account.")
                    .font(.system(size: 13))
                    .lineSpacing(3)
                    .foregroundStyle(RelayColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Reviewed desktop actions")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(RelayColors.textPrimary)
                Text("On-device models handle inference on your Mac after setup. Cloud and CLI providers send task context to the provider you connect. Review requests and tool activity appear in the workspace; you can stop a running task with ⌘.")
                    .font(.system(size: 13))
                    .lineSpacing(3)
                    .foregroundStyle(RelayColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(28)
        .frame(width: 540)
        .background(RelayColors.cardBG)
        .relayPreferredAppearance()
    }

    private func liveBackgroundDownloadBanner(_ activeDownload: ModelDownload) -> some View {
        HStack(spacing: 14) {
            RelayHealthDot(color: RelayColors.accentBlue)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(activeDownload.phase == .verifying ? "Verifying \(activeDownload.manifest.displayName)…" : "Downloading \(activeDownload.manifest.displayName) in background")
                        .font(.relayCaption.weight(.semibold))
                        .foregroundStyle(RelayColors.textPrimary)
                    Text("\(formattedByteCount(activeDownload.receivedBytes)) / \(formattedByteCount(activeDownload.totalBytes))")
                        .font(.relayMono)
                        .foregroundStyle(RelayColors.textSecondary)
                }
                RelayGlowProgressBar(value: activeDownload.progress)
                    .frame(maxWidth: 320)
            }

            Spacer()

            Text(activeDownload.progress, format: .percent.precision(.fractionLength(0)))
                .font(.relayMono.weight(.semibold))
                .foregroundStyle(RelayColors.textPrimary)

            Button(activeDownload.phase == .verifying ? "Cancel" : "Pause") {
                activeDownload.cancel()
            }
            .buttonStyle(RelaySecondaryButtonStyle())

            Button("View") {
                withAnimation(.easeInOut(duration: 0.22)) {
                    coordinator.step = 1
                }
            }
            .buttonStyle(RelayGhostButtonStyle())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .frame(maxWidth: 820)
        .relayGlassCard(cornerRadius: 12, strokeColor: RelayColors.borderSubtle)
    }

    private var footerSummaryText: String {
        "Selected model route · \(store.workspaceProviderTitle)"
    }

    // MARK: - Unified Relay Geometric Display Heading

    private func stepHeading(eyebrow: String? = nil, _ title: String, subtitle: String, compact: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 11) {
            if let eyebrow {
                Text(eyebrow.uppercased())
                    .font(.relayEyebrow)
                    .tracking(1.5)
                    .foregroundStyle(RelayColors.workbenchAccent)
            }
            Text(title)
                .font(compact ? .system(size: 26, weight: .semibold) : .relayWorkbenchTitle)
                .tracking(-0.7)
                .foregroundStyle(RelayColors.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(.relayBody)
                .foregroundStyle(RelayColors.textSecondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 620, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .multilineTextAlignment(.leading)
    }

    // MARK: - Welcome: a real action before the optional tour

    private func welcomeStepView(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 20 : 28) {
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 9) {
                    Rectangle().fill(RelayColors.workbenchAccent).frame(width: 22, height: 2)
                    Text("YOUR MAC. YOUR NEXT MOVE.")
                        .font(.relayEyebrow).tracking(1.7)
                        .foregroundStyle(RelayColors.workbenchAccent)
                }
                Text("From a thought to work\nyou can check.")
                    .font(compact ? .system(size: 32, weight: .semibold) : .relayWorkbenchHero)
                    .tracking(-1.25)
                    .foregroundStyle(RelayColors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text("Ask, review the steps that need you, and keep the result. Start with one real action on this Mac.")
                    .font(.system(size: 15))
                    .lineSpacing(4)
                    .foregroundStyle(RelayColors.textSecondary)
                    .frame(maxWidth: 570, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            localCalculatorTrial

            VStack(alignment: .leading, spacing: 14) {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                        showWelcomeExamples.toggle()
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: showWelcomeExamples ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Explore fictional examples")
                            .font(.relayBodyStrong)
                        Spacer()
                        Text("OPTIONAL TOUR")
                            .font(.relayEyebrow).tracking(1)
                    }
                    .foregroundStyle(RelayColors.textSecondary)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(showWelcomeExamples ? "Expanded" : "Collapsed")
                .accessibilityIdentifier("onboarding.welcome.examples")
                if showWelcomeExamples {
                    OnboardingWelcomePreview(selection: $selectedWelcomeTourTab, compact: compact)
                        .frame(maxWidth: 780)
                }
            }

            if !coordinator.hardware.supported {
                inlineError(coordinator.hardware.summary)
            }
        }
        .frame(maxWidth: 780, alignment: .leading)
    }

    private var localCalculatorTrial: some View {
        OnboardingWorkbenchCalculator(expression: $calculatorExpression, state: coordinator.calculatorTrial) {
            Task { await coordinator.tryLocalCalculator(calculatorExpression) }
        }
    }

    // MARK: - Step 3: Select Primary Intelligence Engine (Interactive Hardware & Routing Telemetry)

    private var modelStep: some View {
        let hasE4B = coordinator.isModelInstalled(.gemma4E4B)
        let hasInstalledModel = coordinator.hasInstalledModel
        return VStack(spacing: isCompactViewport ? 10 : 14) {
            stepHeading(
                eyebrow: "CHOOSE A MODEL",
                "Where should Relay think?",
                subtitle: "Choose an on-device model, a local server, or an existing cloud account. You can connect one later in Settings.",
                compact: isCompactViewport
            )

            // Symmetrical 6-tab provider selector bar
            HStack(spacing: 4) {
                ForEach([OnboardingProviderChoice.onDeviceGemma, .chatGPTCodex, .claudeCLI, .openRouter, .lmStudio, .customLiteRT]) { choice in
                    providerTab(choice)
                }
            }
            .padding(4)
            .background(
                isDarkAppearance ? Color(red: 0.06, green: 0.068, blue: 0.095) : RelayColors.cardBG,
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        isDarkAppearance ? Color.white.opacity(0.10) : RelayColors.borderSubtle,
                        lineWidth: 1
                    )
            )
            .disabled(isNavigationBlocked)

            providerDetailCard(hasE4B: hasE4B, hasInstalledModel: hasInstalledModel)
                .frame(maxWidth: 720)

            // Single-line compact local Gemma 4 status bar when viewing a cloud/CLI tab
            if coordinator.selectedProvider != .onDeviceGemma && coordinator.selectedProvider != .customLiteRT {
                compactOfflineGemmaFallbackBar
                    .frame(maxWidth: 720)
            }
        }
    }

    private func isProviderActive(_ choice: OnboardingProviderChoice) -> Bool {
        switch choice {
        case .onDeviceGemma:
            return coordinator.hasInstalledModel || (store.configuration.backend == .liteRTLM && store.actionsReady)
        case .chatGPTCodex:
            return store.workspaceUsesCodex || store.workspaceUsesCodexCLI
        case .claudeCLI:
            return store.workspaceUsesClaude
        case .openRouter:
            return store.configuration.backend == .openRouter && store.actionsReady
        case .lmStudio:
            return store.configuration.backend == .lmStudio && store.actionsReady
        case .customLiteRT:
            return store.configuration.backend == .liteRTLM && !store.configuration.modelPath.isEmpty && store.actionsReady
        }
    }

    private func providerTab(_ choice: OnboardingProviderChoice) -> some View {
        let isSelected = coordinator.selectedProvider == choice
        let isActive = isProviderActive(choice)
        let title: String = switch choice {
        case .onDeviceGemma: "On this Mac"
        case .chatGPTCodex: "ChatGPT"
        case .claudeCLI: "Claude"
        case .openRouter: "OpenRouter"
        case .lmStudio: "LM Studio"
        case .customLiteRT: "Import model"
        }
        return Button {
            withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.82)) {
                selectProvider(choice)
            }
        } label: {
            HStack(spacing: 6) {
                if isActive {
                    Circle()
                        .fill(
                            isSelected && isDarkAppearance
                                ? Color(red: 0.08, green: 0.45, blue: 0.28)
                                : relayEmerald
                        )
                        .frame(width: 5.5, height: 5.5)
                }
                Text(title)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(
                isSelected
                    ? (isDarkAppearance ? Color.black.opacity(0.90) : Color.white)
                    : RelayColors.textBright
            )
            .padding(.horizontal, 15)
            .frame(height: 32)
            .background {
                if isSelected {
                    Capsule()
                        .fill(isDarkAppearance ? Color.white.opacity(0.96) : RelayColors.buttonFace)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(RelayPressStyle())
        .accessibilityLabel(choice.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func providerDetailCard(hasE4B: Bool, hasInstalledModel: Bool) -> some View {
        switch coordinator.selectedProvider {
        case .onDeviceGemma, .customLiteRT:
            localModelCard(hasE4B: hasE4B, hasInstalledModel: hasInstalledModel)
        case .chatGPTCodex, .claudeCLI:
            subscriptionConnectionCard
        case .openRouter:
            onboardingOpenRouterCard
        case .lmStudio:
            onboardingLMStudioCard
        }
    }

    private var onboardingOpenRouterCard: some View {
        let selected = store.configuration.openRouter
        let currentModel = (selected?.modelID.isEmpty == false) ? (selected?.modelID ?? "") : openRouterModelDraft
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("OpenRouter")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(RelayColors.textPrimary)
                        RelayBadge("Keychain-Scoped", icon: "key.fill", tint: RelayColors.accentCyan, prominent: true)
                    }
                    Text("Route prompts to any frontier model using your personal OpenRouter API key stored in macOS Keychain.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(RelayColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle(
                    "Allow uploads",
                    isOn: Binding(get: { selected?.uploadsApproved == true }, set: store.setOpenRouterUploadsApproved)
                )
                .toggleStyle(.switch)
                .font(.relayCaptionStrong)
            }

            // Quick interactive model preset pills
            HStack(spacing: 6) {
                Text("PRESETS")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(1.4)
                    .foregroundStyle(RelayColors.textMuted)
                ForEach(["anthropic/claude-sonnet-4", "openai/gpt-4.1", "google/gemini-2.5-pro"], id: \.self) { preset in
                    let isCurrent = openRouterModelDraft == preset
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            openRouterModelDraft = preset
                            store.setOpenRouterModel(preset)
                        }
                    } label: {
                        Text(preset)
                            .font(.system(size: 10.5, weight: isCurrent ? .semibold : .medium, design: .monospaced))
                            .foregroundStyle(isCurrent ? RelayColors.textPrimary : RelayColors.textSecondary)
                            .padding(.horizontal, 9)
                            .frame(height: 24)
                            .background(
                                isCurrent
                                    ? relayIndigo.opacity(0.24)
                                    : (isDarkAppearance ? Color.white.opacity(0.04) : RelayColors.surface),
                                in: Capsule()
                            )
                            .overlay(
                                Capsule().strokeBorder(
                                    isCurrent ? relayIndigo.opacity(0.55) : RelayColors.borderSubtle,
                                    lineWidth: 1
                                )
                            )
                    }
                    .buttonStyle(RelayPressStyle())
                }
                Spacer()
            }

            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("MODEL IDENTIFIER")
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .tracking(1.4)
                        .foregroundStyle(RelayColors.textMuted)
                    HStack(spacing: 6) {
                        TextField("", text: $openRouterModelDraft, prompt: Text(""))
                            .textFieldStyle(.plain)
                            .font(.relayMono)
                            .relayTextFieldPrompt("anthropic/claude-sonnet-4", when: openRouterModelDraft.isEmpty, font: .relayMono)
                            .relayTextField(verticalPadding: 7)
                            .frame(height: 34)
                            .onSubmit { store.setOpenRouterModel(openRouterModelDraft) }
                        Button("Use") { store.setOpenRouterModel(openRouterModelDraft) }
                            .buttonStyle(RelaySecondaryButtonStyle())
                            .frame(height: 34)
                    }
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 6) {
                    Text("OPENROUTER API KEY")
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .tracking(1.4)
                        .foregroundStyle(RelayColors.textMuted)
                    HStack(spacing: 6) {
                        SecureField("", text: $openRouterKeyDraft, prompt: Text(""))
                            .textFieldStyle(.plain)
                            .font(.relayMono)
                            .relayTextFieldPrompt("sk-or-v1-…", when: openRouterKeyDraft.isEmpty, font: .relayMono)
                            .relayTextField(verticalPadding: 7)
                            .frame(height: 34)
                            .accessibilityLabel("New OpenRouter API key")
                        Button("Save key") {
                            let submitted = openRouterKeyDraft
                            Task {
                                if await store.replaceOpenRouterKey(submitted), openRouterKeyDraft.utf8.elementsEqual(submitted.utf8) {
                                    openRouterKeyDraft = ""
                                }
                            }
                        }
                        .buttonStyle(RelaySecondaryButtonStyle())
                        .frame(height: 34)
                        .disabled(openRouterKeyDraft.isEmpty)
                    }
                }
                .frame(maxWidth: .infinity)
            }

            HStack(alignment: .center, spacing: 10) {
                Button(store.isPreparingModel ? "Testing…" : "Test & Select") {
                    if !currentModel.isEmpty {
                        store.setOpenRouterModel(currentModel)
                    }
                    Task { await store.refreshModels() }
                }
                .buttonStyle(RelayPrimaryButtonStyle())

                Button("Discover Models") {
                    Task { await store.discoverOpenRouterModels() }
                }
                .buttonStyle(RelaySecondaryButtonStyle())

                Spacer()

                HStack(spacing: 6) {
                    RelayHealthDot(color: store.actionsReady ? relayEmerald : RelayColors.textMuted)
                    Text(store.modelStatus)
                        .font(.relayCaption)
                        .foregroundStyle(RelayColors.textSecondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(18)
        .background { RelayPermissionAtmosphere(isDark: isDarkAppearance, cornerRadius: 16) }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onAppear {
            if let existing = selected?.modelID, !existing.isEmpty {
                openRouterModelDraft = existing
            }
        }
    }

    private var onboardingLMStudioCard: some View {
        let selectedID = store.configuration.lmStudio?.modelID ?? ""
        let values = selectedID.isEmpty || LMStudioProtocolID.contains(store.availableModels, selectedID)
            ? store.availableModels : [selectedID] + store.availableModels
        let pickerModels = values.map { LMStudioModelOption(value: $0) }

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("LM Studio")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(RelayColors.textPrimary)
                        RelayBadge("OpenAI-Compatible · Local", tint: RelayColors.accentAmethyst, prominent: true)
                    }
                    Text("Connect to an OpenAI-compatible local server running on this Mac (http://127.0.0.1:1234/v1).")
                        .font(.system(size: 12.5))
                        .foregroundStyle(RelayColors.textSecondary)
                }
                Spacer()
                if !selectedID.isEmpty {
                    RelayBadge(selectedID, icon: "cube.fill", tint: relayEmerald, prominent: store.actionsReady)
                }
            }

            HStack(alignment: .center, spacing: 10) {
                Text("HOST")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .tracking(1.4)
                    .foregroundStyle(RelayColors.textMuted)
                Text(store.configuration.lmStudio?.endpoint.host.rawValue ?? "127.0.0.1")
                    .font(.relayMono)
                    .foregroundStyle(RelayColors.textPrimary)
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(
                        isDarkAppearance ? Color.white.opacity(0.04) : RelayColors.surface,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(RelayColors.borderSubtle, lineWidth: 1))

                Text("PORT")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .tracking(1.4)
                    .foregroundStyle(RelayColors.textMuted)
                TextField("", text: $lmStudioPortDraft, prompt: Text(""))
                    .textFieldStyle(.plain)
                    .font(.relayMono)
                    .relayTextFieldPrompt("1234", when: lmStudioPortDraft.isEmpty, font: .relayMono)
                    .relayTextField(verticalPadding: 6)
                    .frame(width: 78, height: 32)
                    .onSubmit { _ = store.setLMStudioPort(lmStudioPortDraft) }

                Button("Find models") {
                    if store.setLMStudioPort(lmStudioPortDraft) {
                        Task { await store.discoverLMStudioModels() }
                    }
                }
                .buttonStyle(RelaySecondaryButtonStyle())

                Divider().frame(height: 20)

                Text("MODEL")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .tracking(1.4)
                    .foregroundStyle(RelayColors.textMuted)
                Picker("Model", selection: Binding(get: { LMStudioProtocolID(selectedID) }, set: { store.selectLMStudioModel($0.string) })) {
                    Text("Choose a model").tag(LMStudioProtocolID(""))
                    ForEach(pickerModels) { option in Text(option.value).tag(option.id) }
                }
                .labelsHidden()
                Spacer(minLength: 0)
            }

            HStack(alignment: .center, spacing: 10) {
                Button(store.isPreparingModel ? "Testing…" : "Test & Select") {
                    if store.setLMStudioPort(lmStudioPortDraft) {
                        Task { await store.refreshModels() }
                    }
                }
                .buttonStyle(RelayPrimaryButtonStyle())

                Button("Verify Vision") {
                    if store.setLMStudioPort(lmStudioPortDraft) {
                        Task { await store.checkLMStudioVision() }
                    }
                }
                .buttonStyle(RelaySecondaryButtonStyle())

                Spacer()

                HStack(spacing: 6) {
                    RelayHealthDot(color: store.actionsReady ? relayEmerald : RelayColors.textMuted)
                    Text(store.modelStatus)
                        .font(.relayCaption)
                        .foregroundStyle(RelayColors.textSecondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(18)
        .background { RelayPermissionAtmosphere(isDark: isDarkAppearance, cornerRadius: 16) }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onAppear {
            lmStudioPortDraft = String(store.configuration.lmStudio?.endpoint.port ?? 1234)
        }
    }

    private var subscriptionConnectionCard: some View {
        let isClaude = coordinator.selectedProvider == .claudeCLI
        let name = isClaude ? "Claude" : "ChatGPT"
        let isConnected = isClaude ? store.workspaceUsesClaude : (store.workspaceUsesCodex || store.workspaceUsesCodexCLI)

        return VStack(spacing: 14) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(name)
                            .font(.system(size: 20, weight: .semibold))
                            .tracking(-0.3)
                            .foregroundStyle(RelayColors.textPrimary)
                        RelayBadge(
                            isClaude ? "Claude Code CLI" : "Codex CLI",
                            icon: "terminal.fill",
                            tint: RelayColors.accentBlue,
                            prominent: true
                        )
                    }
                    Text(
                        isClaude
                            ? "Connect your existing Claude Pro, Max, or Team subscription via Claude Code."
                            : "Connect your existing ChatGPT Plus, Pro, or Team subscription via Codex CLI."
                    )
                    .font(.system(size: 12.5))
                    .foregroundStyle(RelayColors.textSecondary)
                }

                Spacer()

                HStack(spacing: 7) {
                    RelayHealthDot(color: isConnected ? relayEmerald : RelayColors.accentAmber)
                    Text(
                        isConnected
                            ? "Connected"
                            : (coordinator.isPreparingModel ? "Verifying…" : "Not connected")
                    )
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isConnected ? relayEmerald : RelayColors.textBright)
                }
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(
                    isDarkAppearance ? Color.white.opacity(0.04) : RelayColors.surface,
                    in: Capsule()
                )
                .overlay(
                    Capsule().strokeBorder(
                        isDarkAppearance ? Color.white.opacity(0.10) : RelayColors.borderSubtle,
                        lineWidth: 1
                    )
                )
            }

            // Interactive Context Routing Pipeline Visualizer
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("ROUTING EXAMPLE · PREVIEW ONLY")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .tracking(1.5)
                        .foregroundStyle(RelayColors.accentBlue)
                    Spacer()
                    HStack(spacing: 4) {
                        Button {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                                cloudRoutingPreviewHybrid = true
                            }
                        } label: {
                            Text("Hybrid Local + \(name)")
                                .font(.system(size: 11, weight: cloudRoutingPreviewHybrid ? .semibold : .medium))
                                .foregroundStyle(cloudRoutingPreviewHybrid ? RelayColors.textPrimary : RelayColors.textSecondary)
                                .padding(.horizontal, 10)
                                .frame(height: 24)
                                .background(
                                    cloudRoutingPreviewHybrid ? relayIndigo.opacity(0.24) : Color.clear,
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)

                        Button {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                                cloudRoutingPreviewHybrid = false
                            }
                        } label: {
                            Text("Direct \(name) CLI")
                                .font(.system(size: 11, weight: !cloudRoutingPreviewHybrid ? .semibold : .medium))
                                .foregroundStyle(!cloudRoutingPreviewHybrid ? RelayColors.textPrimary : RelayColors.textSecondary)
                                .padding(.horizontal, 10)
                                .frame(height: 24)
                                .background(
                                    !cloudRoutingPreviewHybrid ? relayIndigo.opacity(0.24) : Color.clear,
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(2)
                    .background(Color.white.opacity(isDarkAppearance ? 0.04 : 0.08), in: Capsule())
                    .overlay(Capsule().strokeBorder(RelayColors.borderSubtle, lineWidth: 1))
                }

                HStack(spacing: 8) {
                    routingStageNode(
                        icon: "folder.fill.badge.person.crop",
                        title: "Local Vault",
                        subtitle: cloudRoutingPreviewHybrid ? "Gemma 4 retrieves notes" : "Scoped prompt context",
                        tint: relayEmerald
                    )
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(RelayColors.accentBlue)
                    routingStageNode(
                        icon: "sparkles",
                        title: "\(name) Engine",
                        subtitle: isClaude ? "Claude Sonnet / Opus" : "Codex Frontier Reasoning",
                        tint: relayIndigo
                    )
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(RelayColors.accentBlue)
                    routingStageNode(
                        icon: "checkmark.shield.fill",
                        title: "1-Click Review",
                        subtitle: "Executes on your Mac",
                        tint: RelayColors.accentCyan
                    )
                }
            }
            .padding(12)
            .background(
                isDarkAppearance ? Color.white.opacity(0.025) : RelayColors.surface,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isDarkAppearance ? Color.white.opacity(0.08) : RelayColors.borderSubtle, lineWidth: 1)
            )

            HStack(spacing: 10) {
                Button(
                    coordinator.isPreparingModel
                        ? "Checking connection…"
                        : (isConnected ? "Refresh \(name) Session" : "Connect \(name)")
                ) {
                    loadModel()
                }
                .buttonStyle(RelayPrimaryButtonStyle())
                .disabled(isNavigationBlocked || store.isRunning)

                Button("Verify CLI Access") {
                    loadModel()
                }
                .buttonStyle(RelaySecondaryButtonStyle())
                .disabled(isNavigationBlocked || store.isRunning)

                Spacer()

                Text("No separate Relay subscription required.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(RelayColors.textMuted)
            }

            if let error = coordinator.modelSetupError ?? store.errorMessage {
                inlineError(error)
            }

            DisclosureGroup("Model routing & CLI session configuration") {
                Group {
                    if isClaude {
                        ClaudeSettingsView(store: store)
                    } else {
                        CodexProviderSettingsView(store: store)
                    }
                }
                .padding(.top, 10)
            }
            .font(.relayCaptionStrong)
        }
        .padding(18)
        .frame(maxWidth: 700)
        .background { RelayPermissionAtmosphere(isDark: isDarkAppearance, cornerRadius: 16) }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func routingStageNode(icon: String, title: String, subtitle: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1.5) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(RelayColors.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(RelayColors.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(
            isDarkAppearance ? Color.white.opacity(0.03) : RelayColors.cardBG,
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(tint.opacity(0.28), lineWidth: 1)
        )
    }

    private func localModelCard(hasE4B: Bool, hasInstalledModel: Bool) -> some View {
        let embeddedReady = store.configuration.backend == .liteRTLM && store.actionsReady

        return VStack(alignment: .leading, spacing: 12) {
            if coordinator.selectedProvider == .onDeviceGemma {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Label("On-device model", systemImage: "cpu")
                            .font(.relayBodyStrong)
                        Spacer()
                        Text("\(coordinator.hardware.memoryGB) GB memory · \(coordinator.hardware.freeDiskGB) GB disk available")
                            .font(.relayCaption)
                            .foregroundStyle(RelayColors.textSecondary)
                    }
                    Text(coordinator.hardware.summary)
                        .font(.relayCaption)
                        .foregroundStyle(RelayColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Download size is shown below. Runtime memory and speed vary by model and Mac; these are not live performance measurements.")
                        .font(.relayCaption)
                        .foregroundStyle(RelayColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .background(RelayColors.surface, in: RoundedRectangle(cornerRadius: 12))

                // Interactive Side-by-Side Gemma 4 Variant Cards
                HStack(alignment: .top, spacing: 12) {
                    gemmaCatalogVariantCard(
                        manifest: .gemma4E2B,
                        title: "Gemma 4 E2B Instruct",
                        sizeLabel: "2.59 GB",
                        summary: "Fast everyday assistance, low-latency Instant Draft replies, and background vault indexing.",
                        specLine: "8 GB+ Unified Memory",
                        capabilities: ["Instant Draft", "Vault Indexer", "Low RAM"],
                        recommendationBadge: coordinator.hardware.memoryGB < 16 ? "Recommended for \(coordinator.hardware.memoryGB) GB Mac" : "Compact & fast"
                    )

                    gemmaCatalogVariantCard(
                        manifest: .gemma4E4B,
                        title: "Gemma 4 E4B Instruct",
                        sizeLabel: "3.66 GB",
                        summary: "Deeper multi-step planning, richer document synthesis, and visual screen inspection.",
                        specLine: "16 GB+ Unified Memory · Multimodal",
                        capabilities: ["Screen Vision", "Multi-Agent", "Deep Synthesis"],
                        recommendationBadge: coordinator.hardware.memoryGB >= 16 ? "Recommended for \(coordinator.hardware.memoryGB) GB Mac" : "16 GB+ RAM recommended"
                    )
                }
                .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(alignment: .center, spacing: 10) {
                    RelayHealthDot(color: embeddedReady ? relayEmerald : RelayColors.accentBlue)
                    Text("Custom LiteRT-LM Package (.litertlm)")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(RelayColors.textPrimary)
                    Spacer()
                    RelayBadge("Local Package", icon: "shippingbox.fill", tint: RelayColors.accentBlue)
                }

                Text(
                    store.configuration.modelPath.isEmpty
                        ? "Select a compatible .litertlm model package stored on your Mac (Gemma 4, Qwen 3, Qwen 2.5, FunctionGemma). Relay verifies package integrity before activation."
                        : "Selected package: \(URL(fileURLWithPath: store.configuration.modelPath).lastPathComponent)"
                )
                .font(.system(size: 12.5))
                .foregroundStyle(RelayColors.textSecondary)
                .lineSpacing(2.5)

                HStack(spacing: 10) {
                    Button("Choose .litertlm File…") {
                        store.chooseModel()
                    }
                    .buttonStyle(RelayPrimaryButtonStyle())

                    if !store.configuration.modelPath.isEmpty && !embeddedReady {
                        Button(coordinator.isPreparingModel || store.isPreparingModel ? "Loading…" : "Load & Verify") {
                            loadModel()
                        }
                        .buttonStyle(RelaySecondaryButtonStyle())
                        .disabled(coordinator.isPreparingModel || store.isPreparingModel || store.isRunning)
                    }
                    Spacer()
                }
            }

            if let error = coordinator.download.errorMessage ?? coordinator.e4bDownload.errorMessage ?? coordinator.modelSetupError ?? store.errorMessage {
                inlineError(error)
            }
        }
        .padding(16)
        .background { RelayPermissionAtmosphere(isDark: isDarkAppearance, cornerRadius: 16) }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func gemmaCatalogVariantCard(
        manifest: ModelManifest,
        title: String,
        sizeLabel: String,
        summary: String,
        specLine: String,
        capabilities: [String],
        recommendationBadge: String
    ) -> some View {
        let downloader = coordinator.downloader(for: manifest)
        let isInstalled = coordinator.isModelInstalled(manifest)
        let isRecommended = coordinator.recommendedGemmaVariant.filename == manifest.filename
        let isSelectedVariant = coordinator.selectedGemmaVariant.filename == manifest.filename
        let isActiveInStore = store.configuration.backend == .liteRTLM
            && store.actionsReady
            && (store.configuration.modelPath.hasSuffix(manifest.filename) || store.configuration.model == manifest.displayName)
        let isHighlighted = isSelectedVariant || isActiveInStore

        return VStack(alignment: .leading, spacing: 9) {
            // Header row: fixed alignment across both cards
            HStack(alignment: .center, spacing: 8) {
                Circle()
                    .fill(isHighlighted ? relayEmerald : RelayColors.textMuted.opacity(0.4))
                    .frame(width: 7, height: 7)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(RelayColors.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(sizeLabel)
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isHighlighted ? RelayColors.textPrimary : RelayColors.textSecondary)
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .background(
                        isHighlighted
                            ? relayIndigo.opacity(0.28)
                            : (isDarkAppearance ? Color.white.opacity(0.06) : RelayColors.surfaceElevated),
                        in: Capsule()
                    )
            }

            // Badge row: fixed height so summary always starts at exact same Y
            HStack(spacing: 6) {
                RelayBadge(
                    recommendationBadge,
                    icon: isRecommended ? "sparkles" : nil,
                    tint: isRecommended ? relayEmerald : RelayColors.textSecondary,
                    prominent: isRecommended
                )
                if isActiveInStore {
                    RelayBadge("Active", icon: "checkmark.circle.fill", tint: relayEmerald, prominent: true)
                } else if isInstalled {
                    RelayBadge("Installed", icon: "arrow.down.circle.fill", tint: relayEmerald)
                }
                Spacer(minLength: 0)
            }
            .frame(height: 22)

            // Description row: uniform 2-line height
            Text(summary)
                .font(.system(size: 12))
                .foregroundStyle(RelayColors.textSecondary)
                .lineSpacing(2)
                .lineLimit(2)
                .frame(minHeight: 34, alignment: .topLeading)

            // Interactive Capability Pills Row
            HStack(spacing: 5) {
                ForEach(capabilities, id: \.self) { cap in
                    Text(cap)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(isHighlighted ? RelayColors.textPrimary : RelayColors.textSecondary)
                        .padding(.horizontal, 7)
                        .frame(height: 20)
                        .background(
                            isHighlighted
                                ? relayIndigo.opacity(0.18)
                                : (isDarkAppearance ? Color.white.opacity(0.04) : RelayColors.surface),
                            in: Capsule()
                        )
                }
                Spacer(minLength: 0)
            }

            // Spec row: aligned baseline across both cards
            Text(specLine.uppercased())
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .tracking(1.1)
                .foregroundStyle(RelayColors.textMuted)
                .lineLimit(1)

            if downloader.isBusy || downloader.phase == .cancelled || (downloader.receivedBytes > 0 && !isInstalled) {
                VStack(alignment: .leading, spacing: 5) {
                    RelayGlowProgressBar(value: downloader.progress)
                    HStack {
                        Text(downloader.phase == .verifying ? "Verifying SHA-256…" : "\(formattedByteCount(downloader.receivedBytes)) / \(formattedByteCount(downloader.totalBytes))")
                            .font(.relayMonoSmall)
                            .foregroundStyle(RelayColors.textSecondary)
                        Spacer()
                        Text(downloader.progress, format: .percent.precision(.fractionLength(0)))
                            .font(.relayMonoSmall.weight(.semibold))
                            .foregroundStyle(RelayColors.textPrimary)
                    }
                }
            }

            Spacer(minLength: 0)

            // Action row pinned to bottom baseline
            HStack(spacing: 8) {
                if downloader.isBusy {
                    Button(downloader.phase == .verifying ? "Cancel" : "Pause") {
                        downloader.cancel()
                    }
                    .buttonStyle(RelaySecondaryButtonStyle())
                } else if isInstalled {
                    let actionTitle = (coordinator.isPreparingModel || store.isPreparingModel) && isSelectedVariant
                        ? "Verifying & Loading…"
                        : (isActiveInStore ? "Reload Engine" : "Verify & Activate")
                    if isActiveInStore {
                        Button(actionTitle) {
                            Task { await coordinator.activateModel(manifest, store: store) }
                        }
                        .buttonStyle(RelaySecondaryButtonStyle())
                        .disabled(coordinator.isPreparingModel || store.isPreparingModel || store.isRunning)
                    } else {
                        Button(actionTitle) {
                            Task { await coordinator.activateModel(manifest, store: store) }
                        }
                        .buttonStyle(RelayPrimaryButtonStyle())
                        .disabled(coordinator.isPreparingModel || store.isPreparingModel || store.isRunning)
                    }
                } else {
                    let isResumable = downloader.phase == .cancelled || downloader.phase == .failed || downloader.resumableBytes > 0
                    let downloadTitle = isResumable ? "Resume (\(sizeLabel))" : "Download (\(sizeLabel))"
                    if isHighlighted {
                        Button(downloadTitle) {
                            coordinator.startModelDownload(manifest)
                        }
                        .buttonStyle(RelayPrimaryButtonStyle())
                        .disabled(!coordinator.hardware.supported || coordinator.isPreparingModel || store.isPreparingModel || store.isRunning)
                    } else {
                        Button(downloadTitle) {
                            coordinator.startModelDownload(manifest)
                        }
                        .buttonStyle(RelaySecondaryButtonStyle())
                        .disabled(!coordinator.hardware.supported || coordinator.isPreparingModel || store.isPreparingModel || store.isRunning)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minHeight: 184)
        .background(
            isDarkAppearance
                ? Color.white.opacity(isHighlighted ? 0.055 : 0.022)
                : (isHighlighted ? RelayColors.surface : RelayColors.cardBG),
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(
                    isHighlighted
                        ? (isDarkAppearance ? relayIndigo.opacity(0.65) : RelayColors.borderStrong)
                        : (isDarkAppearance ? Color.white.opacity(0.09) : RelayColors.borderSubtle),
                    lineWidth: isHighlighted ? 1.5 : 1
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .onTapGesture {
            withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.8)) {
                coordinator.selectedGemmaVariant = manifest
            }
        }
    }

    private var compactOfflineGemmaFallbackBar: some View {
        let e2b = coordinator.download
        let isInstalled = coordinator.isModelInstalled(.gemma4E2B) || coordinator.isModelInstalled(.gemma4E4B)
        return HStack(alignment: .center, spacing: 10) {
            Image(systemName: "cpu.fill")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(relayEmerald)
            Text("Local Gemma 4 (\(coordinator.hardware.memoryGB) GB Mac) · Offline Instant Draft & Memory Vault")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(RelayColors.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if e2b.isBusy {
                Button("Pause (\(Int(e2b.progress * 100))%)") {
                    e2b.cancel()
                }
                .buttonStyle(RelaySecondaryButtonStyle())
            } else if isInstalled {
                HStack(spacing: 5) {
                    Circle().fill(relayEmerald).frame(width: 6, height: 6)
                    Text("Installed")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(relayEmerald)
                }
            } else {
                Button(e2b.phase == .cancelled || e2b.phase == .failed ? "Resume E2B" : "Download E2B (2.59 GB)") {
                    coordinator.startModelDownload(.gemma4E2B)
                }
                .buttonStyle(RelaySecondaryButtonStyle())
                .disabled(!coordinator.hardware.supported)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(
            isDarkAppearance ? Color(red: 0.055, green: 0.063, blue: 0.086) : RelayColors.cardBG,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isDarkAppearance ? Color.white.opacity(0.09) : RelayColors.borderSubtle,
                    lineWidth: 1
                )
        )
    }

    private func formattedByteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }

    // MARK: - Step 4: System Permissions (Interactive Live Capability Simulator + Strict Grid)

    private var accessStep: some View {
        let fdaGranted = store.nativeSources.liveSources.fullDiskAccessStatus.granted
        return VStack(spacing: isCompactViewport ? 10 : 12) {
            stepHeading(
                eyebrow: "ACCESS, ON YOUR TERMS",
                "Give access when you need it.",
                subtitle: "Enable only what you need. You can continue without these permissions and change them later in Settings.",
                compact: isCompactViewport
            )

            DisclosureGroup("See a fictional permission example", isExpanded: $showPermissionExample) {
                interactivePermissionPreviewBanner
                    .padding(.top, 10)
            }
            .font(.relayBodyStrong)
            .foregroundStyle(RelayColors.textSecondary)

            VStack(spacing: 0) {
                permissionRow(
                    index: 0,
                    title: "Accessibility & App Control",
                    detail: "Lets Relay inspect UI elements, insert unsent drafts, and execute reviewed multi-step actions.",
                    badge: "RECOMMENDED",
                    symbol: "cursorarrow.click.2",
                    granted: coordinator.accessibilityGranted,
                    actionTitle: "Allow Accessibility"
                ) {
                    coordinator.requestAccessibility()
                }
                Rectangle()
                    .fill(isDarkAppearance ? Color.white.opacity(0.07) : RelayColors.borderSubtle)
                    .frame(height: 1)
                    .padding(.leading, 74)
                permissionRow(
                    index: 1,
                    title: "Screen Recording & Visual Context",
                    detail: "Lets Relay inspect active windows, diagrams, and selected screen regions on demand.",
                    badge: "VISUAL CONTEXT",
                    symbol: "macwindow",
                    granted: screenCaptureGranted,
                    actionTitle: "Allow Screen Capture"
                ) {
                    screenCaptureGranted = coordinator.requestScreenCapture()
                }
                Rectangle()
                    .fill(isDarkAppearance ? Color.white.opacity(0.07) : RelayColors.borderSubtle)
                    .frame(height: 1)
                    .padding(.leading, 74)
                permissionRow(
                    index: 2,
                    title: "Full Disk Access for Local Indexing",
                    detail: "Lets Relay’s on-device indexer read Apple Notes, Apple Mail, and local message databases.",
                    badge: "OPTIONAL · LOCAL",
                    symbol: "lock.doc.fill",
                    granted: fdaGranted,
                    actionTitle: "Open System Settings"
                ) {
                    _ = store.nativeSources.liveSources.openFullDiskAccessSettings()
                }
            }
            .background { RelayPermissionAtmosphere(isDark: isDarkAppearance, cornerRadius: 16) }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(relayEmerald)
                Text("All capabilities are optional. Sensitive actions pause for confirmation, and ⌘. stops any task.")
                    .font(.system(size: 12))
                    .foregroundStyle(RelayColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(store.accessibilityCheckRunning ? "Checking…" : "Verify Access") {
                    Task { await store.runAccessibilityCheck() }
                }
                .buttonStyle(RelaySecondaryButtonStyle())
                .disabled(!coordinator.accessibilityGranted || store.accessibilityCheckRunning)
            }
            .padding(.horizontal, 16)
            .frame(height: 42)
            .background(
                isDarkAppearance ? Color(red: 0.055, green: 0.063, blue: 0.086) : RelayColors.surface,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isDarkAppearance ? Color.white.opacity(0.09) : RelayColors.borderSubtle,
                        lineWidth: 1
                    )
            )
        }
        .frame(maxWidth: 740)
    }

    private var interactivePermissionPreviewBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { idx in
                        let label = idx == 0 ? "01 · App Control" : (idx == 1 ? "02 · Visual Scan" : "03 · Local Vault SQLite")
                        let isSelected = selectedPermissionPreview == idx
                        Button {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                                selectedPermissionPreview = idx
                            }
                        } label: {
                            Text(label)
                                .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                                .foregroundStyle(isSelected ? RelayColors.textPrimary : RelayColors.textSecondary)
                                .padding(.horizontal, 11)
                                .frame(height: 24)
                                .background(
                                    isSelected ? relayIndigo.opacity(0.26) : Color.clear,
                                    in: Capsule()
                                )
                                .overlay(
                                    Capsule().strokeBorder(
                                        isSelected ? relayIndigo.opacity(0.55) : Color.clear,
                                        lineWidth: 1
                                    )
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(3)
                .background(Color.white.opacity(isDarkAppearance ? 0.04 : 0.08), in: Capsule())

                Spacer()

                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.75)) {
                        permissionSimulationPulse &+= 1
                        if selectedPermissionPreview == 0 {
                            permissionReviewApproved.toggle()
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: selectedPermissionPreview == 0 ? (permissionReviewApproved ? "checkmark.shield.fill" : "hand.raised.fill") : "play.fill")
                            .font(.system(size: 10, weight: .bold))
                        Text(selectedPermissionPreview == 0 ? (permissionReviewApproved ? "Reviewed & Approved ✓" : "Simulate 1-Click Review") : "Run Live Simulation")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(permissionReviewApproved && selectedPermissionPreview == 0 ? relayEmerald : RelayColors.accentBlue)
                    .padding(.horizontal, 11)
                    .frame(height: 26)
                    .background(
                        (permissionReviewApproved && selectedPermissionPreview == 0 ? relayEmerald : RelayColors.accentBlue).opacity(0.14),
                        in: Capsule()
                    )
                    .overlay(
                        Capsule().strokeBorder(
                            (permissionReviewApproved && selectedPermissionPreview == 0 ? relayEmerald : RelayColors.accentBlue).opacity(0.35),
                            lineWidth: 1
                        )
                    )
                }
                .buttonStyle(RelayPressStyle())
            }

            // Visual Interactive Stage for the Selected Capability
            Group {
                if selectedPermissionPreview == 0 {
                    HStack(spacing: 10) {
                        permissionStageStepCard(
                            step: "1. AX TREE INSPECT",
                            title: "Mail Compose Window",
                            detail: "Finds [To: Alex] & [Body]",
                            icon: "viewfinder",
                            tint: RelayColors.accentBlue,
                            active: true
                        )
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(RelayColors.textMuted)
                        permissionStageStepCard(
                            step: "2. STAGE DRAFT",
                            title: "Inserts Unsent Reply",
                            detail: "Never presses Send alone",
                            icon: "character.cursor.ibeam",
                            tint: relayIndigo,
                            active: true
                        )
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(RelayColors.textMuted)
                        permissionStageStepCard(
                            step: "3. SAFETY GATE",
                            title: permissionReviewApproved ? "Action Approved ✓" : "Paused for Confirmation",
                            detail: permissionReviewApproved ? "Executed with audit log" : "Click Simulate to approve",
                            icon: permissionReviewApproved ? "checkmark.circle.fill" : "lock.shield.fill",
                            tint: permissionReviewApproved ? relayEmerald : RelayColors.accentAmber,
                            active: true
                        )
                    }
                } else if selectedPermissionPreview == 1 {
                    HStack(spacing: 10) {
                        permissionStageStepCard(
                            step: "1. ON-DEMAND CAPTURE",
                            title: "Active Window Frame",
                            detail: "Only captures when asked",
                            icon: "macwindow.badge.plus",
                            tint: RelayColors.accentCyan,
                            active: true
                        )
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(RelayColors.textMuted)
                        permissionStageStepCard(
                            step: "2. VISION & OCR PARSE",
                            title: "Extracts Charts & Text",
                            detail: "Reads tables & UI regions",
                            icon: "doc.viewfinder",
                            tint: relayIndigo,
                            active: true
                        )
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(RelayColors.textMuted)
                        permissionStageStepCard(
                            step: "3. LOCAL MEMORY",
                            title: "Discarded After Turn",
                            detail: "Pixels stay in local RAM",
                            icon: "cpu.fill",
                            tint: relayEmerald,
                            active: true
                        )
                    }
                } else {
                    HStack(spacing: 10) {
                        permissionStageStepCard(
                            step: "1. READ-ONLY SQLITE",
                            title: "Notes, Mail & Messages",
                            detail: "Read-only local databases",
                            icon: "internaldrive.fill",
                            tint: RelayColors.accentAmber,
                            active: true
                        )
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(RelayColors.textMuted)
                        permissionStageStepCard(
                            step: "2. GEMMA 4 INDEXER",
                            title: "Entity & Link Extraction",
                            detail: "Builds [[Entity]] links",
                            icon: "point.3.connected.trianglepath.dotted",
                            tint: relayIndigo,
                            active: true
                        )
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(RelayColors.textMuted)
                        permissionStageStepCard(
                            step: "3. PLAIN MARKDOWN",
                            title: "Local KnowledgeVault",
                            detail: "Standard .md files on Mac",
                            icon: "doc.text.fill",
                            tint: relayEmerald,
                            active: true
                        )
                    }
                }
            }
        }
        .padding(14)
        .background { RelayPermissionAtmosphere(isDark: isDarkAppearance, cornerRadius: 15) }
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    private func permissionStageStepCard(
        step: String,
        title: String,
        detail: String,
        icon: String,
        tint: Color,
        active: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                Text(step)
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .tracking(1.1)
                    .foregroundStyle(tint)
                    .lineLimit(1)
            }
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(RelayColors.textPrimary)
                .lineLimit(1)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(RelayColors.textSecondary)
                .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isDarkAppearance ? Color.white.opacity(0.03) : RelayColors.surface,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(tint.opacity(0.28), lineWidth: 1)
        )
    }

    private func permissionRow(
        index: Int,
        title: String,
        detail: String,
        badge: String,
        symbol: String,
        granted: Bool,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        let isPreviewSelected = selectedPermissionPreview == index
        return HStack(alignment: .center, spacing: 16) {
            RelayIconBadge(
                icon: symbol,
                color: granted ? relayEmerald : (isPreviewSelected ? relayIndigo : RelayColors.accentBlue),
                size: 40,
                iconSize: 17
            )
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(RelayColors.textPrimary)
                    Text(badge)
                        .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(granted ? relayEmerald : RelayColors.textSecondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(
                            isDarkAppearance ? Color.white.opacity(0.06) : RelayColors.surfaceElevated,
                            in: Capsule()
                        )
                    if isPreviewSelected {
                        Text("PREVIEWING")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .tracking(1.1)
                            .foregroundStyle(RelayColors.accentBlue)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(RelayColors.accentBlue.opacity(0.14), in: Capsule())
                    }
                }
                Text(detail)
                    .font(.system(size: 12.5))
                    .lineSpacing(2)
                    .foregroundStyle(RelayColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 14)

            // Uniform 168pt trailing column so buttons and status capsules align on the exact same vertical axis
            Group {
                if granted {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Granted")
                            .font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundStyle(relayEmerald)
                    .frame(width: 158, height: 32)
                    .background(relayEmerald.opacity(0.12), in: Capsule())
                    .overlay(Capsule().strokeBorder(relayEmerald.opacity(0.35), lineWidth: 1))
                } else {
                    Button(action: action) {
                        Text(actionTitle)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(RelayColors.textPrimary)
                            .frame(width: 158, height: 32)
                            .background(
                                isDarkAppearance ? Color.white.opacity(0.07) : RelayColors.surfaceElevated,
                                in: Capsule()
                            )
                            .overlay(
                                Capsule().strokeBorder(
                                    isDarkAppearance ? Color.white.opacity(0.14) : RelayColors.borderDefault,
                                    lineWidth: 1
                                )
                            )
                            .contentShape(Capsule())
                    }
                    .buttonStyle(RelayPressStyle())
                }
            }
            .frame(width: 168, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(
            isPreviewSelected
                ? (isDarkAppearance ? relayIndigo.opacity(0.08) : RelayColors.accentBlue.opacity(0.05))
                : Color.clear
        )
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.26, dampingFraction: 0.82)) {
                selectedPermissionPreview = index
            }
        }
    }

    // MARK: - Step 2: Instant Draft & Command Bar Lesson

    private func magicReplyStep(compact: Bool) -> some View {
        VStack(spacing: compact ? 8 : 12) {
            stepHeading(
                eyebrow: "INSTANT DRAFT & COMMAND BAR",
                "Summon Relay anywhere with Right ⌘ × 2.",
                subtitle: "Try the shortcut with a fictional example below. Your own drafts need a connected model and the relevant Mac permissions.",
                compact: compact
            )
            OnboardingMagicReplyDemoView(store: store, coordinator: coordinator, compact: compact)
                .frame(maxWidth: 740)
        }
    }

    // MARK: - Step 5: Context & Memory Vault (Interactive Live Constellation Graph + Source Grid)

    private struct VaultSourceNodeSpec: Identifiable {
        let id: String
        let shortLabel: String
        let icon: String
        let point: CGPoint
        let tint: Color
        let enabled: Bool
        let toggle: () -> Void
    }

    private var readyStep: some View {
        let live = store.nativeSources.liveSources
        let selectedCount = coordinator.selectedPersonalSourceCount(store: store)

        return VStack(spacing: isCompactViewport ? 8 : 11) {
            stepHeading(
                eyebrow: "CONTEXT & MEMORY VAULT",
                "Choose your sources.",
                subtitle: "Sources are optional. Folders and messages can be indexed locally; selected calendars can contribute to daily preparation. Permissions and schedules remain separate.",
                compact: true
            )

            setupHandoff(selectedCount: selectedCount)

            DisclosureGroup("View your selected source map", isExpanded: $showSourceMap) {
                liveMemoryVaultConstellationBar(selectedCount: selectedCount)
                    .frame(maxWidth: 740)
                    .padding(.top, 10)
            }
            .font(.relayBodyStrong)
            .foregroundStyle(RelayColors.textSecondary)

            // Architectural Source Indexing Grid Card
            VStack(alignment: .leading, spacing: 11) {
                // Row 1: EMAIL & CALENDARS (Symmetrical 2-column grid, 54pt height)
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("MAIL & CALENDAR")
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .tracking(1.8)
                            .foregroundStyle(RelayColors.textMuted)
                        Spacer()
                        HStack(spacing: 4) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 9, weight: .semibold))
                            Text("Choose only the sources you need")
                                .font(.system(size: 10.5, weight: .medium))
                        }
                        .foregroundStyle(RelayColors.textSecondary)
                    }

                    HStack(spacing: 12) {
                        relaySourceCard(
                            title: "Apple Mail",
                            subtitle: live.isEnabled(.appleMail) ? "Selected · Permission required" : "Threads, commitments & follow-ups",
                            icon: "envelope.fill",
                            tint: RelayColors.accentBlue,
                            isSelected: live.isEnabled(.appleMail),
                            featured: true
                        ) {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                                live.setEnabled(.appleMail, !live.isEnabled(.appleMail))
                                vaultLastToggledSource = "Apple Mail"
                            }
                        }

                        relaySourceCard(
                            title: "Apple Calendar",
                            subtitle: store.preparation.calendarRefreshIDs.isEmpty ? "Not included · Choose calendars…" : "Included in daily preparation · This session",
                            icon: "calendar",
                            tint: RelayColors.accentCoral,
                            isSelected: !store.preparation.calendarRefreshIDs.isEmpty,
                            featured: true
                        ) {
                            vaultLastToggledSource = "Apple Calendar"
                            showCalendarSourceSheet = true
                        }
                    }
                }

                // Row 2: MESSAGES (Symmetrical 2-column grid, 54pt height)
                VStack(alignment: .leading, spacing: 5) {
                    Text("DIRECT MESSAGES")
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .tracking(1.8)
                        .foregroundStyle(RelayColors.textMuted)

                    HStack(spacing: 12) {
                        relaySourceCard(
                            title: "WhatsApp",
                            subtitle: live.isEnabled(.whatsapp) ? "Selected for local indexing" : "Index selected local conversation threads",
                            icon: "bubble.left.and.bubble.right.fill",
                            tint: relayEmerald,
                            isSelected: live.isEnabled(.whatsapp),
                            featured: true
                        ) {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                                live.setEnabled(.whatsapp, !live.isEnabled(.whatsapp))
                                vaultLastToggledSource = "WhatsApp"
                            }
                        }

                        relaySourceCard(
                            title: "iMessage",
                            subtitle: live.isEnabled(.imessage) ? "Selected for local indexing" : "Index selected local conversation threads",
                            icon: "message.fill",
                            tint: relayEmerald,
                            isSelected: live.isEnabled(.imessage),
                            featured: true
                        ) {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                                live.setEnabled(.imessage, !live.isEnabled(.imessage))
                                vaultLastToggledSource = "iMessage"
                            }
                        }
                    }
                }

                Rectangle()
                    .fill(isDarkAppearance ? Color.white.opacity(0.07) : RelayColors.borderSubtle)
                    .frame(height: 1)

                // Row 3: NOTES & LOCAL FOLDERS (Symmetrical 5-column full-width row aligned to outer grid margins)
                VStack(alignment: .leading, spacing: 5) {
                    Text("NOTES & LOCAL FOLDERS ON THIS MAC")
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .tracking(1.8)
                        .foregroundStyle(RelayColors.textMuted)

                    HStack(spacing: 8) {
                        relaySourceCard(
                            title: "Apple Notes",
                            subtitle: nil,
                            icon: "note.text",
                            tint: RelayColors.accentAmber,
                            isSelected: live.isEnabled(.notes),
                            featured: false
                        ) {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                                live.setEnabled(.notes, !live.isEnabled(.notes))
                                vaultLastToggledSource = "Apple Notes"
                            }
                        }

                        folderChipButton(
                            title: "Desktop",
                            icon: "desktopcomputer",
                            directory: .desktopDirectory
                        )

                        folderChipButton(
                            title: "Downloads",
                            icon: "arrow.down.to.line",
                            directory: .downloadsDirectory
                        )

                        folderChipButton(
                            title: "Documents",
                            icon: "doc.text",
                            directory: .documentDirectory
                        )

                        Button {
                            vaultLastToggledSource = "Custom Folder"
                            store.chooseFolder()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "folder.badge.plus")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(RelayColors.accentBlue)
                                Text("Add Folder")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                                Spacer(minLength: 2)
                                Image(systemName: "plus")
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .foregroundStyle(RelayColors.textMuted)
                            }
                            .foregroundStyle(RelayColors.textPrimary)
                            .padding(.horizontal, 9)
                            .frame(maxWidth: .infinity, minHeight: 38)
                            .background(
                                isDarkAppearance ? Color.white.opacity(0.03) : RelayColors.surface,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(
                                        isDarkAppearance ? Color.white.opacity(0.20) : RelayColors.borderDefault,
                                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                                    )
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(RelayPressStyle())
                    }
                }

                Rectangle()
                    .fill(isDarkAppearance ? Color.white.opacity(0.07) : RelayColors.borderSubtle)
                    .frame(height: 1)

                // Footer inside card: Single-line source counter + Local MCP Bridge + Background Indexing
                HStack(alignment: .center, spacing: 10) {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(selectedCount >= 3 ? relayEmerald : RelayColors.accentAmber)
                            .frame(width: 6.5, height: 6.5)
                        Text(
                            selectedCount >= 3
                                ? "\(selectedCount) SOURCES SELECTED"
                                : "\(selectedCount) SOURCES SELECTED · OPTIONAL"
                        )
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .tracking(1.2)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(selectedCount >= 3 ? relayEmerald : RelayColors.accentAmber)
                    }

                    Spacer(minLength: 8)

                    Button {
                        showMCPSharingSheet = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "link")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Local MCP Bridge…")
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(RelaySecondaryButtonStyle())
                    .accessibilityIdentifier("onboarding.openMCPSharingSheet")

                    Button {
                        loginItem.refresh()
                        showAnalysisTimingSheet = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "clock.badge.checkmark")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Background Indexing…")
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(RelaySecondaryButtonStyle())
                    .accessibilityIdentifier("onboarding.openAnalysisTimingSheet")
                }
            }
            .padding(16)
            .frame(maxWidth: 740)
            .background { RelayPermissionAtmosphere(isDark: isDarkAppearance, cornerRadius: 16) }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .frame(maxWidth: 740)
        .sheet(isPresented: $showCalendarSourceSheet) {
            onboardingCalendarSourceSheet
        }
        .sheet(isPresented: $showAnalysisTimingSheet) {
            analysisTimingSheet
        }
        .sheet(isPresented: $showMCPSharingSheet) {
            mcpSharingOnboardingSheet
        }
    }

    private func setupHandoff(selectedCount: Int) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: store.workspaceActionsReady ? "arrow.up.right" : "slider.horizontal.3")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(RelayColors.workbenchAccent)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 7) {
                Text(store.workspaceActionsReady ? "Take your next step in Relay." : "Continue at your own pace.")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(RelayColors.textPrimary)
                Text(store.workspaceActionsReady
                    ? "\(store.workspaceProviderTitle) is selected for workspace requests. Launch Relay to try your first task; personal sources remain optional."
                    : "You can open the workspace now and connect a model in Settings when you are ready.")
                    .font(.relayBody)
                    .foregroundStyle(RelayColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(selectedCount) \(selectedCount == 1 ? "source" : "sources") selected · Indexing and daily preparation are separate choices.")
                    .font(.relayCaption)
                    .foregroundStyle(RelayColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RelayColors.workbenchTint, in: RoundedRectangle(cornerRadius: 12))
    }

    private var onboardingCalendarSourceSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Calendar access and daily preparation").font(.relayHeadline)
                Spacer()
                Button("Done") { showCalendarSourceSheet = false }
                    .buttonStyle(RelaySecondaryButtonStyle())
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(CalendarSource.permissionExplanation)
                        .font(.relayCaption).foregroundStyle(RelayColors.textSecondary)
                    Button(store.calendarSource.hasAccess ? "Refresh available calendars" : "Allow Calendar access") {
                        Task { await store.calendarSource.requestAccess() }
                    }
                    .buttonStyle(RelaySecondaryButtonStyle())
                    .disabled(store.calendarSource.isLoading)
                    Text(store.calendarSource.status).font(.relayCaption)
                    if let error = store.calendarSource.errorMessage { inlineError(error) }
                    CalendarSelectionView(source: store.calendarSource)
                    Divider()
                    Toggle("Include selected calendars in daily preparation", isOn: Binding(
                        get: { !store.preparation.calendarRefreshIDs.isEmpty },
                        set: { store.preparation.setCalendarRefreshEnabled($0) }
                    ))
                    .disabled(store.calendarSource.selectedCalendarIDs.isEmpty || !store.calendarSource.hasAccess)
                    .accessibilityIdentifier("onboarding.calendar.includeInPreparation")
                    Text("This is separate from macOS permission. It uses only your selected calendars, applies for this session, and can be turned off without revoking access. Daily preparation must also be enabled below.")
                        .font(.relayCaption).foregroundStyle(RelayColors.textSecondary)
                    Toggle("Enable proactive suggestions", isOn: Binding(
                        get: { store.suggestions.enabled },
                        set: { store.suggestions.setEnabled($0) }
                    ))
                    PreparationScheduleView(scheduler: store.preparation, suggestionsEnabled: store.suggestions.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24)
        .frame(width: 600, height: 620)
        .background(RelayColors.canvas)
        .relayPreferredAppearance()
    }

    private func liveMemoryVaultConstellationBar(selectedCount: Int) -> some View {
        let live = store.nativeSources.liveSources
        let nodes: [VaultSourceNodeSpec] = [
            VaultSourceNodeSpec(
                id: "Apple Mail",
                shortLabel: "Mail",
                icon: "envelope.fill",
                point: CGPoint(x: 0.14, y: 0.25),
                tint: RelayColors.accentBlue,
                enabled: live.isEnabled(.appleMail),
                toggle: { live.setEnabled(.appleMail, !live.isEnabled(.appleMail)) }
            ),
            VaultSourceNodeSpec(
                id: "Apple Calendar",
                shortLabel: "Calendar",
                icon: "calendar",
                point: CGPoint(x: 0.16, y: 0.76),
                tint: RelayColors.accentCoral,
                enabled: !store.preparation.calendarRefreshIDs.isEmpty,
                toggle: { showCalendarSourceSheet = true }
            ),
            VaultSourceNodeSpec(
                id: "WhatsApp",
                shortLabel: "WhatsApp",
                icon: "bubble.left.and.bubble.right.fill",
                point: CGPoint(x: 0.34, y: 0.22),
                tint: relayEmerald,
                enabled: live.isEnabled(.whatsapp),
                toggle: { live.setEnabled(.whatsapp, !live.isEnabled(.whatsapp)) }
            ),
            VaultSourceNodeSpec(
                id: "iMessage",
                shortLabel: "iMessage",
                icon: "message.fill",
                point: CGPoint(x: 0.35, y: 0.78),
                tint: relayEmerald,
                enabled: live.isEnabled(.imessage),
                toggle: { live.setEnabled(.imessage, !live.isEnabled(.imessage)) }
            ),
            VaultSourceNodeSpec(
                id: "Apple Notes",
                shortLabel: "Notes",
                icon: "note.text",
                point: CGPoint(x: 0.66, y: 0.22),
                tint: RelayColors.accentAmber,
                enabled: live.isEnabled(.notes),
                toggle: { live.setEnabled(.notes, !live.isEnabled(.notes)) }
            ),
            VaultSourceNodeSpec(
                id: "Desktop",
                shortLabel: "Desktop",
                icon: "desktopcomputer",
                point: CGPoint(x: 0.85, y: 0.26),
                tint: RelayColors.accentCyan,
                enabled: coordinator.isCommonLocalFolderGranted(.desktopDirectory, store: store),
                toggle: { coordinator.toggleCommonLocalFolder(.desktopDirectory, store: store) }
            ),
            VaultSourceNodeSpec(
                id: "Documents",
                shortLabel: "Documents",
                icon: "doc.text",
                point: CGPoint(x: 0.76, y: 0.78),
                tint: relayIndigo,
                enabled: coordinator.isCommonLocalFolderGranted(.documentDirectory, store: store),
                toggle: { coordinator.toggleCommonLocalFolder(.documentDirectory, store: store) }
            )
        ]


        return HStack(spacing: 14) {
            // Left: Interactive Live Constellation Graph Canvas (event-driven, zero AX main-thread blocking!)
            GeometryReader { geo in
                let center = CGPoint(x: geo.size.width * 0.50, y: geo.size.height * 0.50)
                ZStack {
                    Canvas { context, size in
                        let corePt = CGPoint(x: size.width * 0.50, y: size.height * 0.50)
                        for node in nodes {
                            let pt = CGPoint(x: node.point.x * size.width, y: node.point.y * size.height)
                            var path = Path()
                            path.move(to: corePt)
                            path.addLine(to: pt)

                            if node.enabled {
                                context.stroke(
                                    path,
                                    with: .linearGradient(
                                        Gradient(colors: [relayIndigo.opacity(0.85), node.tint.opacity(0.80)]),
                                        startPoint: corePt,
                                        endPoint: pt
                                    ),
                                    lineWidth: 1.6
                                )
                                let midPt = CGPoint(
                                    x: (corePt.x + pt.x) * 0.5,
                                    y: (corePt.y + pt.y) * 0.5
                                )
                                let pulseRect = CGRect(x: midPt.x - 2.5, y: midPt.y - 2.5, width: 5, height: 5)
                                context.fill(Path(ellipseIn: pulseRect), with: .color(node.tint))
                            } else {
                                context.stroke(
                                    path,
                                    with: .color(Color.white.opacity(isDarkAppearance ? 0.11 : 0.18)),
                                    style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                                )
                            }
                        }
                    }

                    // Clickable Satellite Source Nodes
                    ForEach(nodes) { node in
                        let pos = CGPoint(x: node.point.x * geo.size.width, y: node.point.y * geo.size.height)
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                                vaultLastToggledSource = node.id
                                node.toggle()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(node.enabled ? node.tint : RelayColors.textMuted.opacity(0.45))
                                    .frame(width: 6, height: 6)
                                Text(node.shortLabel)
                                    .font(.system(size: 10, weight: node.enabled ? .semibold : .medium))
                                    .foregroundStyle(node.enabled ? RelayColors.textPrimary : RelayColors.textSecondary)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .background(
                                isDarkAppearance ? Color(red: 0.05, green: 0.06, blue: 0.085) : RelayColors.cardBG,
                                in: Capsule()
                            )
                            .overlay(
                                Capsule().strokeBorder(
                                    node.enabled ? node.tint.opacity(0.75) : Color.white.opacity(0.12),
                                    lineWidth: node.enabled ? 1.2 : 1
                                )
                            )
                            .shadow(color: node.enabled ? node.tint.opacity(0.28) : .clear, radius: 6)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(node.id)
                        .accessibilityValue(node.enabled ? "Selected" : "Not selected")
                        .accessibilityAddTraits(node.enabled ? .isSelected : [])
                        .position(pos)
                    }

                    // Central Memory Vault Hub Node
                    HStack(spacing: 5) {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(relayEmerald)
                        Text("VAULT")
                            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                            .tracking(1.1)
                            .foregroundStyle(RelayColors.textPrimary)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(
                        isDarkAppearance ? Color(red: 0.08, green: 0.09, blue: 0.14) : RelayColors.surfaceElevated,
                        in: Capsule()
                    )
                    .overlay(Capsule().strokeBorder(relayIndigo.opacity(0.8), lineWidth: 1.5))
                    .shadow(color: relayIndigo.opacity(0.35), radius: 10)
                    .position(center)
                }
            }
            .frame(maxWidth: 410, minHeight: 106, maxHeight: 106)
            .background(
                isDarkAppearance ? Color(red: 0.035, green: 0.04, blue: 0.06) : RelayColors.surface,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isDarkAppearance ? Color.white.opacity(0.08) : RelayColors.borderSubtle, lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 6) {
                Text("SOURCE SELECTION")
                    .font(.relayCaptionStrong)
                    .foregroundStyle(RelayColors.textSecondary)
                Text("\(selectedCount) selected")
                    .font(.relayBodyStrong)
                Text("This diagram shows selected sources, not completed work. Review indexing in Knowledge and the calendar agenda in Morning Brief.")
                    .font(.relayCaption)
                    .foregroundStyle(RelayColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background { RelayPermissionAtmosphere(isDark: isDarkAppearance, cornerRadius: 14) }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func relaySourceCard(
        title: String,
        subtitle: String?,
        icon: String,
        tint: Color,
        isSelected: Bool,
        featured: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: featured ? 12 : 5) {
                Image(systemName: icon)
                    .font(.system(size: featured ? 14 : 11, weight: .semibold))
                    .foregroundStyle(isSelected ? relayEmerald : tint)
                    .frame(width: featured ? 32 : 18, height: featured ? 32 : 18)
                    .background(
                        (isSelected ? relayEmerald : tint).opacity(featured ? 0.14 : 0.12),
                        in: RoundedRectangle(cornerRadius: featured ? 8 : 5, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: featured ? 13.5 : 11.5, weight: .semibold))
                        .foregroundStyle(RelayColors.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11.5))
                            .foregroundStyle(RelayColors.textSecondary)
                            .lineLimit(1)
                    }
                }
                .layoutPriority(1)

                Spacer(minLength: featured ? 4 : 2)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "plus")
                    .font(.system(size: featured ? 13 : 9, weight: isSelected ? .bold : .semibold))
                    .foregroundStyle(isSelected ? relayEmerald : RelayColors.textMuted)
            }
            .padding(.horizontal, featured ? 14 : 8)
            .frame(maxWidth: .infinity, minHeight: featured ? 52 : 38, alignment: .leading)
            .background(
                isSelected
                    ? relayEmerald.opacity(0.10)
                    : (isDarkAppearance ? Color.white.opacity(0.03) : RelayColors.surface),
                in: RoundedRectangle(cornerRadius: featured ? 12 : 10, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: featured ? 12 : 10, style: .continuous)
                    .strokeBorder(
                        isSelected
                            ? relayEmerald.opacity(0.45)
                            : (isDarkAppearance ? Color.white.opacity(0.11) : RelayColors.borderSubtle),
                        lineWidth: isSelected ? 1.2 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: featured ? 12 : 10, style: .continuous))
        }
        .buttonStyle(RelayPressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func folderChipButton(
        title: String,
        icon: String,
        directory: FileManager.SearchPathDirectory
    ) -> some View {
        let isSelected = coordinator.isCommonLocalFolderGranted(directory, store: store)
        return relaySourceCard(
            title: title,
            subtitle: nil,
            icon: icon,
            tint: RelayColors.textSecondary,
            isSelected: isSelected,
            featured: false
        ) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                vaultLastToggledSource = title
                coordinator.toggleCommonLocalFolder(directory, store: store)
            }
        }
    }

    // MARK: - Background Indexing & Menu Bar Schedule Sheet

    private var analysisTimingSheet: some View {
        let loginReady = loginItem.status == .enabled
        let idleEnabled = store.pluggedInAnalysis.enabled
        return VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("BACKGROUND INDEXING & SCHEDULE")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .tracking(1.8)
                    .foregroundStyle(RelayColors.accentBlue)
                Text("Keep your Memory Vault current")
                    .font(.system(size: 24, weight: .semibold))
                    .tracking(-0.4)
                    .foregroundStyle(RelayColors.textPrimary)
                Text("Start indexing now and pause anytime. Enable background triggers so Relay updates your local Markdown notes while your Mac is idle.")
                    .font(.system(size: 13))
                    .foregroundStyle(RelayColors.textSecondary)
                    .lineSpacing(2.5)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 10) {
                // Row 1: Overnight & Idle Indexing
                HStack(alignment: .center, spacing: 14) {
                    RelayIconBadge(icon: "moon.stars.fill", color: RelayColors.accentAmethyst, size: 40, iconSize: 17)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Idle & overnight indexing")
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundStyle(RelayColors.textPrimary)
                        Text("Refresh your Knowledge Vault while plugged into power and idle for 4.5 minutes.")
                            .font(.system(size: 12))
                            .foregroundStyle(RelayColors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 10)
                    Group {
                        if idleEnabled {
                            Label("Enabled", systemImage: "checkmark.circle.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(relayEmerald)
                                .frame(width: 104, height: 30)
                                .background(relayEmerald.opacity(0.12), in: Capsule())
                        } else {
                            Button("Enable") {
                                store.pluggedInAnalysis.setEnabled(true)
                                store.preparation.setEnabled(true)
                            }
                            .buttonStyle(RelaySecondaryButtonStyle())
                            .frame(width: 104, alignment: .trailing)
                        }
                    }
                }
                .padding(15)
                .background(
                    isDarkAppearance ? Color.white.opacity(0.035) : RelayColors.surface,
                    in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(
                            isDarkAppearance ? Color.white.opacity(0.09) : RelayColors.borderSubtle,
                            lineWidth: 1
                        )
                )

                // Row 2: Launch at login
                HStack(alignment: .center, spacing: 14) {
                    RelayIconBadge(icon: "power", color: relayEmerald, size: 40, iconSize: 17)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Launch at login")
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundStyle(RelayColors.textPrimary)
                        Text("Keep Relay available in your menu bar and ready for Right ⌘ × 2.")
                            .font(.system(size: 12))
                            .foregroundStyle(RelayColors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 10)
                    Group {
                        if loginReady {
                            Label("Enabled", systemImage: "checkmark.circle.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(relayEmerald)
                                .frame(width: 104, height: 30)
                                .background(relayEmerald.opacity(0.12), in: Capsule())
                        } else {
                            Button("Turn on") {
                                loginItem.setEnabled(true)
                            }
                            .buttonStyle(RelaySecondaryButtonStyle())
                            .frame(width: 104, alignment: .trailing)
                        }
                    }
                }
                .padding(15)
                .background(
                    isDarkAppearance ? Color.white.opacity(0.035) : RelayColors.surface,
                    in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(
                            isDarkAppearance ? Color.white.opacity(0.09) : RelayColors.borderSubtle,
                            lineWidth: 1
                        )
                )
            }

            Text("You can continue using Relay and your workspace normally while background indexing runs.")
                .font(.system(size: 12))
                .foregroundStyle(RelayColors.textSecondary)

            HStack {
                Button("Close") {
                    showAnalysisTimingSheet = false
                }
                .buttonStyle(RelaySecondaryButtonStyle())

                Spacer()

                Button {
                    store.pluggedInAnalysis.setEnabled(true)
                    Task {
                        try? await store.nativeSources.liveSources.runIncrementalIngestion()
                    }
                    showAnalysisTimingSheet = false
                    coordinator.finish()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                        Text("Start Indexing & Launch Relay")
                    }
                    .font(.system(size: 13.5, weight: .semibold))
                    .padding(.horizontal, 20)
                    .frame(height: 38)
                    .foregroundStyle(isDarkAppearance ? Color.black : Color.white)
                    .background(isDarkAppearance ? Color.white : RelayColors.buttonFace, in: Capsule())
                    .shadow(color: relayIndigo.opacity(0.28), radius: 12, y: 3)
                }
                .buttonStyle(RelayPressStyle())
            }
            .padding(.top, 4)
        }
        .padding(26)
        .frame(width: 560)
        .background { RelayPermissionAtmosphere(isDark: isDarkAppearance, cornerRadius: 0) }
        .relayPreferredAppearance()
    }

    // MARK: - Local MCP Knowledge Bridge Sheet (Equal-Height Step Cards)

    private var mcpSharingOnboardingSheet: some View {
        let abbreviatedVaultPath = (store.knowledgeVault.vaultDirectory.path as NSString).abbreviatingWithTildeInPath
        let mcpCommand = store.knowledgeSharing.endpoint?.absoluteString ?? "http://127.0.0.1:8788/mcp"

        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("LOCAL MCP BRIDGE & ENCRYPTED ARCHIVE")
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .tracking(1.6)
                        .foregroundStyle(RelayColors.accentBlue)
                    Text("Local MCP Knowledge Bridge")
                        .font(.system(size: 24, weight: .semibold))
                        .tracking(-0.4)
                        .foregroundStyle(RelayColors.textPrimary)
                    Text("Expose selected Markdown notes from your local Vault to Claude, ChatGPT, or any MCP client over 127.0.0.1.")
                        .font(.system(size: 13))
                        .foregroundStyle(RelayColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                HStack(spacing: 10) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(relayEmerald)
                            .frame(width: 6, height: 6)
                        Text(store.knowledgeSharing.isActive ? "MCP ACTIVE" : "LOCAL VAULT")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .tracking(1.4)
                            .foregroundStyle(relayEmerald)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .overlay(Capsule().strokeBorder(relayEmerald.opacity(0.35), lineWidth: 1))

                    Button("Done") {
                        showMCPSharingSheet = false
                    }
                    .buttonStyle(RelaySecondaryButtonStyle())
                }
            }

            // Local Vault Location Bar
            HStack(spacing: 12) {
                RelayIconBadge(icon: "folder.fill", color: RelayColors.accentBlue, size: 34, iconSize: 15)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Plain-text Markdown Vault directory")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(RelayColors.textPrimary)
                    Text(abbreviatedVaultPath)
                        .font(.relayMonoSmall)
                        .foregroundStyle(RelayColors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Show in Finder") {
                    store.knowledgeVault.revealVaultInFinder()
                }
                .buttonStyle(RelaySecondaryButtonStyle())
            }
            .padding(12)
            .background(
                isDarkAppearance ? Color.white.opacity(0.035) : RelayColors.surface,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(RelayColors.borderSubtle, lineWidth: 1))

            // Left-aligned Client Tab Bar + Equal-Height 2-Step Cards
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    HStack(spacing: 4) {
                        ForEach(MCPClientGuideTab.allCases) { tab in
                            let isSelected = selectedMCPClientTab == tab
                            Button {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    selectedMCPClientTab = tab
                                }
                            } label: {
                                Text(tab.rawValue)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(
                                        isSelected
                                            ? (isDarkAppearance ? Color.black : Color.white)
                                            : RelayColors.textSecondary
                                    )
                                    .padding(.horizontal, 16)
                                    .frame(height: 28)
                                    .background(
                                        isSelected
                                            ? (isDarkAppearance ? Color.white : RelayColors.buttonFace)
                                            : Color.clear,
                                        in: Capsule()
                                    )
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(RelayPressStyle())
                        }
                    }
                    .padding(3)
                    .background(
                        isDarkAppearance ? Color.white.opacity(0.04) : RelayColors.surface,
                        in: Capsule()
                    )
                    .overlay(Capsule().strokeBorder(RelayColors.borderSubtle, lineWidth: 1))

                    Spacer()

                    Text("LOOPBACK ONLY · 127.0.0.1")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .tracking(1.4)
                        .foregroundStyle(RelayColors.textMuted)
                }

                // Equal-height STEP 1 & STEP 2 cards
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("STEP 1 · ENDPOINT")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .tracking(1.6)
                            .foregroundStyle(RelayColors.accentBlue)
                        Text(selectedMCPClientTab == .claude ? "Register with Claude Code / Desktop" : (selectedMCPClientTab == .chatgpt ? "Register with ChatGPT / Codex" : "Copy local MCP endpoint"))
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(RelayColors.textPrimary)
                        HStack(spacing: 8) {
                            Text(mcpCommand)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(RelayColors.textBright)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .padding(.horizontal, 10)
                                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                                .background(
                                    isDarkAppearance ? Color.white.opacity(0.04) : RelayColors.surfaceElevated,
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                                )
                                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(RelayColors.borderSubtle, lineWidth: 1))
                            Button(copiedMCPCommand ? "Copied ✓" : "Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(mcpCommand, forType: .string)
                                copiedMCPCommand = true
                                Task {
                                    try? await Task.sleep(for: .seconds(1.8))
                                    copiedMCPCommand = false
                                }
                            }
                            .buttonStyle(RelaySecondaryButtonStyle())
                        }
                        Spacer(minLength: 0)
                        Text("Token-scoped 15-minute local session on 127.0.0.1. Zero external cloud relay.")
                            .font(.system(size: 11))
                            .foregroundStyle(RelayColors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(
                        isDarkAppearance ? Color.white.opacity(0.03) : RelayColors.surface,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(RelayColors.borderSubtle, lineWidth: 1))

                    VStack(alignment: .leading, spacing: 8) {
                        Text("STEP 2 · QUERY")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .tracking(1.6)
                            .foregroundStyle(RelayColors.accentBlue)
                        Text("Query your local Memory Graph")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(RelayColors.textPrimary)
                        Text("“Summarize my open commitments and linked notes for Friday’s rollout.”")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(RelayColors.textBright)
                            .lineLimit(2)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                isDarkAppearance ? Color.white.opacity(0.04) : RelayColors.surfaceElevated,
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                            )
                        Spacer(minLength: 0)
                        Text("Compatible with any MCP client or portable AES-GCM encrypted .relaynotes archive.")
                            .font(.system(size: 11))
                            .foregroundStyle(RelayColors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(
                        isDarkAppearance ? Color.white.opacity(0.03) : RelayColors.surface,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(RelayColors.borderSubtle, lineWidth: 1))
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            LocalKnowledgeMCPSettingsView(server: store.knowledgeSharing)
                .padding(12)
                .background(
                    isDarkAppearance ? Color.white.opacity(0.03) : RelayColors.surface,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(RelayColors.borderSubtle, lineWidth: 1))

            PortableKnowledgeSharingView()
        }
        .padding(24)
        .frame(width: 680)
        .background { RelayPermissionAtmosphere(isDark: isDarkAppearance, cornerRadius: 0) }
        .relayPreferredAppearance()
    }

    // MARK: - Provider Sync & Helpers

    private func selectProvider(_ choice: OnboardingProviderChoice) {
        coordinator.selectedProvider = choice
        switch choice {
        case .onDeviceGemma, .customLiteRT:
            store.selectLocalProvider(.liteRTLM)
        case .chatGPTCodex:
            store.selectLocalProvider(.codexCLI)
        case .claudeCLI:
            store.selectLocalProvider(.claudeCLI)
        case .openRouter:
            store.selectLocalProvider(.openRouter)
        case .lmStudio:
            store.selectLocalProvider(.lmStudio)
        }
    }

    private func syncProviderSelectionFromStore() {
        if store.workspaceUsesClaude || store.configuration.backend == .claudeCLI {
            coordinator.selectedProvider = .claudeCLI
        } else if store.workspaceUsesCodex || store.workspaceUsesCodexCLI || store.configuration.backend == .codexCLI {
            coordinator.selectedProvider = .chatGPTCodex
        } else {
            switch store.configuration.backend {
            case .openRouter:
                coordinator.selectedProvider = .openRouter
            case .lmStudio:
                coordinator.selectedProvider = .lmStudio
            case .claudeCLI:
                coordinator.selectedProvider = .claudeCLI
            case .codexCLI:
                coordinator.selectedProvider = .chatGPTCodex
            case .liteRTLM, .customResponses:
                break
            }
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
            Text(message).font(.relayCaption).lineSpacing(2).textSelection(.enabled)
        } icon: {
            Image(systemName: "exclamationmark.circle.fill")
        }
        .foregroundStyle(RelayColors.accentAmber)
    }
}

// MARK: - Relay Architectural Stage & Precision Card Surfaces

/// The setup shares the same quiet paper/graphite work surface as the workspace.
struct RelayOnboardingStageAtmosphere: View {
    var isDark: Bool

    var body: some View {
        RelayColors.canvas
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// A single adaptive material for model, permission, and source setup surfaces.
struct RelayPermissionAtmosphere: View {
    var isDark: Bool
    var cornerRadius: CGFloat = 14
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(RelayColors.cardBG)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(contrast == .increased ? RelayColors.borderStrong : RelayColors.borderDefault, lineWidth: 1)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
