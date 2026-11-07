import AppKit
import Foundation
import Testing
@testable import Relay

struct WorkspaceSessionStateTests {
    @Test func wakingDisplaysOrSystemCannotReactivateAnInactiveUserSession() {
        var state = WorkspaceSessionState()
        #expect(state.isActive)
        state.consume(NSWorkspace.sessionDidResignActiveNotification)
        state.consume(NSWorkspace.willSleepNotification)
        state.consume(NSWorkspace.screensDidSleepNotification)
        state.consume(NSWorkspace.didWakeNotification)
        state.consume(NSWorkspace.screensDidWakeNotification)
        #expect(!state.isActive && state.interruptions == [.inactiveSession])
        state.consume(NSWorkspace.sessionDidBecomeActiveNotification)
        #expect(state.isActive)
    }

    @Test(arguments: [
        [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification],
        [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.screensDidWakeNotification],
        [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification],
        [NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.didWakeNotification],
        [NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification],
        [NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification]
    ])
    func allIndependentInterruptionsMustEndInEveryWakeOrder(_ notifications: [Notification.Name]) {
        var state = WorkspaceSessionState()
        state.suspend(.inactiveSession); state.suspend(.systemSleep); state.suspend(.screensSleep)
        for (index, notification) in notifications.enumerated() {
            let recognized = state.consume(notification)
            #expect(recognized)
            #expect(state.isActive == (index == notifications.count - 1))
        }
    }

    @Test func duplicateAndUnrelatedNotificationsNeverClearAnotherInterruption() {
        var state = WorkspaceSessionState()
        state.consume(NSWorkspace.sessionDidResignActiveNotification)
        state.consume(NSWorkspace.sessionDidResignActiveNotification)
        #expect(state.interruptions.count == 1)
        let unrelated = state.consume(Notification.Name("synthetic.unrelated"))
        #expect(!unrelated)
        state.consume(NSWorkspace.screensDidWakeNotification)
        state.consume(NSWorkspace.didWakeNotification)
        #expect(!state.isActive)
        state.consume(NSWorkspace.sessionDidBecomeActiveNotification)
        state.consume(NSWorkspace.sessionDidBecomeActiveNotification)
        #expect(state.isActive)
    }
}
