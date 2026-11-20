import SwiftUI

@MainActor struct DirectMCPConnectorView: View {
    let connector: DirectMCPConnector
    let busy: Bool
    var store: AssistantStore? = nil

    @State private var selectedPreset: OAuthMCPProvider = .notion
    @State private var accountLabel = ""
    @State private var oauthClientID = ""
    @State private var oauthClientSecret = ""
    @State private var customOAuthEndpoint = ""
    @State private var oauthErrorMessage: String?

    @State private var address = ""
    @State private var token = ""
    @State private var legacyOnly = false
    @State private var resourceID = ""
    @State private var toolID = ""
    @State private var arguments = "{}"
    @State private var cloudPreviewOutput: String?

    private var oauth: OAuthMCPConnectorManager { connector.oauthManager }

    private var clientSecretPlaceholder: String {
        if selectedPreset.requiresClientSecret {
            return "Client Secret (required)"
        }
        if selectedPreset == .gmail || selectedPreset == .googleCalendar {
            return "Client Secret (Google Desktop OAuth client)"
        }
        return "Client Secret (optional)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            curatedCloudSection
            Divider().opacity(0.35)
            directMCPSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .relayLitCard(accent: RelayColors.accentBlue, cornerRadius: RelayTheme.radius)
        .onChange(of: connector.endpoint) { _, _ in
            resourceID = ""; toolID = ""; arguments = "{}"
        }
        .onChange(of: selectedPreset) { _, _ in
            oauthClientSecret = ""
            oauthErrorMessage = nil
        }
    }

    // MARK: - Curated Cloud & OAuth 2.0 + PKCE MCP Section

    private var curatedCloudSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                RelayIconBadge(icon: "point.3.connected.trianglepath.dotted", color: RelayColors.accentBlue, size: 38, iconSize: 17)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Cloud & OAuth 2.0 MCP Connectors")
                        .font(.relayHeadline)
                        .foregroundStyle(RelayColors.textPrimary)
                    Text("Connect Notion, Granola, Gmail, Google Calendar, Outlook, Slack, or a custom OAuth 2.0 + S256 PKCE MCP server. Tokens are stored in your Mac Keychain and isolated by account generation.")
                        .font(.relayCaption)
                        .foregroundStyle(RelayColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                ForEach(OAuthMCPProvider.curatedPresets, id: \.self) { preset in
                    let linkedCount = oauth.connections(for: preset).count
                    let isSelected = selectedPreset == preset
                    Button {
                        selectedPreset = preset
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: preset.systemImage)
                                .foregroundStyle(isSelected ? RelayColors.accentBlue : RelayColors.textSecondary)
                            Text(preset.displayName)
                                .font(.relayCaptionStrong)
                                .foregroundStyle(RelayColors.textPrimary)
                            Spacer(minLength: 2)
                            if linkedCount > 0 {
                                RelayBadge("\(linkedCount)", tint: RelayColors.accentEmerald, prominent: true)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            (isSelected ? RelayColors.surfaceElevated : RelayColors.surface),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(isSelected ? RelayColors.accentBlue.opacity(0.6) : RelayColors.borderSubtle, lineWidth: 1)
                        )
                    }
                    .buttonStyle(RelayPressStyle())
                    .accessibilityIdentifier("oauthConnector.preset.\(preset.rawValue)")
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Label(selectedPreset.displayName, systemImage: selectedPreset.systemImage)
                        .font(.relayBodyStrong)
                        .foregroundStyle(RelayColors.textPrimary)
                    Spacer()
                    Button("Custom OAuth MCP") { selectedPreset = .custom }
                        .buttonStyle(RelaySecondaryButtonStyle())
                }
                Text(selectedPreset.subtitle)
                    .font(.relayCaption)
                    .foregroundStyle(RelayColors.textSecondary)

                if selectedPreset == .custom {
                    TextField("HTTPS OAuth MCP endpoint (e.g. https://mcp.example.com/mcp)", text: $customOAuthEndpoint)
                        .textFieldStyle(.plain)
                        .relayTextField()
                }

                HStack(spacing: 8) {
                    TextField("Account label (e.g. Work, Personal)", text: $accountLabel)
                        .textFieldStyle(.plain)
                        .relayTextField()
                    TextField(selectedPreset.supportsDynamicRegistration ? "Client ID (optional — auto-registers if blank)" : "OAuth Client ID", text: $oauthClientID)
                        .textFieldStyle(.plain)
                        .relayTextField()
                        .accessibilityIdentifier("oauthConnector.clientID")
                }

                if selectedPreset.supportsClientSecret {
                    SecureField(clientSecretPlaceholder, text: $oauthClientSecret)
                        .textFieldStyle(.plain)
                        .relayTextField()
                        .accessibilityIdentifier("oauthConnector.clientSecret")
                }

                HStack(spacing: 10) {
                    if oauth.isAuthorizing {
                        ProgressView().controlSize(.small)
                        Button("Cancel Sign-In") {
                            oauthErrorMessage = nil
                            oauth.cancelPendingAuthorization()
                        }
                        .buttonStyle(RelaySecondaryButtonStyle())
                    } else {
                        Button("Sign in with \(selectedPreset.displayName)…") {
                            let chosenPreset = selectedPreset
                            let chosenLabel = accountLabel
                            let chosenClient = oauthClientID
                            let chosenSecret = oauthClientSecret
                            let customURL = URL(string: customOAuthEndpoint.trimmingCharacters(in: .whitespacesAndNewlines))
                            Task {
                                defer { oauthClientSecret = "" }
                                do {
                                    oauthErrorMessage = nil
                                    _ = try await oauth.authorize(
                                        provider: chosenPreset,
                                        customEndpoint: chosenPreset == .custom ? customURL : nil,
                                        clientID: chosenClient,
                                        clientSecret: chosenPreset.supportsClientSecret ? chosenSecret : nil,
                                        accountLabel: chosenLabel
                                    )
                                } catch is CancellationError {
                                    oauthErrorMessage = nil
                                } catch {
                                    oauthErrorMessage = error.localizedDescription
                                }
                            }
                        }
                        .buttonStyle(RelayPrimaryButtonStyle())
                        .disabled(busy || (selectedPreset == .custom && customOAuthEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                        .accessibilityIdentifier("oauthConnector.signIn")
                    }
                    Text(oauthErrorMessage ?? oauth.status)
                        .font(.relayCaption)
                        .foregroundStyle(oauthErrorMessage == nil ? RelayColors.textSecondary : RelayColors.accentAmber)
                        .lineLimit(2)
                }
            }
            .padding(14)
            .background(RelayColors.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(RelayColors.borderSubtle, lineWidth: 1)
            )

            if !oauth.connections.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Connected Cloud Accounts")
                        .font(.system(size: 13, weight: .semibold))
                    ForEach(oauth.connections, id: \.id) { conn in
                        connectedOAuthRow(conn)
                    }
                }
            }

            if let cloudPreviewOutput {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Recent Cloud Snapshot")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Button("Clear") { self.cloudPreviewOutput = nil }
                            .buttonStyle(RelaySecondaryButtonStyle())
                    }
                    ScrollView {
                        Text(verbatim: cloudPreviewOutput)
                            .font(.relayCaption)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 150)
                }
                .padding(12)
                .background(RelayColors.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(RelayColors.borderSubtle, lineWidth: 1)
                )
            }
        }
    }

    private func connectedOAuthRow(_ conn: OAuthMCPConnection) -> some View {
        HStack(spacing: 10) {
            Image(systemName: conn.provider.systemImage)
                .foregroundStyle(conn.state == .connected ? RelayColors.accentEmerald : RelayColors.accentAmber)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(conn.provider.displayName) · \(conn.accountLabel)")
                    .font(.system(size: 12, weight: .semibold))
                Text(conn.state == .connected ? "Connected · Gen \(conn.generation.uuidString.prefix(8))" : "Reconnect required")
                    .font(.relayCaption)
                    .foregroundStyle(RelayTheme.muted)
            }
            Spacer()
            if conn.state == .reconnectRequired {
                Button("Reconnect") {
                    let typedSecret = (selectedPreset == conn.provider && conn.provider.supportsClientSecret) ? oauthClientSecret : nil
                    let typedClientID = (selectedPreset == conn.provider) ? oauthClientID : nil
                    Task {
                        defer {
                            if selectedPreset == conn.provider {
                                oauthClientSecret = ""
                            }
                        }
                        do {
                            oauthErrorMessage = nil
                            _ = try await oauth.authorize(
                                provider: conn.provider,
                                customEndpoint: conn.endpoint,
                                clientID: conn.clientID ?? typedClientID,
                                clientSecret: typedSecret,
                                accountLabel: conn.accountLabel,
                                existingConnectionID: conn.id
                            )
                        } catch is CancellationError {
                            oauthErrorMessage = nil
                        } catch {
                            selectedPreset = conn.provider
                            if let existingClient = conn.clientID, oauthClientID.isEmpty {
                                oauthClientID = existingClient
                            }
                            oauthErrorMessage = error.localizedDescription
                        }
                    }
                }
                .buttonStyle(RelaySecondaryButtonStyle())
            } else {
                Button("Preview Recent") {
                    Task {
                        do {
                            let items = try await oauth.fetchCuratedCloudWindow(connectionID: conn.id, maxItems: 8)
                            cloudPreviewOutput = items.isEmpty
                                ? "No recent eligible items found."
                                : items.map { "• \($0.title) (\($0.subtitle))\n  \($0.body)" }.joined(separator: "\n\n")
                        } catch {
                            cloudPreviewOutput = "Could not load preview: \(error.localizedDescription)"
                        }
                    }
                }
                .buttonStyle(RelaySecondaryButtonStyle())
                .disabled(busy)

                if conn.provider.usesRemoteMCPProtocol {
                    Button(connector.activeOAuthConnection?.id == conn.id ? "Active Session" : "Open Tools") {
                        Task {
                            if connector.endpoint != nil { connector.disconnect() }
                            await connector.connectOAuth(connectionID: conn.id)
                        }
                    }
                    .buttonStyle(RelaySecondaryButtonStyle())
                    .disabled(busy || connector.isBusy || connector.activeOAuthConnection?.id == conn.id)
                }
            }
            Button("Disconnect") {
                oauth.disconnect(connectionID: conn.id)
            }
            .buttonStyle(RelaySecondaryButtonStyle())
            .accessibilityIdentifier("oauthConnector.disconnect.\(conn.id)")
        }
        .padding(8)
        .background(RelayTheme.surface.opacity(0.35), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(RelayColors.borderSubtle, lineWidth: 1)
        )
    }

    // MARK: - Session Direct MCP Section (Preserves Existing Manual Endpoint & Token Flow)

    private var directMCPSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                RelayIconBadge(icon: "terminal.fill", color: RelayColors.accentAmethyst, size: 36, iconSize: 16)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Direct MCP Session Inspector")
                        .font(.relayHeadline)
                        .foregroundStyle(RelayColors.textPrimary)
                    Text("Connect directly to an HTTPS or loopback MCP server with an optional session bearer token to inspect read-only resources and tools.")
                        .font(.relayCaption)
                        .foregroundStyle(RelayColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            if let endpoint = connector.endpoint {
                connected(endpoint)
            } else {
                connectForm
            }
            Text(verbatim: connector.status)
                .font(.relayCaption)
                .foregroundStyle(RelayColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var connectForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("HTTPS or literal loopback MCP endpoint", text: $address)
                .textFieldStyle(.plain)
                .relayTextField()
            SecureField("Bearer token (optional)", text: $token)
                .textFieldStyle(.plain)
                .relayTextField()
            Toggle("Use 2025 Streamable HTTP compatibility", isOn: $legacyOnly)
                .toggleStyle(.switch)
                .font(.relayCaptionStrong)
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
        .padding(14)
        .background(RelayColors.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(RelayColors.borderSubtle, lineWidth: 1)
        )
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
            Toggle("Allow this connection in tasks", isOn: Binding(
                get: { connector.taskReadsEnabled }, set: { connector.setTaskReadsEnabled($0) }))
                .font(.relayCaption).disabled(busy || connector.isBusy)
            Text("Off by default. Enabling shares bounded catalog data with your configured model. Each remote read still needs its exact request review. Writes and automatic retries are unavailable.")
                .font(.relayCaption).foregroundStyle(RelayTheme.muted).fixedSize(horizontal: false, vertical: true)
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
                VStack(alignment: .leading, spacing: 8) {
                    Text("Server response").font(.system(size: 13, weight: .semibold))
                    ScrollView {
                        Text(verbatim: output)
                            .font(.relayCaption).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                    if let store {
                        ReviewedSourceQuestionView(store: store, source: output)
                    }
                }
                .padding(12)
                .background(RelayColors.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(RelayColors.borderSubtle, lineWidth: 1)
                )
            }
        }
        .onChange(of: resourceID) { _, _ in connector.clearPreview() }
        .onChange(of: toolID) { _, _ in arguments = "{}"; connector.clearPreview() }
    }

    private struct SchemaParamDescriptor: Identifiable {
        var id: String { name }
        let name: String
        let type: String
        let description: String?
        let isRequired: Bool
    }

    private func schemaParameters(for tool: DirectMCPTool) -> [SchemaParamDescriptor] {
        guard let props = tool.schema["properties"]?.object, !props.isEmpty else { return [] }
        let requiredSet: Set<String> = {
            if case .array(let items) = tool.schema["required"] {
                return Set(items.compactMap(\.string))
            }
            return []
        }()
        return props.keys.sorted().map { key in
            let propObj = props[key]?.object
            let type = propObj?["type"]?.string ?? "string"
            let desc = propObj?["description"]?.string
            return SchemaParamDescriptor(
                name: key,
                type: type,
                description: desc,
                isRequired: requiredSet.contains(key)
            )
        }
    }

    private var currentArgumentsDict: [String: JSONValue] {
        guard let data = arguments.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: data),
              let obj = decoded.object else {
            return [:]
        }
        return obj
    }

    private func updateArgumentKey(_ key: String, value: JSONValue?) {
        var dict = currentArgumentsDict
        if let value {
            dict[key] = value
        } else {
            dict.removeValue(forKey: key)
        }
        arguments = JSONValue.object(dict).pretty
    }

    private func insertDefaultForKey(_ param: SchemaParamDescriptor) {
        var dict = currentArgumentsDict
        guard dict[param.name] == nil else { return }
        let defaultVal: JSONValue = switch param.type {
        case "boolean": .bool(false)
        case "integer", "number": .number(0)
        case "array": .array([])
        case "object": .object([:])
        default: .string("")
        }
        dict[param.name] = defaultVal
        arguments = JSONValue.object(dict).pretty
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

                let params = schemaParameters(for: tool)
                if !params.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Schema parameters")
                            .font(.relayCaptionStrong)
                            .foregroundStyle(RelayColors.textSecondary)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(params) { param in
                                    let isPresent = currentArgumentsDict[param.name] != nil
                                    Button {
                                        insertDefaultForKey(param)
                                    } label: {
                                        HStack(spacing: 4) {
                                            Text(param.name + (param.isRequired ? "*" : ""))
                                                .font(.relayMonoSmall)
                                            Text(param.type)
                                                .font(.relayMicro)
                                                .foregroundStyle(RelayColors.textMuted)
                                        }
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(
                                            isPresent ? RelayColors.accentBlue.opacity(0.16) : RelayColors.surface,
                                            in: Capsule()
                                        )
                                        .overlay(
                                            Capsule().strokeBorder(
                                                isPresent ? RelayColors.accentBlue.opacity(0.5) : RelayColors.borderSubtle,
                                                lineWidth: 1
                                            )
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(connector.isBusy)
                                    .help(param.description ?? "\(param.name) (\(param.type))")
                                }
                            }
                        }

                        ForEach(params.prefix(6)) { param in
                            HStack(spacing: 8) {
                                Text(param.name + (param.isRequired ? " *" : ""))
                                    .font(.relayMonoSmall)
                                    .foregroundStyle(RelayColors.textSecondary)
                                    .frame(minWidth: 90, alignment: .leading)
                                if param.type == "boolean" {
                                    Toggle("", isOn: Binding(
                                        get: { currentArgumentsDict[param.name] == .bool(true) },
                                        set: { updateArgumentKey(param.name, value: .bool($0)) }
                                    ))
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .disabled(connector.isBusy)
                                    Spacer()
                                } else {
                                    TextField(
                                        param.description ?? param.type,
                                        text: Binding(
                                            get: {
                                                guard let val = currentArgumentsDict[param.name] else { return "" }
                                                switch val {
                                                case .string(let s): return s
                                                case .number(let n): return n.rounded() == n ? String(Int64(n)) : String(n)
                                                default: return ""
                                                }
                                            },
                                            set: { newText in
                                                if newText.isEmpty {
                                                    updateArgumentKey(param.name, value: nil)
                                                } else if param.type == "integer" || param.type == "number", let num = Double(newText) {
                                                    updateArgumentKey(param.name, value: .number(num))
                                                } else {
                                                    updateArgumentKey(param.name, value: .string(newText))
                                                }
                                            }
                                        )
                                    )
                                    .textFieldStyle(.plain)
                                    .font(.relayMonoSmall)
                                    .relayTextField(cornerRadius: 7)
                                    .disabled(connector.isBusy)
                                }
                            }
                        }
                    }
                    .padding(10)
                    .background(RelayColors.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(RelayColors.borderSubtle, lineWidth: 1)
                    )
                }

                DisclosureGroup("Input schema") {
                    ScrollView {
                        Text(verbatim: JSONValue.object(tool.schema).pretty).font(.relayMono).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 140)
                }.font(.relayCaption)
                TextField("JSON arguments", text: $arguments, axis: .vertical)
                    .font(.relayMono)
                    .lineLimit(2...5)
                    .textFieldStyle(.plain)
                    .relayTextField(cornerRadius: 8)
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
        .background(RelayTheme.line.opacity(0.24), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(RelayColors.borderSubtle, lineWidth: 1)
        )
    }
}
