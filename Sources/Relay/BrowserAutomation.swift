import AppKit
import ApplicationServices
import Foundation

/// Qualified navigation only. No model-selected keyboard shortcuts, page clicks or form submission.
@MainActor
enum BrowserAutomation {
    enum Browser: String {
        case chrome = "com.google.Chrome"
        case safari = "com.apple.Safari"
        var name: String { self == .chrome ? "Google Chrome" : "Safari" }
    }

    // Only explicitly identified capability gaps before any destination input
    // may use Launch Services instead of the address control.
    enum DirectOpenFallback: Error { case unsupportedAddressControl, unavailableSafariTabSelection }

    static func validatedBrowser(_ name: String) throws -> Browser {
        let normalized = name.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
        switch normalized {
        case "chrome", "google chrome", "com.google.chrome": return .chrome
        case "safari", "com.apple.safari": return .safari
        default: throw RelayError.message("Browser navigation supports Google Chrome or Safari. Specify one installed browser; other browsers and ambiguous descriptions are not qualified.")
        }
    }

    static func validatedURL(_ raw: String) throws -> URL {
        guard !raw.isEmpty, raw.utf8.count <= 4096,
              !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) }),
              let components = URLComponents(string: raw),
              ["https", "http"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              let url = components.url else {
            throw RelayError.message("Browser navigation requires an HTTP/HTTPS URL up to 4096 UTF-8 bytes, with a host and no credentials, whitespace or control characters.")
        }
        let decoded = raw.removingPercentEncoding ?? raw
        guard !decoded.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !host.contains("%"), !host.contains("\\"), !raw.contains("\\") else {
            throw RelayError.message("Ambiguous or escaped URL hosts are not supported.")
        }
        return url
    }

    static func validatedQuery(_ raw: String) throws -> String {
        guard !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw RelayError.message("Web search requires plain single-line text without keyboard control characters.")
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 1024 else {
            throw RelayError.message("Web search needs a nonempty query up to 1024 UTF-8 bytes.")
        }
        return value
    }

    static func searchURL(query: String) throws -> URL {
        let query = try validatedQuery(query)
        var components = URLComponents()
        components.scheme = "https"
        components.host = "duckduckgo.com"
        components.path = "/"
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components.url else { throw RelayError.message("Could not encode the web search query.") }
        return try validatedURL(url.absoluteString)
    }

    static func destination(for call: ToolCall) throws -> (url: URL, browser: Browser) {
        guard let browserName = call.arguments["browser"]?.string else { throw RelayError.message("Choose Chrome or Safari for this browser task.") }
        let browser = try validatedBrowser(browserName)
        switch call.name {
        case "browser_navigate":
            guard let raw = call.arguments["url"]?.string else { throw RelayError.message("A website URL is required.") }
            return (try validatedURL(raw), browser)
        case "search_web":
            guard let query = call.arguments["query"]?.string else { throw RelayError.message("A search query is required.") }
            return (try searchURL(query: query), browser)
        default: throw RelayError.message("Unsupported qualified browser action.")
        }
    }

    static func navigate(url: URL, browser: Browser) async throws -> ToolResult {
        let deadline = Date().addingTimeInterval(30)
        try checkNavigationDeadline(deadline)
        _ = try validatedURL(url.absoluteString)
        let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.rawValue)
        guard let applicationURL else {
            throw RelayError.message("\(browser.name) is not installed. Install it or explicitly choose another browser; Relay did not open a different browser.")
        }
        if !AXIsProcessTrusted() {
            return try await openDirectly(url: url, browser: browser, applicationURL: applicationURL)
        }
        try checkNavigationDeadline(deadline)
        return try await withDirectOpenFallback(deadline: deadline) {
            try await navigateWithAXAddressBar(url: url, browser: browser, applicationURL: applicationURL, deadline: deadline)
        } open: {
            try await openDirectly(url: url, browser: browser, applicationURL: applicationURL)
        }
    }

    static func withDirectOpenFallback(deadline: Date, addressBar: () async throws -> ToolResult,
                                       open: () async throws -> ToolResult) async throws -> ToolResult {
        do { return try await addressBar() }
        catch is DirectOpenFallback {
            try checkNavigationDeadline(deadline)
            return try await open()
        }
    }

    private static func openDirectly(url: URL, browser: Browser, applicationURL: URL) async throws -> ToolResult {
        try Task.checkCancellation()
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        let app = try await NSWorkspace.shared.open([url], withApplicationAt: applicationURL, configuration: config)
        if AXIsProcessTrusted() {
            let root = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.15)
            var matched = false
            for _ in 0..<18 {
                try Task.checkCancellation()
                if let window = elementAttribute(root, kAXFocusedWindowAttribute),
                   let doc = firstWebDocument(in: window) {
                    let currentURL = stringAttribute(doc, "AXURL")
                    if matchesDestination(currentURL, expected: url) {
                        matched = true
                        break
                    }
                }
                try await Task.sleep(for: .milliseconds(150))
            }
            if matched, url.host?.lowercased().contains("mail.google.com") == true {
                try? await Task.sleep(for: .milliseconds(900))
            }
        }
        return ToolResult(
            summary: "Requested opening \(url.absoluteString) in \(browser.name).",
            evidence: "NSWorkspace accepted the URL in \(browser.name). Observe this browser to verify the loaded page and requested outcome.",
            verified: false
        )
    }

    private static func firstWebDocument(in window: AXUIElement) -> AXUIElement? {
        var queue = [window]
        var cursor = 0
        var visited = Set<CFHashCode>()
        let deadline = Date().addingTimeInterval(0.3)
        while cursor < queue.count, cursor < 200, Date() < deadline {
            let current = queue[cursor]; cursor += 1
            guard visited.insert(CFHash(current)).inserted else { continue }
            AXUIElementSetMessagingTimeout(current, 0.02)
            if attribute(current, "AXHidden") as? Bool == true { continue }
            let role = stringAttribute(current, kAXRoleAttribute)
            if role == "AXWebArea" { return current }
            if let children = attribute(current, kAXChildrenAttribute) as? [AXUIElement] {
                queue.append(contentsOf: children.prefix(80))
            }
        }
        return nil
    }

    private static func navigateWithAXAddressBar(url: URL, browser: Browser, applicationURL: URL, deadline: Date) async throws -> ToolResult {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let application = try await NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration)
        let pid = application.processIdentifier
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 0.2)
        application.activate()
        for _ in 0..<30 {
            try checkNavigationDeadline(deadline)
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try assertForeground(pid)
        guard let originalWindow = elementAttribute(root, kAXFocusedWindowAttribute) else {
            throw RelayError.message("The browser has no identifiable focused window. Open an ordinary browser window, then retry the reviewed request. No destination was typed.")
        }
        try rejectSensitiveWindow(originalWindow)
        guard let originalTab = selectedTab(in: originalWindow) else {
            if browser == .safari, isOrdinarySafariWindow(stringAttribute(originalWindow, kAXIdentifierAttribute)) {
                try assertForeground(pid)
                throw DirectOpenFallback.unavailableSafariTabSelection
            }
            throw RelayError.message("The browser does not expose one original selected tab identity. No new tab, address entry or confirmation was dispatched. In Safari, open a blank second tab or show the tab bar manually, then retry the reviewed request. Hidden single-tab navigation is not qualified; other unsupported layouts need manual inspection.")
        }
        // A known original tab is required before revealing a new one. Newly exposed AX
        // objects alone cannot distinguish a hidden old logical tab from a new tab.
        try postKey(17, flags: .maskCommand, pid: pid, deadline: deadline) // Cmd+T: new tab.
        try await Task.sleep(for: .milliseconds(150))
        try postKey(37, flags: .maskCommand, pid: pid, deadline: deadline) // Cmd+L: address field only.
        var address: AXUIElement?
        for _ in 0..<20 {
            try checkNavigationDeadline(deadline)
            if let candidate = elementAttribute(root, kAXFocusedUIElementAttribute), isAddressField(candidate) {
                address = candidate; break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard let window = elementAttribute(root, kAXFocusedWindowAttribute),
              CFEqual(window, originalWindow), let navigationTab = selectedTab(in: window),
              !CFEqual(navigationTab, originalTab) else {
            throw RelayError.message("The new browser tab could not be verified in its original window. Inspect the browser before retrying. No destination was typed.")
        }
        try rejectSensitiveWindow(window)
        try assertSelectedTab(root: root, window: window, tab: navigationTab)
        try assertForeground(pid)
        guard let address else { throw DirectOpenFallback.unsupportedAddressControl }
        try assertAddressFocus(root: root, field: address, pid: pid)
        // Discover both capabilities before editing. Process-wide selection, deletion,
        // Unicode key events and Return are never used to carry a destination URL.
        var valueSettable = DarwinBoolean(false)
        let valueStatus = AXUIElementIsAttributeSettable(address, kAXValueAttribute as CFString, &valueSettable)
        var rawActions: CFArray?
        let actionStatus = AXUIElementCopyActionNames(address, &rawActions)
        let advertisedActions = actionStatus == .success ? rawActions as? [String] : nil
        let confirmation = BrowserAddressCommit.entryConfirmationAction(
            settableQuerySucceeded: valueStatus == .success, valueSettable: valueSettable.boolValue,
            advertisedActions: advertisedActions)
        try assertSelectedTab(root: root, window: window, tab: navigationTab)
        try assertAddressFocus(root: root, field: address, pid: pid)
        guard let confirmation else {
            try rejectSensitiveWindow(window)
            try assertForeground(pid)
            throw DirectOpenFallback.unsupportedAddressControl
        }
        try checkNavigationDeadline(deadline)
        let destination = url.absoluteString
        RelayActionPointer.shared.show(element: address, label: "Navigate")
        defer { RelayActionPointer.shared.finishAction() }
        guard AXUIElementSetAttributeValue(address, kAXValueAttribute as CFString, destination as CFString) == .success else {
            throw RelayError.message("Direct browser address entry did not report success. Its effect is uncertain; inspect the new tab and address before retrying. No confirmation or keyboard fallback was sent.")
        }
        try await Task.sleep(for: .milliseconds(100))
        try assertSelectedTab(root: root, window: window, tab: navigationTab)
        try assertAddressFocus(root: root, field: address, pid: pid)
        guard stringAttribute(address, kAXValueAttribute) == destination else {
            throw RelayError.message("The directly entered browser address did not read back the reviewed URL exactly. No confirmation was sent; inspect the new tab and address before retrying.")
        }
        // Recheck immediately before committing, after action discovery and tab traversal.
        // The action is performed on this exact native address object, never on the process.
        try assertSelectedTab(root: root, window: window, tab: navigationTab)
        try assertAddressFocus(root: root, field: address, pid: pid)
        guard stringAttribute(address, kAXValueAttribute) == destination else {
            throw RelayError.message("The reviewed address changed before confirmation. No confirmation was sent; inspect the new tab before retrying.")
        }
        try checkNavigationDeadline(deadline)
        guard AXUIElementPerformAction(address, confirmation as CFString) == .success else {
            throw RelayError.message("Target-bound browser address confirmation did not report success. The effect is uncertain; inspect the new tab before retrying. No Return fallback was sent.")
        }
        for _ in 0..<60 {
            try checkNavigationDeadline(deadline)
            try assertForeground(pid)
            try assertSelectedTab(root: root, window: window, tab: navigationTab)
            try rejectSensitiveWindow(window)
            // Never certify an arbitrary cached/background web area. The page must own
            // keyboard focus in the original window and its exact newly-created tab.
            if let document = focusedDocument(root: root, window: window) {
                let title = stringAttribute(document, kAXTitleAttribute)
                let currentURL = stringAttribute(document, "AXURL")
                if documentMatchesReviewedNavigation(pageURL: currentURL, title: title,
                    addressURL: stringAttribute(address, kAXValueAttribute),
                    sameWindow: true, sameNewTab: true, ownsFocus: true, expected: url) {
                    return ToolResult(summary: "Navigated to \(url.host ?? destination) in \(browser.name).", evidence: "Focused page AXURL and browser address readback matched the reviewed destination: \(currentURL). The original window and newly-created selected tab remained identical. Document title: \(title). This verifies the active destination, not complete loading, search-result accuracy or any form submission.", verified: true)
                }
                if isSecurityInterruption(title) {
                    throw RelayError.message("The browser exposed a security or authentication interruption. Handle it directly; Relay will not bypass it.")
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw RelayError.message("Navigation was submitted in the reviewed browser address field, but a matching fresh page URL and title were not verified. The outcome is uncertain; inspect the new tab before retrying. Redirects and unsupported browser Accessibility views require manual inspection.")
    }

    static func checkNavigationDeadline(_ deadline: Date, now: Date = Date()) throws {
        try Task.checkCancellation()
        guard deadline.timeIntervalSinceReferenceDate.isFinite, now.timeIntervalSinceReferenceDate.isFinite, now < deadline else {
            throw RelayError.message("Browser action expired, including possible sleep/wake interruption. No further typing will be sent; inspect the current tab before starting a new request.")
        }
    }

    /// Pure verification contract: a matching URL in another tab is insufficient evidence.
    static func documentMatchesReviewedNavigation(pageURL: String, title: String, addressURL: String,
        sameWindow: Bool, sameNewTab: Bool, ownsFocus: Bool, expected: URL) -> Bool {
        sameWindow && sameNewTab && ownsFocus && !title.isEmpty && !isSecurityInterruption(title)
            && matchesDestination(pageURL, expected: expected)
            && addressMatchesReviewedDestination(addressURL, expected: expected)
    }

    /// Chrome may omit the scheme from its displayed address after Return. This normalization
    /// applies only to address chrome; the independent document AXURL must remain a full URL.
    static func addressMatchesReviewedDestination(_ address: String, expected: URL) -> Bool {
        if matchesDestination(address, expected: expected) { return true }
        guard !address.isEmpty, !address.contains("://"), !address.contains("//"),
              let scheme = expected.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let formatted = try? validatedURL(scheme + "://" + address) else { return false }
        return matchesDestination(formatted.absoluteString, expected: expected)
    }

    struct TabSelectionState: Sendable {
        let index: Int
        let role: String
        let value: Bool?
        let selected: Bool?
    }

    /// AXSelectedChildren is authoritative when nonempty, but conflicting Boolean tab state
    /// invalidates both sources. Empty/missing AXSelectedChildren can use direct tab controls.
    static func selectedTabIndex(explicit: [Int]?, tabs: [TabSelectionState], traversalComplete: Bool) -> Int? {
        guard traversalComplete, !tabs.isEmpty,
              tabs.allSatisfy({ ["AXRadioButton", "AXTab"].contains($0.role) }),
              Set(tabs.map(\.index)).count == tabs.count,
              !tabs.contains(where: { tab in
                  if let value = tab.value, let selected = tab.selected { return value != selected }
                  return false
              }) else { return nil }
        let selected = tabs.filter { ($0.selected ?? $0.value) == true }.map(\.index)
        if let explicit, !explicit.isEmpty {
            guard explicit.count == 1, let index = explicit.first,
                  let tab = tabs.first(where: { $0.index == index }),
                  (tab.selected ?? tab.value) != false,
                  selected.isEmpty || selected == [index] else { return nil }
            return index
        }
        guard tabs.allSatisfy({ $0.value != nil || $0.selected != nil }), selected.count == 1 else { return nil }
        return selected[0]
    }

    /// Only the direct radio/tab children of an outer browser tab group qualify.
    static func qualifiedSelectedTab(in group: AXUIElement) -> AXUIElement? {
        guard stringAttribute(group, kAXRoleAttribute) == "AXTabGroup",
              let children = attribute(group, kAXChildrenAttribute) as? [AXUIElement], children.count <= 200 else { return nil }
        var tabs: [TabSelectionState] = []
        let deadline = Date().addingTimeInterval(1)
        for (index, child) in children.enumerated() {
            guard Date() < deadline else { return nil }
            AXUIElementSetMessagingTimeout(child, 0.025)
            let role = stringAttribute(child, kAXRoleAttribute)
            guard ["AXRadioButton", "AXTab"].contains(role) else { continue }
            guard attribute(child, "AXHidden") as? Bool != true else { continue }
            tabs.append(TabSelectionState(index: index, role: role,
                value: booleanAttribute(child, kAXValueAttribute), selected: booleanAttribute(child, kAXSelectedAttribute)))
        }
        let explicit: [Int]?
        if let raw = attribute(group, kAXSelectedChildrenAttribute) {
            guard let selected = raw as? [AXUIElement] else { return nil }
            let indices = selected.compactMap { selected in children.firstIndex(where: { CFEqual($0, selected) }) }
            guard indices.count == selected.count else { return nil }
            explicit = indices
        } else { explicit = nil }
        guard let index = selectedTabIndex(explicit: explicit, tabs: tabs, traversalComplete: true) else { return nil }
        return children[index]
    }

    private static func selectedTab(in window: AXUIElement) -> AXUIElement? {
        var queue = [window]
        if let toolbar = elementAttribute(window, "AXToolbar") { queue.append(toolbar) }
        var cursor = 0
        var seen: [AXUIElement] = []
        var selections: [AXUIElement] = []
        let deadline = Date().addingTimeInterval(1)
        while cursor < queue.count, cursor < 350, Date() < deadline {
            let element = queue[cursor]; cursor += 1
            guard !seen.contains(where: { CFEqual($0, element) }) else { continue }
            seen.append(element)
            AXUIElementSetMessagingTimeout(element, 0.025)
            if attribute(element, "AXHidden") as? Bool == true { continue }
            let role = stringAttribute(element, kAXRoleAttribute)
            if role == "AXWebArea" { continue }
            if role == "AXTabGroup" {
                if isOrdinarySafariWindow(stringAttribute(window, kAXIdentifierAttribute)) {
                    guard let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement], children.count <= 200 else { return nil }
                    var roles: [String] = []
                    for child in children {
                        guard Date() < deadline else { return nil }
                        AXUIElementSetMessagingTimeout(child, 0.025)
                        roles.append(stringAttribute(child, kAXRoleAttribute))
                    }
                    if isNonTabContentGroup(childRoles: roles, complete: true) { continue }
                }
                guard let selected = qualifiedSelectedTab(in: element) else { return nil }
                selections.append(selected)
                continue // Only outer tab groups, never descendant controls or page-defined tabs.
            }
            if let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
                guard children.count <= 200 else { return nil }
                queue.append(contentsOf: children)
            }
        }
        guard cursor == queue.count, selections.count == 1 else { return nil }
        return selections[0]
    }

    static func isOrdinarySafariWindow(_ identifier: String) -> Bool {
        // Safari uses both values for its ordinary content windows. Neither value
        // establishes tab selection; callers must still verify the selected document.
        return ["SafariWindow?IsSecure=false&UUID=", "SafariWindow?IsSecure=true&UUID="].contains { prefix in
            identifier.hasPrefix(prefix) && identifier.utf8.count > prefix.utf8.count && identifier.utf8.count <= 256
        }
    }

    /// Safari Start Page contains a content AXTabGroup distinct from its native tab bar.
    /// Only complete groups with zero direct tab controls may be skipped; this never
    /// creates a selection or relaxes the requirement for one known original tab.
    static func isNonTabContentGroup(childRoles: [String], complete: Bool) -> Bool {
        complete && childRoles.count <= 200 && !childRoles.contains("")
            && !childRoles.contains { ["AXTab", "AXRadioButton"].contains($0) }
    }

    private static func booleanAttribute(_ element: AXUIElement, _ name: String) -> Bool? {
        guard let raw = attribute(element, name) else { return nil }
        if CFGetTypeID(raw) == CFBooleanGetTypeID() { return raw as? Bool }
        // AXRadioButton/AXTab commonly expose binary NSNumber values rather than CFBoolean.
        if let number = raw as? NSNumber, number.doubleValue == 0 || number.doubleValue == 1 { return number.boolValue }
        return nil
    }

    private static func assertSelectedTab(root: AXUIElement, window: AXUIElement, tab: AXUIElement) throws {
        try Task.checkCancellation()
        guard let currentWindow = elementAttribute(root, kAXFocusedWindowAttribute), CFEqual(currentWindow, window),
              let currentTab = selectedTab(in: currentWindow), CFEqual(currentTab, tab) else {
            throw RelayError.message("The browser window or newly-created selected tab changed or could not be verified. Navigation stopped; inspect any partial state before retrying.")
        }
    }

    private static func focusedDocument(root: AXUIElement, window: AXUIElement) -> AXUIElement? {
        var current = elementAttribute(root, kAXFocusedUIElementAttribute)
        var document: AXUIElement?
        var visited = Set<CFHashCode>()
        for _ in 0..<24 {
            guard let element = current, visited.insert(CFHash(element)).inserted else { return nil }
            AXUIElementSetMessagingTimeout(element, 0.025)
            let role = stringAttribute(element, kAXRoleAttribute)
            if role == "AXWebArea" { document = element }
            if role == "AXWindow" { return CFEqual(element, window) ? document : nil }
            current = elementAttribute(element, kAXParentAttribute)
        }
        return nil
    }

    static func matchesDestination(_ actual: String, expected: URL) -> Bool {
        guard let url = try? validatedURL(actual), var left = URLComponents(url: url, resolvingAgainstBaseURL: false),
              var right = URLComponents(url: expected, resolvingAgainstBaseURL: false) else { return false }
        left.scheme = left.scheme?.lowercased(); right.scheme = right.scheme?.lowercased()
        left.host = left.host?.lowercased(); right.host = right.host?.lowercased()
        if left.path.isEmpty { left.path = "/" }; if right.path.isEmpty { right.path = "/" }
        return left == right
    }

    static func isSecurityInterruption(_ title: String) -> Bool {
        let title = title.lowercased()
        return ["privacy error", "your connection is not private", "not secure", "certificate", "authentication required", "sign in to", "log in to"].contains { title.contains($0) }
    }

    private static func isAddressField(_ field: AXUIElement) -> Bool {
        let role = stringAttribute(field, kAXRoleAttribute)
        guard ["AXTextField", "AXComboBox"].contains(role), stringAttribute(field, kAXSubroleAttribute) != "AXSecureTextField" else { return false }
        // Page-provided labels are untrusted. A field inside web content is never an address bar.
        var parent = elementAttribute(field, kAXParentAttribute)
        var depth = 0
        while let current = parent, depth < 16 {
            if stringAttribute(current, kAXRoleAttribute) == "AXWebArea" { return false }
            if stringAttribute(current, kAXRoleAttribute) == "AXWindow" { break }
            parent = elementAttribute(current, kAXParentAttribute)
            depth += 1
        }
        guard parent != nil, depth < 16 else { return false }
        let label = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXIdentifierAttribute].map { stringAttribute(field, $0) }.joined(separator: " ").lowercased()
        return ["address and search", "address bar", "smart search", "addressfield", "omnibox", "location field"].contains { label.contains($0) }
    }

    private static func rejectSensitiveWindow(_ window: AXUIElement) throws {
        for element in descendants(window, chromeOnly: true) {
            let role = stringAttribute(element, kAXRoleAttribute)
            let subrole = stringAttribute(element, kAXSubroleAttribute)
            if role == "AXSheet" || role == "AXDialog" || ["AXDialog", "AXSystemDialog", "AXSecureTextField"].contains(subrole) || role == "AXSecureTextField" || attribute(element, "AXModal") as? Bool == true {
                throw RelayError.message("A browser dialog or secure field is present. Handle authentication or sensitive input directly before navigation.")
            }
        }
    }

    private static func assertForeground(_ pid: pid_t) throws {
        try Task.checkCancellation()
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            throw RelayError.message("The browser lost foreground focus; navigation stopped. No input was sent to another process.")
        }
    }
    private static func assertAddressFocus(root: AXUIElement, field: AXUIElement, pid: pid_t) throws {
        try assertForeground(pid)
        guard let focused = elementAttribute(root, kAXFocusedUIElementAttribute), CFEqual(focused, field),
              attribute(field, kAXFocusedAttribute) as? Bool == true, isAddressField(field) else {
            throw RelayError.message("The reviewed browser address field lost focus. Fixed navigation stopped; inspect partial address input before retrying.")
        }
    }
    private static func postKey(_ code: CGKeyCode, flags: CGEventFlags = [], pid: pid_t, deadline: Date) throws {
        try checkNavigationDeadline(deadline)
        try assertForeground(pid)
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { throw RelayError.message("Could not create qualified browser input.") }
        down.flags = flags; up.flags = flags
        down.postToPid(pid); up.postToPid(pid)
    }
    private static func descendants(_ root: AXUIElement, chromeOnly: Bool = false) -> [AXUIElement] {
        var queue = [root]
        if let toolbar = elementAttribute(root, "AXToolbar") { queue.append(toolbar) }
        var result: [AXUIElement] = []
        var visited = Set<CFHashCode>()
        let deadline = Date().addingTimeInterval(0.7)
        while !queue.isEmpty, result.count < 350, Date() < deadline {
            let element = queue.removeFirst()
            guard visited.insert(CFHash(element)).inserted else { continue }
            AXUIElementSetMessagingTimeout(element, 0.025)
            result.append(element)
            // The navigation workflow never touches page fields. Inspect browser dialogs/chrome,
            // not the contents of another tab's form, before opening a new independent tab.
            if chromeOnly && stringAttribute(element, kAXRoleAttribute) == "AXWebArea" { continue }
            if let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf: children.prefix(100)) }
        }
        return result
    }
    private static func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }
    private static func stringAttribute(_ element: AXUIElement, _ name: String) -> String {
        if let value = attribute(element, name) as? String { return value }
        if let value = attribute(element, name) as? URL { return value.absoluteString }
        return ""
    }
    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
}
