import SwiftUI

struct CustomResponsesSettingsView: View {
    let store: AssistantStore
    @State private var preset: CustomResponsesPreset = .lmStudio
    @State private var baseURL = ""
    @State private var modelID = ""
    @State private var reasoningEffort = CustomResponsesConfiguration.defaultReasoningEffort
    @State private var keyDraft = CustomResponsesKeyDraft()
    @State private var keySaveTask: Task<Void, Never>?
    @State private var keySavedMessage: String?

    private var selected: CustomResponsesConfiguration? { store.configuration.customResponses }
    private var selectedEndpoint: CustomResponsesEndpoint? { selected?.endpoint }
    private var selectedID: String { selected?.modelID ?? "" }
    private var isLoopbackEndpoint: Bool { selectedEndpoint?.isLoopback == true }
    private var hasAppliedBaseURL: Bool {
        CustomResponsesKeyDraft.isBaseURLApplied(baseURL, to: store.configuration)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                RelayIconBadge(icon: "bolt.horizontal.circle.fill", color: RelayColors.accentAmber, size: 38, iconSize: 17)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("OpenAI Responses API")
                            .font(.relayHeadline)
                            .foregroundStyle(RelayColors.textPrimary)
                        RelayBadge(
                            isLoopbackEndpoint ? "Loopback HTTP" : "Endpoint-Scoped HTTPS",
                            tint: RelayColors.accentAmber,
                            prominent: true
                        )
                    }
                    Text(isLoopbackEndpoint
                        ? "Connects to a local OpenAI Responses-compatible server over loopback HTTP without changing your Codex or CLI configuration."
                        : "Sends prompts, tool schemas, and approved context over HTTPS to the selected OpenAI Responses-compatible endpoint using an endpoint-scoped Keychain key.")
                        .font(.relayCaption)
                        .foregroundStyle(RelayColors.textSecondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if !selectedID.isEmpty {
                    RelayBadge(selectedID, tint: RelayColors.accentEmerald, prominent: store.actionsReady)
                }
            }

            Group {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        Text("Preset")
                            .font(.relayCaptionStrong)
                            .foregroundStyle(RelayColors.textSecondary)
                            .frame(width: 80, alignment: .leading)
                        Picker("Preset", selection: Binding(get: { preset }, set: { clearKeyDraft(); preset = $0 })) {
                            ForEach(CustomResponsesPreset.allCases, id: \.self) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 200)
                        .disabled(store.isPreparingModel)
                        .onChange(of: preset) { _, next in
                            clearKeyDraft()
                            guard next != .custom else { return }
                            baseURL = next.defaultBaseURL
                            store.setCustomResponsesConfiguration(
                                baseURL: next.defaultBaseURL,
                                modelID: modelID,
                                reasoningEffort: reasoningEffort,
                                requiresAPIKey: next.defaultRequiresAPIKey
                            )
                        }

                        Spacer(minLength: 8)

                        Text("Reasoning")
                            .font(.relayCaptionStrong)
                            .foregroundStyle(RelayColors.textSecondary)
                        Picker("Reasoning", selection: $reasoningEffort) {
                            ForEach(CustomResponsesConfiguration.supportedReasoningEfforts, id: \.self) { effort in
                                Text(effort).tag(effort)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 120)
                        .disabled(store.isPreparingModel)
                        .onChange(of: reasoningEffort) { _, next in
                            store.setCustomResponsesConfiguration(
                                baseURL: selected?.baseURL ?? baseURL,
                                modelID: modelID,
                                reasoningEffort: next,
                                requiresAPIKey: selected?.requiresAPIKey
                            )
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Endpoint Base URL")
                            .font(.relayCaptionStrong)
                            .foregroundStyle(RelayColors.textSecondary)
                        HStack(spacing: 8) {
                            TextField("", text: Binding(get: { baseURL }, set: { clearKeyDraft(); baseURL = $0 }), prompt: Text(""))
                                .textFieldStyle(.plain)
                                .font(.relayMono)
                                .relayTextFieldPrompt("https://.../v1 or http://127.0.0.1:1234/v1", when: baseURL.isEmpty, font: .relayMono)
                                .relayTextField()
                                .disabled(store.isPreparingModel)
                                .accessibilityLabel("Responses API endpoint URL")
                                .accessibilityIdentifier("settings.customResponsesBaseURL")
                            Button("Apply URL") {
                                clearKeyDraft()
                                preset = CustomResponsesPreset.matching(baseURL: baseURL)
                                store.setCustomResponsesConfiguration(
                                    baseURL: baseURL,
                                    modelID: modelID,
                                    reasoningEffort: reasoningEffort,
                                    requiresAPIKey: nil
                                )
                                if let applied = store.configuration.customResponses?.baseURL,
                                   (try? CustomResponsesConfiguration.validatedEndpoint(baseURL)) == store.configuration.customResponses?.endpoint {
                                    baseURL = applied
                                }
                            }
                            .buttonStyle(RelaySecondaryButtonStyle())
                            .disabled(store.isPreparingModel)
                        }
                    }

                    if !hasAppliedBaseURL {
                        Text("Apply the URL to change upload permission, manage keys, or check models and images.")
                            .font(.relayCaption)
                            .foregroundStyle(RelayColors.accentAmber)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider().overlay(RelayTheme.line)

                    if !isLoopbackEndpoint {
                        Toggle(
                            "Allow sending prompts, selected files, and checked images to this remote Responses endpoint",
                            isOn: Binding(
                                get: { selected?.uploadsApproved == true },
                                set: { store.setCustomResponsesUploadsApproved($0, typedBaseURL: baseURL) }
                            )
                        )
                        .toggleStyle(.switch)
                        .font(.relayCaptionStrong)
                        .disabled(store.isPreparingModel || !hasAppliedBaseURL)
                        .accessibilityIdentifier("settings.customResponsesApproveUploads")
                    } else {
                        Toggle(
                            "Require API key for this local loopback Responses server",
                            isOn: Binding(
                                get: { selected?.requiresAPIKey == true },
                                set: { required in
                                    guard hasAppliedBaseURL, let selected else { return }
                                    store.setCustomResponsesConfiguration(
                                        baseURL: selected.baseURL,
                                        modelID: modelID,
                                        reasoningEffort: reasoningEffort,
                                        requiresAPIKey: required
                                    )
                                }
                            )
                        )
                        .toggleStyle(.switch)
                        .font(.relayCaptionStrong)
                        .disabled(store.isPreparingModel || !hasAppliedBaseURL)
                        .accessibilityIdentifier("settings.customResponsesRequireLocalKey")
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Endpoint API Key (Keychain)")
                            .font(.relayCaptionStrong)
                            .foregroundStyle(RelayColors.textSecondary)
                        HStack(spacing: 8) {
                            let displayedKey = keyDraft.displayedValue(
                                for: store.configuration,
                                typedBaseURL: baseURL,
                                storeEpoch: store.customResponsesKeySaveEpoch
                            )
                            let keyPrompt = isLoopbackEndpoint && selected?.requiresAPIKey != true
                                ? "Optional local API key (stored in Keychain for this URL)"
                                : "Responses API key (stored in Keychain for this URL)"
                            SecureField(
                                "",
                                text: Binding(
                                    get: { displayedKey },
                                    set: {
                                        keyDraft.set(
                                            $0,
                                            for: store.configuration,
                                            typedBaseURL: baseURL,
                                            storeEpoch: store.customResponsesKeySaveEpoch
                                        )
                                    }
                                ),
                                prompt: Text("")
                            )
                            .textFieldStyle(.plain)
                            .font(.relayMono)
                            .relayTextFieldPrompt(keyPrompt, when: displayedKey.isEmpty, font: .relayMono)
                            .relayTextField()
                            .disabled(store.isPreparingModel || !hasAppliedBaseURL)
                            .accessibilityLabel("API key for the applied Responses endpoint")
                                .accessibilityIdentifier("settings.customResponsesAPIKey")

                            Button("Save key") {
                                guard let admission = store.captureCustomResponsesKeySaveAdmission(typedBaseURL: baseURL),
                                      let submitted = keyDraft.submission(for: admission, typedBaseURL: baseURL) else { return }
                                keySaveTask?.cancel()
                                keySaveTask = Task {
                                    guard !Task.isCancelled,
                                          store.isCustomResponsesKeySaveAdmissionCurrent(admission, typedBaseURL: baseURL),
                                          keyDraft.isCurrent(
                                              submitted,
                                              configuration: store.configuration,
                                              typedBaseURL: baseURL,
                                              storeEpoch: store.customResponsesKeySaveEpoch
                                          ) else { return }
                                    if await store.replaceCustomResponsesKey(submitted.value, admission: admission),
                                       !Task.isCancelled, keyDraft.epoch == submitted.epoch {
                                        keyDraft.clear()
                                        keySavedMessage = "API key saved in Keychain for this endpoint."
                                    }
                                }
                            }
                            .buttonStyle(RelaySecondaryButtonStyle())
                            .disabled(
                                store.isPreparingModel
                                    || !hasAppliedBaseURL
                                    || keyDraft.submission(
                                        for: store.configuration,
                                        typedBaseURL: baseURL,
                                        storeEpoch: store.customResponsesKeySaveEpoch
                                    ) == nil
                            )

                            Button("Remove key") {
                                guard let admission = store.captureCustomResponsesKeySaveAdmission(typedBaseURL: baseURL) else { return }
                                let epoch = keyDraft.epoch
                                keySaveTask?.cancel()
                                keySaveTask = Task {
                                    guard !Task.isCancelled,
                                          store.isCustomResponsesKeySaveAdmissionCurrent(admission, typedBaseURL: baseURL),
                                          keyDraft.epoch == epoch else { return }
                                    if await store.replaceCustomResponsesKey(nil, admission: admission),
                                       !Task.isCancelled, keyDraft.epoch == epoch {
                                        keyDraft.clear()
                                        keySavedMessage = "API key removed from Keychain for this endpoint."
                                    }
                                }
                            }
                            .buttonStyle(RelaySecondaryButtonStyle())
                            .disabled(store.isPreparingModel || !hasAppliedBaseURL)
                        }
                        Text("Keys are scoped to the normalized endpoint URL in Keychain; ChatGPT/Codex CLI credentials and other providers' keys are never used.")
                            .font(.relayCaption)
                            .foregroundStyle(RelayColors.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider().overlay(RelayTheme.line)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Model ID")
                            .font(.relayCaptionStrong)
                            .foregroundStyle(RelayColors.textSecondary)
                        HStack(spacing: 8) {
                            TextField("", text: $modelID, prompt: Text(""))
                                .textFieldStyle(.plain)
                                .font(.relayMono)
                                .relayTextFieldPrompt("e.g. openai/gpt-5.4 or qwen/qwen3-coder", when: modelID.isEmpty, font: .relayMono)
                                .relayTextField()
                                .onSubmit {
                                    store.setCustomResponsesConfiguration(
                                        baseURL: selected?.baseURL ?? baseURL,
                                        modelID: modelID,
                                        reasoningEffort: reasoningEffort,
                                        requiresAPIKey: selected?.requiresAPIKey
                                    )
                                }
                                .accessibilityLabel("Responses API model ID")
                                .accessibilityIdentifier("settings.customResponsesModelID")
                            Button("Use model") {
                                store.setCustomResponsesConfiguration(
                                    baseURL: selected?.baseURL ?? baseURL,
                                    modelID: modelID,
                                    reasoningEffort: reasoningEffort,
                                    requiresAPIKey: selected?.requiresAPIKey
                                )
                            }
                            .buttonStyle(RelaySecondaryButtonStyle())
                        }
                    }

                    HStack(spacing: 10) {
                        Button("Find models") {
                            checkAppliedEndpoint(.discoverModels)
                        }
                        .buttonStyle(RelaySecondaryButtonStyle())
                        .disabled(!hasAppliedBaseURL || store.isPreparingModel || (!isLoopbackEndpoint && selected?.uploadsApproved != true))

                        if !store.availableModels.isEmpty {
                            Menu("Choose discovered model (\(store.availableModels.count))") {
                                ForEach(store.availableModels.map { LMStudioModelOption(value: $0) }) { item in
                                    Button(item.value) {
                                        modelID = item.value
                                        store.setCustomResponsesConfiguration(
                                            baseURL: selected?.baseURL ?? baseURL,
                                            modelID: item.value,
                                            reasoningEffort: reasoningEffort,
                                            requiresAPIKey: selected?.requiresAPIKey
                                        )
                                    }
                                }
                            }
                            .menuStyle(.borderlessButton)
                        }
                        Spacer()
                    }
                }
                .disabled(store.isPreparingModel)
                .padding(14)
                .background(RelayColors.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(RelayColors.borderSubtle, lineWidth: 1)
                )

                HStack(spacing: 10) {
                    Button(store.isPreparingModel ? "Checking…" : "Check model") {
                        checkAppliedEndpoint(.verifyModel)
                    }
                    .buttonStyle(RelayPrimaryButtonStyle())
                    .disabled(!hasAppliedBaseURL || store.isPreparingModel || !store.configuration.hasConfiguredInferenceModel)
                    Button("Check images") {
                        checkAppliedEndpoint(.verifyImages)
                    }
                    .buttonStyle(RelaySecondaryButtonStyle())
                    .disabled(!hasAppliedBaseURL || store.isPreparingModel || !store.configuration.hasConfiguredInferenceModel)

                    if store.isPreparingModel {
                        ProgressView().controlSize(.small)
                        Button("Stop checking") { store.stop() }.buttonStyle(RelaySecondaryButtonStyle())
                    }
                    Spacer()
                }
            }
            .disabled(store.isRunning && !store.isPreparingModel)

            if let keySavedMessage {
                Text(keySavedMessage)
                    .font(.relayCaption)
                    .foregroundStyle(RelayColors.accentEmerald)
            }

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
        .relayLitCard(accent: RelayColors.accentAmber, cornerRadius: RelayTheme.radius)
        .onAppear {
            let currentURL = selected?.baseURL ?? CustomResponsesConfiguration.defaultBaseURL
            baseURL = currentURL
            preset = CustomResponsesPreset.matching(baseURL: currentURL)
            modelID = selectedID
            reasoningEffort = selected?.reasoningEffort ?? CustomResponsesConfiguration.defaultReasoningEffort
        }
        .onChange(of: baseURL) { _, _ in clearKeyDraft() }
        .onChange(of: store.configuration) { old, next in
            clearKeyDraft(keepingMessage: keyDraft.value.isEmpty && old.backend == next.backend
                && old.customResponses?.endpoint == next.customResponses?.endpoint)
        }
        .onChange(of: selected?.baseURL) { _, value in
            let next = value ?? CustomResponsesConfiguration.defaultBaseURL
            baseURL = next
            preset = CustomResponsesPreset.matching(baseURL: next)
        }
        .onChange(of: selectedID) { _, value in
            modelID = value
        }
        .onChange(of: selected?.reasoningEffort) { _, value in
            reasoningEffort = value ?? CustomResponsesConfiguration.defaultReasoningEffort
        }
        .onDisappear { clearKeyDraft() }
    }
    private func checkAppliedEndpoint(_ check: AssistantStore.CustomResponsesSettingsCheck) {
        guard let admission = store.captureCustomResponsesKeySaveAdmission(typedBaseURL: baseURL) else { return }
        Task {
            await store.runCustomResponsesSettingsCheck(check, admission: admission, typedBaseURL: baseURL)
        }
    }
    private func clearKeyDraft(keepingMessage: Bool = false) {
        keySaveTask?.cancel(); keySaveTask = nil
        keyDraft.clear(); if !keepingMessage { keySavedMessage = nil }
    }
}

nonisolated struct CustomResponsesKeySaveAdmission: Equatable, Sendable {
    let configuration: ModelConfiguration
    let epoch: UUID
    let revision: Int
}

/// Ephemeral secret text belongs to the exact selection that received it.
/// No Codable/persistence, credential lookup, ambient fallback or authority.
nonisolated struct CustomResponsesKeyDraft {
    struct Submission: Sendable {
        let value: String
        let configuration: ModelConfiguration
        let epoch: UUID
        let storeEpoch: UUID
        let storeRevision: Int

        var admission: CustomResponsesKeySaveAdmission {
            CustomResponsesKeySaveAdmission(
                configuration: configuration,
                epoch: storeEpoch,
                revision: storeRevision
            )
        }
    }
    private(set) var value = ""
    private(set) var epoch = UUID()
    private var owner: ModelConfiguration?
    private var ownerStoreEpoch: UUID?

    static func isBaseURLApplied(_ typedBaseURL: String, to configuration: ModelConfiguration) -> Bool {
        guard configuration.backend == .customResponses,
              let selected = configuration.customResponses,
              let selectedEndpoint = selected.endpoint else {
            return false
        }
        let trimmed = typedBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let typedEndpoint = try? CustomResponsesConfiguration.validatedEndpoint(trimmed) else {
            return false
        }
        return typedEndpoint == selectedEndpoint
            && Data(trimmed.utf8) == Data(selected.baseURL.utf8)
    }

    func displayedValue(
        for configuration: ModelConfiguration,
        typedBaseURL: String? = nil,
        storeEpoch: UUID? = nil
    ) -> String {
        let effectiveURL = typedBaseURL ?? configuration.customResponses?.baseURL ?? ""
        guard Self.isBaseURLApplied(effectiveURL, to: configuration),
              owner == configuration else {
            return ""
        }
        if let storeEpoch, let ownerStoreEpoch, ownerStoreEpoch != storeEpoch {
            return ""
        }
        return value
    }

    mutating func set(
        _ value: String,
        for configuration: ModelConfiguration,
        typedBaseURL: String? = nil,
        storeEpoch: UUID? = nil
    ) {
        let effectiveURL = typedBaseURL ?? configuration.customResponses?.baseURL ?? ""
        guard Self.isBaseURLApplied(effectiveURL, to: configuration) else {
            clear()
            return
        }
        if owner != configuration || (storeEpoch != nil && ownerStoreEpoch != nil && ownerStoreEpoch != storeEpoch) {
            clear()
        }
        owner = configuration
        if let storeEpoch {
            ownerStoreEpoch = storeEpoch
        }
        self.value = value
    }

    mutating func clear() {
        value = ""
        owner = nil
        ownerStoreEpoch = nil
        epoch = UUID()
    }

    func submission(
        for configuration: ModelConfiguration,
        typedBaseURL: String? = nil,
        storeEpoch: UUID = UUID(),
        storeRevision: Int = 0
    ) -> Submission? {
        let effectiveURL = typedBaseURL ?? configuration.customResponses?.baseURL ?? ""
        guard Self.isBaseURLApplied(effectiveURL, to: configuration),
              owner == configuration,
              ownerStoreEpoch == nil || ownerStoreEpoch == storeEpoch,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return .init(
            value: value,
            configuration: configuration,
            epoch: epoch,
            storeEpoch: storeEpoch,
            storeRevision: storeRevision
        )
    }

    func submission(
        for admission: CustomResponsesKeySaveAdmission,
        typedBaseURL: String? = nil
    ) -> Submission? {
        submission(
            for: admission.configuration,
            typedBaseURL: typedBaseURL,
            storeEpoch: admission.epoch,
            storeRevision: admission.revision
        )
    }

    func isCurrent(
        _ submission: Submission,
        configuration: ModelConfiguration,
        typedBaseURL: String? = nil,
        storeEpoch: UUID? = nil
    ) -> Bool {
        let effectiveURL = typedBaseURL ?? configuration.customResponses?.baseURL ?? ""
        guard Self.isBaseURLApplied(effectiveURL, to: configuration),
              owner == configuration,
              submission.configuration == configuration,
              submission.epoch == epoch,
              Data(submission.value.utf8) == Data(value.utf8) else {
            return false
        }
        if let ownerStoreEpoch, ownerStoreEpoch != submission.storeEpoch {
            return false
        }
        if let storeEpoch, submission.storeEpoch != storeEpoch {
            return false
        }
        return true
    }
}
