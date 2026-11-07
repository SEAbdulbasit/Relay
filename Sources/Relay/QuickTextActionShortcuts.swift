import AppKit
import Carbon
import Foundation
import Observation

/// Only explicitly enabled registered hotkeys invoke a callback. There is no
/// key monitor, text capture, inference, or registration during initialization.
@Observable @MainActor
final class QuickTextActionShortcutsController {
    nonisolated enum Action: String, CaseIterable, Codable, Sendable, Identifiable {
        case summarize, proofread
        var id: Self { self }
        var title: String { self == .summarize ? "Summarize document" : "Proofread selection" }
    }
    nonisolated struct Shortcut: Codable, Equatable, Hashable, Sendable, Identifiable {
        let keyCode: UInt32
        let modifiers: UInt32
        var id: String { "\(keyCode)-\(modifiers)" }
        var title: String {
            let prefix = [(UInt32(controlKey), "⌃"), (UInt32(optionKey), "⌥"), (UInt32(shiftKey), "⇧"), (UInt32(cmdKey), "⌘")]
                .filter { modifiers & $0.0 != 0 }.map(\.1).joined()
            return prefix + ([UInt32(kVK_ANSI_Comma): ",", UInt32(kVK_ANSI_Period): ".", UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_P): "P"][keyCode] ?? "Key \(keyCode)")
        }
        static let summaryDefault = Shortcut(keyCode: UInt32(kVK_ANSI_Comma), modifiers: UInt32(cmdKey | shiftKey))
        static let proofreadDefault = Shortcut(keyCode: UInt32(kVK_ANSI_Period), modifiers: UInt32(cmdKey | shiftKey))
        static let choices: [Shortcut] = [.summaryDefault, .proofreadDefault,
            .init(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(controlKey | optionKey)),
            .init(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(controlKey | optionKey))]
        var isAllowed: Bool { Self.choices.contains(self) }
    }
    private struct Preferences: Codable { let shortcuts: [String: Shortcut]; let enabled: [String: Bool] }
    typealias Register = @MainActor (Action, Shortcut) throws -> Void
    typealias Unregister = @MainActor (Action) throws -> Void

    var onSummarize: () -> Void = {}
    var onProofread: () -> Void = {}
    private(set) var errorMessage: String?
    private(set) var enabledActions = Set<Action>()
    private(set) var shortcuts: [Action: Shortcut] = [.summarize: .summaryDefault, .proofread: .proofreadDefault]
    private var workspaceState = WorkspaceSessionState()
    var isSuspended: Bool { !workspaceState.isActive }
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let registerOverride: Register?
    @ObservationIgnored private let unregisterOverride: Unregister?
    @ObservationIgnored private let configuredNotificationCenter: NotificationCenter?
    @ObservationIgnored private let observesWorkspaceLifecycle: Bool
    @ObservationIgnored private var lifecycleCenter: NotificationCenter?
    @ObservationIgnored private var lifecycleObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var preferredEnabled = Set<Action>()
    @ObservationIgnored private var references: [Action: EventHotKeyRef] = [:]
    @ObservationIgnored private var registrationIDs: [Action: UInt32] = [:]
    @ObservationIgnored private var pendingUnregistration = Set<Action>()
    @ObservationIgnored private var registering = Set<Action>()
    @ObservationIgnored private var unregistering = Set<Action>()
    @ObservationIgnored private var registrationRevision: UInt64 = 0
    @ObservationIgnored private var nextID: UInt32 = 0
    @ObservationIgnored private var handler: EventHandlerRef?
    private static let preferenceKey = "relay.quickText.shortcuts.v1"
    private static let signature: OSType = 0x526C7951 // RlyQ

    init(defaults: UserDefaults? = .standard, register: Register? = nil, unregister: Unregister? = nil,
         workspaceNotificationCenter: NotificationCenter? = nil) {
        self.defaults = defaults
        self.registerOverride = register
        self.unregisterOverride = unregister
        self.configuredNotificationCenter = workspaceNotificationCenter
        self.observesWorkspaceLifecycle = workspaceNotificationCenter != nil || defaults === UserDefaults.standard
        if let data = defaults?.data(forKey: Self.preferenceKey), data.count <= 4_096,
           let saved = try? JSONDecoder().decode(Preferences.self, from: data) {
            for action in Action.allCases {
                if let shortcut = saved.shortcuts[action.rawValue], shortcut.isAllowed {
                    shortcuts[action] = shortcut
                    if saved.enabled[action.rawValue] == true { preferredEnabled.insert(action) }
                }
            }
            if shortcuts[.summarize] == shortcuts[.proofread] {
                shortcuts = [.summarize: .summaryDefault, .proofread: .proofreadDefault]
                preferredEnabled = []
            }
        }
    }

    /// Call only after the owner has installed callbacks. Saved enabled choices
    /// represent prior opt-in; a fresh install has no registration or capture.
    func activateSavedPreferences() {
        observeWorkspaceLifecycle()
        guard !isSuspended else { return }
        activatePreferredActions()
    }
    func isEnabled(_ action: Action) -> Bool { enabledActions.contains(action) }
    func shortcut(for action: Action) -> Shortcut { shortcuts[action] ?? (action == .summarize ? .summaryDefault : .proofreadDefault) }

    func setEnabled(_ value: Bool, for action: Action) {
        if value {
            guard !isEnabled(action) else { return }
            observeWorkspaceLifecycle()
            preferredEnabled.insert(action)
            persist()
            if isSuspended {
                return
            }
        } else {
            guard preferredEnabled.contains(action) || isEnabled(action) || pendingUnregistration.contains(action)
                    || references[action] != nil else { return }
        }
        errorMessage = nil
        do {
            if value {
                try activate(action)
            } else {
                registrationRevision &+= 1
                if isEnabled(action) || references[action] != nil { pendingUnregistration.insert(action) }
                registrationIDs.removeValue(forKey: action)
                enabledActions.remove(action)
                preferredEnabled.remove(action)
                persist()
                try unregister(action)
            }
            persist()
        } catch { errorMessage = "\(action.title) shortcut: \(error.localizedDescription)" }
    }

    /// Block callbacks before asking macOS to release any key. Desired opt-ins
    /// and choices remain saved, even when native unregistration fails.
    func suspend(for reason: WorkspaceSessionState.Interruption) {
        guard !workspaceState.interruptions.contains(reason) else { return }
        workspaceState.suspend(reason)
        suspendRegistrations()
    }

    func resume(after reason: WorkspaceSessionState.Interruption) {
        guard workspaceState.interruptions.contains(reason) else { return }
        workspaceState.resume(reason)
        if !isSuspended { activatePreferredActions() }
    }

    private func suspendRegistrations() {
        registrationRevision &+= 1
        pendingUnregistration.formUnion(enabledActions)
        pendingUnregistration.formUnion(references.keys)
        registrationIDs.removeAll()
        enabledActions.removeAll()
        var failures: [String] = []
        for action in Action.allCases where pendingUnregistration.contains(action) {
            do { try unregister(action) }
            catch { failures.append("\(action.title): \(error.localizedDescription)") }
        }
        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
    }

    private func activatePreferredActions() {
        guard !isSuspended else { return }
        var failures: [String] = []
        var cleanupFailed = Set<Action>()
        for action in Action.allCases where pendingUnregistration.contains(action) {
            do { try unregister(action) }
            catch {
                cleanupFailed.insert(action)
                failures.append("\(action.title): \(error.localizedDescription)")
            }
        }
        for action in Action.allCases where preferredEnabled.contains(action) && !isEnabled(action) && !cleanupFailed.contains(action) {
            do { try activate(action) }
            catch { failures.append("\(action.title): \(error.localizedDescription)") }
        }
        errorMessage = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    private func activate(_ action: Action) throws {
        guard !isSuspended else { return }
        guard registering.insert(action).inserted else {
            throw RelayError.message("Shortcut registration is already in progress. The action remains inactive.")
        }
        defer { registering.remove(action) }
        try unregister(action)
        guard !isSuspended else { throw RelayError.message("The user session became inactive. The shortcut remains off until resume.") }
        let shortcut = shortcut(for: action)
        guard shortcut.isAllowed else { throw RelayError.message("Choose a supported shortcut that preserves Settings and Stop.") }
        guard nextID < UInt32.max else { throw RelayError.message("The shortcut registration limit was reached. Restart Relay before enabling it again.") }
        nextID += 1
        let id = nextID
        let expected = registrationRevision
        if let registerOverride { try registerOverride(action, shortcut) }
        else { try registerNative(action, shortcut: shortcut, id: id) }
        guard !isSuspended, registrationRevision == expected, preferredEnabled.contains(action) else {
            pendingUnregistration.insert(action)
            try unregister(action)
            throw RelayError.message("The user session or shortcut changed during registration. The action remains inactive; enable it again when ready.")
        }
        registrationIDs[action] = id
        enabledActions.insert(action)
    }

    private func unregister(_ action: Action) throws {
        guard pendingUnregistration.contains(action) || references[action] != nil else { return }
        guard unregistering.insert(action).inserted else {
            throw RelayError.message("Shortcut cleanup is already in progress. The action remains inactive.")
        }
        defer { unregistering.remove(action) }
        if let unregisterOverride { try unregisterOverride(action) }
        else if let ref = references[action] {
            let status = UnregisterEventHotKey(ref)
            guard status == noErr else {
                throw RelayError.message("macOS could not release this key (\(status)). The action is inactive; try again.")
            }
        }
        references.removeValue(forKey: action)
        pendingUnregistration.remove(action)
    }

    private func observeWorkspaceLifecycle() {
        guard observesWorkspaceLifecycle, lifecycleObservers.isEmpty else { return }
        let center = configuredNotificationCenter ?? NSWorkspace.shared.notificationCenter
        lifecycleCenter = center
        lifecycleObservers = WorkspaceSessionState.notifications.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let wasActive = self.workspaceState.isActive
                    guard self.workspaceState.consume(name) else { return }
                    if !self.workspaceState.isActive { self.suspendRegistrations() }
                    else if !wasActive { self.activatePreferredActions() }
                }
            }
        }
    }

    func setShortcut(_ shortcut: Shortcut, for action: Action) {
        errorMessage = nil
        guard !isEnabled(action) else { errorMessage = "Turn off this shortcut before changing it."; return }
        guard shortcut.isAllowed else { errorMessage = "Choose one of the supported combinations. ⌘, remains Settings and ⌘. remains Stop."; return }
        guard !Action.allCases.contains(where: { $0 != action && self.shortcut(for: $0) == shortcut }) else {
            errorMessage = "Summary and proofreading need different shortcuts."; return
        }
        shortcuts[action] = shortcut
        persist()
    }

    func activateFromRegisteredShortcut(_ action: Action, registrationID: UInt32? = nil) {
        guard !isSuspended, isEnabled(action), registrationID == nil || registrationIDs[action] == registrationID else { return }
        if action == .summarize { onSummarize() } else { onProofread() }
    }

    private func persist() {
        guard let defaults else { return }
        let saved = Preferences(shortcuts: Dictionary(uniqueKeysWithValues: shortcuts.map { ($0.key.rawValue, $0.value) }),
            enabled: Dictionary(uniqueKeysWithValues: Action.allCases.map { ($0.rawValue, preferredEnabled.contains($0)) }))
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: Self.preferenceKey) }
    }

    private func registerNative(_ action: Action, shortcut: Shortcut, id: UInt32) throws {
        if handler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            var installed: EventHandlerRef?
            let status = InstallEventHandler(GetApplicationEventTarget(), Self.callback, 1, &type,
                Unmanaged.passUnretained(self).toOpaque(), &installed)
            guard status == noErr, let installed else { throw RelayError.message("macOS could not install the shortcut handler (\(status)).") }
            handler = installed
        }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            if references.isEmpty, let handler { RemoveEventHandler(handler); self.handler = nil }
            throw RelayError.message("\(shortcut.title) is unavailable (macOS \(status)). Choose a different combination; it remains off.")
        }
        references[action] = ref
    }

    nonisolated private static let callback: EventHandlerUPP = { _, event, context in
        guard let event, let context else { return OSStatus(eventNotHandledErr) }
        var id = EventHotKeyID()
        let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
            MemoryLayout<EventHotKeyID>.size, nil, &id)
        guard status == noErr, id.signature == 0x526C7951, Thread.isMainThread else { return OSStatus(eventNotHandledErr) }
        let controller = Unmanaged<QuickTextActionShortcutsController>.fromOpaque(context).takeUnretainedValue()
        let registrationID = id.id
        return MainActor.assumeIsolated {
            guard let action = controller.registrationIDs.first(where: { $0.value == registrationID })?.key else { return OSStatus(eventNotHandledErr) }
            controller.activateFromRegisteredShortcut(action, registrationID: registrationID)
            return noErr
        }
    }

    isolated deinit {
        if let lifecycleCenter { for observer in lifecycleObservers { lifecycleCenter.removeObserver(observer) } }
        for action in enabledActions.union(pendingUnregistration).union(references.keys) {
            if let unregisterOverride { try? unregisterOverride(action) }
            else if let ref = references[action] { UnregisterEventHotKey(ref) }
        }
        if let handler { RemoveEventHandler(handler) }
    }
}
