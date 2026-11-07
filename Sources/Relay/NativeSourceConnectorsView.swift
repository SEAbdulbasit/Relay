import SwiftUI

/// Use Relay's source controls to capture only the current explicit app selection.
@MainActor
struct NativeSourceConnectorsView: View {
    let sources: NativePersonalSources
    let busy: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Notes and Mail")
                .font(.system(size: 15, weight: .semibold))
            Text("Select up to 8 notes or messages in the Apple app, then capture that selection here. Relay keeps the plain text for this session and omits attachments. macOS may ask for Automation access on the first capture.")
                .font(.relayCaption).foregroundStyle(RelayTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(NativePersonalSourceKind.allCases) { kind in
                connector(kind)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .relayLitCard(accent: RelayColors.accentBlue, cornerRadius: RelayTheme.radius)
    }

    private func connector(_ kind: NativePersonalSourceKind) -> some View {
        let items = sources.items(for: kind)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Label(kind.displayName, systemImage: kind == .notes ? "note.text" : "envelope")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if sources.capturing == kind {
                    ProgressView().controlSize(.small)
                    Button(sources.refreshing == kind ? "Stop refresh" : "Stop capture") { sources.cancelCapture() }
                        .buttonStyle(RelaySecondaryButtonStyle())
                } else {
                    Button("Capture selected \(kind.itemsName)") {
                        Task { await sources.captureSelection(kind) }
                    }
                    .buttonStyle(RelaySecondaryButtonStyle())
                    .disabled(busy || sources.isCapturing)
                }
                if !items.isEmpty {
                    Button("Forget") { sources.forget(kind) }
                        .buttonStyle(RelaySecondaryButtonStyle())
                        .accessibilityLabel("Forget captured \(kind.itemsName)")
                }
            }
            Text(sources.status(for: kind))
                .font(.relayCaption).foregroundStyle(RelayTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            if sources.canRefresh(kind) {
                HStack(spacing: 10) {
                    Toggle("Keep these items up to date", isOn: Binding(
                        get: { sources.isRefreshEnabled(kind) },
                        set: { sources.setRefreshEnabled($0, for: kind) }))
                        .toggleStyle(.switch)
                        .disabled(!sources.isRefreshEnabled(kind) && (busy || sources.isCapturing))
                        .help("Refreshes only the captured items once a minute while Relay runs. Capture again after Notes or Mail restarts. Text stays in this Relay session.")
                        .accessibilityIdentifier("nativeSources.autoRefresh.\(kind.rawValue)")
                    Spacer(minLength: 4)
                    Button("Refresh now") { Task { await sources.refreshCaptured(kind) } }
                        .buttonStyle(RelaySecondaryButtonStyle())
                        .disabled(busy || sources.isCapturing)
                        .accessibilityIdentifier("nativeSources.refresh.\(kind.rawValue)")
                }
                .font(.relayCaption)
            }
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .foregroundStyle(RelayTheme.ink)
                        .lineLimit(1)
                    if let date = item.sentAt ?? item.receivedAt {
                        Text((item.sentAt == nil ? "Received " : "Sent ") + date.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(RelayTheme.muted)
                    }
                }
                .font(.relayCaption)
                .textSelection(.enabled)
            }
        }
    }
}
