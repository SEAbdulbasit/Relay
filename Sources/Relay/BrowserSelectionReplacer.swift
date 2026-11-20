import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

/// Preserves and restores pasteboard contents across guarded temporary `Cmd+V` / `Cmd+C`
/// operations in browsers and rich web editors (`PFR-06`, `PFR-07`, `DTP-09`).
/// Never overwrites newer clipboard content if `changeCount` advanced after our write.
@MainActor
struct ClipboardSnapshot: Sendable {
    struct Entry: Sendable, Equatable {
        var typeRawValue: String
        var data: Data
    }

    struct Item: Sendable, Equatable {
        var entries: [Entry]
    }

    static let maximumItems = 16
    static let maximumTypesPerItem = 32
    static let maximumTotalBytes = 4 * 1_024 * 1_024

    let items: [Item]
    let capturedChangeCount: Int
    let truncated: Bool

    static func capture(from pasteboard: NSPasteboard = .general) -> ClipboardSnapshot {
        let changeCount = pasteboard.changeCount
        guard let rawItems = pasteboard.pasteboardItems, !rawItems.isEmpty else {
            return ClipboardSnapshot(items: [], capturedChangeCount: changeCount, truncated: false)
        }

        var captured: [Item] = []
        var remainingBytes = Self.maximumTotalBytes
        var wasTruncated = rawItems.count > Self.maximumItems

        for rawItem in rawItems.prefix(Self.maximumItems) {
            var entries: [Entry] = []
            let types = rawItem.types
            if types.count > Self.maximumTypesPerItem {
                wasTruncated = true
            }
            for type in types.prefix(Self.maximumTypesPerItem) {
                guard let data = rawItem.data(forType: type) else { continue }
                guard data.count <= remainingBytes else {
                    wasTruncated = true
                    continue
                }
                remainingBytes -= data.count
                entries.append(Entry(typeRawValue: type.rawValue, data: data))
            }
            if !entries.isEmpty {
                captured.append(Item(entries: entries))
            }
        }

        return ClipboardSnapshot(items: captured, capturedChangeCount: changeCount, truncated: wasTruncated)
    }

    /// Restores the snapshot only if `pasteboard.changeCount == ownedChangeCount`.
    /// Returns `true` when the pasteboard was restored (or cleared back to empty),
    /// and `false` if the user or another app placed newer data on the clipboard.
    @discardableResult
    func restoreIfOwned(to pasteboard: NSPasteboard = .general, ownedChangeCount: Int) -> Bool {
        guard pasteboard.changeCount == ownedChangeCount else {
            return false
        }
        pasteboard.clearContents()
        guard !items.isEmpty else {
            return true
        }
        let restoredItems: [NSPasteboardItem] = items.map { snapshotItem in
            let pbItem = NSPasteboardItem()
            for entry in snapshotItem.entries {
                pbItem.setData(entry.data, forType: NSPasteboard.PasteboardType(entry.typeRawValue))
            }
            return pbItem
        }
        return pasteboard.writeObjects(restoredItems)
    }
}

/// Verified AX-first + guarded temporary-pasteboard `Cmd+V` selection replacer and
/// unsent reply inserter for Chrome, Safari, WebKit, and Electron editors (`PFR-06`, `PFR-07`).
@MainActor
enum BrowserSelectionReplacer {
    static let maximumSelectionBytes = 12_000
    static let maximumReplacementBytes = 16_000

    enum EditableMode: String, Sendable, Equatable {
        case axWritable
        case browserEditable
        case readOnly
    }

    enum DeliveryMechanism: String, Sendable, Equatable {
        case accessibility
        case pasteboardUndoSafe
    }

    enum Outcome: Sendable, Equatable {
        case replaced(DeliveryMechanism)
        case copyOnly(reason: String)
    }

    struct Transport {
        var isProcessCurrent: @MainActor (pid_t, Date?) -> Bool
        var isFrontmost: @MainActor (pid_t) -> Bool
        var activateProcess: @MainActor (pid_t) -> Bool
        var isTargetStillValid: @MainActor () -> Bool
        var readCurrentSelectedText: @MainActor () -> String?
        var tryAXReplace: @MainActor (String) -> Bool
        var pasteboard: @MainActor () -> NSPasteboard
        var postCommandV: @MainActor () -> Bool
        var restoreDelay: Duration
    }

    static let browserBundleIdentifiers: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.google.Chrome.beta",
        "company.thebrowser.Browser",
        "company.thebrowser.dia",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
        "org.mozilla.firefox",
        "org.mozilla.nightly",
        "app.zen-browser.zen",
        "com.kagi.kagimacOS",
        "com.sigmaos.sigmaos.macos",
    ]

    static let deniedBundleIdentifiers: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty",
        "io.alacritty",
        "com.github.wez.wezterm",
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "com.dashlane.dashlanephonefinal",
        "com.apple.SecurityAgent",
    ]

    private static let deniedKeywords = [
        "password", "passcode", "passkey", "one-time", "otp", "2fa", "mfa",
        "verification code", "security code", "pin", "cvv", "cvc",
        "card number", "iban", "routing number", "ssn", "social security",
        "tax id", "secret key", "api key", "private key", "recovery key",
        "recovery phrase", "seed phrase",
    ]

    struct Target {
        let sourceAppName: String
        let bundleIdentifier: String?
        let processID: pid_t
        let launchedAt: Date?
        let selectedText: String
        let existingFieldText: String
        let editableMode: EditableMode
        let isWebContent: Bool
        private let transport: Transport

        var canReplace: Bool {
            switch editableMode {
            case .axWritable, .browserEditable:
                return !selectedText.isEmpty
            case .readOnly:
                return false
            }
        }

        var canInsertAtCaret: Bool {
            switch editableMode {
            case .axWritable, .browserEditable:
                return true
            case .readOnly:
                return false
            }
        }

        init(
            sourceAppName: String,
            bundleIdentifier: String?,
            processID: pid_t,
            launchedAt: Date?,
            selectedText: String,
            existingFieldText: String = "",
            editableMode: EditableMode,
            isWebContent: Bool,
            transport: Transport
        ) {
            self.sourceAppName = sourceAppName
            self.bundleIdentifier = bundleIdentifier
            self.processID = processID
            self.launchedAt = launchedAt
            self.selectedText = selectedText
            self.existingFieldText = existingFieldText
            self.editableMode = editableMode
            self.isWebContent = isWebContent
            self.transport = transport
        }

        /// Immediate synchronous replacement when the target app is already frontmost,
        /// scheduling non-blocking clipboard restoration after `restoreDelay`.
        /// Returns `nil` when async focus restoration is required first.
        func replaceIfFrontmost(with replacement: String) -> Outcome? {
            guard let validated = Self.validatedText(replacement) else {
                return .copyOnly(reason: "The replacement text contained unsupported control characters.")
            }
            guard canReplace else {
                return .copyOnly(reason: "This selection is read-only. Copy the reviewed text instead.")
            }
            guard transport.isProcessCurrent(processID, launchedAt) else {
                return .copyOnly(reason: "The original app closed before replacement. Copy the reviewed text instead.")
            }
            guard transport.isFrontmost(processID) else {
                return nil
            }
            return performReplacementOnFrontmostTarget(validated, requireMatchingSelection: true)
        }

        /// Full async replacement: restores focus to the original app/editor if needed,
        /// attempts verified AX write first on native controls, and falls back to
        /// undo-safe guarded pasteboard `Cmd+V` with automatic clipboard restoration.
        func replace(with replacement: String) async -> Outcome {
            guard let validated = Self.validatedText(replacement) else {
                return .copyOnly(reason: "The replacement text contained unsupported control characters.")
            }
            guard canReplace else {
                return .copyOnly(reason: "This selection is read-only. Copy the reviewed text instead.")
            }
            guard await ensureTargetFrontmost() else {
                return .copyOnly(reason: "Focus moved away from \(sourceAppName). Copy the reviewed text instead.")
            }
            return performReplacementOnFrontmostTarget(validated, requireMatchingSelection: true)
        }

        /// Inserts an unsent draft at the focused caret/selection (used by Magic Reply).
        /// Never presses Return or submits the form.
        func insertUnsentReply(_ reply: String) async -> Outcome {
            guard let validated = Self.validatedText(reply) else {
                return .copyOnly(reason: "The drafted reply contained unsupported control characters.")
            }
            guard canInsertAtCaret else {
                return .copyOnly(reason: "No editable reply field is focused in \(sourceAppName).")
            }
            guard await ensureTargetFrontmost() else {
                return .copyOnly(reason: "Focus moved away from \(sourceAppName) before inserting the draft.")
            }
            return performReplacementOnFrontmostTarget(validated, requireMatchingSelection: !selectedText.isEmpty)
        }

        private func ensureTargetFrontmost() async -> Bool {
            guard transport.isProcessCurrent(processID, launchedAt) else { return false }
            if transport.isFrontmost(processID) { return true }
            guard transport.activateProcess(processID) else { return false }
            for _ in 0..<12 {
                try? await Task.sleep(for: .milliseconds(25))
                if Task.isCancelled { return false }
                if transport.isFrontmost(processID) {
                    try? await Task.sleep(for: .milliseconds(25))
                    return transport.isProcessCurrent(processID, launchedAt)
                }
            }
            return transport.isFrontmost(processID)
        }

        private func performReplacementOnFrontmostTarget(_ text: String, requireMatchingSelection: Bool) -> Outcome {
            guard transport.isTargetStillValid() else {
                return .copyOnly(reason: "The original editor changed before replacement. Copy the reviewed text instead.")
            }
            if requireMatchingSelection {
                if let current = transport.readCurrentSelectedText(), current != selectedText {
                    return .copyOnly(reason: "The selected text in \(sourceAppName) changed before replacement. Copy the reviewed text instead.")
                }
            }

            // 1. Try verified AX range replacement first when native AX write is supported cleanly.
            if editableMode == .axWritable, !isWebContent, transport.tryAXReplace(text) {
                return .replaced(.accessibility)
            }

            // 2. Guarded temporary-pasteboard Cmd+V replacement (records single Undo step in
            // Chrome/Safari/WebKit/Electron editors and restores prior NSPasteboard items).
            let pb = transport.pasteboard()
            let snapshot = ClipboardSnapshot.capture(from: pb)
            pb.clearContents()
            guard pb.setString(text, forType: .string) else {
                return .copyOnly(reason: "Could not stage replacement text on the pasteboard.")
            }
            let ownedChangeCount = pb.changeCount

            guard transport.postCommandV() else {
                snapshot.restoreIfOwned(to: pb, ownedChangeCount: ownedChangeCount)
                return .copyOnly(reason: "Relay could not deliver Cmd+V to \(sourceAppName). Check Accessibility permission.")
            }

            let delay = transport.restoreDelay
            Task { @MainActor in
                try? await Task.sleep(for: delay)
                snapshot.restoreIfOwned(to: pb, ownedChangeCount: ownedChangeCount)
            }
            return .replaced(.pasteboardUndoSafe)
        }

        private static func validatedText(_ raw: String) -> String? {
            let trimmedCheck = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedCheck.isEmpty, raw.utf8.count <= BrowserSelectionReplacer.maximumReplacementBytes else { return nil }
            let hasForbiddenControl = raw.unicodeScalars.contains { scalar in
                guard CharacterSet.controlCharacters.contains(scalar) || scalar.value == 0x7F else { return false }
                return scalar != "\n" && scalar != "\r" && scalar != "\t"
            }
            return hasForbiddenControl ? nil : raw
        }
    }

    // MARK: - Live Capture Entry Points

    /// Captures a selection in the given (or frontmost) app, warming browser AX trees if needed
    /// and supporting both native controls and Chrome/Safari/WebKit editable fields.
    static func captureSelection(
        in application: NSRunningApplication? = nil,
        allowCopyFallback: Bool = false
    ) async -> Target? {
        guard AXIsProcessTrusted() else { return nil }
        guard let app = resolvedTargetApplication(preferred: application) else { return nil }
        let bundleID = app.bundleIdentifier
        if let bundleID, deniedBundleIdentifiers.contains(bundleID) { return nil }
        if bundleID == Bundle.main.bundleIdentifier { return nil }

        let pid = app.processIdentifier
        let launchedAt = app.launchDate
        let appName = app.localizedName ?? "App"
        let appElement = AXUIElementCreateApplication(pid)
        let isBrowser = bundleID.map { browserBundleIdentifiers.contains($0) } ?? false

        if isBrowser {
            warmBrowserAccessibility(appElement: appElement, bundleID: bundleID)
        }

        var focused = focusedElement(in: appElement)
        if focused == nil && isBrowser {
            try? await Task.sleep(for: .milliseconds(45))
            focused = focusedElement(in: appElement)
        }
        guard let element = focused else { return nil }
        guard !isDeniedOrSecureElement(element) else { return nil }

        let window = axElement(element, attribute: kAXWindowAttribute as String)
            ?? axElement(appElement, attribute: kAXFocusedWindowAttribute as String)
        let webContent = isBrowser || hasWebAreaAncestor(element)
        let mode = classifyEditableMode(element, isWebContent: webContent)

        var selected = readSelectedTextViaAX(element)
        if (selected == nil || selected?.isEmpty == true), isBrowser {
            try? await Task.sleep(for: .milliseconds(35))
            if let refreshed = focusedElement(in: appElement), !isDeniedOrSecureElement(refreshed) {
                selected = readSelectedTextViaAX(refreshed)
            }
        }
        if (selected == nil || selected?.isEmpty == true), allowCopyFallback, app.isActive {
            selected = await copySelectedTextPreservingClipboard()
        }

        guard let selectedText = selected,
              !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              selectedText.utf8.count <= Self.maximumSelectionBytes else {
            return nil
        }

        let fieldValue = axString(element, attribute: kAXValueAttribute as String) ?? ""
        let transport = makeLiveTransport(
            appElement: appElement,
            element: element,
            window: window,
            expectedSelectedText: selectedText
        )
        return Target(
            sourceAppName: appName,
            bundleIdentifier: bundleID,
            processID: pid,
            launchedAt: launchedAt,
            selectedText: selectedText,
            existingFieldText: String(fieldValue.prefix(8_000)),
            editableMode: mode,
            isWebContent: webContent,
            transport: transport
        )
    }

    /// Synchronous selection capture used by `NotchOverlayController.proofreadCurrentSelection`
    /// when a `BoundTextSelection` was already captured via AX in a browser or rich editor.
    static func captureSelectionSynchronously(
        in application: NSRunningApplication? = nil,
        fallbackSelectedText: String? = nil
    ) -> Target? {
        guard AXIsProcessTrusted() else { return nil }
        guard let app = resolvedTargetApplication(preferred: application) else { return nil }
        let bundleID = app.bundleIdentifier
        if let bundleID, deniedBundleIdentifiers.contains(bundleID) { return nil }
        if bundleID == Bundle.main.bundleIdentifier { return nil }

        let pid = app.processIdentifier
        let launchedAt = app.launchDate
        let appName = app.localizedName ?? "App"
        let appElement = AXUIElementCreateApplication(pid)
        let isBrowser = bundleID.map { browserBundleIdentifiers.contains($0) } ?? false
        if isBrowser {
            warmBrowserAccessibility(appElement: appElement, bundleID: bundleID)
        }

        guard let element = focusedElement(in: appElement),
              !isDeniedOrSecureElement(element) else { return nil }
        let window = axElement(element, attribute: kAXWindowAttribute as String)
            ?? axElement(appElement, attribute: kAXFocusedWindowAttribute as String)
        let webContent = isBrowser || hasWebAreaAncestor(element)
        let mode = classifyEditableMode(element, isWebContent: webContent)
        let selected = readSelectedTextViaAX(element) ?? fallbackSelectedText
        guard let selectedText = selected,
              !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              selectedText.utf8.count <= Self.maximumSelectionBytes else {
            return nil
        }
        let fieldValue = axString(element, attribute: kAXValueAttribute as String) ?? ""
        let transport = makeLiveTransport(
            appElement: appElement,
            element: element,
            window: window,
            expectedSelectedText: selectedText
        )
        return Target(
            sourceAppName: appName,
            bundleIdentifier: bundleID,
            processID: pid,
            launchedAt: launchedAt,
            selectedText: selectedText,
            existingFieldText: String(fieldValue.prefix(8_000)),
            editableMode: mode,
            isWebContent: webContent,
            transport: transport
        )
    }

    /// Captures a focused editable reply field (with or without selected text) for Magic Reply
    /// across native apps AND browser compose boxes (Gmail, Slack web, WhatsApp web, etc.).
    static func captureFocusedReplyField(in application: NSRunningApplication? = nil) async -> Target? {
        guard AXIsProcessTrusted() else { return nil }
        guard let app = resolvedTargetApplication(preferred: application) else { return nil }
        let bundleID = app.bundleIdentifier
        if let bundleID, deniedBundleIdentifiers.contains(bundleID) { return nil }
        if bundleID == Bundle.main.bundleIdentifier { return nil }

        let pid = app.processIdentifier
        let launchedAt = app.launchDate
        let appName = app.localizedName ?? "App"
        let appElement = AXUIElementCreateApplication(pid)
        let isBrowser = bundleID.map { browserBundleIdentifiers.contains($0) } ?? false

        if isBrowser {
            warmBrowserAccessibility(appElement: appElement, bundleID: bundleID)
        }

        var focused = focusedElement(in: appElement)
        if let candidate = focused {
            let role = axString(candidate, attribute: kAXRoleAttribute as String) ?? ""
            if isBrowser && (role == "AXWindow" || role == "AXWebArea" || role == "AXGroup") {
                try? await Task.sleep(for: .milliseconds(45))
                focused = focusedElement(in: appElement) ?? candidate
            }
        } else if isBrowser {
            try? await Task.sleep(for: .milliseconds(45))
            focused = focusedElement(in: appElement)
        }

        guard let element = focused, !isDeniedOrSecureElement(element) else { return nil }
        let window = axElement(element, attribute: kAXWindowAttribute as String)
            ?? axElement(appElement, attribute: kAXFocusedWindowAttribute as String)
        let webContent = isBrowser || hasWebAreaAncestor(element)
        var mode = classifyEditableMode(element, isWebContent: webContent)

        // In some web apps (e.g. Gmail/WhatsApp/Discord contenteditable), the focused node is an
        // AXGroup inside an editable ancestor or web area when the user placed their caret there.
        if mode == .readOnly, webContent, isLikelyWebComposeElement(element) {
            mode = .browserEditable
        }
        guard mode != .readOnly else { return nil }

        let selectedText = readSelectedTextViaAX(element) ?? ""
        let fieldValue = axString(element, attribute: kAXValueAttribute as String) ?? ""
        let transport = makeLiveTransport(
            appElement: appElement,
            element: element,
            window: window,
            expectedSelectedText: selectedText
        )
        return Target(
            sourceAppName: appName,
            bundleIdentifier: bundleID,
            processID: pid,
            launchedAt: launchedAt,
            selectedText: selectedText,
            existingFieldText: String(fieldValue.prefix(8_000)),
            editableMode: mode,
            isWebContent: webContent,
            transport: transport
        )
    }

    // MARK: - Accessibility & Event Helpers

    private static func resolvedTargetApplication(preferred: NSRunningApplication?) -> NSRunningApplication? {
        if let preferred, !preferred.isTerminated, preferred.bundleIdentifier != Bundle.main.bundleIdentifier {
            return preferred
        }
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           !frontmost.isTerminated,
           frontmost.bundleIdentifier != Bundle.main.bundleIdentifier {
            return frontmost
        }
        return nil
    }

    static func warmBrowserAccessibility(appElement: AXUIElement, bundleID: String?) {
        AXUIElementSetMessagingTimeout(appElement, 0.8)
        if bundleID == "com.apple.Safari" || bundleID == "com.apple.SafariTechnologyPreview" {
            _ = AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        } else {
            _ = AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            _ = AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }

    private static func focusedElement(in appElement: AXUIElement) -> AXUIElement? {
        AXUIElementSetMessagingTimeout(appElement, 0.8)
        if let direct = axElement(appElement, attribute: kAXFocusedUIElementAttribute as String) {
            AXUIElementSetMessagingTimeout(direct, 0.8)
            return direct
        }
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.8)
        guard let fallback = axElement(systemWide, attribute: kAXFocusedUIElementAttribute as String) else {
            return nil
        }
        var elementPID: pid_t = 0
        var appPID: pid_t = 0
        AXUIElementGetPid(fallback, &elementPID)
        AXUIElementGetPid(appElement, &appPID)
        guard elementPID == appPID else { return nil }
        AXUIElementSetMessagingTimeout(fallback, 0.8)
        return fallback
    }

    static func isDeniedOrSecureElement(_ element: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        for depth in 0..<8 {
            guard let node = current else { break }
            let role = axString(node, attribute: kAXRoleAttribute as String) ?? ""
            let subrole = axString(node, attribute: kAXSubroleAttribute as String) ?? ""
            if role == "AXSecureTextField" || subrole == "AXSecureTextField" || subrole == "AXPasswordField" {
                return true
            }
            // Search bars / URL bars are not message/proofread compose targets when depth == 0 and single-line address bar.
            if depth <= 3 {
                let labels = [
                    axString(node, attribute: kAXDescriptionAttribute as String),
                    axString(node, attribute: kAXTitleAttribute as String),
                    axString(node, attribute: kAXPlaceholderValueAttribute as String),
                    axString(node, attribute: "AXDOMIdentifier"),
                ]
                .compactMap { $0?.lowercased() }
                .joined(separator: " ")
                if deniedKeywords.contains(where: { labels.contains($0) }) {
                    return true
                }
            }
            current = axElement(node, attribute: kAXParentAttribute as String)
        }
        return false
    }

    private static func hasWebAreaAncestor(_ element: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        for _ in 0..<24 {
            guard let node = current else { return false }
            if axString(node, attribute: kAXRoleAttribute as String) == "AXWebArea" {
                return true
            }
            current = axElement(node, attribute: kAXParentAttribute as String)
        }
        return false
    }

    private static func classifyEditableMode(_ element: AXUIElement, isWebContent: Bool) -> EditableMode {
        let role = axString(element, attribute: kAXRoleAttribute as String) ?? ""
        let subrole = axString(element, attribute: kAXSubroleAttribute as String) ?? ""
        if role == "AXSecureTextField" || subrole == "AXPasswordField" || subrole == "AXSecureTextField" {
            return .readOnly
        }
        var valueSettable = DarwinBoolean(false)
        let canSetValue = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &valueSettable) == .success && valueSettable.boolValue
        var selectedSettable = DarwinBoolean(false)
        let canSetSelected = AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &selectedSettable) == .success && selectedSettable.boolValue

        let isTextRole = ["AXTextArea", "AXTextField", "AXComboBox"].contains(role)
        let hasEditableAncestor = axElement(element, attribute: "AXEditableAncestor") != nil
            || axBool(element, attribute: "AXFocused") == true && hasEditableAncestorWalk(element)

        if isWebContent {
            if isTextRole || canSetValue || canSetSelected || hasEditableAncestor {
                return .browserEditable
            }
            return .readOnly
        }

        if isTextRole && canSetSelected && canSetValue {
            return .axWritable
        }
        if isTextRole || canSetValue || canSetSelected || hasEditableAncestor {
            return .browserEditable
        }
        return .readOnly
    }

    private static func hasEditableAncestorWalk(_ element: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        for _ in 0..<10 {
            guard let node = current else { return false }
            if axElement(node, attribute: "AXEditableAncestor") != nil { return true }
            let roleDesc = (axString(node, attribute: kAXRoleDescriptionAttribute as String) ?? "").lowercased()
            if roleDesc.contains("text entry") || roleDesc.contains("editable") {
                return true
            }
            var settable = DarwinBoolean(false)
            if AXUIElementIsAttributeSettable(node, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue {
                let role = axString(node, attribute: kAXRoleAttribute as String) ?? ""
                if role != "AXWindow" && role != "AXWebArea" && role != "AXScrollArea" {
                    return true
                }
            }
            current = axElement(node, attribute: kAXParentAttribute as String)
        }
        return false
    }

    private static func isLikelyWebComposeElement(_ element: AXUIElement) -> Bool {
        let role = axString(element, attribute: kAXRoleAttribute as String) ?? ""
        guard ["AXGroup", "AXTextArea", "AXTextField", "AXGenericElement"].contains(role) else { return false }
        var current: AXUIElement? = element
        for _ in 0..<6 {
            guard let node = current else { break }
            let hints = [
                axString(node, attribute: kAXDescriptionAttribute as String),
                axString(node, attribute: kAXTitleAttribute as String),
                axString(node, attribute: kAXPlaceholderValueAttribute as String),
                axString(node, attribute: kAXRoleDescriptionAttribute as String),
            ]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
            if ["message", "reply", "compose", "write", "chat", "comment", "post", "email", "body", "textbox"].contains(where: { hints.contains($0) }) {
                return true
            }
            current = axElement(node, attribute: kAXParentAttribute as String)
        }
        return false
    }

    private static func readSelectedTextViaAX(_ element: AXUIElement) -> String? {
        if let direct = axString(element, attribute: kAXSelectedTextAttribute as String), !direct.isEmpty {
            return direct
        }
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let rangeValue = rangeRef,
           CFGetTypeID(rangeValue) == AXValueGetTypeID() {
            let axVal = unsafeBitCast(rangeValue, to: AXValue.self)
            var cfRange = CFRange()
            if AXValueGetValue(axVal, .cfRange, &cfRange), cfRange.location >= 0, cfRange.length > 0 {
                var paramRef: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(
                    element,
                    kAXStringForRangeParameterizedAttribute as CFString,
                    axVal,
                    &paramRef
                ) == .success, let str = paramRef as? String, !str.isEmpty {
                    return str
                }
                if let full = axString(element, attribute: kAXValueAttribute as String) {
                    let ns = full as NSString
                    if cfRange.location + cfRange.length <= ns.length {
                        let slice = ns.substring(with: NSRange(location: cfRange.location, length: cfRange.length))
                        if !slice.isEmpty { return slice }
                    }
                }
            }
        }
        return nil
    }

    private static func copySelectedTextPreservingClipboard() async -> String? {
        let pb = NSPasteboard.general
        let snapshot = ClipboardSnapshot.capture(from: pb)
        pb.clearContents()
        let markerCount = pb.changeCount
        guard postKeyChord(keyCode: CGKeyCode(kVK_ANSI_C), flags: .maskCommand) else {
            snapshot.restoreIfOwned(to: pb, ownedChangeCount: markerCount)
            return nil
        }
        var copied: String?
        for _ in 0..<8 {
            try? await Task.sleep(for: .milliseconds(20))
            if pb.changeCount != markerCount {
                copied = pb.string(forType: .string)
                break
            }
        }
        let afterCopyCount = pb.changeCount
        snapshot.restoreIfOwned(to: pb, ownedChangeCount: afterCopyCount)
        return copied
    }

    private static func makeLiveTransport(
        appElement: AXUIElement,
        element: AXUIElement,
        window: AXUIElement?,
        expectedSelectedText: String
    ) -> Transport {
        Transport(
            isProcessCurrent: { pid, launchedAt in
                guard let running = NSRunningApplication(processIdentifier: pid), !running.isTerminated else {
                    return false
                }
                return running.launchDate == launchedAt
            },
            isFrontmost: { pid in
                NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
            },
            activateProcess: { pid in
                guard let running = NSRunningApplication(processIdentifier: pid), !running.isTerminated else {
                    return false
                }
                let ok = running.activate()
                if let window {
                    _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                }
                _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                return ok
            },
            isTargetStillValid: {
                guard AXIsProcessTrusted(), !isDeniedOrSecureElement(element) else { return false }
                if let window,
                   let currentWindow = axElement(appElement, attribute: kAXFocusedWindowAttribute as String),
                   !CFEqual(window, currentWindow) {
                    return false
                }
                if let currentFocused = focusedElement(in: appElement) {
                    if isDeniedOrSecureElement(currentFocused) { return false }
                    if !CFEqual(element, currentFocused) {
                        // Try restoring focus to the bookmarked element inside the same window.
                        _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                        if let afterFocus = focusedElement(in: appElement), !CFEqual(element, afterFocus) {
                            // Allow child-of-element focus in rich contenteditable DOM trees.
                            if !isDescendant(afterFocus, of: element) && !isDescendant(element, of: afterFocus) {
                                return false
                            }
                        }
                    }
                }
                return true
            },
            readCurrentSelectedText: {
                readSelectedTextViaAX(element)
            },
            tryAXReplace: { replacement in
                if let current = readSelectedTextViaAX(element), !expectedSelectedText.isEmpty, current != expectedSelectedText {
                    return false
                }
                guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, replacement as CFTypeRef) == .success else {
                    return false
                }
                if let full = axString(element, attribute: kAXValueAttribute as String) {
                    return full.contains(replacement)
                }
                return true
            },
            pasteboard: { .general },
            postCommandV: {
                postKeyChord(keyCode: CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
            },
            restoreDelay: .milliseconds(500)
        )
    }

    private static func isDescendant(_ child: AXUIElement, of ancestor: AXUIElement) -> Bool {
        var current: AXUIElement? = child
        for _ in 0..<8 {
            guard let node = current else { return false }
            if CFEqual(node, ancestor) { return true }
            current = axElement(node, attribute: kAXParentAttribute as String)
        }
        return false
    }

    static func postKeyChord(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return false
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private static func axElement(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func axString(_ element: AXUIElement, attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        if let str = value as? String { return str }
        if let attr = value as? NSAttributedString { return attr.string }
        return nil
    }

    private static func axBool(_ element: AXUIElement, attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? Bool
    }
}
