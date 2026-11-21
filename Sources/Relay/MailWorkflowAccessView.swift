import SwiftUI

struct MailWorkflowAccessView: View {
    let busy: Bool
    @State private var requesting = false
    @State private var status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "envelope")
                    .font(RelayPageStyle.symbol)
                    .foregroundStyle(RelayColors.textSecondary)
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Apple Mail Actions")
                        .font(RelayPageStyle.sectionTitle)
                        .foregroundStyle(RelayColors.textPrimary)
                    Text("Create a plain-text draft using an existing Mail account, then review its exact sender, recipients, and contents before sending.")
                        .font(RelayPageStyle.caption)
                        .foregroundStyle(RelayColors.textSecondary)
                }
                Spacer()
                Button(requesting ? "Requesting access…" : "Allow Apple Mail actions") {
                    requesting = true
                    Task {
                        defer { requesting = false }
                        do {
                            try await MailWorkflowAppleEvents.requestAccess()
                            status = "The Automation permission request completed. Each draft and send still requires your exact review."
                        } catch { status = error.localizedDescription }
                    }
                }
                .buttonStyle(RelaySecondaryButtonStyle())
                .disabled(busy || requesting)
                .accessibilityIdentifier("mailWorkflow.requestAccess")
            }

            Text("Open Apple Mail first. macOS Automation access is required. Drafts may sync through the account configured in Mail.")
                .font(RelayPageStyle.caption)
                .foregroundStyle(RelayColors.textMuted)

            if let status {
                Text(status)
                    .font(RelayPageStyle.caption)
                    .foregroundStyle(RelayColors.textSecondary)
            }
        }
        .relayFormSection()
    }
}
