import AppKit
import ApplicationServices
import Foundation

/// Reads the selected accessible document only. Never launches, navigates, runs scripts or edits a page.
@MainActor
enum BrowserPageReader {
    nonisolated struct LinkInfo: Sendable, Equatable {
        let title: String
        let url: String
    }
    nonisolated struct Snapshot: Sendable {
        let url: String
        let title: String
        let text: String
        let links: [LinkInfo]
        let truncated: Bool
    }
    private struct Identity {
        let pid: pid_t
        let window: AXUIElement
        let document: AXUIElement
        let tab: AXUIElement
        let url: String
        let title: String
    }

    static func read(expectedURL: String, browser: String) async throws -> Snapshot {
        let expected = try BrowserAutomation.validatedURL(expectedURL)
        let browser = try BrowserAutomation.validatedBrowser(browser)
        guard AXIsProcessTrusted() else { throw RelayError.message("Reading a browser page needs Relay's Accessibility permission. No page was read.") }
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: browser.rawValue)
        guard applications.count == 1, let application = applications.first, !application.isTerminated else {
            throw RelayError.message("The selected browser must already be running as one identifiable process. No browser was opened.")
        }
        let root = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.15)
        let before = try identity(root: root, pid: application.processIdentifier, expected: expected)
        let budgets = snapshotBudgets(url: before.url, title: before.title)
        var queue = [before.document]
        var visited: [AXUIElement] = []
        var chunks: [String] = []
        var links: [LinkInfo] = []
        var seenLinks = Set<String>()
        var totalTextBytes = 0
        var totalLinkBytes = 0
        var cursor = 0
        var truncated = false
        let deadline = Date().addingTimeInterval(3)
        while cursor < queue.count, cursor < 700, Date() < deadline, totalTextBytes < budgets.text {
            try Task.checkCancellation()
            let element = queue[cursor]
            cursor += 1
            guard !visited.contains(where: { CFEqual($0, element) }) else { continue }
            visited.append(element)
            AXUIElementSetMessagingTimeout(element, 0.02)
            if attribute(element, "AXHidden") as? Bool == true { continue }
            try rejectSensitive(element)
            let role = string(element, kAXRoleAttribute)
            // Never include any editable field value, including a page's password/recipient fields.
            if ["AXStaticText", "AXHeading", "AXLink"].contains(role) {
                let value = string(element, kAXValueAttribute)
                let label = value.isEmpty ? string(element, kAXTitleAttribute) : value
                if !label.isEmpty {
                    let bounded = boundedText([label], maximumBytes: 1200)
                    if bounded.utf8.count < label.utf8.count { truncated = true }
                    chunks.append(bounded)
                    totalTextBytes += bounded.utf8.count
                }
                if role == "AXLink", links.count >= 50 { truncated = true }
                if role == "AXLink", links.count < 50,
                   let link = validatedLink(title: label, url: string(element, "AXURL"), relativeTo: expected),
                   seenLinks.insert(link.url).inserted {
                    let cost = link.title.utf8.count + link.url.utf8.count + 32
                    if totalLinkBytes + cost <= budgets.links { links.append(link); totalLinkBytes += cost }
                    else { truncated = true }
                }
            }
            if !["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role),
               let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
                if children.count > 100 { truncated = true }
                queue.append(contentsOf: children.prefix(100))
            }
            if cursor % 25 == 0 { await Task.yield() }
        }
        truncated = truncated || cursor < queue.count
        try Task.checkCancellation()
        let after = try identity(root: root, pid: application.processIdentifier, expected: expected)
        guard snapshotIdentityMatches(sameProcess: before.pid == after.pid && !application.isTerminated,
                                      sameWindow: CFEqual(before.window, after.window), sameTab: CFEqual(before.tab, after.tab),
                                      sameDocument: CFEqual(before.document, after.document), beforeURL: before.url,
                                      afterURL: after.url, beforeTitle: before.title, afterTitle: after.title, expected: expected) else {
            throw RelayError.message("The browser window, tab or destination changed during page inspection. The snapshot was discarded; read the current page again.")
        }
        let text = boundedText(chunks, maximumBytes: budgets.text)
        truncated = truncated || chunks.joined(separator: "\n").utf8.count > text.utf8.count
        guard !text.isEmpty || !links.isEmpty else {
            throw RelayError.message("The selected page exposed no readable static text or HTTP/HTTPS links. Canvas content, PDFs and unsupported browser Accessibility views need another explicit inspection method.")
        }
        return Snapshot(url: after.url, title: boundedText([after.title], maximumBytes: 1024), text: text, links: links, truncated: truncated)
    }

    /// Includes metadata and formatting headroom; links cannot dominate the model context.
    nonisolated static func snapshotBudgets(url: String, title: String) -> (text: Int, links: Int) {
        let metadataBytes = url.utf8.count + boundedText([title], maximumBytes: 1024).utf8.count + 512
        let available = max(0, 12_000 - metadataBytes)
        let links = min(3000, available / 3)
        return (min(8000, available - links), links)
    }

    static func validatedLink(title: String, url: String, relativeTo base: URL) -> LinkInfo? {
        guard !url.isEmpty, url.utf8.count <= 4096,
              let absolute = URL(string: url, relativeTo: base)?.absoluteURL,
              let checked = try? BrowserAutomation.validatedURL(absolute.absoluteString) else { return nil }
        return LinkInfo(title: boundedText([title], maximumBytes: 512), url: checked.absoluteString)
    }

    nonisolated static func boundedText(_ chunks: [String], maximumBytes: Int) -> String {
        guard maximumBytes > 0 else { return "" }
        let text = chunks.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        var result = ""
        var size = 0
        for scalar in text.unicodeScalars {
            guard size + scalar.utf8.count <= maximumBytes else { break }
            if CharacterSet.controlCharacters.contains(scalar), scalar != "\n", scalar != "\t" { continue }
            result.unicodeScalars.append(scalar)
            size += scalar.utf8.count
        }
        return result
    }

    private static func identity(root: AXUIElement, pid: pid_t, expected: URL) throws -> Identity {
        guard let window = element(root, kAXFocusedWindowAttribute) else { throw RelayError.message("The browser has no identifiable selected window.") }
        var queue = [window]
        if let toolbar = element(window, "AXToolbar") { queue.append(toolbar) }
        var cursor = 0
        var visited: [AXUIElement] = []
        var documents: [AXUIElement] = []
        var selectedTabs: [AXUIElement] = []
        let deadline = Date().addingTimeInterval(1)
        while cursor < queue.count, cursor < 300, Date() < deadline {
            let current = queue[cursor]; cursor += 1
            guard !visited.contains(where: { CFEqual($0, current) }) else { continue }
            visited.append(current)
            AXUIElementSetMessagingTimeout(current, 0.02)
            if attribute(current, "AXHidden") as? Bool == true { continue }
            try rejectSensitive(current)
            let role = string(current, kAXRoleAttribute)
            if role == "AXTabGroup" {
                var isContentGroup = false
                let windowIdentifier = string(window, kAXIdentifierAttribute)
                if BrowserAutomation.isOrdinarySafariWindow(windowIdentifier) {
                    guard let children = attribute(current, kAXChildrenAttribute) as? [AXUIElement], children.count <= 200 else {
                        throw RelayError.message("Safari's content/tab group could not be inspected within the identity budget. No page snapshot was returned.")
                    }
                    var roles: [String] = []
                    for child in children {
                        guard Date() < deadline else {
                            throw RelayError.message("Safari's content/tab group exceeded the identity inspection deadline. No page snapshot was returned.")
                        }
                        AXUIElementSetMessagingTimeout(child, 0.02)
                        roles.append(string(child, kAXRoleAttribute))
                    }
                    isContentGroup = isUnselectedSafariContentGroup(windowIdentifier: windowIdentifier,
                        childRoles: roles, complete: true)
                }
                if !isContentGroup {
                    guard let selected = BrowserAutomation.qualifiedSelectedTab(in: current) else {
                        throw RelayError.message("The browser tab group has absent, ambiguous or conflicting selection state. No page snapshot was returned.")
                    }
                    selectedTabs.append(selected)
                }
                // A Safari content group still contains the selected web document.
                // Descend below it; only selection validation was skipped, not inspection.
            }
            if role == "AXWebArea" {
                documents.append(current)
                continue // Nested frames belong to this document, not another tab.
            }
            if let children = attribute(current, kAXChildrenAttribute) as? [AXUIElement] {
                guard children.count <= 200 else { throw RelayError.message("Browser chrome exceeds the identity inspection budget. No page snapshot was returned.") }
                // Direct tab selection is checked above; tab labels/close buttons cannot contain
                // the selected page and need not consume the document inspection budget.
                queue.append(contentsOf: children.filter {
                    let childRole = string($0, kAXRoleAttribute)
                    return !["AXRadioButton", "AXTab"].contains(childRole)
                })
            }
        }
        guard cursor == queue.count, documents.count == 1, let document = documents.first,
              selectedTabs.count == 1, let tab = selectedTabs.first,
              let focused = focusedDocument(root: root, window: window), CFEqual(focused, document) else {
            throw RelayError.message("The selected browser tab could not be identified uniquely within the inspection budget. No page snapshot was returned.")
        }
        let url = string(document, "AXURL")
        let title = string(document, kAXTitleAttribute)
        if let failure = pageIdentityFailure(url: url, title: title, expected: expected) {
            throw RelayError.message(failure)
        }
        return Identity(pid: pid, window: window, document: document, tab: tab, url: url, title: title)
    }

    static func isUnselectedSafariContentGroup(windowIdentifier: String, childRoles: [String], complete: Bool) -> Bool {
        BrowserAutomation.isOrdinarySafariWindow(windowIdentifier)
            && BrowserAutomation.isNonTabContentGroup(childRoles: childRoles, complete: complete)
    }

    /// Security/title failures never suggest automatic navigation as a recovery path.
    /// A read remains read-only; only an already-requested opening may use reviewed navigation.
    static func pageIdentityFailure(url: String, title: String, expected: URL) -> String? {
        if BrowserAutomation.isSecurityInterruption(title) {
            return "The selected page shows a security or authentication interruption. Handle it directly; Relay will not bypass it or return a page snapshot."
        }
        guard !title.isEmpty else {
            return "The selected browser page has no readable title. No page snapshot was returned; inspect the current page directly."
        }
        guard BrowserAutomation.matchesDestination(url, expected: expected) else {
            return "The selected browser page does not match the expected URL. No page snapshot was returned. If the user requested opening this destination, use browser_navigate with destination review first, then read the verified URL. Otherwise inspect the current page; this read does not navigate."
        }
        return nil
    }

    static func snapshotIdentityMatches(sameProcess: Bool, sameWindow: Bool, sameTab: Bool, sameDocument: Bool,
                                        beforeURL: String, afterURL: String, beforeTitle: String, afterTitle: String,
                                        expected: URL) -> Bool {
        sameProcess && sameWindow && sameTab && sameDocument && beforeURL == afterURL && beforeTitle == afterTitle
            && !beforeTitle.isEmpty && !BrowserAutomation.isSecurityInterruption(afterTitle)
            && BrowserAutomation.matchesDestination(beforeURL, expected: expected)
            && BrowserAutomation.matchesDestination(afterURL, expected: expected)
    }

    private static func focusedDocument(root: AXUIElement, window: AXUIElement) -> AXUIElement? {
        var current = element(root, kAXFocusedUIElementAttribute)
        var document: AXUIElement?
        var visited: [AXUIElement] = []
        for _ in 0..<24 {
            guard let value = current, !visited.contains(where: { CFEqual($0, value) }) else { return nil }
            visited.append(value)
            AXUIElementSetMessagingTimeout(value, 0.02)
            let role = string(value, kAXRoleAttribute)
            if role == "AXWebArea" { document = value }
            if role == "AXWindow" { return CFEqual(value, window) ? document : nil }
            current = element(value, kAXParentAttribute)
        }
        return nil
    }

    private static func rejectSensitive(_ element: AXUIElement) throws {
        let role = string(element, kAXRoleAttribute)
        let subrole = string(element, kAXSubroleAttribute)
        guard !["AXSheet", "AXDialog", "AXSecureTextField"].contains(role),
              !["AXDialog", "AXSystemDialog", "AXSecureTextField"].contains(subrole),
              attribute(element, "AXModal") as? Bool != true else {
            throw RelayError.message("A secure field or modal/authentication dialog is present. Handle it directly; Relay will not read this page.")
        }
    }
    private static func string(_ element: AXUIElement, _ name: String) -> String {
        if let value = attribute(element, name) as? String { return value }
        if let value = attribute(element, name) as? URL { return value.absoluteString }
        return ""
    }
    private static func element(_ source: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(source, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }
    private static func attribute(_ source: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(source, name as CFString, &value) == .success ? value : nil
    }
}
