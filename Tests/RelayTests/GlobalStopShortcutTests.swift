import Testing
@testable import Relay

@MainActor
struct GlobalStopShortcutTests {
    @Test func defaultOffAndDisabledCallbacksNeverStopAnything() {
        var stops = 0
        var registrations = 0
        let shortcut = GlobalStopShortcutController(onStop: { stops += 1 }, register: { registrations += 1 }, unregister: {})
        #expect(!shortcut.enabled)
        shortcut.activateFromRegisteredShortcut()
        #expect(stops == 0)
        #expect(registrations == 0)
        shortcut.setEnabled(true)
        shortcut.setEnabled(true)
        shortcut.activateFromRegisteredShortcut()
        #expect(registrations == 1)
        #expect(stops == 1)
        shortcut.setEnabled(false)
        shortcut.activateFromRegisteredShortcut()
        #expect(stops == 1)
        #expect(!shortcut.enabled)
    }

    @Test func registrationFailureDoesNotClaimEnabledOrInvokeStop() {
        var stops = 0
        let shortcut = GlobalStopShortcutController(onStop: { stops += 1 }, register: {
            throw RelayError.message("Shortcut collision")
        }, unregister: {})
        shortcut.setEnabled(true)
        #expect(!shortcut.enabled)
        #expect(shortcut.errorMessage?.contains("collision") == true)
        shortcut.activateFromRegisteredShortcut()
        #expect(stops == 0)
    }

    @Test func unregisterFailureKeepsTruthfulEnabledStateAndCanRetry() {
        var fail = true
        var stops = 0
        let shortcut = GlobalStopShortcutController(onStop: { stops += 1 }, register: {}, unregister: {
            if fail { throw RelayError.message("Unregister failed") }
        })
        shortcut.setEnabled(true)
        shortcut.setEnabled(false)
        #expect(shortcut.enabled)
        #expect(shortcut.errorMessage != nil)
        shortcut.activateFromRegisteredShortcut()
        #expect(stops == 1)
        fail = false
        shortcut.setEnabled(false)
        #expect(!shortcut.enabled)
        #expect(shortcut.errorMessage == nil)
        shortcut.activateFromRegisteredShortcut()
        #expect(stops == 1)
    }
}
