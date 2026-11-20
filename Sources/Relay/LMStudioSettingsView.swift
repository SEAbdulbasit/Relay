import SwiftUI

nonisolated struct LMStudioModelOption: Identifiable {
    let value: String
    var id: LMStudioProtocolID { LMStudioProtocolID(value) }
}

struct LMStudioSettingsView: View {
    let store: AssistantStore
    @State private var port = "1234"
    private var selectedID: String { store.configuration.lmStudio?.modelID ?? "" }
    private var pickerModels: [LMStudioModelOption] {
        let current = selectedID
        let values = current.isEmpty || LMStudioProtocolID.contains(store.availableModels, current)
            ? store.availableModels : [current] + store.availableModels
        return values.map { LMStudioModelOption(value: $0) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                RelayIconBadge(icon: "server.rack", color: RelayColors.accentAmethyst, size: 38, iconSize: 17)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("LM Studio Local Server")
                            .font(.relayHeadline)
                            .foregroundStyle(RelayColors.textPrimary)
                        RelayBadge("OpenAI-Compatible", tint: RelayColors.accentAmethyst, prominent: true)
                    }
                    Text("Connect to LM Studio running on this Mac. Prompts, tools, and visual attachments remain on your local machine.")
                        .font(.relayCaption)
                        .foregroundStyle(RelayColors.textSecondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if !selectedID.isEmpty {
                    RelayBadge(selectedID, icon: "cube.fill", tint: RelayColors.accentEmerald, prominent: store.actionsReady)
                }
            }

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Text("Server Host")
                        .font(.relayCaptionStrong)
                        .foregroundStyle(RelayColors.textSecondary)
                        .frame(width: 90, alignment: .leading)
                    Text(store.configuration.lmStudio?.endpoint.host.rawValue ?? "127.0.0.1")
                        .font(.relayMono)
                        .foregroundStyle(RelayColors.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(RelayColors.cardBG, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(RelayColors.borderSubtle, lineWidth: 1)
                        )
                        .textSelection(.enabled)

                    Text("Port")
                        .font(.relayCaptionStrong)
                        .foregroundStyle(RelayColors.textSecondary)
                    TextField("", text: $port, prompt: Text(""))
                        .textFieldStyle(.plain)
                        .font(.relayMono)
                        .relayTextFieldPrompt("1234", when: port.isEmpty, font: .relayMono)
                        .relayTextField()
                        .frame(width: 96)
                        .accessibilityLabel("LM Studio local port")
                        .onSubmit { store.setLMStudioPort(port) }

                    Button("Find models") {
                        if store.setLMStudioPort(port) { Task { await store.discoverLMStudioModels() } }
                    }
                    .buttonStyle(RelaySecondaryButtonStyle())
                    Spacer()
                }
                .disabled(store.isRunning || store.isPreparingModel)

                Divider().overlay(RelayTheme.line)

                HStack(spacing: 12) {
                    Text("Active Model")
                        .font(.relayCaptionStrong)
                        .foregroundStyle(RelayColors.textSecondary)
                        .frame(width: 90, alignment: .leading)
                    Picker("Model", selection: Binding(get: { LMStudioProtocolID(selectedID) }, set: { store.selectLMStudioModel($0.string) })) {
                        Text("Choose a model").tag(LMStudioProtocolID(""))
                        ForEach(pickerModels) { option in Text(option.value).tag(option.id) }
                    }
                    .labelsHidden()
                    .disabled(store.isRunning || store.isPreparingModel)
                    Spacer()
                }

                Text("A listed model may still need to be loaded in LM Studio. Choose one, then check that it can plan actions.")
                    .font(.relayCaption)
                    .foregroundStyle(RelayColors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .background(RelayColors.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(RelayColors.borderSubtle, lineWidth: 1)
            )

            HStack(spacing: 10) {
                Button(store.isPreparingModel ? "Checking…" : "Check model") {
                    if store.setLMStudioPort(port) { Task { await store.refreshModels() } }
                }
                .buttonStyle(RelayPrimaryButtonStyle())
                .disabled(store.isRunning || store.isPreparingModel || !store.configuration.hasConfiguredInferenceModel)

                Button("Check images") {
                    if store.setLMStudioPort(port) { Task { await store.checkLMStudioVision() } }
                }
                .buttonStyle(RelaySecondaryButtonStyle())
                .disabled(store.isRunning || store.isPreparingModel || !store.configuration.hasConfiguredInferenceModel)

                if store.isPreparingModel {
                    ProgressView().controlSize(.small)
                    Button("Stop") { store.stop() }.buttonStyle(RelaySecondaryButtonStyle())
                } else {
                    Button("Disconnect") { store.unloadModel() }
                        .buttonStyle(RelaySecondaryButtonStyle())
                        .disabled(store.isRunning || store.isPreparingModel)
                    if store.workspaceUsesCodex || store.workspaceUsesCodexCLI {
                        Button("Use for workspace") { store.selectWorkspaceLocal() }
                            .buttonStyle(RelaySecondaryButtonStyle())
                            .disabled(store.isRunning || store.checkingCodex)
                    }
                }
                Spacer()
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
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let status = store.localVisionStatus {
                Text(status)
                    .font(.relayCaption)
                    .foregroundStyle(RelayColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Relay checks image support with a sample before sending the image you choose. Chat and text actions use this model; Double Tap keeps its own model setting.")
                .font(.relayCaption)
                .foregroundStyle(RelayColors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .relayLitCard(accent: RelayColors.accentAmethyst, cornerRadius: RelayTheme.radius)
        .onAppear { port = String(store.configuration.lmStudio?.endpoint.port ?? 1234) }
        .onChange(of: store.configuration.lmStudio?.endpoint.port) { _, value in port = String(value ?? 1234) }
    }
}
