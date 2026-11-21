import SwiftUI

struct OpenRouterSettingsView: View {
    let store: AssistantStore
    @State private var keyDraft = ""
    @State private var modelDraft = ""
    @State private var keyFeedback: String?
    private var selected: OpenRouterConfiguration? { store.configuration.openRouter }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "network")
                    .font(RelayPageStyle.symbol)
                    .foregroundStyle(RelayColors.textSecondary)
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("OpenRouter Cloud API")
                            .font(RelayPageStyle.sectionTitle)
                            .foregroundStyle(RelayColors.textPrimary)
                        RelayBadge("Keychain-Scoped", icon: "key.fill", tint: RelayColors.accentCyan, prominent: true)
                    }
                    Text("Optional cloud inference across frontier models. Selected conversations, admitted source content, and chosen images leave this Mac under OpenRouter and its model providers’ privacy terms.")
                        .font(RelayPageStyle.caption)
                        .foregroundStyle(RelayColors.textSecondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if let modelID = selected?.modelID, !modelID.isEmpty {
                    RelayBadge(modelID, tint: RelayColors.accentEmerald, prominent: store.actionsReady)
                }
            }

            Group {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle(
                        "Allow these uploads to OpenRouter",
                        isOn: Binding(get: { selected?.uploadsApproved == true }, set: store.setOpenRouterUploadsApproved)
                    )
                    .toggleStyle(.switch)
                    .font(.relayBodyStrong)
                    .foregroundStyle(RelayColors.textPrimary)

                    Divider().overlay(RelayTheme.line)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("API key (stored in macOS Keychain)")
                            .font(.relayCaptionStrong)
                            .foregroundStyle(RelayColors.textSecondary)
                        HStack(spacing: 8) {
                            SecureField("", text: $keyDraft, prompt: Text(""))
                                .textFieldStyle(.plain)
                                .font(.relayMono)
                                .relayTextFieldPrompt("sk-or-v1-…", when: keyDraft.isEmpty, font: .relayMono)
                                .relayTextField()
                                .accessibilityLabel("New OpenRouter API key")
                            Button("Save key") {
                                let submitted = keyDraft
                                keyFeedback = nil
                                Task {
                                    if await store.replaceOpenRouterKey(submitted), keyDraft.utf8.elementsEqual(submitted.utf8) {
                                        keyDraft = ""
                                        keyFeedback = "API key saved in macOS Keychain."
                                    }
                                }
                            }
                            .buttonStyle(RelaySecondaryButtonStyle())
                            .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isPreparingModel)

                            Button("Remove key") {
                                keyFeedback = nil
                                Task {
                                    if await store.replaceOpenRouterKey(nil) {
                                        keyDraft = ""
                                        keyFeedback = "API key removed from macOS Keychain."
                                    }
                                }
                            }
                            .buttonStyle(RelaySecondaryButtonStyle())
                            .disabled(store.isPreparingModel)
                        }
                        if let keyFeedback {
                            Label(keyFeedback, systemImage: "checkmark.circle")
                                .font(RelayPageStyle.caption)
                                .foregroundStyle(RelayColors.textSecondary)
                                .accessibilityIdentifier("settings.openRouterKeyFeedback")
                        }
                        Text("Only this provider’s Keychain item is used. Saved keys are never displayed; ChatGPT credentials are never used.")
                            .font(RelayPageStyle.caption)
                            .foregroundStyle(RelayColors.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider().overlay(RelayTheme.line)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Model ID")
                            .font(.relayCaptionStrong)
                            .foregroundStyle(RelayColors.textSecondary)
                        HStack(spacing: 8) {
                            TextField("", text: $modelDraft, prompt: Text(""))
                                .textFieldStyle(.plain)
                                .font(.relayMono)
                                .relayTextFieldPrompt("e.g. anthropic/claude-sonnet-4 or google/gemini-2.5-pro", when: modelDraft.isEmpty, font: .relayMono)
                                .relayTextField()
                                .accessibilityLabel("OpenRouter model ID")
                                .onSubmit { if !modelDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { store.setOpenRouterModel(modelDraft) } }
                            Button("Use model") { store.setOpenRouterModel(modelDraft) }
                                .buttonStyle(RelaySecondaryButtonStyle())
                                .disabled(modelDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }

                    HStack(spacing: 10) {
                        Button("Find models") { Task { await store.discoverOpenRouterModels() } }
                            .buttonStyle(RelaySecondaryButtonStyle())
                        if !store.availableModels.isEmpty {
                            Menu("Choose discovered model (\(store.availableModels.count))") {
                                ForEach(store.availableModels.map { LMStudioModelOption(value: $0) }) { item in
                                    Button(item.value) { modelDraft = item.value; store.setOpenRouterModel(item.value) }
                                }
                            }
                            .menuStyle(.borderlessButton)
                        }
                        Spacer()
                    }
                }
                .disabled(store.isPreparingModel)
                .padding(.vertical, 4)

                HStack(spacing: 10) {
                    Button(store.isPreparingModel ? "Checking…" : "Check model") { Task { await store.refreshModels() } }
                        .buttonStyle(RelayPrimaryButtonStyle())
                        .disabled(store.isPreparingModel || !store.configuration.hasConfiguredInferenceModel)
                    Button("Check images") { Task { await store.checkLMStudioVision() } }
                        .buttonStyle(RelaySecondaryButtonStyle())
                        .disabled(store.isPreparingModel || !store.configuration.hasConfiguredInferenceModel)
                    if store.isPreparingModel {
                        ProgressView().controlSize(.small)
                        Button("Stop checking") { store.stop() }.buttonStyle(RelaySecondaryButtonStyle())
                    }
                    Spacer()
                }
            }
            .disabled(store.isRunning && !store.isPreparingModel)

            Text("Checks make requests to OpenRouter and may cost credits. Model listing is not evidence of tool or image support. No request starts just by opening Settings.")
                .font(RelayPageStyle.caption)
                .foregroundStyle(RelayColors.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: store.actionsReady ? "checkmark.circle.fill" : "circle.dotted")
                    .foregroundStyle(store.actionsReady ? RelayColors.accentEmerald : RelayColors.textMuted)
                Text(store.modelStatus)
                    .font(RelayPageStyle.caption)
                    .foregroundStyle(RelayColors.textSecondary)
                    .textSelection(.enabled)
            }
            if let error = store.errorMessage {
                Text(error)
                    .font(RelayPageStyle.caption)
                    .foregroundStyle(RelayColors.accentCoral)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let status = store.localVisionStatus {
                Text(status)
                    .font(RelayPageStyle.caption)
                    .foregroundStyle(RelayColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .relayFormSection()
        .onAppear { modelDraft = selected?.modelID ?? "" }
        .onChange(of: selected?.modelID) { _, value in modelDraft = value ?? "" }
        .onChange(of: keyDraft) { _, value in if !value.isEmpty { keyFeedback = nil } }
        .onDisappear { keyDraft = ""; keyFeedback = nil }
    }
}
