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
        case model = "Model", access = "Access", knowledge = "Knowledge", memory = "Memory", voice = "Voice"
        var icon: String {
            switch self {
            case .model: "cpu"
            case .access: "lock.shield"
            case .knowledge: "books.vertical"
            case .memory: "square.stack.3d.up"
            case .voice: "speaker.wave.2"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            navigation
            Rectangle().fill(RelayTheme.line).frame(width: 1)
            VStack(spacing: 0) {
                HStack {
                    Text(tab.rawValue).font(.system(size: 18, weight: .semibold))
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .medium))
                            .frame(width: 28, height: 28)
                            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(RelayPressStyle())
                    .accessibilityLabel("Close settings")
                    .keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, 28).padding(.vertical, 16)
                Rectangle().fill(RelayTheme.line).frame(height: 1)

                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        switch tab {
                        case .model: modelSettings
                        case .access: accessSettings
                        case .knowledge: KnowledgeView(store: store, isSettingsPane: true)
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
        .frame(width: 860, height: 720)
        .background(RelayTheme.background)
        .foregroundStyle(RelayTheme.ink)
        .font(.system(size: 14))
        .tint(RelayTheme.accent)
        .onAppear {
            if let requested = SettingsTab(rawValue: initialSection) { tab = requested }
        }
        .task {
            agentDesktopStatus = await AgentDesktopBridge.queryStatus()
        }
    }

    // MARK: - Navigation Sidebar
    private var navigation: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                RelayMark(size: 26)
                Text("Settings").font(.system(size: 18, weight: .semibold))
            }
            .padding(.horizontal, 12).padding(.top, 8)

            VStack(spacing: 4) {
                ForEach(SettingsTab.allCases, id: \.self) { item in
                    Button { tab = item } label: {
                        HStack(spacing: 12) {
                            Image(systemName: item.icon)
                                .font(.system(size: 15, weight: .medium)).frame(width: 20)
                            Text(item.rawValue).font(.system(size: 14, weight: tab == item ? .semibold : .regular))
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(tab == item ? RelayTheme.ink : RelayTheme.muted)
                        .padding(.horizontal, 12).frame(height: 38)
                        .background(tab == item ? Color.white.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(tab == item ? Color.white.opacity(0.12) : Color.clear, lineWidth: 1))
                    }
                    .buttonStyle(RelayPressStyle())
                    .accessibilityAddTraits(tab == item ? .isSelected : [])
                }
            }

            Spacer(minLength: 20)

            // Setup Assistant Re-entry Button
            if let onOpenSetup {
                Button { dismiss(); onOpenSetup() } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "sparkles")
                            .foregroundStyle(RelayColors.accentGold)
                            .frame(width: 20)
                        Text("Setup Assistant").font(.system(size: 13, weight: .medium))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(RelayTheme.line, lineWidth: 1))
                }
                .buttonStyle(RelayPressStyle())
                .accessibilityLabel("Run setup assistant")
            }

            HStack(spacing: 7) {
                Circle().fill(RelayColors.accentEmerald).frame(width: 6, height: 6)
                Text("100% Offline · Runs on your Mac").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(RelayTheme.muted)
            }
            .padding(.horizontal, 12).padding(.bottom, 8)
        }
        .padding(12)
        .frame(width: 196)
        .frame(maxHeight: .infinity)
        .background(RelayTheme.sidebar)
    }

    // MARK: - Model Settings
    private var modelSettings: some View {
        VStack(alignment: .leading, spacing: 22) {
            sectionTitle("Your local intelligence", detail: "Gemma runs on this Mac through LiteRT-LM. No hosted model account is needed.")

            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "cpu").font(.system(size: 26)).foregroundStyle(RelayColors.accentEmerald)
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

                HStack {
                    Text("Compute Backend")
                        .font(.system(size: 14, weight: .medium))
                    Spacer()
                    Picker("Compute", selection: $store.configuration.computeBackend) {
                        Text("CPU").tag("cpu")
                        Text("GPU").tag("gpu")
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 200)
                    .disabled(store.isPreparingModel)
                    .onChange(of: store.configuration.computeBackend) { _, _ in store.saveConfiguration() }
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
            .relayGlassCard(cornerRadius: RelayTheme.radius)

            note("Inference runs on this Mac. Model downloads and user-requested browser tasks may use the internet.", icon: "desktopcomputer")

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

            VStack(alignment: .leading, spacing: 10) {
                Toggle("Global Stop Shortcut · ⌘⇧Esc", isOn: Binding(get: { store.globalStop.enabled }, set: { store.setGlobalStopEnabled($0) }))
                    .font(.system(size: 14))
                Text("Stops new actions and cancels pending work. A dispatched action may finish. Check Activity before retrying. No keyboard recording.")
                    .font(.relayCaption).foregroundStyle(RelayTheme.muted).lineSpacing(3)
                Text(store.globalStop.status).font(.relayMono).foregroundStyle(RelayTheme.muted)
                if let error = store.globalStop.errorMessage { Text(error).font(.system(size: 13)).foregroundStyle(RelayColors.accentCoral) }
            }
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
                            Image(systemName: "folder").foregroundStyle(RelayColors.accentBlue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(URL(fileURLWithPath: grant.path).lastPathComponent).font(.system(size: 14, weight: .medium))
                                Text(grant.path).font(.system(size: 12)).foregroundStyle(RelayTheme.muted).lineLimit(2).textSelection(.enabled)
                            }
                            Spacer()
                            Toggle("Write", isOn: $grant.writable).toggleStyle(.checkbox).font(.system(size: 13))
                                .onChange(of: grant.writable) { _, _ in store.saveConfiguration() }
                            Button { store.removeGrant(grant.id) } label: { Image(systemName: "xmark").font(.system(size: 12)) }
                                .buttonStyle(.plain).accessibilityLabel("Remove \(grant.path)")
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
            }
            .padding(20)
            .relayGlassCard(cornerRadius: RelayTheme.radius)

            note("Passwords and private credentials remain strictly protected. External content cannot widen task scope.", icon: "hand.raised")
        }
    }

    private var quickAccessSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Global Keyboard Shortcuts").font(.system(size: 16, weight: .semibold))

            Toggle("Quick access · ⌘⇧Space", isOn: Binding(get: { store.quickAccess.enabled }, set: { store.setQuickAccessEnabled($0) }))
                .font(.system(size: 14))
            Text("Brings Relay forward instantly from any application.")
                .font(.relayCaption).foregroundStyle(RelayTheme.muted).lineSpacing(3)

            Toggle("Include selected text in reply draft", isOn: $store.selectionCaptureEnabled)
                .font(.system(size: 14)).disabled(!store.quickAccess.enabled)
            Text("When triggered, copies selected text into a draft with the source app name. Password fields are automatically excluded.")
                .font(.relayCaption).foregroundStyle(RelayTheme.muted).lineSpacing(3)

            Text(store.quickAccess.status).font(.relayMono).foregroundStyle(RelayTheme.muted)
            if let error = store.quickAccess.errorMessage { Text(error).font(.system(size: 13)).foregroundStyle(.white) }
            if store.selectionCaptureEnabled { Text(store.selectionStatus).font(.system(size: 13)).foregroundStyle(RelayTheme.muted) }
        }
        .padding(20)
        .relayGlassCard(cornerRadius: RelayTheme.radius)
    }

    // MARK: - Memory Settings
    private var memorySettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionTitle("Local Memory & Profile", detail: "Approve personalized preferences for future conversations. Task data is never automatically committed.")

            if store.memories.isEmpty {
                note("No memories saved yet. Start fresh or add preferences below.", icon: "square.stack.3d.up")
            }

            ForEach($store.memories) { $memory in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(RelayColors.accentEmerald)
                    TextField("Approved memory", text: $memory.text, axis: .vertical)
                        .font(.system(size: 14)).textFieldStyle(.plain)
                        .onChange(of: memory.text) { _, _ in store.approvedMemoryEdited() }
                    Spacer()
                    Button { store.deleteMemory(memory.id) } label: { Image(systemName: "trash").font(.system(size: 13)) }
                        .buttonStyle(.plain).foregroundStyle(RelayTheme.muted)
                        .accessibilityLabel("Delete memory: \(memory.text)")
                }
                .padding(14)
                .relayGlassCard(cornerRadius: 10)
            }

            VStack(alignment: .leading, spacing: 10) {
                TextField("e.g. Always format terminal commands in code blocks", text: $memoryText, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
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

            WritingProfileView(profile: store.writingProfile)

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
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 20, weight: .medium))
            Text(detail).font(.relayBody).foregroundStyle(RelayTheme.muted).lineSpacing(4)
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
