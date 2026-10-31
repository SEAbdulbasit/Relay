import Foundation
import Testing
@testable import Relay

@MainActor
struct QuickAccessTests {
    @Test func optInRegistersOnceAndDoesNotActivateUntilRequested() {
        var registrations = 0
        var removals = 0
        var activations = 0
        let controller = QuickAccessController(onActivate: { activations += 1 }, register: { registrations += 1 }, unregister: { removals += 1 })
        #expect(!controller.enabled)
        #expect(registrations == 0)
        controller.activateFromRegisteredShortcut()
        #expect(activations == 0)
        controller.setEnabled(true)
        controller.setEnabled(true)
        #expect(controller.enabled)
        #expect(registrations == 1)
        #expect(activations == 0)
        controller.activateFromRegisteredShortcut()
        #expect(activations == 1)
        controller.setEnabled(false)
        controller.setEnabled(false)
        controller.activateFromRegisteredShortcut()
        #expect(removals == 1)
        #expect(activations == 1)
    }

    @Test func shortcutCollisionFailsWithoutActivationOrFalseEnabledState() {
        var activations = 0
        let controller = QuickAccessController(onActivate: { activations += 1 }, register: { throw RelayError.message("Shortcut already in use") })
        controller.setEnabled(true)
        #expect(!controller.enabled)
        #expect(controller.errorMessage == "Shortcut already in use")
        controller.activateFromRegisteredShortcut()
        #expect(activations == 0)
    }

    @Test func failedUnregisterDoesNotClaimShortcutIsOff() {
        var fail = true
        let controller = QuickAccessController(register: {}, unregister: { if fail { throw RelayError.message("Cannot unregister") } })
        controller.setEnabled(true)
        controller.setEnabled(false)
        #expect(controller.enabled)
        #expect(controller.errorMessage != nil)
        fail = false
        controller.setEnabled(false)
        #expect(!controller.enabled)
        #expect(controller.errorMessage == nil)
    }

    @Test func selectionIsBoundedAndKeepsSourceProvenance() throws {
        let text = "  A selected café excerpt 🌍  "
        let snapshot = try QuickSelectionCapture.validatedSnapshot(text: text, sourceBundleID: "test.fixture", sourceAppName: "Fixture", windowTitle: "Test document")
        #expect(snapshot.text == text)
        #expect(snapshot.sourceBundleID == "test.fixture")
        #expect(snapshot.sourceAppName == "Fixture")
        #expect(snapshot.windowTitle == "Test document")
        #expect(throws: (any Error).self) { try QuickSelectionCapture.validatedSnapshot(text: " \n", sourceBundleID: "fixture", sourceAppName: "", windowTitle: "") }
        #expect(throws: (any Error).self) { try QuickSelectionCapture.validatedSnapshot(text: String(repeating: "🌍", count: 2_001), sourceBundleID: "fixture", sourceAppName: "", windowTitle: "") }
        #expect(throws: (any Error).self) { try QuickSelectionCapture.validatedSnapshot(text: "text", sourceBundleID: "", sourceAppName: "", windowTitle: "") }
    }

    @Test func secureAndModalControlsRefuseSelectionCapture() throws {
        try QuickSelectionCapture.validateControl(role: "AXTextArea", subrole: "", label: "Notes", isModal: false)
        for (role, subrole, label, modal) in [("AXTextField", "AXSecureTextField", "", false), ("AXTextField", "", "Password", false), ("AXSheet", "", "", false), ("AXWindow", "AXDialog", "", false), ("AXWindow", "", "", true)] {
            #expect(throws: (any Error).self) { try QuickSelectionCapture.validateControl(role: role, subrole: subrole, label: label, isModal: modal) }
        }
    }
}
