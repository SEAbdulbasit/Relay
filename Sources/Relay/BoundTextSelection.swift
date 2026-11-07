import AppKit
import ApplicationServices
import Foundation

/// A session-only selected-text binding. Full field contents are used only for
/// local drift checks and are never included in the inference input.
@MainActor
final class BoundTextSelection {
    nonisolated struct State: Sendable {
        let processID: Int32
        let launchedAt: Date
        let bundleID: String
        let sourceAppName: String
        let windowTitle: String
        let windowIdentity: String
        let editorIdentity: String
        let fullValue: String?
        let range: NSRange?
        let selectedText: String
        let enabled: Bool
        let writable: Bool
        let formattingSafe: Bool
        let secure: Bool
        var webContent = false

        var replacementRange: Range<String.Index>? {
            guard enabled, writable, formattingSafe, !secure, !webContent,
                  !Self.browserBundles.contains(bundleID.lowercased()),
                  let fullValue, fullValue.utf8.count <= BoundTextSelection.maximumFieldBytes,
                  let range, range.location >= 0, range.length > 0,
                  range.location <= fullValue.utf16.count,
                  range.length <= fullValue.utf16.count - range.location,
                  let indices = Range(range, in: fullValue),
                  fullValue[indices].utf16.elementsEqual(selectedText.utf16) else { return nil }
            return indices
        }

        func matches(_ other: Self) -> Bool {
            processID == other.processID && launchedAt == other.launchedAt && bundleID == other.bundleID
                && windowIdentity == other.windowIdentity && editorIdentity == other.editorIdentity
                && windowTitle.utf16.elementsEqual(other.windowTitle.utf16) && range == other.range
                && enabled == other.enabled && writable == other.writable && formattingSafe == other.formattingSafe
                && secure == other.secure && webContent == other.webContent && selectedText.utf16.elementsEqual(other.selectedText.utf16)
                && Self.sameValue(fullValue, other.fullValue)
        }

        private static func sameValue(_ left: String?, _ right: String?) -> Bool {
            switch (left, right) {
            case (.some(let left), .some(let right)): left.utf16.elementsEqual(right.utf16)
            case (.none, .none): true
            default: false
            }
        }

        private static let browserBundles: Set<String> = ["com.google.chrome", "com.google.chrome.canary", "com.apple.safari",
            "com.apple.safaritechnologypreview", "com.microsoft.edgemac", "com.brave.browser", "org.mozilla.firefox",
            "org.mozilla.nightly", "company.thebrowser.browser", "company.thebrowser.dia", "com.operasoftware.opera", "com.vivaldi.vivaldi"]
    }

    nonisolated enum ReplacementOutcome: Equatable, Sendable {
        case replaced
        case unchanged
        case copyOnly(reason: String)
        case uncertain(reason: String)
    }

    nonisolated static let maximumSelectionBytes = 8_000
    nonisolated static let maximumFieldBytes = 16_000
    nonisolated static let maximumReplacementBytes = 16_000

    private var captured: State?
    private var readCurrent: (() throws -> State)?
    private var writeSelection: ((String) throws -> Void)?
    private var attemptedReplacement = false

    var selectedText: String { captured?.selectedText ?? "" }
    var sourceAppName: String { captured?.sourceAppName ?? "" }
    var windowTitle: String { captured?.windowTitle ?? "" }
    var canReplace: Bool { !attemptedReplacement && captured?.replacementRange != nil }

    /// Tests inject a synthetic editor; production callers use capture(application:).
    init(state: State, readCurrent: @escaping () throws -> State, writeSelection: @escaping (String) throws -> Void) throws {
        guard !state.secure, state.enabled, !state.bundleID.isEmpty,
              state.processID > 0, state.launchedAt.timeIntervalSinceReferenceDate.isFinite,
              Self.usableText(state.selectedText, maximumBytes: Self.maximumSelectionBytes),
              !state.selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RelayError.message("Select readable plain text of up to 8,000 UTF-8 bytes in an ordinary app field.")
        }
        captured = state
        self.readCurrent = readCurrent
        self.writeSelection = writeSelection
    }

    /// Explicit invocation only. A supplied original app is inspected without
    /// activating it, scanning other windows, or reading the clipboard.
    static func capture(application: NSRunningApplication? = nil) throws -> BoundTextSelection {
        try Task.checkCancellation()
        let target = try NativeTarget.capture(application: application)
        let first = try target.read()
        let second = try target.read()
        guard first.matches(second) else { throw RelayError.message("The selected text changed during capture. Select it again.") }
        return try BoundTextSelection(state: second, readCurrent: { try target.read(requireForeground: true) },
                                      writeSelection: { try target.replace($0, expected: second) })
    }

    /// Called only after the exact correction has been displayed and approved.
    /// A failed or uncertain write consumes this binding and is never replayed.
    func replaceReviewed(with replacement: String) throws -> ReplacementOutcome {
        try Task.checkCancellation()
        guard !attemptedReplacement, let captured, let readCurrent, let writeSelection else {
            return .copyOnly(reason: "This selection is no longer available for replacement. Copy the correction instead.")
        }
        guard Self.usableText(replacement, maximumBytes: Self.maximumReplacementBytes),
              let fullValue = captured.fullValue, let range = captured.replacementRange else {
            return .copyOnly(reason: "This editor cannot safely replace the captured selection. Copy the correction instead.")
        }
        let current: State
        do { current = try readCurrent() }
        catch { return .copyOnly(reason: "The original app or selection is no longer current. Copy the correction instead.") }
        guard captured.matches(current), current.replacementRange != nil else {
            return .copyOnly(reason: "The original field or selection changed. Copy the correction instead.")
        }
        if replacement.utf16.elementsEqual(captured.selectedText.utf16) { return .unchanged }
        let expected = fullValue.replacingCharacters(in: range, with: replacement)
        guard expected.utf8.count <= Self.maximumFieldBytes else {
            return .copyOnly(reason: "The corrected field would exceed the complete readback limit. Copy the correction instead.")
        }
        try Task.checkCancellation()
        attemptedReplacement = true
        do { try writeSelection(replacement) }
        catch { return .uncertain(reason: "Replacement could not be confirmed. Inspect the original field before making another edit.") }
        guard !Task.isCancelled else {
            return .uncertain(reason: "Replacement may have finished before Stop. Inspect the original field; it will not be repeated.")
        }
        do {
            let after = try readCurrent()
            guard after.processID == captured.processID, after.launchedAt == captured.launchedAt,
                  after.windowIdentity == captured.windowIdentity, after.editorIdentity == captured.editorIdentity,
                  let actual = after.fullValue, actual.utf16.elementsEqual(expected.utf16) else {
                return .uncertain(reason: "The whole edited field did not match the expected text. Inspect it before another edit.")
            }
            return .replaced
        } catch { return .uncertain(reason: "The edited field could not be read back. Inspect it before another edit.") }
    }

    func clear() {
        captured = nil
        readCurrent = nil
        writeSelection = nil
        attemptedReplacement = true
    }

    nonisolated static func usableText(_ text: String, maximumBytes: Int) -> Bool {
        !text.isEmpty && text.utf8.count <= maximumBytes && !text.unicodeScalars.contains {
            $0.properties.generalCategory == .control && $0 != "\n" && $0 != "\r" && $0 != "\t"
        }
    }

    nonisolated static func requireReplacementState(expected: State, current: State) throws {
        guard expected.matches(current), expected.replacementRange != nil, current.replacementRange != nil else {
            throw RelayError.message("The exact selected field changed immediately before replacement. No new write was requested.")
        }
    }

    static func replacementFormattingIsSafe(_ attributed: NSAttributedString, selected: String) -> Bool {
        guard attributed.length > 0, attributed.string.utf16.elementsEqual(selected.utf16) else { return false }
        var first: NSDictionary?
        var safe = true
        // AXLink/AXAttachment are the values of the AX attributed-text keys;
        // Cocoa NSAttributedString uses the separate NSLink/NSAttachment keys.
        let forbidden: Set<String> = ["NSLink", "NSAttachment", "AXLink", "AXAttachment"]
        attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attributes, _, stop in
            guard !attributes.keys.contains(where: { forbidden.contains($0.rawValue) }) else { safe = false; stop.pointee = true; return }
            let current = attributes as NSDictionary
            if let first, !first.isEqual(current) { safe = false; stop.pointee = true }
            else if first == nil { first = current }
        }
        return safe
    }

    private struct NativeTarget {
        let application: NSRunningApplication
        let launchedAt: Date
        let bundleID: String
        let root: AXUIElement
        let window: AXUIElement
        let editor: AXUIElement

        static func capture(application chosen: NSRunningApplication?) throws -> Self {
            guard AXIsProcessTrusted() else { throw RelayError.message("Selected-text actions need Relay's macOS Accessibility access.") }
            guard let app = chosen ?? NSWorkspace.shared.frontmostApplication, !app.isTerminated,
                  let bundleID = app.bundleIdentifier, bundleID != Bundle.main.bundleIdentifier,
                  !protectedBundles.contains(bundleID.lowercased()), let launchedAt = app.launchDate else {
                throw RelayError.message("Choose text in an ordinary application before starting this action.")
            }
            let root = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.05)
            guard let editor = element(root, kAXFocusedUIElementAttribute), let window = element(root, kAXFocusedWindowAttribute) else {
                throw RelayError.message("The chosen app did not expose a focused text selection.")
            }
            let target = Self(application: app, launchedAt: launchedAt, bundleID: bundleID, root: root, window: window, editor: editor)
            _ = try target.validateIdentity(requireForeground: false)
            return target
        }

        func read(requireForeground: Bool = false) throws -> State {
            let webContent = try validateIdentity(requireForeground: requireForeground)
            return try readFields(webContent: webContent)
        }

        private func readFields(webContent: Bool) throws -> State {
            guard let selected = Self.attribute(editor, kAXSelectedTextAttribute) as? String,
                  selected.isEmpty || BoundTextSelection.usableText(selected, maximumBytes: BoundTextSelection.maximumSelectionBytes) else {
                throw RelayError.message("The chosen control did not expose a bounded plain-text selection.")
            }
            let rawValue = Self.attribute(editor, kAXValueAttribute) as? String
            let value = rawValue.flatMap { $0.utf8.count <= BoundTextSelection.maximumFieldBytes ? $0 : nil }
            let range = Self.selectedRange(editor)
            var settable = DarwinBoolean(false)
            let writable = AXUIElementIsAttributeSettable(editor, kAXSelectedTextAttribute as CFString, &settable) == .success && settable.boolValue
            let role = Self.attribute(editor, kAXRoleAttribute) as? String ?? ""
            return State(processID: application.processIdentifier, launchedAt: launchedAt, bundleID: bundleID,
                sourceAppName: application.localizedName ?? bundleID,
                windowTitle: String((Self.attribute(window, kAXTitleAttribute) as? String ?? "").prefix(500)),
                windowIdentity: String(CFHash(window)), editorIdentity: String(CFHash(editor)), fullValue: value, range: range,
                selectedText: selected, enabled: Self.attribute(editor, kAXEnabledAttribute) as? Bool != false,
                writable: writable, formattingSafe: ["AXTextArea", "AXTextField"].contains(role) && Self.plainFormatting(editor, range: range, selected: selected), secure: false,
                webContent: webContent)
        }

        func replace(_ text: String, expected: State) throws {
            try Task.checkCancellation()
            let webContent = try validateIdentity(requireForeground: true)
            // The hierarchy validation above may take time. Read field bytes and
            // selected range again after it, immediately before the single write.
            try BoundTextSelection.requireReplacementState(expected: expected, current: readFields(webContent: webContent))
            try Task.checkCancellation()
            AXUIElementSetMessagingTimeout(editor, 0.3)
            guard AXUIElementSetAttributeValue(editor, kAXSelectedTextAttribute as CFString, text as CFString) == .success else {
                throw RelayError.message("The editor did not confirm the selected-text write.")
            }
        }

        private func validateIdentity(requireForeground: Bool) throws -> Bool {
            try Task.checkCancellation()
            guard AXIsProcessTrusted(), !application.isTerminated, application.launchDate == launchedAt,
                  application.bundleIdentifier == bundleID,
                  !requireForeground || NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier,
                  let currentWindow = Self.element(root, kAXFocusedWindowAttribute), CFEqual(currentWindow, window),
                  let currentEditor = Self.element(root, kAXFocusedUIElementAttribute), CFEqual(currentEditor, editor) else {
                throw RelayError.message("The original application, window or text field is no longer current.")
            }
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(500))
            var current: AXUIElement? = editor
            var seen: [AXUIElement] = []
            var webContent = false
            for _ in 0..<20 {
                guard ContinuousClock.now < deadline, let node = current, !seen.contains(where: { CFEqual($0, node) }) else { break }
                seen.append(node)
                AXUIElementSetMessagingTimeout(node, 0.05)
                var pid: pid_t = 0
                guard AXUIElementGetPid(node, &pid) == .success, pid == application.processIdentifier else { break }
                let role = Self.attribute(node, kAXRoleAttribute) as? String ?? ""
                if ["AXWebArea", "AXHTMLArea", "AXHTMLContent"].contains(role) { webContent = true }
                let subrole = Self.attribute(node, kAXSubroleAttribute) as? String ?? ""
                let label = [kAXDescriptionAttribute, kAXTitleAttribute, kAXIdentifierAttribute, kAXPlaceholderValueAttribute]
                    .map { Self.attribute(node, $0) as? String ?? "" }.joined(separator: " ")
                guard !role.isEmpty else { break }
                try QuickSelectionCapture.validateControl(role: role, subrole: subrole, label: label,
                    isModal: Self.attribute(node, kAXModalAttribute) as? Bool == true)
                guard !["passcode", "one-time code", "security code", "credit card", "secret key", "recovery phrase"].contains(where: label.lowercased().contains) else {
                    throw RelayError.message("Selected-text actions are unavailable in protected fields.")
                }
                if CFEqual(node, window) { return webContent }
                current = Self.element(node, kAXParentAttribute)
            }
            throw RelayError.message("The selection's window context could not be checked completely.")
        }

        private static func plainFormatting(_ editor: AXUIElement, range: NSRange?, selected: String) -> Bool {
            guard let range, range.length > 0, varValueRangeFits(range) else { return false }
            var capturedRange = cfRange(range)
            guard let axRange = AXValueCreate(.cfRange, &capturedRange) else { return false }
            var result: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(editor, kAXAttributedStringForRangeParameterizedAttribute as CFString,
                    axRange, &result) == .success, let attributed = result as? NSAttributedString,
                  attributed.length == range.length else { return false }
            return BoundTextSelection.replacementFormattingIsSafe(attributed, selected: selected)
        }

        private static func varValueRangeFits(_ range: NSRange) -> Bool { range.location >= 0 && range.length > 0 && range.location <= Int.max - range.length }
        private static func cfRange(_ range: NSRange) -> CFRange { CFRange(location: range.location, length: range.length) }
        private static func selectedRange(_ editor: AXUIElement) -> NSRange? {
            guard let value = attribute(editor, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
            var range = CFRange()
            guard AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cfRange, &range), range.location >= 0, range.length >= 0 else { return nil }
            return NSRange(location: range.location, length: range.length)
        }
        private static func attribute(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(node, name as CFString, &value) == .success ? value : nil
        }
        private static func element(_ node: AXUIElement, _ name: String) -> AXUIElement? {
            guard let value = attribute(node, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return unsafeDowncast(value, to: AXUIElement.self)
        }
        private static let protectedBundles: Set<String> = ["com.apple.terminal", "com.googlecode.iterm2", "dev.warp.warp-stable",
            "com.apple.systempreferences", "com.apple.passwords", "com.apple.keychainaccess", "com.1password.1password", "com.bitwarden.desktop"]
    }
}
