import AppKit
import Observation
import SwiftUI
import UserNotifications

@Observable @MainActor
final class MorningBriefNotifications {
    private(set) var enabled = false
    private(set) var authorization: UNAuthorizationStatus?
    private(set) var isRequesting = false
    private(set) var errorMessage: String?

    @ObservationIgnored private let persistenceURL: URL?
    @ObservationIgnored private let readAuthorization: @MainActor () async -> UNAuthorizationStatus?
    @ObservationIgnored private let requestAuthorization: @MainActor () async throws -> Bool
    @ObservationIgnored private let enqueue: @MainActor (UNNotificationRequest) async throws -> Void

    init(
        persistenceURL: URL? = nil,
        readAuthorization: @escaping @MainActor () async -> UNAuthorizationStatus? = {
            guard let center = MorningBriefNotifications.systemCenter else { return nil }
            return await withCheckedContinuation { continuation in
                center.getNotificationSettings { @Sendable settings in
                    continuation.resume(returning: settings.authorizationStatus)
                }
            }
        },
        requestAuthorization: @escaping @MainActor () async throws -> Bool = {
            try await MorningBriefNotifications.systemCenter?.requestAuthorization(options: [.alert]) ?? false
        },
        enqueue: @escaping @MainActor (UNNotificationRequest) async throws -> Void = {
            try await MorningBriefNotifications.systemCenter?.add($0)
        }
    ) {
        self.persistenceURL = persistenceURL
        self.readAuthorization = readAuthorization
        self.requestAuthorization = requestAuthorization
        self.enqueue = enqueue
        if let persistenceURL, let data = try? LocalStateFile.read(persistenceURL, maximumBytes: 8) {
            enabled = (try? JSONDecoder().decode(Bool.self, from: data)) ?? false
        }
    }

    private static var systemCenter: UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        return .current()
    }

    var mayDeliver: Bool { authorization == .authorized || authorization == .provisional }

    func refresh() async {
        authorization = await readAuthorization()
    }

    func enable() async {
        guard !isRequesting else { return }
        isRequesting = true
        defer { isRequesting = false }
        errorMessage = nil
        await refresh()
        do {
            if authorization == .notDetermined {
                _ = try await requestAuthorization()
                await refresh()
            }
            if mayDeliver, !enabled { try saveEnabled(true) }
        } catch {
            errorMessage = "Relay couldn’t enable Morning Brief notifications. " + error.localizedDescription
        }
    }

    func disable() {
        guard !isRequesting else { return }
        do {
            try saveEnabled(false)
            errorMessage = nil
        } catch {
            errorMessage = "Relay couldn’t save the change to Morning Brief notifications. " + error.localizedDescription
        }
    }

    func briefPrepared() async {
        guard enabled else { return }
        await refresh()
        guard enabled, mayDeliver else { return }

        let content = UNMutableNotificationContent()
        content.title = "Your Morning Brief is ready"
        content.body = "Open Relay to review it in Knowledge."
        do {
            try await enqueue(UNNotificationRequest(identifier: "relay.morningBrief.ready", content: content, trigger: nil))
            errorMessage = nil
        } catch {
            errorMessage = "Relay prepared the Morning Brief but couldn’t deliver its notification. " + error.localizedDescription
        }
    }

    private func saveEnabled(_ enabled: Bool) throws {
        if let persistenceURL {
            try FileManager.default.createDirectory(at: persistenceURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try LocalPrivateFileWriter.write(data: JSONEncoder().encode(enabled), to: persistenceURL, maximumBytes: 8)
        }
        self.enabled = enabled
    }
}

struct MorningBriefNotificationView: View {
    let notifications: MorningBriefNotifications

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Morning Brief notifications")
                .font(.system(size: 14, weight: .semibold))
            Text("Show a macOS notification when a scheduled brief is ready to review.")
            if notifications.authorization == .denied {
                Text("Allow notifications for Relay in System Settings › Notifications.")
                    .accessibilityIdentifier("preparation.briefNotificationPermission")
            } else if notifications.enabled, notifications.mayDeliver {
                Text("Enabled")
                    .accessibilityIdentifier("preparation.briefNotificationStatus")
            }
            if notifications.enabled {
                Button("Turn off brief notifications") { notifications.disable() }
                    .disabled(notifications.isRequesting)
                    .accessibilityIdentifier("preparation.disableBriefNotifications")
            }
            if !notifications.enabled || notifications.authorization == .notDetermined {
                Button("Enable brief notifications") { Task { await notifications.enable() } }
                    .disabled(notifications.authorization == nil || notifications.authorization == .denied || notifications.isRequesting)
                    .accessibilityIdentifier("preparation.enableBriefNotifications")
            }
            if let error = notifications.errorMessage { Text(error).textSelection(.enabled) }
        }
        .font(.system(size: 14))
        .buttonStyle(RelaySecondaryButtonStyle())
        .task { await notifications.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await notifications.refresh() }
        }
    }
}
