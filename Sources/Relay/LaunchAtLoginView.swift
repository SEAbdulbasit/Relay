import AppKit
import Observation
import ServiceManagement
import SwiftUI

@Observable @MainActor
final class LaunchAtLogin {
    private(set) var status: SMAppService.Status?
    private(set) var errorMessage: String?

    @ObservationIgnored private let readStatus: () -> SMAppService.Status
    @ObservationIgnored private let register: () throws -> Void
    @ObservationIgnored private let unregister: () throws -> Void

    init(
        readStatus: @escaping () -> SMAppService.Status = { SMAppService.mainApp.status },
        register: @escaping () throws -> Void = {
            guard Bundle.main.bundleURL.pathExtension == "app", Bundle.main.bundleIdentifier != nil else {
                throw RelayError.message("Open Relay.app from Finder to enable login launch. A command-line build cannot register an app login item.")
            }
            try SMAppService.mainApp.register()
        },
        unregister: @escaping () throws -> Void = { try SMAppService.mainApp.unregister() }
    ) {
        self.readStatus = readStatus
        self.register = register
        self.unregister = unregister
    }

    func refresh() {
        let current = readStatus()
        if status != current { errorMessage = nil }
        status = current
    }

    func setEnabled(_ enabled: Bool) {
        refresh()
        switch (enabled, status) {
        case (true, .notRegistered), (true, .notFound), (false, .enabled), (false, .requiresApproval):
            break
        default:
            return
        }

        let failure: String?
        do {
            if enabled { try register() } else { try unregister() }
            failure = nil
        } catch {
            failure = error.localizedDescription
        }

        refresh()
        let applied = enabled ? status == .enabled || status == .requiresApproval : status == .notRegistered
        if applied {
            errorMessage = nil
        } else {
            errorMessage = failure ?? "macOS hasn’t confirmed the change. Check Login Items in System Settings."
        }
    }
}

struct LaunchAtLoginView: View {
    @State private var loginItem = LaunchAtLogin()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "power")
                    .font(RelayPageStyle.symbol)
                    .foregroundStyle(RelayColors.textSecondary)
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Open Relay at Login")
                        .font(.relayHeadline)
                        .foregroundStyle(RelayColors.textPrimary)
                    Text("Open Relay when you sign in to this Mac so scheduled preparation can resume.")
                        .font(.relayCaption)
                        .foregroundStyle(RelayColors.textSecondary)
                }
                Spacer()
                RelayBadge(
                    statusText,
                    tint: loginItem.status == .enabled ? RelayColors.accentEmerald : RelayColors.textSecondary,
                    prominent: loginItem.status == .enabled
                )
                .accessibilityIdentifier("preparation.loginItemStatus")
            }

            HStack(spacing: 10) {
                if loginItem.status == .requiresApproval || loginItem.errorMessage != nil {
                    Button("Open Login Items in System Settings") { SMAppService.openSystemSettingsLoginItems() }
                        .accessibilityIdentifier("preparation.openLoginItems")
                }

                switch loginItem.status {
                case .notRegistered, .notFound:
                    Button(loginItem.status == .notFound ? "Retry enabling at login" : "Enable at login") { loginItem.setEnabled(true) }
                        .accessibilityIdentifier("preparation.enableLoginItem")
                case .enabled:
                    Button("Disable at login") { loginItem.setEnabled(false) }
                        .accessibilityIdentifier("preparation.disableLoginItem")
                case .requiresApproval:
                    Button("Remove login item") { loginItem.setEnabled(false) }
                        .accessibilityIdentifier("preparation.disableLoginItem")
                default:
                    EmptyView()
                }
                if loginItem.status == .notFound {
                    Button("Check again") { loginItem.refresh() }
                }
                Spacer()
            }
            .buttonStyle(RelaySecondaryButtonStyle())

            if let guidance = statusGuidance {
                Text(guidance)
                    .font(.relayCaption)
                    .foregroundStyle(RelayColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let errorMessage = loginItem.errorMessage {
                Text(errorMessage)
                    .font(.relayCaption)
                    .foregroundStyle(RelayColors.accentCoral)
                    .textSelection(.enabled)
            }
        }
        .font(.relayBody)
        .onAppear { loginItem.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()
        }
    }

    private var statusText: String {
        guard let status = loginItem.status else { return "Checking the login item…" }
        switch status {
        case .notRegistered: return "Off"
        case .enabled: return "Enabled in macOS"
        case .requiresApproval: return "Approval needed"
        case .notFound: return "Registration not found"
        @unknown default: return "Unknown status"
        }
    }
    private var statusGuidance: String? {
        switch loginItem.status {
        case .requiresApproval: "Allow Relay in Login Items in System Settings to finish setup."
        case .notFound: "macOS couldn’t find Relay’s login registration. Open Relay.app from Finder, then retry enabling it. Registration may still require approval in System Settings."
        default: nil
        }
    }

}
