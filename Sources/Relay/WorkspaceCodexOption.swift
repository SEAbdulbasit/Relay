import SwiftUI

struct WorkspaceCodexOption: View {
    let store: AssistantStore
    @AppStorage(CodexCLIClient.reasoningEffortDefaultsKey) private var reasoningRaw = CodexReasoningEffort.low.rawValue
    @AppStorage(CodexCLIClient.modelIDDefaultsKey) private var modelID = CodexCLIClient.defaultPlanningModel
    @AppStorage(CodexCLIClient.allowUnverifiedStandaloneDefaultsKey) private var allowStandalone = false

    private var reasoningBinding: Binding<CodexReasoningEffort> {
        Binding(
            get: { CodexReasoningEffort(rawValue: reasoningRaw) ?? .low },
            set: { reasoningRaw = $0.rawValue }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "cloud")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(RelayColors.accentBlue)
                    .frame(width: 30, height: 30)
                    .background(RelayColors.accentBlue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)
                Text("ChatGPT via Codex CLI")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                if store.workspaceUsesCodex || store.workspaceUsesCodexCLI {
                    Label("Active this session", systemImage: "checkmark.circle.fill")
                        .font(.relayCaption)
                        .foregroundStyle(RelayColors.accentEmerald)
                }
            }

            Text("Use your existing ChatGPT sign-in for multi-turn workspace requests, visual attachments, and Mac app actions. No Relay account or local model download is required.")
                .font(.system(size: 13))
                .foregroundStyle(RelayTheme.ink)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Text("Model")
                        .font(.relayCaption)
                        .foregroundStyle(RelayColors.textSecondary)
                        .frame(width: 72, alignment: .leading)
                    Picker("Model", selection: $modelID) {
                        ForEach(CodexCLIClient.supportedModels, id: \.self) { slug in
                            Text(slug).tag(slug)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

                HStack(spacing: 12) {
                    Text("Reasoning")
                        .font(.relayCaption)
                        .foregroundStyle(RelayColors.textSecondary)
                        .frame(width: 72, alignment: .leading)
                    Picker("Reasoning effort", selection: reasoningBinding) {
                        ForEach(CodexReasoningEffort.allCases, id: \.self) { tier in
                            Text(tier.title).tag(tier)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }

                Toggle(
                    "Allow standalone Codex CLI (Homebrew / npm / ~/.local/bin)",
                    isOn: $allowStandalone
                )
                .font(.relayCaption)
                .foregroundStyle(RelayColors.textSecondary)
            }
            .disabled(store.isRunning || store.voice.isBusy || store.checkingCodex)

            Text("OpenAI receives selected prompts, admitted source excerpts, and checked images through your local Codex CLI session. Relay executes Mac and browser actions locally and still requires approval before sending mail, committing calendar writes, moving files, or overwriting content.")
                .font(.relayCaption)
                .foregroundStyle(RelayColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                if store.workspaceUsesCodex || store.workspaceUsesCodexCLI {
                    Button("Use selected model provider") { store.selectWorkspaceLocal() }
                        .buttonStyle(RelaySecondaryButtonStyle())
                } else {
                    Button(store.checkingCodex ? "Checking Sign-in…" : "Use ChatGPT") {
                        Task { await store.selectWorkspaceCodexCLI() }
                    }
                    .buttonStyle(RelayPrimaryButtonStyle())
                    if store.checkingCodex { ProgressView().controlSize(.small) }
                }
            }
            .disabled(store.isRunning || store.voice.isBusy || store.checkingCodex)

            if let status = store.codexStatus, !store.workspaceUsesCodex, !store.workspaceUsesCodexCLI {
                Text(status)
                    .font(.relayCaption)
                    .foregroundStyle(RelayColors.textSecondary)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .relayLitCard(accent: RelayColors.accentBlue, cornerRadius: RelayTheme.radius)
    }
}

struct CodexProviderSettingsView: View {
    let store: AssistantStore
    @State private var checkingLogin = false
    @State private var readiness: CodexCLIReadiness?

    private var effective: CodexCLIConfiguration {
        store.configuration.effectiveCodexCLI
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { effective.modelID },
            set: { slug in
                CodexCLIClient.preferredModelID = slug
                updateConfiguration(
                    modelID: slug,
                    reasoningEffort: effective.reasoningEffort,
                    allowUnverifiedStandalone: effective.allowUnverifiedStandalone
                )
            }
        )
    }

    private var reasoningBinding: Binding<CodexReasoningEffort> {
        Binding(
            get: { effective.reasoningEffort },
            set: { effort in
                CodexCLIClient.preferredReasoningEffort = effort
                updateConfiguration(
                    modelID: effective.modelID,
                    reasoningEffort: effort,
                    allowUnverifiedStandalone: effective.allowUnverifiedStandalone
                )
            }
        )
    }

    private var allowStandaloneBinding: Binding<Bool> {
        Binding(
            get: { effective.allowUnverifiedStandalone },
            set: { allow in
                CodexCLIClient.allowUnverifiedStandalone = allow
                updateConfiguration(
                    modelID: effective.modelID,
                    reasoningEffort: effective.reasoningEffort,
                    allowUnverifiedStandalone: allow
                )
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                RelayIconBadge(icon: "terminal.fill", color: RelayColors.accentBlue, size: 38, iconSize: 17)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("ChatGPT via Codex CLI")
                            .font(.relayHeadline)
                            .foregroundStyle(RelayColors.textPrimary)
                        RelayBadge("CLI Session", tint: RelayColors.accentBlue, prominent: true)
                    }
                    Text("Use your existing ChatGPT login via Codex CLI across chat, Mac actions, Knowledge consolidation, Magic Reply, and Proactive briefs. No Relay account or separate API key is required.")
                        .font(.relayCaption)
                        .foregroundStyle(RelayColors.textSecondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if readiness?.isReady == true {
                    RelayBadge("Signed in", icon: "checkmark.circle.fill", tint: RelayColors.accentEmerald, prominent: true)
                }
            }

            Group {
                HStack(spacing: 10) {
                    Button(checkingLogin ? "Checking sign-in…" : "Check sign-in") {
                        Task { await refreshReadiness() }
                    }
                    .buttonStyle(RelaySecondaryButtonStyle())
                    .disabled(checkingLogin || store.isPreparingModel)

                    if checkingLogin {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                }

                if let readiness {
                    Label(
                        readiness.message,
                        systemImage: readiness.isReady ? "checkmark.shield.fill" : "exclamationmark.triangle"
                    )
                    .font(.relayCaptionStrong)
                    .foregroundStyle(readiness.isReady ? RelayColors.accentEmerald : RelayColors.accentAmber)
                    .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        Text("Model")
                            .font(.relayCaptionStrong)
                            .foregroundStyle(RelayColors.textSecondary)
                            .frame(width: 90, alignment: .leading)
                        Picker("Codex model", selection: modelBinding) {
                            ForEach(CodexCLIClient.supportedModels, id: \.self) { slug in
                                Text(slug).tag(slug)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        Spacer()
                    }

                    HStack(spacing: 12) {
                        Text("Reasoning")
                            .font(.relayCaptionStrong)
                            .foregroundStyle(RelayColors.textSecondary)
                            .frame(width: 90, alignment: .leading)
                        Picker("Reasoning effort", selection: reasoningBinding) {
                            ForEach(CodexReasoningEffort.allCases, id: \.self) { tier in
                                Text(tier.title).tag(tier)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }

                    Divider().overlay(RelayTheme.line)

                    Toggle(
                        "Allow standalone Codex CLI (Homebrew / npm / ~/.local/bin)",
                        isOn: allowStandaloneBinding
                    )
                    .toggleStyle(.switch)
                    .font(.relayCaptionStrong)
                    .foregroundStyle(RelayColors.textPrimary)
                }
                .padding(14)
                .background(RelayColors.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(RelayColors.borderSubtle, lineWidth: 1)
                )
                .disabled(store.isPreparingModel)

                HStack(spacing: 10) {
                    Button(store.isPreparingModel ? "Checking…" : "Check model") {
                        Task {
                            await refreshReadiness()
                            await store.refreshModels()
                        }
                    }
                    .buttonStyle(RelayPrimaryButtonStyle())
                    .disabled(store.isPreparingModel || !store.configuration.hasConfiguredInferenceModel)

                    Button("Check images") {
                        Task { await store.checkLMStudioVision() }
                    }
                    .buttonStyle(RelaySecondaryButtonStyle())
                    .disabled(store.isPreparingModel || !store.configuration.hasConfiguredInferenceModel)

                    if store.isPreparingModel {
                        ProgressView().controlSize(.small)
                        Button("Stop checking") { store.stop() }
                            .buttonStyle(RelaySecondaryButtonStyle())
                    }
                    Spacer()
                }
            }
            .disabled(store.isRunning && !store.isPreparingModel)

            Text("Selected prompts, admitted source excerpts, and checked images are sent to OpenAI under your ChatGPT account’s privacy settings. Codex CLI runs inside Relay’s sandbox with native shell and browser tools disabled.")
                .font(.relayCaption)
                .foregroundStyle(RelayColors.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: store.actionsReady ? "checkmark.circle.fill" : "circle.dotted")
                    .foregroundStyle(store.actionsReady ? RelayColors.accentEmerald : RelayColors.textMuted)
                Text(store.modelStatus)
                    .font(.relayCaption)
                    .foregroundStyle(RelayColors.textSecondary)
                    .textSelection(.enabled)
            }

            if let error = store.errorMessage {
                Text(error)
                    .font(.relayCaption)
                    .foregroundStyle(RelayColors.accentCoral)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let status = store.localVisionStatus {
                Text(status)
                    .font(.relayCaption)
                    .foregroundStyle(RelayColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .relayLitCard(accent: RelayColors.accentBlue, cornerRadius: RelayTheme.radius)
        .onAppear {
            Task { await refreshReadiness() }
        }
    }

    private func updateConfiguration(
        modelID: String,
        reasoningEffort: CodexReasoningEffort,
        allowUnverifiedStandalone: Bool
    ) {
        guard !store.isPreparingModel else { return }
        do {
            let next = try CodexCLIConfiguration(
                modelID: modelID,
                reasoningEffort: reasoningEffort,
                allowUnverifiedStandalone: allowUnverifiedStandalone
            )
            store.configuration.codexCLI = next
            if store.configuration.backend != .codexCLI {
                store.configuration.backend = .codexCLI
            }
            store.errorMessage = nil
            store.saveConfiguration()
        } catch {
            store.errorMessage = (error as? CodexCLIError)?.localizedDescription ?? error.localizedDescription
        }
    }

    private func refreshReadiness() async {
        guard !checkingLogin else { return }
        checkingLogin = true
        defer { checkingLogin = false }
        readiness = await CodexCLIClient().readiness(configuration: effective)
    }
}
