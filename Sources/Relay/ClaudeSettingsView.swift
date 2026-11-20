import SwiftUI

struct ClaudeSettingsView: View {
    let store: AssistantStore
    @State private var customModelDraft = ""
    @State private var checkingLogin = false
    @State private var readiness: ClaudeCLIReadiness?
    @State private var cliVersion: String?
    @State private var loginProcess: Process?
    @State private var tokenRejected = ClaudeCLIClient.sharedAuthTokenRejected

    private var needsSignIn: Bool {
        tokenRejected || readiness == .signedOut
    }

    private var effective: ClaudeCLIConfiguration {
        store.configuration.effectiveClaudeCLI
    }

    private var modelBinding: Binding<ClaudeCLIModel> {
        Binding(
            get: { effective.model },
            set: { nextModel in
                updateConfiguration(
                    model: nextModel,
                    customModelID: effective.customModelID,
                    reasoningEffort: effective.reasoningEffort,
                    allowUnverifiedBinary: effective.allowUnverifiedBinary
                )
            }
        )
    }

    private var reasoningBinding: Binding<ClaudeReasoningEffort> {
        Binding(
            get: { effective.reasoningEffort },
            set: { nextEffort in
                updateConfiguration(
                    model: effective.model,
                    customModelID: effective.customModelID,
                    reasoningEffort: nextEffort,
                    allowUnverifiedBinary: effective.allowUnverifiedBinary
                )
            }
        )
    }

    private var allowUnverifiedBinding: Binding<Bool> {
        Binding(
            get: { effective.allowUnverifiedBinary },
            set: { allow in
                updateConfiguration(
                    model: effective.model,
                    customModelID: effective.customModelID,
                    reasoningEffort: effective.reasoningEffort,
                    allowUnverifiedBinary: allow
                )
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                RelayIconBadge(icon: "sparkles", color: RelayColors.accentEmerald, size: 38, iconSize: 17)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("Claude via Claude Code CLI")
                            .font(.relayHeadline)
                            .foregroundStyle(RelayColors.textPrimary)
                        if let cliVersion {
                            RelayBadge("v\(cliVersion)", tint: RelayColors.textSecondary)
                        }
                    }
                    Text("Reuse your existing Claude subscription login (`claude -p`) for chat, Mac actions, Knowledge consolidation, Magic Reply, and Proactive briefs. No Relay account or separate API key is required.")
                        .font(.relayCaption)
                        .foregroundStyle(RelayColors.textSecondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if case .ready(let plan) = readiness, !tokenRejected {
                    let badgeText = plan.map { "Signed in · \($0.capitalized)" } ?? "Signed in"
                    RelayBadge(badgeText, icon: "checkmark.circle.fill", tint: RelayColors.accentEmerald, prominent: true)
                } else if tokenRejected {
                    RelayBadge("Token expired", icon: "exclamationmark.triangle.fill", tint: RelayColors.accentAmber, prominent: true)
                } else if readiness == .signedOut {
                    RelayBadge("Signed out", icon: "person.crop.circle.badge.exclamationmark", tint: RelayColors.accentAmber, prominent: true)
                }
            }

            Group {
                if tokenRejected {
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: "key.slash.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(RelayColors.accentAmber)
                            .accessibilityHidden(true)
                        Text("Your Claude OAuth access token expired or was rejected. Use Sign In with Claude below to refresh your login in one click.")
                            .font(.relayCaption)
                            .foregroundStyle(RelayColors.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RelayColors.accentAmber.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(RelayColors.accentAmber.opacity(0.28), lineWidth: 1)
                    )
                }

                HStack(spacing: 10) {
                    if needsSignIn {
                        Button(loginProcess?.isRunning == true ? "Signing In…" : "Sign In with Claude") {
                            startInteractiveSignIn()
                        }
                        .buttonStyle(RelayPrimaryButtonStyle())
                        .disabled(checkingLogin || store.isPreparingModel || loginProcess?.isRunning == true)
                    }

                    Button(checkingLogin ? "Checking sign-in…" : "Check sign-in") {
                        Task { await refreshReadiness() }
                    }
                    .buttonStyle(RelaySecondaryButtonStyle())
                    .disabled(checkingLogin || store.isPreparingModel)

                    if !needsSignIn {
                        Button(loginProcess?.isRunning == true ? "Signing In…" : "Sign In with Claude") {
                            startInteractiveSignIn()
                        }
                        .buttonStyle(RelaySecondaryButtonStyle())
                        .disabled(checkingLogin || store.isPreparingModel || loginProcess?.isRunning == true)
                    }

                    if checkingLogin || loginProcess?.isRunning == true {
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
                        Picker("Claude model", selection: modelBinding) {
                            ForEach(ClaudeCLIModel.allCases, id: \.self) { option in
                                Text(option.title).tag(option)
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
                            ForEach(ClaudeReasoningEffort.allCases, id: \.self) { tier in
                                Text(tier.title).tag(tier)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }

                    Divider().overlay(RelayTheme.line)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Custom model override (optional)")
                            .font(.relayCaptionStrong)
                            .foregroundStyle(RelayColors.textSecondary)
                        HStack(spacing: 8) {
                            TextField("", text: $customModelDraft, prompt: Text(""))
                                .textFieldStyle(.plain)
                                .font(.relayMono)
                                .relayTextFieldPrompt("Leave empty for preset, or e.g. claude-sonnet-4-6", when: customModelDraft.isEmpty, font: .relayMono)
                                .relayTextField()
                                .onSubmit { applyCustomModel() }
                                .accessibilityIdentifier("settings.claudeCustomModelID")
                            Button("Apply") { applyCustomModel() }
                                .buttonStyle(RelaySecondaryButtonStyle())
                            if !effective.customModelID.isEmpty {
                                Button("Use preset") {
                                    customModelDraft = ""
                                    applyCustomModel()
                                }
                                .buttonStyle(RelaySecondaryButtonStyle())
                            }
                        }
                    }

                    Toggle(
                        "Allow standalone Claude CLI (Homebrew / npm / ~/.local/bin)",
                        isOn: allowUnverifiedBinding
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

            Text("Selected prompts, admitted source excerpts, and checked images are sent to Anthropic under your Claude account’s privacy terms and usage limits. Native Claude Code shell, file, and MCP tools stay disabled; Relay validates every structured action locally.")
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
        .relayLitCard(accent: RelayColors.accentEmerald, cornerRadius: RelayTheme.radius)
        .onAppear {
            customModelDraft = effective.customModelID
            tokenRejected = ClaudeCLIClient.sharedAuthTokenRejected
            Task { await refreshReadiness() }
        }
        .onChange(of: effective.customModelID) { _, value in
            customModelDraft = value
        }
        .onChange(of: store.errorMessage) { _, _ in
            let rejected = ClaudeCLIClient.sharedAuthTokenRejected
            if rejected != tokenRejected {
                tokenRejected = rejected
            }
            if rejected {
                readiness = .signedOut
            }
        }
        .onDisappear {
            if loginProcess?.isRunning == true {
                loginProcess?.terminate()
            }
            loginProcess = nil
        }
    }

    private func applyCustomModel() {
        updateConfiguration(
            model: effective.model,
            customModelID: customModelDraft,
            reasoningEffort: effective.reasoningEffort,
            allowUnverifiedBinary: effective.allowUnverifiedBinary
        )
    }

    private func updateConfiguration(
        model: ClaudeCLIModel,
        customModelID: String,
        reasoningEffort: ClaudeReasoningEffort,
        allowUnverifiedBinary: Bool
    ) {
        guard !store.isPreparingModel else { return }
        do {
            let next = try ClaudeCLIConfiguration(
                model: model,
                customModelID: customModelID,
                reasoningEffort: reasoningEffort,
                allowUnverifiedBinary: allowUnverifiedBinary
            )
            store.configuration.claudeCLI = next
            if store.configuration.backend != .claudeCLI {
                store.configuration.backend = .claudeCLI
            }
            store.errorMessage = nil
            store.saveConfiguration()
        } catch {
            store.errorMessage = (error as? ClaudeCLIError)?.localizedDescription ?? error.localizedDescription
        }
    }

    private func refreshReadiness() async {
        guard !checkingLogin else { return }
        checkingLogin = true
        defer { checkingLogin = false }
        let client = ClaudeCLIClient()
        let config = effective
        async let state = client.readiness(configuration: config)
        async let version = client.installedVersion(allowUnverifiedBinary: config.allowUnverifiedBinary)
        readiness = await state
        cliVersion = await version
        tokenRejected = client.authTokenRejected
    }

    private func startInteractiveSignIn() {
        do {
            store.errorMessage = nil
            let process = try ClaudeCLIClient.startInteractiveLogin(
                allowUnverifiedBinary: effective.allowUnverifiedBinary
            ) { _ in
                Task { @MainActor in
                    self.loginProcess = nil
                    self.tokenRejected = ClaudeCLIClient.sharedAuthTokenRejected
                    await self.refreshReadiness()
                    if self.readiness?.isReady == true, self.store.configuration.backend == .claudeCLI {
                        await self.store.refreshModels()
                    }
                }
            }
            tokenRejected = ClaudeCLIClient.sharedAuthTokenRejected
            loginProcess = process
        } catch {
            store.errorMessage = (error as? ClaudeCLIError)?.localizedDescription ?? error.localizedDescription
        }
    }
}
