import AppKit
import ApplicationServices
import Carbon
import Foundation
import Observation

/// An opt-in registered shortcut, not a keyboard event monitor or background recorder.
@Observable @MainActor
final class QuickAccessController {
    private(set) var enabled = false
    private(set) var status = "Quick access is off."
    private(set) var errorMessage: String?
    var onActivate: () -> Void

    @ObservationIgnored private var hotKey: EventHotKeyRef?
    @ObservationIgnored private var handler: EventHandlerRef?
    @ObservationIgnored private let registerOverride: (() throws -> Void)?
    @ObservationIgnored private let unregisterOverride: (() throws -> Void)?
    private static let signature: OSType = 0x526C7948 // RlyH

    init(onActivate: @escaping () -> Void = {},
         register: (() throws -> Void)? = nil,
         unregister: (() throws -> Void)? = nil) {
        self.onActivate = onActivate
        registerOverride = register
        unregisterOverride = unregister
    }

    func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        errorMessage = nil
        do {
            if value {
                if let registerOverride { try registerOverride() }
                else { try registerCarbon() }
                enabled = true
                status = "Quick access on · ⌘⇧Space"
            } else {
                if let unregisterOverride { try unregisterOverride() }
                else { try unregisterCarbon() }
                enabled = false
                status = "Quick access is off."
            }
        } catch {
            errorMessage = error.localizedDescription
            status = enabled ? "Could not turn off quick access. Try again." : "Shortcut unavailable. Quick access remains off."
        }
    }

    /// Carbon's callback only requests the UI callback. It never reads context or runs tools.
    func activateFromRegisteredShortcut() {
        guard enabled else { return }
        onActivate()
    }

    private func registerCarbon() throws {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        var newHandler: EventHandlerRef?
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), Self.carbonHandler, 1, &event, context, &newHandler)
        guard installed == noErr else { throw RelayError.message("macOS could not install the quick-access shortcut handler (\(installed)).") }
        var newKey: EventHotKeyRef?
        let keyID = EventHotKeyID(signature: Self.signature, id: 1)
        let registered = RegisterEventHotKey(UInt32(kVK_Space), UInt32(cmdKey | shiftKey), keyID, GetApplicationEventTarget(), 0, &newKey)
        guard registered == noErr, let newKey else {
            if let newHandler { RemoveEventHandler(newHandler) }
            throw RelayError.message("⌘⇧Space could not be registered (macOS \(registered)). Another app may already use this shortcut. Quick access has not been enabled.")
        }
        handler = newHandler
        hotKey = newKey
    }

    private func unregisterCarbon() throws {
        if let hotKey {
            let result = UnregisterEventHotKey(hotKey)
            guard result == noErr else { throw RelayError.message("macOS could not unregister ⌘⇧Space (\(result)).") }
            self.hotKey = nil
        }
        if let handler { RemoveEventHandler(handler); self.handler = nil }
    }

    nonisolated private static let carbonHandler: EventHandlerUPP = { _, event, context in
        guard let event, let context else { return OSStatus(eventNotHandledErr) }
        var keyID = EventHotKeyID()
        let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                       MemoryLayout<EventHotKeyID>.size, nil, &keyID)
        guard result == noErr, keyID.signature == 0x526C7948, keyID.id == 1 else { return OSStatus(eventNotHandledErr) }
        let controller = Unmanaged<QuickAccessController>.fromOpaque(context).takeUnretainedValue()
        Task { @MainActor in controller.activateFromRegisteredShortcut() }
        return noErr
    }

    isolated deinit {
        if enabled {
            if let unregisterOverride { try? unregisterOverride() }
            else { try? unregisterCarbon() }
        }
    }
}

nonisolated struct SelectedTextSnapshot: Sendable {
    let text: String
    let sourceBundleID: String
    let sourceAppName: String
    let windowTitle: String
    let capturedAt: Date
}

/// Explicit selection capture only. Calling this helper is a user-triggered action, not a
/// side effect of registering the hotkey. It never captures screenshots or secure fields.
@MainActor
enum QuickSelectionCapture {
    static func capture() throws -> SelectedTextSnapshot {
        guard AXIsProcessTrusted() else { throw RelayError.message("Selected text needs Relay's Accessibility permission. No text was captured.") }
        guard let app = NSWorkspace.shared.frontmostApplication, let bundleID = app.bundleIdentifier else {
            throw RelayError.message("The frontmost app could not be identified. No text was captured.")
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.2)
        guard let focused = element(root, kAXFocusedUIElementAttribute) else { throw RelayError.message("The current app exposes no focused selection.") }
        var current: AXUIElement? = focused
        var visited = Set<CFHashCode>()
        var title = ""
        var reachedWindow = false
        for _ in 0..<20 {
            guard let node = current, visited.insert(CFHash(node)).inserted else { break }
            AXUIElementSetMessagingTimeout(node, 0.1)
            let role = string(node, kAXRoleAttribute)
            let subrole = string(node, kAXSubroleAttribute)
            let label = string(node, kAXDescriptionAttribute)
            try validateControl(role: role, subrole: subrole, label: label,
                                isModal: attribute(node, kAXModalAttribute) as? Bool == true)
            if role == "AXWindow" { title = string(node, kAXTitleAttribute); reachedWindow = true; break }
            current = element(node, kAXParentAttribute)
        }
        guard reachedWindow else { throw RelayError.message("The selection's window context could not be checked completely. Nothing was captured.") }
        guard let selected = attribute(focused, kAXSelectedTextAttribute) as? String else {
            throw RelayError.message("The focused control does not expose selected text. Nothing was captured.")
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            throw RelayError.message("The frontmost app changed during capture. The selection was discarded.")
        }
        return try validatedSnapshot(text: selected, sourceBundleID: bundleID,
                                     sourceAppName: app.localizedName ?? bundleID, windowTitle: title)
    }

    nonisolated static func validateControl(role: String, subrole: String, label: String, isModal: Bool) throws {
        let identity = [role, subrole, label].joined(separator: " ").lowercased()
        guard !isModal, !["AXSheet", "AXDialog"].contains(role),
              !identity.contains("secure"), !identity.contains("password"), !subrole.localizedCaseInsensitiveContains("dialog") else {
            throw RelayError.message("Selection capture is unavailable in secure fields or modal dialogs. Nothing was captured.")
        }
    }

    nonisolated static func validatedSnapshot(text: String, sourceBundleID: String, sourceAppName: String, windowTitle: String) throws -> SelectedTextSnapshot {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RelayError.message("Select some text first. Nothing was captured.") }
        guard text.utf8.count <= 8_000 else { throw RelayError.message("The selection is over 8,000 UTF-8 bytes. Select a shorter excerpt; nothing was captured.") }
        guard !sourceBundleID.isEmpty else { throw RelayError.message("Selection provenance is missing. Nothing was captured.") }
        return SelectedTextSnapshot(text: text, sourceBundleID: sourceBundleID, sourceAppName: sourceAppName,
                                    windowTitle: String(windowTitle.prefix(500)), capturedAt: Date())
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    private static func string(_ element: AXUIElement, _ name: String) -> String { attribute(element, name) as? String ?? "" }
    private static func element(_ node: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(node, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }
}
