import AppKit
import ApplicationServices
import Foundation

/// Qualified read-only workflow through Finder's visible Accessibility UI, not a filesystem search.
@MainActor
enum FinderAutomation {
    static func validatedQuery(_ query: String) throws -> String {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 256,
              !value.unicodeScalars.contains(where: { $0.properties.generalCategory == .control || CharacterSet.newlines.contains($0) }) else {
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
        var targetWindow: AXUIElement?
        for _ in 0..<20 {
            try Task.checkCancellation()
            if let focused = element(root, kAXFocusedWindowAttribute) { targetWindow = focused; break }
            let available = windows(root)
            if available.count == 1 { targetWindow = available[0]; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let window = targetWindow else { throw RelayError.message("Finder did not expose one target window. Focus the Finder window you want to search, then retry.") }
        let pid = finder.processIdentifier
        AXUIElementSetMessagingTimeout(window, 0.15)
        _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        finder.activate()
        for _ in 0..<20 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
               let focused = element(root, kAXFocusedWindowAttribute), CFEqual(window, focused) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try requireFocusedWindow(root: root, window: window, pid: pid)

        var candidate = focusedSearchField(root: root, window: window)
        if candidate == nil {
            // Finder's Find command exposes and focuses its toolbar search field.
            try postCommand(.find, pid: pid) {
                try requireFocusedWindow(root: root, window: window, pid: pid)
            }
            for _ in 0..<20 {
                try requireFocusedWindow(root: root, window: window, pid: pid)
                candidate = focusedSearchField(root: root, window: window)
                if candidate != nil { break }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        guard let field = candidate, let original = attribute(field, kAXValueAttribute) as? String else {
            throw RelayError.message("Finder did not expose a focused toolbar search field. Open Find in the intended Finder window and try again. No query was typed.")
        }

        if original != query {
            func requireUnchangedSearchField() throws {
                guard attribute(field, kAXValueAttribute) as? String == original,
                      attribute(field, kAXFocusedAttribute) as? Bool == true else {
                    throw RelayError.message("Finder’s search field or its query changed. Inspect Finder before retrying. No further input was sent.")
                }
                try requireFocusedWindow(root: root, window: window, pid: pid)
                guard let focused = element(root, kAXFocusedUIElementAttribute), CFEqual(field, focused) else {
                    throw RelayError.message("Finder’s focused search field or its query changed. Inspect Finder before retrying. No further input was sent.")
                }
            }
            try requireUnchangedSearchField()
            if !wholeQuerySelected(value: original, range: selectedRange(field)) {
                try selectQuery(field, value: original, pid: pid, validate: requireUnchangedSearchField)
            }
            for _ in 0..<10 {
                try requireUnchangedSearchField()
                if wholeQuerySelected(value: original, range: selectedRange(field)) { break }
                try await Task.sleep(for: .milliseconds(40))
            }
            // A Unicode edit replaces only the verified selection and lets Finder
            // receive its ordinary search-edit notification. Delete and Return are unsafe here.
            try postText(query, pid: pid) {
                guard wholeQuerySelected(value: original, range: selectedRange(field)) else {
                    throw RelayError.message("Finder did not expose a complete selection of the old query. No replacement text was sent.")
                }
                try requireUnchangedSearchField()
            }
        }

        for _ in 0..<30 {
            try requireFocusedWindow(root: root, window: window, pid: pid)
            let title = value(window, kAXTitleAttribute)
            if value(field, kAXValueAttribute) == query, isSearchResultsView(title: title) {
                var matchingName = false
                let resultDeadline = Date().addingTimeInterval(1)
                repeat {
                    try requireFocusedWindow(root: root, window: window, pid: pid)
                    guard value(field, kAXValueAttribute) == query,
                          value(window, kAXTitleAttribute) == title else { break }
                    matchingName = visibleExactResult(query: query, window: window, deadline: resultDeadline)
                    if matchingName || Date() >= resultDeadline { break }
                    try await Task.sleep(for: .milliseconds(100))
                } while Date() < resultDeadline
                try requireFocusedWindow(root: root, window: window, pid: pid)
                guard value(field, kAXValueAttribute) == query, value(window, kAXTitleAttribute) == title else {
                    throw RelayError.message("Finder's query or results window changed during verification. Inspect the current search before retrying.")
                }
                let outcome = matchingName
                    ? "A visible result is named “\(query)”; it was not opened or modified."
                    : "A matching file has not been verified."
                return ToolResult(summary: "Finder’s search field contains “\(query)”. \(outcome)", evidence: "Finder process \(pid), window “\(title)”: independent AX readback matched the query and Finder's search-results mode appeared. \(outcome) Results may still be loading/indexing; this does not prove a matching file exists when no exact result is visible.", verified: true)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        try requireFocusedWindow(root: root, window: window, pid: pid)
        let queryMatches = value(field, kAXValueAttribute) == query
        return ToolResult(summary: queryMatches ? "Finder’s search field contains “\(query)”, but the results view could not be verified." : "The Finder search query could not be verified.",
                          evidence: "Inspect Finder before retrying. This workflow verifies English Finder search mode. No confirmation key was sent.", verified: false)
    }

    static func isSearchResultsView(title: String) -> Bool {
        title.hasPrefix("Searching “") && title.hasSuffix("”")
    }

    static func isSearchControl(role: String, subrole: String, roleDescription: String,
                                inToolbar: Bool, enabled: Bool, hidden: Bool) -> Bool {
        let description = roleDescription.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return inToolbar && enabled && !hidden && subrole != "AXSecureTextField" && (role == "AXSearchField" ||
            (role == "AXTextField" && (subrole == "AXSearchField" || ["search field", "search text field"].contains(description))))
    }

    static func wholeQuerySelected(value: String, range: CFRange?) -> Bool {
        guard let range else { return false }
        return range.location == 0 && range.length == value.utf16.count
    }

    /// Positive evidence only: a search can match file contents or substrings, and
    /// a bounded result snapshot cannot establish absence from the computer.
    static func isExactVisibleFilename(query: String, role: String, labels: [String],
                                       insideResults: Bool, hidden: Bool) -> Bool {
        insideResults && !hidden && ["AXImage", "AXStaticText"].contains(role)
            && labels.contains(query)
    }

    static func isResultContainer(role: String, identifier: String) -> Bool {
        role == "AXTable" || (role == "AXCollection")
            || (role == "AXList" && ["IconView", "ListView"].contains(identifier))
    }

    private static func visibleExactResult(query: String, window: AXUIElement, deadline: Date) -> Bool {
        var queue: [(AXUIElement, Bool)] = [(window, false)]
        var visited: [AXUIElement] = []
        var cursor = 0
        while cursor < queue.count, cursor < 250, Date() < deadline {
            let (element, inResults) = queue[cursor]; cursor += 1
            guard !visited.contains(where: { CFEqual($0, element) }) else { continue }
            visited.append(element)
            AXUIElementSetMessagingTimeout(element, 0.01)
            guard attribute(element, "AXHidden") as? Bool != true else { continue }
            let role = value(element, kAXRoleAttribute)
            // Inspect result collections/tables only; never enter sidebar outlines,
            // toolbars, editable search fields, dialogs, or file preview content.
            guard !["AXOutline", "AXToolbar", "AXTextField", "AXTextArea", "AXSheet", "AXDialog", "AXWebArea"].contains(role) else { continue }
            let resultContainer = inResults || isResultContainer(role: role, identifier: value(element, kAXIdentifierAttribute))
            let labels = [value(element, kAXTitleAttribute), value(element, kAXDescriptionAttribute),
                          role == "AXStaticText" ? value(element, kAXValueAttribute) : ""]
            if isExactVisibleFilename(query: query, role: role, labels: labels,
                                      insideResults: resultContainer, hidden: false) { return true }
            if let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
                queue.append(contentsOf: children.prefix(100).map { ($0, resultContainer) })
            }
        }
        return false
    }

    private static func selectQuery(_ field: AXUIElement, value: String, pid: pid_t, validate: () throws -> Void) throws {
        var settable = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(field, kAXSelectedTextRangeAttribute as CFString, &settable)
        guard status == .success || status == .attributeUnsupported else {
            throw RelayError.message("Finder’s query selection could not be checked. No replacement text was sent.")
        }
        if status == .success, settable.boolValue {
            var range = CFRange(location: 0, length: value.utf16.count)
            guard let selection = AXValueCreate(.cfRange, &range) else { throw RelayError.message("Could not construct the Finder query selection.") }
            try validate()
            guard AXUIElementSetAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, selection) == .success else {
                throw RelayError.message("Finder did not accept a selection on the search field. No replacement text was sent.")
            }
        } else {
            try postCommand(.selectAll, pid: pid, validate: validate)
        }
    }

    private enum FinderCommand: CGKeyCode { case find = 3, selectAll = 0 }

    private static func postCommand(_ command: FinderCommand, pid: pid_t, validate: () throws -> Void) throws {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: command.rawValue, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: command.rawValue, keyDown: false) else { throw RelayError.message("Could not create Finder command events.") }
        down.flags = .maskCommand; up.flags = .maskCommand
        try validate()
        down.postToPid(pid); up.postToPid(pid)
    }

    private static func postText(_ text: String, pid: pid_t, validate: () throws -> Void) throws {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { throw RelayError.message("Could not create Finder text input events.") }
        down.flags = []; up.flags = []
        let units = Array(text.utf16)
        units.withUnsafeBufferPointer { buffer in
            if let base = buffer.baseAddress { down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base) }
        }
        try validate()
        down.postToPid(pid); up.postToPid(pid)
    }

    private static func requireFocusedWindow(root: AXUIElement, window: AXUIElement, pid: pid_t) throws {
        try Task.checkCancellation()
        guard AXIsProcessTrusted(), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let focused = element(root, kAXFocusedWindowAttribute), CFEqual(window, focused),
              value(window, kAXRoleAttribute) == "AXWindow", value(window, kAXSubroleAttribute) != "AXDialog",
              attribute(window, kAXModalAttribute) as? Bool != true,
              (attribute(window, "AXSheets") as? [AXUIElement] ?? []).isEmpty else {
            throw RelayError.message("The intended Finder window lost focus or became unavailable. Inspect Finder before retrying. No further input was sent.")
        }
    }

    private static func focusedSearchField(root: AXUIElement, window: AXUIElement) -> AXUIElement? {
        guard let field = element(root, kAXFocusedUIElementAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(field, 0.1)
        guard attribute(field, kAXFocusedAttribute) as? Bool == true else { return nil }
        var ancestor = element(field, kAXParentAttribute)
        var inToolbar = false
        for _ in 0..<12 {
            guard let node = ancestor else { return nil }
            AXUIElementSetMessagingTimeout(node, 0.05)
            if CFEqual(node, window) {
                return isSearchControl(role: value(field, kAXRoleAttribute), subrole: value(field, kAXSubroleAttribute),
                    roleDescription: value(field, kAXRoleDescriptionAttribute), inToolbar: inToolbar,
                    enabled: attribute(field, kAXEnabledAttribute) as? Bool == true,
                    hidden: attribute(field, "AXHidden") as? Bool == true) ? field : nil
            }
            let role = value(node, kAXRoleAttribute)
            guard !["AXWindow", "AXSheet", "AXDialog", "AXWebArea"].contains(role),
                  attribute(node, kAXModalAttribute) as? Bool != true else { return nil }
            if role == "AXToolbar" { inToolbar = true }
            ancestor = element(node, kAXParentAttribute)
        }
        return nil
    }

    private static func selectedRange(_ field: AXUIElement) -> CFRange? {
        guard let selection = attribute(field, kAXSelectedTextRangeAttribute), CFGetTypeID(selection) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(unsafeDowncast(selection, to: AXValue.self), .cfRange, &range) else { return nil }
        return range
    }

    private static func windows(_ root: AXUIElement) -> [AXUIElement] { attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? [] }
    private static func element(_ node: AXUIElement, _ name: String) -> AXUIElement? {
        guard let element = attribute(node, name), CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(element, to: AXUIElement.self)
    }
    private static func value(_ element: AXUIElement, _ name: String) -> String { attribute(element, name) as? String ?? "" }
    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var output: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &output) == .success ? output : nil
    }
}
