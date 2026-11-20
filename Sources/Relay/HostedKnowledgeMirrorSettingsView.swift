import AppKit
import SwiftUI

struct HostedKnowledgeMirrorSettingsView: View {
    let mirror: HostedKnowledgeMirror
    @State private var expanded = false
    @State private var endpoint = ""
    @State private var confirmEnable = false
    @State private var confirmDisable = false
    @State private var copied = false
    @State private var provider: Provider = .claude

    private enum Provider: String, CaseIterable, Identifiable {
        case claude = "Claude"
        case chatGPT = "ChatGPT"
        case other = "Other MCP clients"

        var id: Self { self }
    }

    var body: some View {
        DisclosureGroup("Share your Markdown vault through a hosted MCP mirror", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Relay encrypts the Markdown vault on this Mac before sending it. The mirror receives the private link’s credential and can use it to decrypt the stored copy when answering requests. Anyone with the link can read, replace or delete the hosted copy.")
                Text("Relay shares Markdown under the vault folder, including writing style notes. Indexed originals, source credentials and conversation history are outside this folder.")
                    .foregroundStyle(RelayTheme.muted)
                if let host = mirror.host {
                    Text(mirror.lastSync == nil ? host : "\(host)/…/mcp")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                if let status = mirror.status {
                    Text(status)
                        .accessibilityIdentifier("hostedKnowledgeMirror.status")
                }
                if let lastSync = mirror.lastSync {
                    Text("Last synced \(lastSync.formatted(date: .abbreviated, time: .shortened))")
                }
                if mirror.isEnabled {
                    if mirror.lastSync != nil {
                        connectorSetup
                        accessActivity
                    }
                    HStack {
                        Button("Check for updates") { Task { await mirror.synchronize(immediate: true) } }
                            .disabled(mirror.isBusy)
                        Button("Stop sharing…") { confirmDisable = true }
                    }
                } else if mirror.deletionPending {
                    Button("Retry removing hosted copy") { Task { await mirror.synchronize(immediate: true) } }
                        .disabled(mirror.isBusy)
                } else {
                    TextField("Compatible mirror HTTPS origin", text: $endpoint)
                        .textFieldStyle(.plain)
                        .relayTextField()
                        .accessibilityIdentifier("hostedKnowledgeMirror.endpoint")
                    Button("Enable hosted sharing…") { confirmEnable = true }
                        .disabled((try? HostedKnowledgeMirrorTransport.origin(endpoint)) == nil || mirror.isBusy)
                }
            }
            .font(.relayCaption)
            .buttonStyle(RelaySecondaryButtonStyle())
            .padding(.top, 12)
        }
        .font(.relayCallout.weight(.medium))
        .accessibilityIdentifier("hostedKnowledgeMirror.disclosure")
        .confirmationDialog("Share your Markdown vault?", isPresented: $confirmEnable, titleVisibility: .visible) {
            Button("Encrypt and upload vault") { Task { await mirror.enable(origin: endpoint) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Relay will send your Markdown vault to \(endpoint) and sync future changes while sharing is on.")
        }
        .confirmationDialog("Stop hosted sharing?", isPresented: $confirmDisable, titleVisibility: .visible) {
            Button("Stop sharing and remove hosted copy", role: .destructive) {
                copied = false
                Task { await mirror.disable() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Relay will ask the mirror to delete its copy. Your local notes stay on this Mac.")
        }
    }

    private var connectorSetup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Connect to", selection: $provider) {
                ForEach(Provider.allCases) { choice in
                    Text(choice.rawValue).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            switch provider {
            case .claude:
                Text("In Claude on web or desktop, open Customize → Connectors and add a custom connector named Relay Knowledge. Paste the private MCP link as the server URL and choose No sign in if prompted. Enable Relay Knowledge in your conversation. To use it on your phone, sign in to the same Claude account.")
                Link("Claude connector setup", destination: URL(string: "https://support.claude.com/en/articles/11175166-get-started-with-custom-connectors-using-remote-mcp")!)
            case .chatGPT:
                Text("In ChatGPT on the web, enable developer mode where your workspace permits it. Create a custom app named Relay Knowledge, use the private MCP link as its URL, and choose No authentication if prompted. Add the app to your chat. Custom MCP apps are available on the web.")
                Link("ChatGPT custom app setup", destination: URL(string: "https://help.openai.com/en/articles/12584461-developer-mode-and-full-mcp-connectors-in-chatgpt")!)
            case .other:
                Text("In an MCP client that supports remote Streamable HTTP, add Relay Knowledge using the private link as the server URL. The link already contains the credential.")
            }
            Text("Ask the client to use Relay Knowledge to read the vault structure or a specific note. Cloud clients must be able to reach your mirror over the internet.")
                .foregroundStyle(RelayTheme.muted)
            Button(copied ? "Link copied" : "Copy private MCP link") {
                guard let url = mirror.connectorURL() else { return }
                NSPasteboard.general.clearContents()
                copied = NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
            .accessibilityIdentifier("hostedKnowledgeMirror.copyLink")
            .onChange(of: provider) { _, _ in copied = false }
        }
    }

    private var accessActivity: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let access = mirror.access {
                Text("Notes read in the last 24 hours: \(access.notesRead)")
                Text("Tool calls in the last 24 hours: \(access.toolCalls)")
                if let date = access.lastAccess {
                    Text("Last access \(date.formatted(date: .abbreviated, time: .shortened))")
                }
            } else if mirror.accessUnavailable {
                Text("Couldn’t load access activity from the mirror.")
            }
            Button(mirror.isRefreshingAccess ? "Checking access activity…" : "Check access activity") {
                Task { await mirror.refreshAccess() }
            }
            .disabled(mirror.isRefreshingAccess)
            .accessibilityIdentifier("hostedKnowledgeMirror.refreshAccess")
        }
    }
}
