import AppKit
import SwiftUI

struct LocalKnowledgeMCPSettingsView: View {
    @Bindable var server: LocalKnowledgeMCPServer
    private let vault: KnowledgeVaultManager
    @State private var expanded = false
    @State private var notes: [LocalMarkdownNote] = []
    @State private var selected: Set<URL> = []
    @State private var feedback: String?

    init(server: LocalKnowledgeMCPServer, vault: KnowledgeVaultManager = .shared) {
        self.server = server
        self.vault = vault
    }

    var body: some View {
        DisclosureGroup("Share selected notes with a local MCP client", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Choose up to \(LocalKnowledgeMCPServer.maximumNotes) Vault notes. A client on this Mac with the access token can read their Markdown for up to 15 minutes. Sharing ends when this Mac sleeps or you stop it.")
                Text(server.status)
                    .accessibilityIdentifier("knowledgeSharing.status")
                if server.isActive {
                    activeShare
                } else {
                    noteSelection
                }
                if let feedback {
                    Text(feedback)
                        .accessibilityIdentifier("knowledgeSharing.feedback")
                }
            }
            .font(.system(size: 14))
            .padding(.top, 12)
        }
        .onChange(of: expanded) { _, value in if value, !server.isActive { refresh() } }
        .accessibilityIdentifier("knowledgeSharing.disclosure")
    }

    private var activeShare: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let url = server.endpoint {
                Text(url.absoluteString)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                Text("Use Streamable HTTP. Send the token as a Bearer credential in the Authorization header.")
                HStack {
                    Button("Copy endpoint") { copy(url.absoluteString, label: "Endpoint copied.") }
                    if let token = server.token {
                        Button("Copy access token") { copy(token, label: "Access token copied.") }
                    }
                }
                .buttonStyle(RelaySecondaryButtonStyle())
            }
            if let expiry = server.expiresAt {
                Text("Sharing ends at \(expiry.formatted(date: .omitted, time: .shortened)).")
            }
            Button("Stop sharing") {
                server.stop()
                selected.removeAll()
                refresh()
            }
            .buttonStyle(RelaySecondaryButtonStyle())
            .accessibilityIdentifier("knowledgeSharing.stop")
        }
    }

    private var noteSelection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if notes.isEmpty {
                Text("Create a Vault note to share it.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(notes) { note in
                            Toggle(isOn: Binding(get: { selected.contains(note.id) }, set: { value in
                                if value { selected.insert(note.id) }
                                else { selected.remove(note.id) }
                            })) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(note.title)
                                    if !note.body.isEmpty {
                                        Text(String(decoding: note.body.utf8.prefix(140), as: UTF8.self))
                                            .font(.caption)
                                            .foregroundStyle(RelayTheme.muted)
                                            .lineLimit(2)
                                    }
                                }
                            }
                            .disabled(selected.count >= LocalKnowledgeMCPServer.maximumNotes && !selected.contains(note.id))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
            }
            HStack {
                Button("Refresh notes") { refresh() }
                    .buttonStyle(RelaySecondaryButtonStyle())
                Button("Start local sharing") { start() }
                    .buttonStyle(RelayPrimaryButtonStyle())
                    .disabled(selected.isEmpty)
                    .accessibilityIdentifier("knowledgeSharing.start")
            }
        }
    }

    private func refresh() {
        do {
            let current = try vault.loadNotes()
            let unchanged = Set(current.filter(notes.contains).map(\.id))
            selected.formIntersection(unchanged)
            notes = current
            feedback = nil
        } catch {
            selected.removeAll()
            notes = []
            feedback = "Relay couldn’t load the local Vault notes."
        }
    }

    private func start() {
        do {
            try server.start(notes: notes.filter { selected.contains($0.id) })
            feedback = nil
        } catch {
            feedback = error.localizedDescription
        }
    }

    private func copy(_ value: String, label: String) {
        let clipboard = NSPasteboard.general
        clipboard.clearContents()
        feedback = clipboard.setString(value, forType: .string) ? label : "The item couldn’t be copied."
    }
}
