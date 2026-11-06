import SwiftUI
import AppKit
import ApplicationServices

struct SettingsView: View {
    @Bindable var store: AssistantStore
    var onOpenSetup: (() -> Void)? = nil
    var initialSection = "Model"
    @Environment(\.dismiss) private var dismiss
    @State private var tab = SettingsTab.model
    @State private var memoryText = ""
    @State private var accessibilityGranted = AXIsProcessTrusted()
    @State private var accessibilityCheckRunning = false
    @State private var agentDesktopStatus: AgentDesktopStatus?
    @State private var isUpdatingAgentDesktop = false
    @State private var agentDesktopUpdateMessage: String?

    private enum SettingsTab: String, CaseIterable {
        case model = "Model", access = "Access", sources = "Sources", knowledge = "Knowledge", memory = "Memory", voice = "Voice"
        var icon: String {
            switch self {
            case .model: "cpu"
            case .access: "lock.shield"
            case .sources: "tray.full"
            case .knowledge: "books.vertical"
            case .memory: "square.stack.3d.up"
            case .voice: "speaker.wave.2"
            }
        }
        var accent: Color {
            switch self {
            case .model: RelayColors.accentEmerald
            case .access: RelayColors.accentBlue
            case .sources: RelayColors.accentEmerald
            case .knowledge: RelayColors.accentGold
            case .memory: RelayColors.accentAmethyst
            case .voice: RelayColors.accentCoral
            }
        }
    }

    var body: some View {
        ZStack {
            RelayTheme.background.ignoresSafeArea()
            RelayAtmosphere(focused: false)
                .opacity(0.45)
                .ignoresSafeArea()

            HStack(spacing: 0) {
                navigation
                Rectangle().fill(RelayTheme.line).frame(width: 1)
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        RelayIconBadge(icon: tab.icon, color: tab.accent, size: 28, iconSize: 13)
                        Text(tab.rawValue)
                            .font(.system(size: 16, weight: .semibold, design: .default))
                        Spacer()
                        RelayIconButton(
                            icon: "xmark",
                            label: "Close settings",
                            size: 32
                        ) {
                            dismiss()
                        }
                        .keyboardShortcut(.cancelAction)
                    }
                    .padding(.horizontal, 28)
                    .frame(height: 56)
                    Rectangle().fill(RelayTheme.line).frame(height: 1)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 26) {
                            switch tab {
                            case .model: modelSettings
                            case .access: accessSettings
                            case .sources:
                                sectionTitle("Personal sources", detail: "Choose the exact items Relay can read. Captured content stays on this Mac.")
                                NativeSourceConnectorsView(sources: store.nativeSources, busy: store.isRunning)
                                PrivateSourceQuestionView(store: store)
                                ChatArchiveView(store: store)
                                DirectMCPConnectorView(connector: store.directMCP, busy: store.isRunning && !store.directMCP.isBusy)
                                if let response = store.directMCP.output {
                                    ReviewedSourceQuestionView(store: store, source: response)
                                }
                            case .knowledge:
                                KnowledgeView(store: store, isSettingsPane: true)
                                LocalKnowledgeMCPSettingsView(server: store.knowledgeSharing)
                                PortableKnowledgeSharingView()
                            case .voice: SpeechOutputView(speech: store.speech, diagnostic: store.speechDiagnostic, taskBusy: store.isRunning || store.voice.isBusy || store.isClearingConversation || store.accessibilityCheckRunning)
                            case .memory:
                                memorySettings
                                Divider().overlay(RelayTheme.line)
                                ConversationExportView(store: store)
                                Divider().overlay(RelayTheme.line)
                                DiagnosticsView(store: store)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(28)
                    }
                    .id(tab)
                    .scrollIndicators(.visible)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 820, minHeight: 620)
        .foregroundStyle(RelayTheme.ink)
        .font(.system(size: 14))
        .tint(RelayTheme.accent)
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
        .disclosureGroupStyle(RelayDisclosureGroupStyle(accent: tab.accent))
        .onAppear {
            if let requested = SettingsTab(rawValue: initialSection) { tab = requested }
        }
        .task {
            agentDesktopStatus = await AgentDesktopBridge.queryStatus()
        }
    }

    // MARK: - Navigation Sidebar (Aligned 56pt Header Bar + Continuous Hairline)
    private var navigation: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                SpinningLogo(size: 20)
                Text("Settings")
                    .font(.system(size: 16, weight: .semibold, design: .default))
                Spacer()
            }
            .padding(.horizontal, 18)
            .frame(height: 56)

            Rectangle().fill(RelayTheme.line).frame(height: 1)

            VStack(alignment: .leading, spacing: 16) {
                VStack(spacing: 5) {
                    ForEach(SettingsTab.allCases, id: \.self) { item in
                        SettingsSidebarTabButton(
                            title: item.rawValue,
                            icon: item.icon,
                            accent: item.accent,
                            isSelected: tab == item
                        ) {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                tab = item
                            }
                        }
                    }
                }
                .padding(.top, 14)

                Spacer(minLength: 20)

                // Setup Assistant Re-entry Button
                if let onOpenSetup {
                    Button { dismiss(); onOpenSetup() } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "sparkles")
                                .foregroundStyle(RelayColors.accentGold)
                                .frame(width: 20)
                            Text("Setup Assistant")
                                .font(.system(size: 13, weight: .medium))
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(RelayColors.textMuted)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(RelayColors.accentGold.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(RelayColors.accentGold.opacity(0.24), lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(RelayPressStyle())
                    .accessibilityLabel("Run setup assistant")
                }

                HStack(spacing: 7) {
                    Circle()
                        .fill(RelayColors.accentEmerald)
                        .frame(width: 6, height: 6)
                        .shadow(color: RelayColors.accentEmerald.opacity(0.6), radius: 4)
                    Text(store.workspaceUsesCodex ? "Workspace uses ChatGPT" : "Local inference · Runs on your Mac")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(RelayTheme.muted)
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
            .padding(12)
        }
        .frame(width: 208)
        .frame(maxHeight: .infinity)
        .background(RelayTheme.sidebar.opacity(0.88))
    }

    // MARK: - Model Settings
    private var modelSettings: some View {
        VStack(alignment: .leading, spacing: 22) {
            sectionTitle("Workspace intelligence", detail: "Choose on-device Gemma or use your existing ChatGPT sign-in for workspace tasks.")

            WorkspaceCodexOption(store: store)

            sectionTitle("Your local intelligence", detail: "Gemma and Relay’s private sources work on this Mac without an account.")

            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    RelayIconBadge(icon: "cpu", color: RelayColors.accentEmerald, size: 38, iconSize: 17)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(store.configuration.modelPath.isEmpty ? "No model selected" : URL(fileURLWithPath: store.configuration.modelPath).lastPathComponent)
                            .font(.system(size: 16, weight: .semibold))
                            .lineLimit(2)
                        Text(store.configuration.modelPath.isEmpty ? "Select or download a .litertlm model package." : "Local Model Package · LiteRT-LM")
                            .font(.system(size: 13)).foregroundStyle(RelayTheme.muted)
                    }
                    Spacer()
                    Button("Choose model…") { store.chooseModel() }
                        .buttonStyle(RelaySecondaryButtonStyle())
                        .disabled(store.isPreparingModel)
                }

                Divider().overlay(RelayTheme.line)

                VStack(alignment: .leading, spacing: 10) {
                    Text("On-Device Model Catalog")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(ModelManifest.supportedArchitecturesNote)
                        .font(.relayCaption)
                        .foregroundStyle(RelayTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(ModelManifest.catalog, id: \.filename) { manifest in
                        let installedURL = ModelManifest.resolveInstalledURL(for: manifest)
                        let isSelected = installedURL?.path == store.configuration.modelPath
                        HStack(spacing: 12) {
                            RelayHealthDot(color: isSelected && store.actionsReady ? RelayColors.accentEmerald : (installedURL != nil ? RelayColors.accentGold : RelayColors.textMuted))
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 8) {
                                    Text(manifest.displayName)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(.white)
                                    Text(manifest == .gemma4E4B ? "3.66 GB · High accuracy" : "2.59 GB · Fast and compact")
                                        .font(.system(size: 11.5, weight: .medium))
                                        .foregroundStyle(RelayColors.textSecondary)
                                }
                                Text(manifest.filename)
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .foregroundStyle(RelayTheme.muted)
                            }
                            Spacer()
                            if isSelected && store.actionsReady {
                                Text("ACTIVE")
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(RelayColors.accentEmerald)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(RelayColors.accentEmerald.opacity(0.12), in: Capsule())
                            } else if installedURL != nil {
                                Button(isSelected ? "Load \(manifest.displayName)" : "Use \(manifest.displayName)") {
                                    Task { await store.selectCatalogModel(manifest) }
                                }
                                .buttonStyle(RelaySecondaryButtonStyle())
                                .disabled(store.isPreparingModel || store.isRunning)
                            } else {
                                Text("Not downloaded")
                                    .font(.relayCaption)
                                    .foregroundStyle(RelayTheme.muted)
                            }
                        }
                        .padding(12)
                        .background(Color.white.opacity(isSelected ? 0.055 : 0.025), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(isSelected ? RelayColors.accentEmerald.opacity(0.35) : Color.white.opacity(0.08), lineWidth: 1))
                    }
                }

                Divider().overlay(RelayTheme.line)

                HStack {
                    Text("Compute Backend")
                        .font(.system(size: 14, weight: .medium))
                    Spacer()
                    HStack(spacing: 3) {
                        ForEach([("cpu", "CPU"), ("gpu", "GPU")], id: \.0) { tag, label in
                            let selected = store.configuration.computeBackend == tag
                            Button {
                                store.configuration.computeBackend = tag
                                store.saveConfiguration()
                            } label: {
                                Text(label)
                                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                                    .foregroundStyle(selected ? .white : RelayColors.textSecondary)
                                    .frame(width: 68, height: 26)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .fill(selected ? RelayColors.accentEmerald.opacity(0.22) : Color.clear)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .strokeBorder(selected ? RelayColors.accentEmerald.opacity(0.45) : Color.clear, lineWidth: 1)
                                    )
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(RelayPressStyle())
                            .disabled(store.isPreparingModel)
                        }
                    }
                    .padding(3)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
                }

                Text("Apple Silicon CPU is recommended for optimal stability across turn-based agent execution.")
                    .font(.relayCaption).foregroundStyle(RelayTheme.muted)

                HStack(spacing: 12) {
                    Button(store.isPreparingModel ? "Preparing…" : store.actionsReady ? "Reload model" : "Load model") { saveAndRefresh() }
                        .buttonStyle(RelayPrimaryButtonStyle())
                        .disabled(store.configuration.modelPath.isEmpty || store.isRunning)

                    Button("Unload") { store.unloadModel() }
                        .buttonStyle(RelaySecondaryButtonStyle())
                        .disabled(store.isRunning)

                    if store.isPreparingModel {
                        ProgressView().controlSize(.small)
                        Button("Stop preparation") { store.stop() }.buttonStyle(RelaySecondaryButtonStyle())
                    }
                    Spacer()
                }

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: store.actionsReady ? "checkmark.circle.fill" : "circle.dotted")
                        .foregroundStyle(store.actionsReady ? RelayColors.accentEmerald : RelayTheme.muted)
                    Text(store.modelStatus).font(.system(size: 13)).foregroundStyle(RelayTheme.muted).textSelection(.enabled)
                }

                if let error = store.errorMessage {
                    Text(error).font(.system(size: 13)).foregroundStyle(RelayColors.accentCoral)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
            .relayLitCard(accent: RelayColors.accentEmerald, cornerRadius: RelayTheme.radius)

            note("Gemma runs on this Mac. Model downloads, ChatGPT, and user-requested browser tasks use the internet.", icon: "desktopcomputer")

            DisclosureGroup("Computer-use engine · advanced") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "macwindow.on.rectangle")
                        .font(.system(size: 24))
                        .foregroundStyle(RelayColors.accentBlue)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text("Agent-Desktop Computer Use Engine")
                                .font(.system(size: 16, weight: .semibold))
                            if let status = agentDesktopStatus, status.available {
                                Text("v\(status.version)")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundStyle(RelayColors.accentEmerald)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(RelayColors.accentEmerald.opacity(0.14), in: Capsule())
                            }
                        }
                        Text("Bundled vercel-labs/agent-desktop CLI + C FFI (libagent_desktop_ffi.dylib) for skeleton snapshots, @ref targeting, and headless AX actions.")
                            .font(.system(size: 13))
                            .foregroundStyle(RelayTheme.muted)
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
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(status.ffiLoaded ? RelayColors.accentEmerald : RelayColors.accentGold)

                        Label(
                            status.accessibilityGranted ? "AX Tree Ready" : "AX Permission Needed",
                            systemImage: status.accessibilityGranted ? "hand.tap.fill" : "lock.fill"
                        )
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(status.accessibilityGranted ? RelayColors.accentEmerald : RelayTheme.muted)

                        Spacer()
                        Text(status.target)
                            .font(.relayMono)
                            .foregroundStyle(RelayTheme.muted)
                    }
                }

                if let updateMsg = agentDesktopUpdateMessage {
                    Text(updateMsg)
                        .font(.relayMono)
                        .foregroundStyle(RelayTheme.muted)
                        .lineLimit(2)
                }
            }
            .padding(20)
            .relayGlassCard(cornerRadius: RelayTheme.radius)

            }.font(.system(size: 14, weight: .medium))

            DisclosureGroup("Model details & verification logs") {
                VStack(alignment: .leading, spacing: 10) {
                    if !store.configuration.modelPath.isEmpty {
                        Text(store.configuration.modelPath).font(.relayMono).textSelection(.enabled)
                    }
                    Text("Loading checks the engine and runs a structured probe call verifying tool call generation. Mac control permissions are validated independently through macOS Accessibility.")
                    Text("Recommended model: Gemma 4 E2B (2.59 GB). Re-run the Setup assistant to download or verify this model.")
                }
                .font(.system(size: 13)).foregroundStyle(RelayTheme.muted)
                .lineSpacing(3).padding(.top, 10)
            }
            .font(.system(size: 14, weight: .medium))
        }
    }

    // MARK: - Access Settings
    private var accessSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            sectionTitle("Access & Permissions", detail: "Choose app controls and file access for your tasks.")


            quickAccessSettings
            focusedDraftSettings

            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: Binding(get: { store.globalStop.enabled }, set: { store.setGlobalStopEnabled($0) })) {
                    Text("Global Stop Shortcut · ⌘⇧Esc")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(.switch)

                Text("Stops new actions and cancels pending work. A dispatched action may finish. Check Activity before retrying. No keyboard recording.")
                    .font(.relayCaption).foregroundStyle(RelayTheme.muted).lineSpacing(3)
                Text(store.globalStop.status).font(.relayMono).foregroundStyle(RelayTheme.muted)
                if let error = store.globalStop.errorMessage { Text(error).font(.system(size: 13)).foregroundStyle(RelayColors.accentCoral) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .relayGlassCard(cornerRadius: RelayTheme.radius)

            VStack(alignment: .leading, spacing: 8) {
                Text("Authorized Files & Folders").font(.system(size: 18, weight: .semibold))
                Text("Grant write access only where necessary for your tasks.").font(.system(size: 14)).foregroundStyle(RelayTheme.muted)
            }

            HStack {
                Button("Add files…", systemImage: "doc.badge.plus") { store.chooseFiles() }
                Button("Add folder…", systemImage: "folder.badge.plus") { store.chooseFolder() }
            }
            .buttonStyle(RelaySecondaryButtonStyle()).controlSize(.regular)

            if store.grants.isEmpty {
                note("No files or folders selected. Add them above or use the attachment control in chat.", icon: "folder")
            } else {
                VStack(spacing: 0) {
                    ForEach($store.grants) { $grant in
                        HStack(alignment: .center, spacing: 12) {
                            RelayIconBadge(icon: "folder.fill", color: RelayColors.accentBlue, size: 32, iconSize: 14)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(URL(fileURLWithPath: grant.path).lastPathComponent).font(.system(size: 14, weight: .medium))
                                Text(grant.path).font(.system(size: 12)).foregroundStyle(RelayTheme.muted).lineLimit(2).textSelection(.enabled)
                            }
                            Spacer()
                            Toggle("Write", isOn: $grant.writable).toggleStyle(.checkbox).font(.system(size: 13))
                                .onChange(of: grant.writable) { _, _ in store.saveConfiguration() }
                            RelayIconButton(
                                icon: "xmark",
                                label: "Remove \(grant.path)",
                                size: 32
                            ) {
                                store.removeGrant(grant.id)
                            }
                        }
                        .padding(.vertical, 10)
                        Divider().overlay(RelayTheme.line)
                    }
                }
            }

            // Accessibility Permission
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Mac Accessibility Controls", systemImage: "cursorarrow.motionlines")
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text(accessibilityGranted ? "Accessibility allowed" : "Permission needed")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(accessibilityGranted ? RelayColors.accentEmerald : RelayColors.accentAmber)
                }

                Text("Accessibility permits Relay to inspect UI hierarchies, enter text into authorized apps, and click buttons. Passwords and credentials remain strictly untouched.")
                    .font(.relayCaption).foregroundStyle(RelayTheme.muted).lineSpacing(3)

                HStack {
                    Button("Request Accessibility") { requestAccessibility() }
                    Button("Open System Settings") { openAccessibilitySettings() }
                    Button("Check again") { accessibilityGranted = AXIsProcessTrusted() }
                }
                .buttonStyle(RelaySecondaryButtonStyle()).controlSize(.regular)
                .onAppear { accessibilityGranted = AXIsProcessTrusted() }

                Divider().overlay(RelayTheme.line).padding(.vertical, 4)

                Text("Harmless Control Check").font(.system(size: 14, weight: .medium))
                Text("Launches an isolated test window to verify text entry and button actuation with synthetic events.")
                    .font(.relayCaption).foregroundStyle(RelayTheme.muted).lineSpacing(3)

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
                    .buttonStyle(RelaySecondaryButtonStyle()).controlSize(.regular)
                    .disabled(!accessibilityGranted || store.isRunning || accessibilityCheckRunning)

                    if accessibilityCheckRunning { ProgressView().controlSize(.regular) }
                }

                Text(store.accessibilityCheckStatus)
                    .font(.system(size: 13)).foregroundStyle(RelayTheme.muted)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Accessibility check status: \(store.accessibilityCheckStatus)")

                Divider().overlay(RelayTheme.line).padding(.vertical, 4)

                Text("Screen capture check").font(.system(size: 14, weight: .medium))
                Text("Reads a marker from the bundled test window. The screenshot stays in memory and is discarded.")
                    .font(.relayCaption).foregroundStyle(RelayTheme.muted).lineSpacing(3)
                Button("Run screen capture check", systemImage: "macwindow") {
                    Task { await store.runScreenCaptureCheck() }
                }
                .buttonStyle(RelaySecondaryButtonStyle())
                .disabled(store.isRunning || store.voice.isBusy)
                .accessibilityIdentifier("settings.screenCaptureCheck")
                Text(store.screenCaptureCheckStatus.summary)
                    .font(.system(size: 13)).foregroundStyle(RelayTheme.muted)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.screenCaptureStatus")
            }
            .padding(20)
            .relayGlassCard(cornerRadius: RelayTheme.radius)

            note("Passwords and private credentials remain strictly protected. External content cannot widen task scope.", icon: "hand.raised")
        }
    }

    private var focusedDraftSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(get: { store.focusedDraft.sidekickEnabled }, set: { store.setRightCommandSidekickEnabled($0) })) {
                Text("Sidekick · Right Command once")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
            .accessibilityIdentifier("settings.rightCommandSidekick")
            Text(store.focusedDraft.sidekickStatus).font(.relayMono).foregroundStyle(RelayTheme.muted)
            Divider()
            Toggle(isOn: Binding(get: { store.focusedDraft.enabled }, set: { store.setFocusedDraftEnabled($0) })) {
                Text("Double Tap · Right Command twice")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
            .accessibilityIdentifier("settings.focusedDraft")

            Text("Put the caret at the end of a supported multiline reply field, then tap Right Command twice. Relay drafts locally from nearby visible text and the reply you started. It leaves the draft in place for you to review.")
                .font(.relayCaption).foregroundStyle(RelayTheme.muted).lineSpacing(3)
            Text("Requires Accessibility and a loaded model. Only modifier events are monitored. Turn off other apps’ Right Command drafting shortcuts before enabling.")
                .font(.relayCaption).foregroundStyle(RelayTheme.muted).lineSpacing(3)
            Text(store.focusedDraft.status).font(.relayMono).foregroundStyle(RelayTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings.focusedDraftStatus")
            if store.focusedDraft.isBusy {
                Button("Stop drafting") { store.stop() }.buttonStyle(RelaySecondaryButtonStyle())
            }
            Divider()
            DraftModelSettingsView(preferences: store.draftModel, busy: store.isRunning)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .relayLitCard(accent: RelayColors.accentBlue, cornerRadius: RelayTheme.radius)
    }

    private var quickAccessSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Global Keyboard Shortcuts").font(.system(size: 16, weight: .semibold))

            Toggle(isOn: Binding(get: { store.quickAccess.enabled }, set: { store.setQuickAccessEnabled($0) })) {
                Text("Quick access · ⌘⇧Space")
                    .font(.system(size: 14, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)

            Text("Brings Relay forward instantly from any application.")
                .font(.relayCaption).foregroundStyle(RelayTheme.muted).lineSpacing(3)

            Divider().overlay(RelayTheme.line).padding(.vertical, 2)

            Toggle(isOn: $store.selectionCaptureEnabled) {
                Text("Include selected text in reply draft")
                    .font(.system(size: 14, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
            .disabled(!store.quickAccess.enabled)

            Text("When triggered, copies selected text into a draft with the source app name. Password fields are automatically excluded.")
                .font(.relayCaption).foregroundStyle(RelayTheme.muted).lineSpacing(3)

            Text(store.quickAccess.status).font(.relayMono).foregroundStyle(RelayTheme.muted)
            if let error = store.quickAccess.errorMessage { Text(error).font(.system(size: 13)).foregroundStyle(.white) }
            if store.selectionCaptureEnabled { Text(store.selectionStatus).font(.system(size: 13)).foregroundStyle(RelayTheme.muted) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .relayLitCard(accent: RelayColors.accentBlue, cornerRadius: RelayTheme.radius)
    }

    // MARK: - Memory Settings
    private var memorySettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionTitle("Local Memory & Profile", detail: "Approve personalized preferences for future conversations. Task data is never automatically committed.")

            if store.memories.isEmpty {
                note("No memories saved yet. Start fresh or add preferences below.", icon: "square.stack.3d.up")
            }

            ForEach($store.memories) { $memory in
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(RelayColors.accentEmerald)
                    TextField("Approved memory", text: $memory.text, axis: .vertical)
                        .font(.system(size: 14)).textFieldStyle(.plain)
                        .onChange(of: memory.text) { _, _ in store.approvedMemoryEdited() }
                    Spacer()
                    RelayIconButton(
                        icon: "trash",
                        label: "Delete memory: \(memory.text)",
                        size: 32,
                        tint: RelayColors.textSecondary
                    ) {
                        store.deleteMemory(memory.id)
                    }
                }
                .padding(14)
                .relayGlassCard(cornerRadius: 10)
            }

            VStack(alignment: .leading, spacing: 10) {
                TextField(
                    "",
                    text: $memoryText,
                    prompt: Text("e.g. Always format terminal commands in code blocks").foregroundStyle(RelayColors.textDim),
                    axis: .vertical
                )
                    .lineLimit(2...4)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))

                HStack {
                    Text("Saved strictly on your Mac.").font(.relayCaption).foregroundStyle(RelayTheme.muted)
                    Spacer()
                    Button("Approve & remember") {
                        store.addMemory(memoryText.trimmingCharacters(in: .whitespacesAndNewlines))
                        memoryText = ""
                    }
                    .buttonStyle(RelayPrimaryButtonStyle())
                    .disabled(memoryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            WritingProfileView(profile: store.writingProfile, canLearn: store.actionsReady && !store.isRunning) { samples in
                let reply = try await store.auxiliaryText(WritingStyleSuggestion.prompt(samples: samples))
                return try WritingStyleSuggestion.parse(reply.content)
            }

            Divider().overlay(RelayTheme.line)

            VStack(alignment: .leading, spacing: 10) {
                Text("Conversation History").font(.system(size: 15, weight: .semibold))
                Text("Clear active conversation history. This does not undo any created files or external changes.")
                    .font(.relayCaption).foregroundStyle(RelayTheme.muted)
                Button("Clear conversation") { store.clearConversation() }
                    .buttonStyle(RelaySecondaryButtonStyle())
                    .disabled(store.isRunning || store.pendingReview != nil)
            }
        }
    }

    // MARK: - Helpers
    private func sectionTitle(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            OnboardingWhisper(tab.rawValue + " CONFIGURATION")
            Text(title)
                .display(26)
                .foregroundStyle(.white)
            Text(detail)
                .font(.system(size: 14, weight: .regular, design: .default))
                .foregroundStyle(RelayColors.textSecondary)
                .lineSpacing(3)
        }
    }

    private func note(_ text: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(RelayTheme.ink)
            Text(text).font(.system(size: 14)).foregroundStyle(RelayTheme.muted).lineSpacing(3)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .relayGlassCard(cornerRadius: 10)
    }

    private func saveAndRefresh() {
        store.saveConfiguration()
        Task { await store.refreshModels() }
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

private struct SettingsSidebarTabButton: View {
    let title: String
    let icon: String
    let accent: Color
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isSelected ? accent : (isHovered ? .white : RelayTheme.muted))
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 14.5, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? .white : .white.opacity(isHovered ? 0.92 : 0.76))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Capsule()
                    .fill(Color.white.opacity(isSelected ? 0.10 : (isHovered ? 0.045 : 0)))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(RelayPressStyle())
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
