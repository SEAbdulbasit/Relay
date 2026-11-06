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
        register: @escaping () throws -> Void = { try SMAppService.mainApp.register() },
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
        case (true, .notRegistered), (false, .enabled), (false, .requiresApproval):
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
        VStack(alignment: .leading, spacing: 7) {
            Text("Open Relay at login")
                .font(.system(size: 14, weight: .semibold))
            Text("Open Relay when you sign in to this Mac so scheduled preparation can resume.")
            Text(statusText)
                .accessibilityIdentifier("preparation.loginItemStatus")

            VStack(alignment: .leading, spacing: 8) {
                if loginItem.status == .requiresApproval || loginItem.errorMessage != nil {
                    Button("Open Login Items in System Settings") { SMAppService.openSystemSettingsLoginItems() }
                        .accessibilityIdentifier("preparation.openLoginItems")
                }

                switch loginItem.status {
                case .notRegistered:
                    Button("Enable at login") { loginItem.setEnabled(true) }
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
            }
            .buttonStyle(RelaySecondaryButtonStyle())

            if let errorMessage = loginItem.errorMessage {
                Text(errorMessage).textSelection(.enabled)
            }
        }
        .font(.system(size: 14))
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
        case .requiresApproval: return "Allow Relay in Login Items in System Settings to finish setup."
        case .notFound: return "macOS couldn’t find Relay’s login item. Reopen Relay from its app bundle and try again."
        @unknown default: return "macOS reported an unknown login item status."
        }
    }
}
