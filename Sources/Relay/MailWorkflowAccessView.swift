import SwiftUI

struct MailWorkflowAccessView: View {
    let busy: Bool
    @State private var requesting = false
    @State private var status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Apple Mail actions").font(.relayHeadline.weight(.semibold))
            Text("Create a plain-text draft using an existing Mail account, then review its exact sender, recipients and contents before sending.")
                .font(.relayBody)
            Text("Open Apple Mail first. macOS Automation access is required. Drafts may sync through the account configured in Mail.")
                .font(.relayCaption).foregroundStyle(RelayColors.textSecondary)
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
            if let status { Text(status).font(.relayCaption).foregroundStyle(RelayColors.textSecondary) }
        }
        .padding(20)
        .relayGlassCard(cornerRadius: RelayTheme.radius)
    }
}
