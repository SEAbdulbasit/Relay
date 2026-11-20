import Foundation
import ServiceManagement
import Testing
@testable import Relay

@MainActor
struct LaunchAtLoginTests {
    @Test func approvalIsReadFromMacOSAndPendingRegistrationCanBeRemoved() {
        var systemStatus: SMAppService.Status = .notRegistered
        var registrationCount = 0
        var removalCount = 0
        let loginItem = LaunchAtLogin(
            readStatus: { systemStatus },
            register: {
                registrationCount += 1
                systemStatus = .requiresApproval
            },
            unregister: {
                removalCount += 1
                systemStatus = .notRegistered
            }
        )

        loginItem.refresh()
        #expect(loginItem.status == .notRegistered)
        #expect(registrationCount == 0)

        loginItem.setEnabled(true)
        #expect(loginItem.status == .requiresApproval)
        #expect(loginItem.errorMessage == nil)
        loginItem.setEnabled(true)
        #expect(registrationCount == 1)

        loginItem.setEnabled(false)
        #expect(loginItem.status == .notRegistered)
        #expect(removalCount == 1)
    }

    @Test func registrationFailureKeepsSystemStatusAndExternalApprovalRefreshesIt() {
        var systemStatus: SMAppService.Status = .notRegistered
        let loginItem = LaunchAtLogin(
            readStatus: { systemStatus },
            register: { throw CocoaError(.fileWriteNoPermission) },
            unregister: {}
        )

        loginItem.setEnabled(true)
        #expect(loginItem.status == .notRegistered)
        #expect(loginItem.errorMessage != nil)
        loginItem.refresh()
        #expect(loginItem.errorMessage != nil)

        systemStatus = .enabled
        loginItem.refresh()
        #expect(loginItem.status == .enabled)
        #expect(loginItem.errorMessage == nil)
    }

    @Test func missingRegistrationCanBeRetriedExplicitlyWithoutAutomaticOptIn() {
        var systemStatus: SMAppService.Status = .notFound
        var registrationCount = 0
        let loginItem = LaunchAtLogin(readStatus: { systemStatus }, register: {
            registrationCount += 1
            systemStatus = .requiresApproval
        }, unregister: {})
        loginItem.refresh()
        loginItem.refresh()
        #expect(registrationCount == 0)
        loginItem.setEnabled(true)
        #expect(registrationCount == 1)
        #expect(loginItem.status == .requiresApproval)
        #expect(loginItem.errorMessage == nil)
    }

    @Test func missingRegistrationFailureRemainsVisibleAndRetryCanRecover() {
        var systemStatus: SMAppService.Status = .notFound
        var fail = true
        let loginItem = LaunchAtLogin(readStatus: { systemStatus }, register: {
            if fail { throw CocoaError(.fileNoSuchFile) }
            systemStatus = .enabled
        }, unregister: {})
        loginItem.setEnabled(true)
        #expect(loginItem.status == .notFound)
        #expect(loginItem.errorMessage != nil)
        loginItem.refresh()
        #expect(loginItem.errorMessage != nil)
        fail = false
        loginItem.setEnabled(true)
        #expect(loginItem.status == .enabled)
        #expect(loginItem.errorMessage == nil)
    }

}
