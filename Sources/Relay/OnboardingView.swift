import SwiftUI
import AppKit

/// Clean, consistent 5-page standalone onboarding flow.
/// Every page shares the exact same 560pt centered layout, typography, surface card geometry, and primary CTA placement.
/// Zero progress bars ("1/4", "2/4"), zero fake personas, and zero visual clutter.
struct OnboardingView: View {
    @Bindable var coordinator: OnboardingCoordinator
    @Bindable var store: AssistantStore

    @State private var chosenTask = "Open Calculator"
    @Environment(\.scenePhase) private var scenePhase

    // Retained for lifecycle identifier contract; never rendered as a "1/5" counter bar.
    private let steps = ["Welcome", "Offline Privacy", "Local Model", "Mac Access", "Launchpad"]

    var body: some View {
        ZStack {
            RelayTheme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar

                Spacer(minLength: 24)

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
                .frame(width: 560)

                Spacer(minLength: 24)

                bottomFooter
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RelayTheme.background)
        .foregroundStyle(RelayTheme.ink)
        .tint(RelayColors.accentEmerald)
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

    // MARK: - Shared Top Bar (Identical across all pages)

    private var topBar: some View {
        HStack {
            if coordinator.step > 0 {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        coordinator.step -= 1
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Back")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(RelayColors.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(coordinator.isPreparingModel || store.isPreparingModel || store.accessibilityCheckRunning)
            } else {
                HStack(spacing: 8) {
                    RelayMark(size: 22)
                    Text("Relay")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }

            Spacer()

            if coordinator.step < 4 {
                Button {
                    coordinator.finish()
                } label: {
                    Text("Skip setup")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(RelayColors.textMuted)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(coordinator.download.isBusy || coordinator.isPreparingModel || store.isPreparingModel || store.accessibilityCheckRunning)
            }
        }
        .frame(height: 36)
    }

    private var bottomFooter: some View {
        Text("100% Offline · Runs locally on Apple Silicon")
            .font(.system(size: 12))
            .foregroundStyle(RelayColors.textDim)
            .frame(height: 20)
    }

    // MARK: - Shared Page Layout Template

    private func pageHeader(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                    .frame(width: 44, height: 44)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                    )
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .padding(.bottom, 2)

            Text(title)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            Text(subtitle)
                .font(.system(size: 14.5))
                .foregroundStyle(RelayColors.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 480)
        }
    }

    private func primaryContinueButton(title: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(enabled ? Color.black : Color.white.opacity(0.35))
            .frame(width: 220, height: 42)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(enabled ? Color.white : Color.white.opacity(0.08))
            )
        }
        .buttonStyle(RelayPressStyle())
        .disabled(!enabled)
    }

    private func featureRow(icon: String, title: String, detail: String, badge: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(RelayColors.textSecondary)
                .frame(width: 32, height: 32)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    if let badge {
                        Text(badge)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(RelayColors.accentEmerald)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(RelayColors.accentEmerald.opacity(0.12), in: Capsule())
                    }
                }
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(RelayColors.textSecondary)
                    .lineSpacing(2)
            }
        }
    }

    // MARK: - Page 0: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 28) {
            pageHeader(
                icon: "arrow.triangle.swap",
                title: "Meet Relay",
                subtitle: "A private local assistant that works with your files and Mac apps—running entirely on your device."
            )

            VStack(alignment: .leading, spacing: 18) {
                featureRow(
                    icon: "cpu",
                    title: "Runs on Apple Silicon",
                    detail: "Powered by a local Gemma 4 model with zero cloud dependencies.",
                    badge: "\(coordinator.hardware.memoryGB) GB RAM"
                )
                Divider().overlay(Color.white.opacity(0.07))
                featureRow(
                    icon: "folder",
                    title: "Scoped to your folders",
                    detail: "Reads and searches only the local files and folders you explicitly grant."
                )
                Divider().overlay(Color.white.opacity(0.07))
                featureRow(
                    icon: "hand.raised",
                    title: "Always under your control",
                    detail: "Asks before sensitive actions and stops immediately anytime you press ⌘."
                )
            }
            .padding(22)
            .background(RelayColors.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )

            primaryContinueButton(title: "Get Started", enabled: coordinator.hardware.supported) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    coordinator.step = 1
                }
            }
        }
    }

    // MARK: - Page 1: Offline Privacy

    private var privacyStep: some View {
        VStack(spacing: 28) {
            pageHeader(
                icon: "lock.shield",
                title: "Private by design",
                subtitle: "Relay operates 100% offline. No accounts, no telemetry, and no external servers ever touch your workspace."
            )

            VStack(alignment: .leading, spacing: 18) {
                featureRow(
                    icon: "wifi.slash",
                    title: "100% local inference",
                    detail: "Every prompt, document summary, and action plan is computed on this Mac.",
                    badge: "Offline"
                )
                Divider().overlay(Color.white.opacity(0.07))
                featureRow(
                    icon: "checkmark.shield",
                    title: "Explicit action approval",
                    detail: "Relay previews tool calls and asks for one-time confirmation before modifying data."
                )
                Divider().overlay(Color.white.opacity(0.07))
                featureRow(
                    icon: "command",
                    title: "Global stop shortcut",
                    detail: "Press ⌘. at any moment to immediately cancel active tasks or computer use."
                )
            }
            .padding(22)
            .background(RelayColors.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )

            primaryContinueButton(title: "Continue") {
                withAnimation(.easeInOut(duration: 0.2)) {
                    coordinator.step = 2
                }
            }
        }
    }

    // MARK: - Page 2: Local Model

    private var modelStep: some View {
        VStack(spacing: 28) {
            pageHeader(
                icon: "cpu",
                title: "Set up your local model",
                subtitle: "Relay uses Gemma 4 E2B for fast, private reasoning and Mac automation."
            )

            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: store.actionsReady ? "checkmark.circle.fill" : "shippingbox")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(store.actionsReady ? RelayColors.accentEmerald : .white)
                        .frame(width: 38, height: 38)
                        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text("Gemma 4 E2B Instruct")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                            Text(store.actionsReady ? "Active" : "2.59 GB")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(store.actionsReady ? RelayColors.accentEmerald : RelayColors.textSecondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Color.white.opacity(0.06), in: Capsule())
                        }
                        Text(store.configuration.modelPath.isEmpty
                             ? "gemma-4-E2B-it.litertlm · LiteRT-LM Engine"
                             : URL(fileURLWithPath: store.configuration.modelPath).lastPathComponent)
                            .font(.system(size: 12.5))
                            .foregroundStyle(RelayColors.textSecondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    if !coordinator.download.isBusy {
                        if coordinator.download.installedURL != nil || coordinator.download.existingFileAvailable {
                            Button(coordinator.isPreparingModel ? "Verifying…" : (store.actionsReady ? "Reload" : "Activate")) {
                                useDownloadedModel()
                            }
                            .buttonStyle(RelayPrimaryButtonStyle())
                            .disabled(coordinator.isPreparingModel || store.isRunning)
                        } else {
                            Button(coordinator.download.phase == .cancelled || coordinator.download.phase == .failed ? "Resume" : "Download") {
                                coordinator.download.start()
                            }
                            .buttonStyle(RelayPrimaryButtonStyle())
                            .disabled(!coordinator.hardware.supported || coordinator.isPreparingModel || store.isRunning)
                        }
                    }
                }

                if coordinator.download.isBusy {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: coordinator.download.progress)
                            .tint(RelayColors.accentEmerald)
                        HStack {
                            Text(coordinator.download.status)
                                .font(.system(size: 12, design: .monospaced))
                            Spacer()
                            Text(coordinator.download.progress, format: .percent.precision(.fractionLength(0)))
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            Button(coordinator.download.phase == .verifying ? "Cancel" : "Pause") {
                                coordinator.download.cancel()
                            }
                            .buttonStyle(RelaySecondaryButtonStyle())
                        }
                        .foregroundStyle(RelayColors.textSecondary)
                    }
                }

                Divider().overlay(Color.white.opacity(0.07))

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Have a local .litertlm model file?")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                        Text("Select an existing model package from disk.")
                            .font(.system(size: 12))
                            .foregroundStyle(RelayColors.textMuted)
                    }
                    Spacer()
                    Button("Choose File…") {
                        store.chooseModel()
                    }
                    .buttonStyle(RelaySecondaryButtonStyle())

                    if !store.configuration.modelPath.isEmpty && !store.actionsReady {
                        Button("Load") {
                            loadModel()
                        }
                        .buttonStyle(RelaySecondaryButtonStyle())
                        .disabled(coordinator.isPreparingModel || store.isRunning)
                    }
                }

                if let error = coordinator.download.errorMessage ?? coordinator.modelSetupError ?? store.errorMessage {
                    inlineError(error)
                }
            }
            .padding(22)
            .background(RelayColors.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )

            primaryContinueButton(
                title: "Continue",
                enabled: !coordinator.download.isBusy && !coordinator.isPreparingModel
            ) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    coordinator.step = 3
                }
            }
        }
    }

    // MARK: - Page 3: Mac Access

    private var accessStep: some View {
        VStack(spacing: 28) {
            pageHeader(
                icon: "macwindow",
                title: "Grant Mac access",
                subtitle: "Enable Accessibility so Relay can inspect windows and act when asked, and connect local folders for search."
            )

            VStack(alignment: .leading, spacing: 18) {
                // Row 1: Accessibility
                HStack(spacing: 14) {
                    Image(systemName: coordinator.accessibilityGranted ? "checkmark.shield.fill" : "lock.shield")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(coordinator.accessibilityGranted ? RelayColors.accentEmerald : RelayColors.textSecondary)
                        .frame(width: 34, height: 34)
                        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Mac Accessibility")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                        Text(coordinator.accessibilityGranted ? "Permission granted for window inspection and input." : "Required to read UI elements and click or type.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(RelayColors.textSecondary)
                    }
                    Spacer()
                    if coordinator.accessibilityGranted {
                        Text("Allowed")
                            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(RelayColors.accentEmerald)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(RelayColors.accentEmerald.opacity(0.12), in: Capsule())
                    } else {
                        Button("Grant Access") {
                            coordinator.requestAccessibility()
                        }
                        .buttonStyle(RelayPrimaryButtonStyle())
                    }
                }

                Divider().overlay(Color.white.opacity(0.07))

                // Row 2: Self-Test Fixture
                HStack(spacing: 14) {
                    Image(systemName: "checkmark.rectangle.stack")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(RelayColors.textSecondary)
                        .frame(width: 34, height: 34)
                        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Control Self-Test")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                        Text(store.accessibilityCheckRunning ? "Verifying in isolated window…" : "Optional check in a harmless test window.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(RelayColors.textSecondary)
                    }
                    Spacer()
                    Button(store.accessibilityCheckRunning ? "Running…" : "Verify") {
                        Task { await store.runAccessibilityCheck() }
                    }
                    .buttonStyle(RelaySecondaryButtonStyle())
                    .disabled(!coordinator.accessibilityGranted || store.accessibilityCheckRunning)
                }

                Divider().overlay(Color.white.opacity(0.07))

                // Row 3: Scoped Local Folders
                HStack(spacing: 14) {
                    Image(systemName: "folder")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(RelayColors.textSecondary)
                        .frame(width: 34, height: 34)
                        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Approved Folders")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                        Text(store.grants.isEmpty ? "No folders added yet." : "\(store.grants.count) folder(s) connected for local search.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(RelayColors.textSecondary)
                    }
                    Spacer()
                    Button("Add Folder…") {
                        store.chooseFolder()
                    }
                    .buttonStyle(RelaySecondaryButtonStyle())
                }
            }
            .padding(22)
            .background(RelayColors.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )

            primaryContinueButton(title: "Continue", enabled: !store.accessibilityCheckRunning) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    coordinator.step = 4
                }
            }
        }
    }

    // MARK: - Page 4: Launchpad

    private var readyStep: some View {
        VStack(spacing: 28) {
            pageHeader(
                icon: "sparkles",
                title: "Ready to start",
                subtitle: "Choose a first prompt to pre-fill in your workspace, or open Relay with a blank conversation."
            )

            VStack(spacing: 10) {
                taskChoiceRow(
                    title: "Open Calculator",
                    detail: "Launch the macOS Calculator app and verify its window is active.",
                    icon: "plus.forwardslash.minus"
                )
                taskChoiceRow(
                    title: "What can you help me do?",
                    detail: "See how Relay works with your local files and Mac apps.",
                    icon: "bubble.left.and.bubble.right"
                )
                taskChoiceRow(
                    title: "Start with an empty workspace",
                    detail: "Open Relay without pre-filling a prompt.",
                    icon: "square.dashed"
                )
            }
            .padding(18)
            .background(RelayColors.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )

            primaryContinueButton(title: "Open Relay") {
                if chosenTask != "Start with an empty workspace" &&
                    store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    store.draft = chosenTask
                }
                coordinator.finish()
            }
        }
    }

    private func taskChoiceRow(title: String, detail: String, icon: String) -> some View {
        let selected = chosenTask == title
        return Button {
            chosenTask = title
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(selected ? RelayColors.accentEmerald : RelayColors.textSecondary)
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

                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(selected ? RelayColors.accentEmerald : Color.white.opacity(0.22))
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? Color.white.opacity(0.05) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? RelayColors.accentEmerald.opacity(0.45) : Color.white.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
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
