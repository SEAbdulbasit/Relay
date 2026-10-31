import Carbon
import Foundation
import Observation

/// Explicit registration only. No event tap, key monitor, capture or background execution.
@Observable @MainActor
final class GlobalStopShortcutController {
    private(set) var enabled = false
    private(set) var status = "Global Stop is off."
    private(set) var errorMessage: String?
    var onStop: () -> Void

    @ObservationIgnored private var hotKey: EventHotKeyRef?
    @ObservationIgnored private var handler: EventHandlerRef?
    @ObservationIgnored private let registerOverride: (() throws -> Void)?
    @ObservationIgnored private let unregisterOverride: (() throws -> Void)?
    private static let signature: OSType = 0x526C7953 // RlyS; distinct from Quick Access RlyH.

    init(onStop: @escaping () -> Void = {}, register: (() throws -> Void)? = nil,
         unregister: (() throws -> Void)? = nil) {
        self.onStop = onStop
        registerOverride = register
        unregisterOverride = unregister
    }

    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        errorMessage = nil
        do {
            if value {
                if let registerOverride { try registerOverride() }
                else { try registerCarbon() }
                enabled = true
                status = "Global Stop on · ⌘⇧Escape"
            } else {
                if let unregisterOverride { try unregisterOverride() }
                else { try unregisterCarbon() }
                enabled = false
                status = "Global Stop is off."
            }
        } catch {
            errorMessage = error.localizedDescription
            status = enabled ? "Could not unregister Global Stop. Try again." : "Global Stop shortcut unavailable; it remains off."
        }
    }

    /// Queued callbacks must recheck opt-in state before touching the task.
    func activateFromRegisteredShortcut() {
        guard enabled else { return }
        onStop()
    }

    private func registerCarbon() throws {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        var newHandler: EventHandlerRef?
        let installed = InstallEventHandler(GetApplicationEventTarget(), Self.carbonHandler, 1, &event,
                                           Unmanaged.passUnretained(self).toOpaque(), &newHandler)
        guard installed == noErr, let newHandler else {
            throw RelayError.message("macOS could not install the Global Stop handler (\(installed)).")
        }
        var newKey: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: Self.signature, id: 1)
        let registered = RegisterEventHotKey(UInt32(kVK_Escape), UInt32(cmdKey | shiftKey), identifier,
                                            GetApplicationEventTarget(), 0, &newKey)
        guard registered == noErr, let newKey else {
            RemoveEventHandler(newHandler)
            throw RelayError.message("⌘⇧Escape could not be registered (macOS \(registered)). Another app may already use it. Global Stop remains off.")
        }
        handler = newHandler
        hotKey = newKey
    }

    private func unregisterCarbon() throws {
        if let hotKey {
            let result = UnregisterEventHotKey(hotKey)
            guard result == noErr else { throw RelayError.message("macOS could not unregister Global Stop (\(result)).") }
            self.hotKey = nil
        }
        if let handler {
            let result = RemoveEventHandler(handler)
            guard result == noErr else { throw RelayError.message("macOS could not remove the Global Stop handler (\(result)).") }
            self.handler = nil
        }
    }

    nonisolated private static let carbonHandler: EventHandlerUPP = { _, event, context in
        guard let event, let context else { return OSStatus(eventNotHandledErr) }
        var identifier = EventHotKeyID()
        let read = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
        guard read == noErr, identifier.signature == 0x526C7953, identifier.id == 1 else {
            return OSStatus(eventNotHandledErr)
        }
        // Application Carbon handlers are delivered by the application's main event loop.
        // Acquire the reference there, then guard enabled again when the queued action runs.
        guard Thread.isMainThread else { return OSStatus(eventNotHandledErr) }
        let controller = Unmanaged<GlobalStopShortcutController>.fromOpaque(context).takeUnretainedValue()
        Task { @MainActor [weak controller] in controller?.activateFromRegisteredShortcut() }
        return noErr
    }

    isolated deinit {
        if let unregisterOverride {
            if enabled { try? unregisterOverride() }
        } else {
            if let hotKey { UnregisterEventHotKey(hotKey) }
            if let handler { RemoveEventHandler(handler) }
        }
    }
}
