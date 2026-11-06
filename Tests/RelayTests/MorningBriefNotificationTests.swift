import Foundation
import Testing
import UserNotifications
@testable import Relay

@MainActor
struct MorningBriefNotificationTests {
    @Test func scheduledBriefOnlyAlertsAfterExplicitOptInAndWhileAuthorized() async throws {
        var authorization = UNAuthorizationStatus.notDetermined
        var prompts = 0
        var requests: [UNNotificationRequest] = []
        let notifications = MorningBriefNotifications(
            readAuthorization: { authorization },
            requestAuthorization: {
                prompts += 1
                authorization = .authorized
                return true
            },
            enqueue: { requests.append($0) }
        )

        await notifications.refresh()
        await notifications.briefPrepared()
        #expect(prompts == 0)
        #expect(requests.isEmpty)

        await notifications.enable()
        #expect(notifications.enabled)
        #expect(prompts == 1)

        await notifications.briefPrepared()
        let request = try #require(requests.first)
        #expect(request.content.title == "Your Morning Brief is ready")
        #expect(request.content.body == "Open Relay to review it in Knowledge.")
        #expect(request.content.userInfo.isEmpty)
        #expect(request.trigger == nil)

        authorization = .denied
        await notifications.briefPrepared()
        #expect(requests.count == 1)
        #expect(prompts == 1)
    }

    @Test func denialLeavesNotificationsOffAndOptOutSurvivesRelaunch() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("notification-setting.json")
        var authorization = UNAuthorizationStatus.notDetermined
        let notifications = MorningBriefNotifications(
            persistenceURL: url,
            readAuthorization: { authorization },
            requestAuthorization: {
                authorization = .denied
                return false
            },
            enqueue: { _ in Issue.record("Opted-out notifications must never be delivered") }
        )

        await notifications.enable()
        #expect(!notifications.enabled)
        #expect(notifications.authorization == .denied)
        await notifications.briefPrepared()

        authorization = .authorized
        await notifications.enable()
        #expect(MorningBriefNotifications(persistenceURL: url).enabled)
        notifications.disable()
        #expect(!MorningBriefNotifications(persistenceURL: url).enabled)
        await notifications.briefPrepared()
    }
}
