import SwiftUI

@MainActor struct DirectMCPConnectorView: View {
    let connector: DirectMCPConnector
    let busy: Bool
    @State private var address = ""
    @State private var token = ""
    @State private var legacyOnly = false
    @State private var resourceID = ""
    @State private var toolID = ""
    @State private var arguments = "{}"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Direct MCP").font(.system(size: 15, weight: .semibold))
            Text("Connect to a server you trust. Relay lists available reads and sends only the request you review here. The token and results stay in memory for this session.")
                .font(.relayCaption).foregroundStyle(RelayTheme.muted).fixedSize(horizontal: false, vertical: true)
            if let endpoint = connector.endpoint {
                connected(endpoint)
            } else {
                connectForm
            }
            Text(verbatim: connector.status)
                .font(.relayCaption).foregroundStyle(RelayTheme.muted).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .relayLitCard(accent: RelayColors.accentBlue, cornerRadius: RelayTheme.radius)
        .onChange(of: connector.endpoint) { _, _ in
            resourceID = ""; toolID = ""; arguments = "{}"
        }
    }

    private var connectForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("HTTPS or literal loopback MCP endpoint", text: $address)
                .textFieldStyle(.roundedBorder)
            SecureField("Bearer token (optional)", text: $token)
                .textFieldStyle(.roundedBorder)
            Toggle("Use 2025 Streamable HTTP compatibility", isOn: $legacyOnly)
                .font(.relayCaption)
            HStack {
                if connector.isBusy {
                    ProgressView().controlSize(.small)
                    Button("Cancel connection") { connector.disconnect() }
                        .buttonStyle(RelaySecondaryButtonStyle())
                } else {
                    Button("Connect and list reads") {
                        let suppliedToken = token
                        let selectedEndpoint = address
                        let useLegacy = legacyOnly
                        token = ""
                        Task { await connector.connect(address: selectedEndpoint, token: suppliedToken, legacyOnly: useLegacy) }
                    }
                    .buttonStyle(RelaySecondaryButtonStyle())
                    .disabled(busy || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func connected(_ endpoint: URL) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: "\(connector.connectionName) · \(connector.protocolVersion)").font(.system(size: 13, weight: .semibold))
                    Text(verbatim: endpoint.absoluteString).font(.relayMono).textSelection(.enabled)
                }
                Spacer()
                Button("Disconnect") { connector.disconnect() }.buttonStyle(RelaySecondaryButtonStyle())
            }
            if !connector.resources.isEmpty {
                HStack {
                    Picker("Resource", selection: $resourceID) {
                        Text("Choose a resource").tag("")
                        ForEach(connector.resources) { resource in Text(verbatim: resource.title).tag(resource.id) }
                    }
                    .disabled(connector.isBusy)
                    Button("Preview resource") { connector.prepareResource(resourceID) }
                        .buttonStyle(RelaySecondaryButtonStyle())
                        .disabled(busy || connector.isBusy || resourceID.isEmpty)
                }
            }
            if !connector.tools.isEmpty { toolControls }
            if let preview = connector.preview { review(preview) }
            if let output = connector.output {
                Text("Server response").font(.system(size: 13, weight: .semibold))
                ScrollView {
                    Text(verbatim: output)
                        .font(.relayCaption).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            }
        }
        .onChange(of: resourceID) { _, _ in connector.clearPreview() }
        .onChange(of: toolID) { _, _ in arguments = "{}"; connector.clearPreview() }
    }

    private var toolControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Tools marked read-only", selection: $toolID) {
                Text("Choose a tool").tag("")
                ForEach(connector.tools) { tool in Text(verbatim: tool.title).tag(tool.id) }
            }
            .disabled(connector.isBusy)
            if let tool = connector.tools.first(where: { $0.id == toolID }) {
                if let description = tool.description {
                    Text(verbatim: description).font(.relayCaption).foregroundStyle(RelayTheme.muted)
                }
                Text("The server supplies the read-only label. Review the tool and arguments before running it.")
                    .font(.relayCaption).foregroundStyle(RelayTheme.muted)
                DisclosureGroup("Input schema") {
                    ScrollView {
                        Text(verbatim: JSONValue.object(tool.schema).pretty).font(.relayMono).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 140)
                }.font(.relayCaption)
                TextField("JSON arguments", text: $arguments, axis: .vertical)
                    .font(.relayMono).lineLimit(2...5).textFieldStyle(.roundedBorder)
                    .onChange(of: arguments) { _, _ in connector.clearPreview() }
                    .disabled(connector.isBusy)
                Button("Preview tool request") { connector.prepareTool(toolID, arguments: arguments) }
                    .buttonStyle(RelaySecondaryButtonStyle()).disabled(busy || connector.isBusy)
            }
        }
    }

    private func review(_ preview: DirectMCPReadPreview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Review request").font(.system(size: 13, weight: .semibold))
            Text(verbatim: preview.endpoint.absoluteString).font(.relayMono).textSelection(.enabled)
            Text(verbatim: "\(preview.methodName) · \(preview.target)").font(.relayMono).textSelection(.enabled)
            if let values = preview.arguments { Text(verbatim: values).font(.relayMono).textSelection(.enabled) }
            HStack {
                Button("Send this read") { Task { await connector.performReviewedRead(preview.id) } }
                    .buttonStyle(RelayPrimaryButtonStyle()).disabled(busy || connector.isBusy)
                Button("Cancel") { connector.clearPreview() }.buttonStyle(RelaySecondaryButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RelayTheme.line.opacity(0.24), in: RoundedRectangle(cornerRadius: 8))
    }
}
