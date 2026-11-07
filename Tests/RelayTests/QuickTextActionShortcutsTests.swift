import AppKit
import Carbon
import Foundation
import Testing
@testable import Relay

@MainActor
struct QuickTextActionShortcutsTests {
    @Test func freshDefaultsDoNotRegisterOrCaptureAndOnlyEnabledCallbacksCanFire() {
        var registered: [QuickTextActionShortcutsController.Action] = [], callbacks: [String] = []
        let shortcuts = QuickTextActionShortcutsController(defaults: nil, register: { action, _ in registered.append(action) }, unregister: { _ in })
        shortcuts.onSummarize = { callbacks.append("summary") }
        shortcuts.onProofread = { callbacks.append("proofread") }
        #expect(registered.isEmpty && shortcuts.enabledActions.isEmpty)
        shortcuts.activateFromRegisteredShortcut(.summarize)
        #expect(callbacks.isEmpty)
        shortcuts.setEnabled(true, for: .summarize)
        shortcuts.activateFromRegisteredShortcut(.summarize)
        shortcuts.activateFromRegisteredShortcut(.proofread)
        #expect(callbacks == ["summary"] && registered == [.summarize])
        shortcuts.setEnabled(false, for: .summarize)
        shortcuts.activateFromRegisteredShortcut(.summarize)
        #expect(callbacks == ["summary"])
    }

    @Test func reservedAndCollidingShortcutsCannotReplaceSettingsStopOrQuickAccess() {
        let shortcuts = QuickTextActionShortcutsController(defaults: nil, register: { _, _ in }, unregister: { _ in })
        let original = shortcuts.shortcut(for: .summarize)
        for (key, modifiers) in [(UInt32(kVK_ANSI_Comma), UInt32(cmdKey)), (UInt32(kVK_ANSI_Period), UInt32(cmdKey)),
                                (UInt32(kVK_Space), UInt32(cmdKey | shiftKey)), (UInt32(kVK_Escape), UInt32(cmdKey | shiftKey))] {
            shortcuts.setShortcut(.init(keyCode: key, modifiers: modifiers), for: .summarize)
            #expect(shortcuts.shortcut(for: .summarize) == original && shortcuts.errorMessage != nil)
        }
        shortcuts.setShortcut(.proofreadDefault, for: .summarize)
        #expect(shortcuts.shortcut(for: .summarize) == original && shortcuts.errorMessage != nil)
        let alternative = QuickTextActionShortcutsController.Shortcut.choices[2]
        shortcuts.setShortcut(alternative, for: .summarize)
        #expect(shortcuts.shortcut(for: .summarize) == alternative)
        shortcuts.setEnabled(true, for: .summarize)
        shortcuts.setShortcut(original, for: .summarize)
        #expect(shortcuts.shortcut(for: .summarize) == alternative && shortcuts.errorMessage != nil)
    }

    @Test func failedRegistrationAndFailedUnregistrationKeepStateHonest() {
        let failures = RegistrationFailures()
        let shortcuts = QuickTextActionShortcutsController(defaults: nil, register: { _, _ in
            if failures.registration { throw RelayError.message("Synthetic registration unavailable") }
        }, unregister: { _ in if failures.unregistration { throw RelayError.message("Synthetic unregister failure") } })
        shortcuts.setEnabled(true, for: .proofread)
        #expect(!shortcuts.isEnabled(.proofread) && shortcuts.errorMessage != nil)
        failures.registration = false
        shortcuts.setEnabled(true, for: .proofread)
        #expect(shortcuts.isEnabled(.proofread))
        failures.unregistration = true
        shortcuts.setEnabled(false, for: .proofread)
        #expect(!shortcuts.isEnabled(.proofread) && shortcuts.errorMessage != nil)
        failures.unregistration = false
        shortcuts.setEnabled(false, for: .proofread)
        #expect(!shortcuts.isEnabled(.proofread))
    }

    private final class RegistrationFailures {
        var registration = true
        var unregistration = false
    }

    @Test func savedOptInWaitsForExplicitActivationAfterCallbacksAreInstalled() throws {
        let name = "relay.summary.shortcuts.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let first = QuickTextActionShortcutsController(defaults: defaults, register: { _, _ in }, unregister: { _ in })
        let chosen = QuickTextActionShortcutsController.Shortcut.choices[2]
        first.setShortcut(chosen, for: .summarize)
        first.setEnabled(true, for: .summarize)
        var restoredRegistrations = 0, calls = 0
        let restored = QuickTextActionShortcutsController(defaults: defaults, register: { _, shortcut in
            #expect(shortcut == chosen); restoredRegistrations += 1
        }, unregister: { _ in })
        #expect(restoredRegistrations == 0 && restored.enabledActions.isEmpty)
        restored.onSummarize = { calls += 1 }
        restored.activateSavedPreferences()
        restored.activateFromRegisteredShortcut(.summarize)
        #expect(restoredRegistrations == 1 && calls == 1)
        restored.setEnabled(false, for: .summarize)
        restored.setEnabled(true, for: .summarize)
        restored.activateFromRegisteredShortcut(.summarize, registrationID: 1)
        #expect(calls == 1, "A callback queued for the old registration must remain invalid after re-enabling")
    }

    @Test func invalidSavedShortcutCannotEnableAFallbackCombination() throws {
        let name = "relay.summary.shortcuts.invalid.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let data = try JSONSerialization.data(withJSONObject: [
            "shortcuts": ["summarize": ["keyCode": Int(kVK_ANSI_Comma), "modifiers": Int(cmdKey)]],
            "enabled": ["summarize": true]
        ])
        defaults.set(data, forKey: "relay.quickText.shortcuts.v1")
        var registrations = 0
        let shortcuts = QuickTextActionShortcutsController(defaults: defaults, register: { _, _ in registrations += 1 }, unregister: { _ in })
        shortcuts.activateSavedPreferences()
        #expect(registrations == 0 && !shortcuts.isEnabled(.summarize))
    }

    @Test func lifecycleObserversWaitForExplicitActivationAndResumeNeverInvokesAnAction() {
        let center = NotificationCenter(), probe = LifecycleProbe()
        let shortcuts = probe.controller(center: center)
        center.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        #expect(!shortcuts.isSuspended && probe.registrations.isEmpty)
        shortcuts.activateSavedPreferences()
        center.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        #expect(shortcuts.isSuspended)
        shortcuts.setEnabled(true, for: .summarize)
        #expect(!shortcuts.isEnabled(.summarize) && probe.registrations.isEmpty)
        center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        #expect(shortcuts.isSuspended && probe.registrations.isEmpty)
        center.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        #expect(!shortcuts.isSuspended && shortcuts.isEnabled(.summarize))
        #expect(probe.registrations == [.summarize] && probe.callbacks.isEmpty)
    }

    @Test(arguments: [
        (NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification),
        (NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification),
        (NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification)
    ])
    func everyInterruptionBlocksQueuedCallbacksAndResumeUsesFreshIDs(_ notifications: (Notification.Name, Notification.Name)) {
        let center = NotificationCenter(), probe = LifecycleProbe()
        let shortcuts = probe.controller(center: center)
        shortcuts.activateSavedPreferences()
        shortcuts.setEnabled(true, for: .summarize)
        shortcuts.activateFromRegisteredShortcut(.summarize, registrationID: 1)
        #expect(probe.callbacks == [.summarize])
        center.post(name: notifications.0, object: nil)
        shortcuts.activateFromRegisteredShortcut(.summarize, registrationID: 1)
        shortcuts.activateFromRegisteredShortcut(.summarize)
        #expect(shortcuts.isSuspended && !shortcuts.isEnabled(.summarize))
        #expect(probe.callbacks == [.summarize] && probe.unregistrations == [.summarize])
        center.post(name: notifications.1, object: nil)
        #expect(shortcuts.isEnabled(.summarize) && probe.registrations == [.summarize, .summarize])
        #expect(probe.callbacks == [.summarize], "Resume may register keys, never capture text or invoke actions.")
        shortcuts.activateFromRegisteredShortcut(.summarize, registrationID: 1)
        #expect(probe.callbacks == [.summarize])
        shortcuts.activateFromRegisteredShortcut(.summarize, registrationID: 2)
        #expect(probe.callbacks == [.summarize, .summarize])
    }

    @Test func overlappingInterruptionsDoNotResumeUntilTheUserAndAllDisplaysAreActive() {
        let center = NotificationCenter(), probe = LifecycleProbe()
        let shortcuts = probe.controller(center: center)
        shortcuts.activateSavedPreferences()
        shortcuts.setEnabled(true, for: .summarize); shortcuts.setEnabled(true, for: .proofread)
        for notification in [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.willSleepNotification,
                             NSWorkspace.screensDidSleepNotification] { center.post(name: notification, object: nil) }
        for notification in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            center.post(name: notification, object: nil)
            #expect(shortcuts.isSuspended && shortcuts.enabledActions.isEmpty)
        }
        #expect(probe.registrations.count == 2 && probe.unregistrations.count == 2)
        center.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        #expect(!shortcuts.isSuspended && shortcuts.enabledActions == [.summarize, .proofread])
        shortcuts.activateFromRegisteredShortcut(.summarize, registrationID: 1)
        shortcuts.activateFromRegisteredShortcut(.proofread, registrationID: 2)
        #expect(probe.callbacks.isEmpty)
        shortcuts.activateFromRegisteredShortcut(.summarize, registrationID: 3)
        shortcuts.activateFromRegisteredShortcut(.proofread, registrationID: 4)
        #expect(probe.callbacks == [.summarize, .proofread])
    }

    @Test func suspensionPreservesTheSavedOptInAndChoiceButExplicitOptOutPreventsResume() throws {
        let name = "relay.summary.shortcuts.lifecycle.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let probe = LifecycleProbe(), shortcuts = probe.controller(defaults: defaults, center: NotificationCenter())
        let choice = QuickTextActionShortcutsController.Shortcut.choices[2]
        shortcuts.setShortcut(choice, for: .summarize)
        shortcuts.setEnabled(true, for: .summarize)
        let saved = defaults.data(forKey: "relay.quickText.shortcuts.v1")
        shortcuts.suspend(for: .inactiveSession)
        #expect(defaults.data(forKey: "relay.quickText.shortcuts.v1") == saved)
        let restoredProbe = LifecycleProbe(), restored = restoredProbe.controller(defaults: defaults)
        restored.activateSavedPreferences()
        #expect(restored.isEnabled(.summarize) && restored.shortcut(for: .summarize) == choice)
        shortcuts.setEnabled(false, for: .summarize)
        shortcuts.resume(after: .inactiveSession)
        #expect(shortcuts.enabledActions.isEmpty && probe.registrations.count == 1)
        let optedOut = LifecycleProbe().controller(defaults: defaults)
        optedOut.activateSavedPreferences()
        #expect(optedOut.enabledActions.isEmpty)
    }

    @Test func failedSuspendUnregistrationNeverReenablesOldIDsAndBlocksResumeUntilCleanup() {
        let probe = LifecycleProbe(), shortcuts = probe.controller()
        shortcuts.setEnabled(true, for: .summarize)
        probe.failUnregister = true
        probe.onUnregister = { probe.shortcut?.activateFromRegisteredShortcut(.summarize, registrationID: 1) }
        shortcuts.suspend(for: .systemSleep)
        #expect(shortcuts.isSuspended && shortcuts.enabledActions.isEmpty && shortcuts.errorMessage != nil)
        #expect(probe.callbacks.isEmpty)
        shortcuts.resume(after: .systemSleep)
        #expect(!shortcuts.isSuspended && shortcuts.enabledActions.isEmpty && shortcuts.errorMessage != nil)
        #expect(probe.registrations.count == 1)
        probe.failUnregister = false
        shortcuts.setEnabled(true, for: .summarize)
        shortcuts.activateFromRegisteredShortcut(.summarize, registrationID: 1)
        #expect(probe.callbacks.isEmpty)
        shortcuts.activateFromRegisteredShortcut(.summarize, registrationID: 2)
        #expect(shortcuts.isEnabled(.summarize) && probe.callbacks == [.summarize])
    }

    @Test func failedResumeRegistrationLeavesTheActionInactiveAndRetriesWithAnotherFreshID() {
        let probe = LifecycleProbe(), shortcuts = probe.controller()
        shortcuts.setEnabled(true, for: .summarize)
        shortcuts.suspend(for: .screensSleep)
        probe.failRegister = true
        shortcuts.resume(after: .screensSleep)
        #expect(shortcuts.enabledActions.isEmpty && shortcuts.errorMessage != nil)
        shortcuts.activateFromRegisteredShortcut(.summarize, registrationID: 1)
        shortcuts.activateFromRegisteredShortcut(.summarize, registrationID: 2)
        #expect(probe.callbacks.isEmpty)
        probe.failRegister = false
        shortcuts.setEnabled(true, for: .summarize)
        shortcuts.activateFromRegisteredShortcut(.summarize, registrationID: 2)
        #expect(probe.callbacks.isEmpty)
        shortcuts.activateFromRegisteredShortcut(.summarize, registrationID: 3)
        #expect(probe.callbacks == [.summarize])
    }

    @Test func aSessionChangeDuringRegistrationCannotCommitThatOldRegistration() {
        let center = NotificationCenter(), probe = LifecycleProbe()
        let shortcuts = probe.controller(center: center)
        probe.onRegister = {
            probe.onRegister = nil
            center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        }
        shortcuts.setEnabled(true, for: .summarize)
        #expect(shortcuts.isSuspended && shortcuts.enabledActions.isEmpty && shortcuts.errorMessage != nil)
        shortcuts.activateFromRegisteredShortcut(.summarize, registrationID: 1)
        #expect(probe.callbacks.isEmpty && probe.unregistrations == [.summarize])
        center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        shortcuts.activateFromRegisteredShortcut(.summarize, registrationID: 1)
        #expect(probe.callbacks.isEmpty)
        shortcuts.activateFromRegisteredShortcut(.summarize, registrationID: 2)
        #expect(probe.callbacks == [.summarize])
    }

    @Test func nestedIndependentRegistrationKeepsEachActionsOwnAllocatedID() {
        let probe = LifecycleProbe(), shortcuts = probe.controller()
        probe.onRegister = {
            probe.onRegister = nil
            probe.shortcut?.setEnabled(true, for: .proofread)
        }
        shortcuts.setEnabled(true, for: .summarize)
        shortcuts.activateFromRegisteredShortcut(.summarize, registrationID: 1)
        shortcuts.activateFromRegisteredShortcut(.proofread, registrationID: 2)
        #expect(probe.callbacks == [.summarize, .proofread])
    }

    @Test func controllerDeinitializationRemovesItsSyntheticObserversAndReleasesActiveKeys() {
        let center = NotificationCenter(), probe = LifecycleProbe()
        var shortcuts: QuickTextActionShortcutsController? = probe.controller(center: center)
        shortcuts?.activateSavedPreferences()
        shortcuts?.setEnabled(true, for: .summarize)
        weak var released = shortcuts
        shortcuts = nil
        #expect(released == nil && probe.unregistrations == [.summarize])
        center.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        center.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        #expect(probe.registrations == [.summarize] && probe.callbacks.isEmpty)
    }

    @MainActor private final class LifecycleProbe {
        weak var shortcut: QuickTextActionShortcutsController?
        var registrations: [QuickTextActionShortcutsController.Action] = []
        var unregistrations: [QuickTextActionShortcutsController.Action] = []
        var callbacks: [QuickTextActionShortcutsController.Action] = []
        var failRegister = false, failUnregister = false
        var onRegister: (@MainActor () -> Void)?, onUnregister: (@MainActor () -> Void)?

        func controller(defaults: UserDefaults? = nil, center: NotificationCenter? = nil) -> QuickTextActionShortcutsController {
            let controller = QuickTextActionShortcutsController(defaults: defaults, register: { [self] action, _ in
                registrations.append(action)
                onRegister?()
                if failRegister { throw RelayError.message("Synthetic registration unavailable") }
            }, unregister: { [self] action in
                unregistrations.append(action)
                onUnregister?()
                if failUnregister { throw RelayError.message("Synthetic unregister failure") }
            }, workspaceNotificationCenter: center)
            shortcut = controller
            controller.onSummarize = { [self] in callbacks.append(.summarize) }
            controller.onProofread = { [self] in callbacks.append(.proofread) }
            return controller
        }
    }
}
