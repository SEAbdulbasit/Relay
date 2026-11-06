import SwiftUI

struct WorkspaceCodexOption: View {
    let store: AssistantStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "cloud")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(RelayColors.accentBlue)
                    .frame(width: 30, height: 30)
                    .background(RelayColors.accentBlue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)
                Text("ChatGPT via Codex CLI")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                if store.workspaceUsesCodex {
                    Label("Active this session", systemImage: "checkmark.circle.fill")
                        .font(.relayCaption)
                        .foregroundStyle(RelayColors.accentEmerald)
                }
            }

            Text("Use your existing ChatGPT sign-in for workspace requests and Mac app actions. No Relay account or local model download is required.")
                .font(.system(size: 13))
                .foregroundStyle(RelayTheme.ink)
                .fixedSize(horizontal: false, vertical: true)

            Text("OpenAI receives the request and action status. Relay asks before sharing an app list or visible app or webpage text. Files, calendar, knowledge and screenshots use the local model.")
                .font(.relayCaption)
                .foregroundStyle(RelayColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                if store.workspaceUsesCodex {
                    Button("Use Local Model") { store.selectWorkspaceLocal() }
                        .buttonStyle(RelaySecondaryButtonStyle())
                } else {
                    Button(store.checkingCodex ? "Checking Sign-in…" : "Use ChatGPT") {
                        Task { await store.selectWorkspaceCodex() }
                    }
                    .buttonStyle(RelayPrimaryButtonStyle())
                    if store.checkingCodex { ProgressView().controlSize(.small) }
                }
            }
            .disabled(store.isRunning || store.voice.isBusy || store.checkingCodex)

            if let status = store.codexStatus, !store.workspaceUsesCodex {
                Text(status)
                    .font(.relayCaption)
                    .foregroundStyle(RelayColors.textSecondary)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .relayLitCard(accent: RelayColors.accentBlue, cornerRadius: RelayTheme.radius)
    }
}
