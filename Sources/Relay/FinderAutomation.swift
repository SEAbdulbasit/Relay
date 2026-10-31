import AppKit
import ApplicationServices
import Foundation

/// Qualified read-only workflow through Finder's visible Accessibility UI, not a filesystem search.
@MainActor
enum FinderAutomation {
    static func validatedQuery(_ query: String) throws -> String {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 256,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw RelayError.message("Finder search needs a nonempty single-line query up to 256 UTF-8 bytes.")
        }
        return value
    }

    static func search(query: String) async throws -> ToolResult {
        let query = try validatedQuery(query)
        guard AXIsProcessTrusted() else { throw RelayError.message("Finder search needs Accessibility permission for Relay. Enable it in System Settings → Privacy & Security → Accessibility, then retry. Nothing was typed or clicked.") }
        try Task.checkCancellation()
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") else { throw RelayError.message("Finder is not available.") }
        let finder = try await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        try Task.checkCancellation()
        let root = AXUIElementCreateApplication(finder.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.15)
        if windows(root).isEmpty {
            guard NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) else { throw RelayError.message("Could not open a Finder window.") }
        }
        var window: AXUIElement?
        for _ in 0..<20 {
            try Task.checkCancellation()
            if let candidate = windows(root).first { window = candidate; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let window else { throw RelayError.message("No accessible Finder window appeared.") }
        _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        finder.activate()
        var field = findSearchField(window)
        if field == nil {
            // Finder's standard Find command expands a collapsed search toolbar.
            for _ in 0..<20 {
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == finder.processIdentifier { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            try postKey(3, flags: .maskCommand, pid: finder.processIdentifier)
            for _ in 0..<20 {
                try Task.checkCancellation()
                field = findSearchField(window)
                if field != nil { break }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        if field == nil, let focused = attribute(root, kAXFocusedUIElementAttribute),
           CFGetTypeID(focused) == AXUIElementGetTypeID() {
            let candidate = unsafeDowncast(focused, to: AXUIElement.self)
            if value(candidate, kAXRoleAttribute) == "AXTextField" || value(candidate, kAXRoleAttribute) == "AXSearchField" {
                field = candidate
            }
        }
        guard let field else { throw RelayError.message("Finder's accessible search field was not found. Restore Search in the Finder toolbar and try again.") }
        try Task.checkCancellation()
        AXUIElementSetMessagingTimeout(field, 0.5)
        guard AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success else { throw RelayError.message("Finder search could not be focused; nothing was typed.") }
        for _ in 0..<20 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == finder.processIdentifier { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == finder.processIdentifier,
              attribute(field, kAXFocusedAttribute) as? Bool == true else {
            throw RelayError.message("Finder does not have foreground search-field focus. No keyboard input was dispatched.")
        }
        // AXValue changes alone do not send Finder's search-edit notifications. Use a bounded,
        // fixed input sequence in this qualified workflow, always targeted to Finder's PID.
        try postKey(0, flags: .maskCommand, pid: finder.processIdentifier) // Select query only.
        try postKey(51, pid: finder.processIdentifier) // Delete selected query.
        try Task.checkCancellation()
        var units = Array(query.utf16)
        guard let textDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let textUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { throw RelayError.message("Could not create Finder text input events.") }
        textDown.flags = []; textUp.flags = []
        let unitCount = units.count
        units.withUnsafeMutableBufferPointer { buffer in
            if let base = buffer.baseAddress {
                textDown.keyboardSetUnicodeString(stringLength: unitCount, unicodeString: base)
                textUp.keyboardSetUnicodeString(stringLength: unitCount, unicodeString: base)
            }
        }
        textDown.postToPid(finder.processIdentifier); textUp.postToPid(finder.processIdentifier)
        try await Task.sleep(for: .milliseconds(100))
        try Task.checkCancellation()
        guard value(field, kAXValueAttribute) == query else { throw RelayError.message("Finder did not read back the typed query exactly. Search has not been verified.") }
        try postKey(36, pid: finder.processIdentifier) // Confirm search.
        for _ in 0..<30 {
            try Task.checkCancellation()
            let currentWindow: AXUIElement
            if let focusedWindow = attribute(root, kAXFocusedWindowAttribute), CFGetTypeID(focusedWindow) == AXUIElementGetTypeID() {
                currentWindow = unsafeDowncast(focusedWindow, to: AXUIElement.self)
            } else { currentWindow = window }
            let title = value(currentWindow, kAXTitleAttribute)
            if value(field, kAXValueAttribute) == query, title.hasPrefix("Searching “"), title.hasSuffix("”") {
                return ToolResult(summary: "Started Finder search for “\(query)”.", evidence: "Finder process \(finder.processIdentifier), window “\(title)”: independent AX readback matched the query and Finder's search-results mode appeared. Results may still be loading/indexing; this does not prove a matching file exists or that all locations were searched.", verified: true)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw RelayError.message("The query was typed, but Finder did not expose a verified search-results view. The search outcome is uncertain; inspect Finder before retrying. This workflow currently verifies English Finder search controls.")
    }

    private static func postKey(_ code: CGKeyCode, flags: CGEventFlags = [], pid: pid_t) throws {
        try Task.checkCancellation()
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { throw RelayError.message("Finder lost foreground focus; fixed keyboard sequence stopped.") }
        down.flags = flags; up.flags = flags
        down.postToPid(pid); up.postToPid(pid)
    }

    private static func windows(_ root: AXUIElement) -> [AXUIElement] { attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? [] }
    private static func findSearchField(_ window: AXUIElement) -> AXUIElement? {
        descendants(window).first {
            let role = value($0, kAXRoleAttribute)
            let subrole = value($0, kAXSubroleAttribute)
            return subrole.localizedCaseInsensitiveContains("search") || role == "AXSearchField" ||
                (role == "AXTextField" && value($0, kAXRoleDescriptionAttribute).localizedCaseInsensitiveContains("search"))
        }
    }
    private static func descendants(_ root: AXUIElement) -> [AXUIElement] {
        var queue = [root]
        // Finder exposes its toolbar through AXToolbar independently of AXChildren.
        if let toolbar = attribute(root, "AXToolbar"), CFGetTypeID(toolbar) == AXUIElementGetTypeID() {
            queue.append(unsafeDowncast(toolbar, to: AXUIElement.self))
        }
        var index = 0
        let deadline = Date().addingTimeInterval(1)
        while index < queue.count && index < 300 && Date() < deadline {
            let element = queue[index]; index += 1
            AXUIElementSetMessagingTimeout(element, 0.025)
            if let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf: children.prefix(100)) }
        }
        return Array(queue.prefix(index))
    }
    private static func value(_ element: AXUIElement, _ name: String) -> String { attribute(element, name) as? String ?? "" }
    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var output: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &output) == .success ? output : nil
    }
}
