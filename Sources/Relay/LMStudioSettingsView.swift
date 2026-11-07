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
        VStack(alignment: .leading, spacing: 14) {
            Text("LM Studio").font(.system(size: 16, weight: .semibold))
            Text("Connect to LM Studio running on this Mac. Its privacy settings apply.")
                .font(.relayCaption).foregroundStyle(RelayColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Text(store.configuration.lmStudio?.endpoint.host.rawValue ?? "127.0.0.1")
                    .font(.relayMono).textSelection(.enabled)
                TextField("Port", text: $port).textFieldStyle(.roundedBorder).frame(width: 90)
                    .accessibilityLabel("LM Studio local port")
                    .onSubmit { store.setLMStudioPort(port) }
                Button("Find models") {
                    if store.setLMStudioPort(port) { Task { await store.discoverLMStudioModels() } }
                }.buttonStyle(RelaySecondaryButtonStyle())
            }.disabled(store.isRunning)
            Picker("Model", selection: Binding(get: { LMStudioProtocolID(selectedID) }, set: { store.selectLMStudioModel($0.string) })) {
                Text("Choose a model").tag(LMStudioProtocolID(""))
                ForEach(pickerModels) { option in Text(option.value).tag(option.id) }
            }.disabled(store.isRunning)
            Text("A listed model may still need to be loaded in LM Studio. Choose one, then check that it can plan actions.")
                .font(.relayCaption).foregroundStyle(RelayColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button(store.isPreparingModel ? "Checking…" : "Check model") {
                    if store.setLMStudioPort(port) { Task { await store.refreshModels() } }
                }.buttonStyle(RelayPrimaryButtonStyle())
                    .disabled(store.isRunning || !store.configuration.hasConfiguredInferenceModel)
                Button("Check images") {
                    if store.setLMStudioPort(port) { Task { await store.checkLMStudioVision() } }
                }.buttonStyle(RelaySecondaryButtonStyle())
                    .disabled(store.isRunning || !store.configuration.hasConfiguredInferenceModel)
                if store.isPreparingModel {
                    ProgressView().controlSize(.small)
                    Button("Stop") { store.stop() }.buttonStyle(RelaySecondaryButtonStyle())
                } else {
                    Button("Disconnect") { store.unloadModel() }.buttonStyle(RelaySecondaryButtonStyle()).disabled(store.isRunning)
                    if store.workspaceUsesCodex {
                        Button("Use for workspace") { store.selectWorkspaceLocal() }
                            .buttonStyle(RelaySecondaryButtonStyle()).disabled(store.isRunning || store.checkingCodex)
                    }
                }
            }
            Label(store.modelStatus, systemImage: store.actionsReady ? "checkmark.circle.fill" : "circle.dotted")
                .font(.system(size: 13)).foregroundStyle(RelayColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = store.errorMessage {
                Text(error).font(.system(size: 13)).foregroundStyle(RelayColors.accentCoral)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if let status = store.localVisionStatus {
                Text(status).font(.relayCaption).foregroundStyle(RelayColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Relay checks image support with a sample before sending the image you choose. Chat and text actions use this model; Double Tap keeps its own model setting.")
                .font(.relayCaption).foregroundStyle(RelayColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .relayLitCard(accent: RelayColors.accentEmerald, cornerRadius: RelayTheme.radius)
        .onAppear { port = String(store.configuration.lmStudio?.endpoint.port ?? 1234) }
        .onChange(of: store.configuration.lmStudio?.endpoint.port) { _, value in port = String(value ?? 1234) }
    }
}
