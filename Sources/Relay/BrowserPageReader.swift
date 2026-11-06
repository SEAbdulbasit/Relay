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
        let headings: [String]
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
        var resolvedBefore: Identity?
        for attempt in 0..<4 {
            do {
                resolvedBefore = try identity(root: root, pid: application.processIdentifier, expected: expected)
                break
            } catch {
                let msg = error.localizedDescription
                let isTransientLoad = msg.contains("does not match the expected URL") || msg.contains("has no readable title")
                if attempt < 3 && isTransientLoad {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .milliseconds(250))
                    continue
                }
                throw error
            }
        }
        guard let initialBefore = resolvedBefore else {
            throw RelayError.message("The selected browser tab could not be identified uniquely within the inspection budget. No page snapshot was returned.")
        }

        func capturePass(startingFrom before: Identity) async throws -> (chunks: [String], headings: [String], links: [LinkInfo], truncated: Bool) {
            let budgets = snapshotBudgets(url: before.url, title: before.title)
            var queue = [before.document]
            var visited: [AXUIElement] = []
            var chunks: [String] = []
            var headings: [String] = []
            var links: [LinkInfo] = []
            var seenLinks = Set<String>()
            var totalTextBytes = 0
            var totalLinkBytes = 0
            var cursor = 0
            var truncated = false
            let deadline = Date().addingTimeInterval(4.0)
            while cursor < queue.count, cursor < 2400, Date() < deadline, totalTextBytes < budgets.text {
                try Task.checkCancellation()
                let element = queue[cursor]
                cursor += 1
                guard !visited.contains(where: { CFEqual($0, element) }) else { continue }
                visited.append(element)
                AXUIElementSetMessagingTimeout(element, 0.02)
                if attribute(element, "AXHidden") as? Bool == true { continue }
                try rejectSensitive(element)
                let role = string(element, kAXRoleAttribute)
                if role == "AXHeading", headings.count < 20 {
                    var label = string(element, kAXValueAttribute)
                    if label.isEmpty { label = string(element, kAXTitleAttribute) }
                    if label.isEmpty, let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
                        label = children.prefix(20).filter { string($0, kAXRoleAttribute) == "AXStaticText" }
                            .map { string($0, kAXValueAttribute) }.joined(separator: " ")
                    }
                    if !label.isEmpty { headings.append(boundedText([label], maximumBytes: 512)) }
                }
                // Never include any editable field value, including a page's password/recipient fields.
                if ["AXStaticText", "AXHeading", "AXLink", "AXCell"].contains(role) {
                    let value = string(element, kAXValueAttribute)
                    let title = value.isEmpty ? string(element, kAXTitleAttribute) : value
                    let label = (title.isEmpty && ["AXLink", "AXCell"].contains(role))
                        ? string(element, kAXDescriptionAttribute)
                        : title
                    if !label.isEmpty {
                        let bounded = boundedText([label], maximumBytes: 1200)
                        if bounded.utf8.count < label.utf8.count { truncated = true }
                        if chunks.last != bounded {
                            chunks.append(bounded)
                            totalTextBytes += bounded.utf8.count
                        }
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
                    if children.count > 120 { truncated = true }
                    let slice = children.prefix(120)
                    var highPriority: [AXUIElement] = []
                    var regular: [AXUIElement] = []
                    for child in slice {
                        let cRole = string(child, kAXRoleAttribute)
                        let cSubrole = string(child, kAXSubroleAttribute)
                        if cSubrole == "AXLandmarkMain" || ["AXTable", "AXGrid", "AXRow", "AXCell", "AXArticle"].contains(cRole) {
                            highPriority.append(child)
                        } else {
                            regular.append(child)
                        }
                    }
                    if !highPriority.isEmpty {
                        queue.insert(contentsOf: highPriority, at: cursor)
                    }
                    queue.append(contentsOf: regular)
                }
                if cursor % 25 == 0 { await Task.yield() }
            }
            truncated = truncated || cursor < queue.count
            return (chunks, headings, links, truncated)
        }

        var before = initialBefore
        var pass = try await capturePass(startingFrom: before)
        if isGmailLoadingShell(expected: expected, chunks: pass.chunks) {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(800))
            let refreshed = try identity(root: root, pid: application.processIdentifier, expected: expected)
            guard matchesRequestedTab(sameProcess: before.pid == refreshed.pid && !application.isTerminated,
                                      sameWindow: CFEqual(before.window, refreshed.window),
                                      sameTab: CFEqual(before.tab, refreshed.tab), beforeURL: before.url,
                                      afterURL: refreshed.url, expected: expected) else {
                throw RelayError.message("The selected browser window or tab changed while the page loaded. The snapshot was discarded. Select the requested page and try reading again.")
            }
            // The loading shell may replace its document within this exact tab. Bind the
            // second pass to that new document and recheck it before returning any text.
            before = refreshed
            pass = try await capturePass(startingFrom: before)
        }
        let budgets = snapshotBudgets(url: before.url, title: before.title)
        let chunks = pass.chunks
        let headings = pass.headings
        let links = pass.links
        var truncated = pass.truncated
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
        return Snapshot(url: after.url, title: boundedText([after.title], maximumBytes: 1024), text: text, headings: headings, links: links, truncated: truncated)
    }

    static func isGmailLoadingShell(expected: URL, chunks: [String]) -> Bool {
        expected.host?.lowercased() == "mail.google.com" && chunks.count < 25
            && chunks.joined(separator: "\n").contains("Using Gmail with screen readers")
    }

    static func observesSelectedDestination(root: AXUIElement, pid: pid_t, expected: URL) -> Bool {
        guard let before = try? identity(root: root, pid: pid, expected: expected),
              let after = try? identity(root: root, pid: pid, expected: expected) else { return false }
        return snapshotIdentityMatches(sameProcess: before.pid == after.pid, sameWindow: CFEqual(before.window, after.window),
            sameTab: CFEqual(before.tab, after.tab), sameDocument: CFEqual(before.document, after.document),
            beforeURL: before.url, afterURL: after.url, beforeTitle: before.title, afterTitle: after.title, expected: expected)
    }

    static func matchesRequestedTab(sameProcess: Bool, sameWindow: Bool, sameTab: Bool,
                                    beforeURL: String, afterURL: String, expected: URL) -> Bool {
        sameProcess && sameWindow && sameTab
            && BrowserAutomation.matchesDestination(beforeURL, expected: expected)
            && BrowserAutomation.matchesDestination(afterURL, expected: expected)
    }

    nonisolated static func headingEvidence(headings: [String], truncated: Bool) -> String {
        if headings.isEmpty {
            return "No heading exposed in the inspected Accessibility content. The page title is metadata; do not report it as a main heading. "
                + (truncated ? "Inspection was truncated, so an omitted heading may exist." : "Inaccessible or dynamic content may still contain headings.")
        }
        return "Accessible heading text (untrusted; no main-heading rank established):\n"
            + boundedText(headings, maximumBytes: 1024)
            + (truncated ? "\nInspection was truncated; additional headings may be omitted." : "")
    }

    /// Includes metadata and formatting headroom; links cannot dominate the model context.
    nonisolated static func snapshotBudgets(url: String, title: String) -> (text: Int, links: Int) {
        let metadataBytes = url.utf8.count + boundedText([title], maximumBytes: 1024).utf8.count + 1536
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
              selectedTabs.count <= 1 else {
            throw RelayError.message("The selected browser tab could not be identified uniquely within the inspection budget. No page snapshot was returned.")
        }
        let focused = focusedDocument(root: root, window: window)
        let focusMatches = focused.map { CFEqual($0, document) }
        // With Safari's tab bar hidden, keyboard focus can remain in browser chrome.
        // The sole exposed document in the focused window is still the selected page.
        // A conflicting focused document is never accepted, nor is a real tab group
        // with ambiguous selection (rejected above). Exact URL/title and stable
        // window/document identity are checked before AND after reading.
        let documentIdentity = permitsDocumentIdentity(
            windowIdentifier: string(window, kAXIdentifierAttribute), selectedTabCount: selectedTabs.count,
            documentCount: documents.count, focusedDocumentMatches: focusMatches,
            traversalComplete: cursor == queue.count)
        let uniqueTabDocumentIdentity = selectedTabs.count == 1 && documents.count == 1
            && focusMatches != false && cursor == queue.count
        guard focusMatches == true || documentIdentity || uniqueTabDocumentIdentity,
              let tab = selectedTabs.first ?? (documentIdentity ? document : nil) else {
            throw RelayError.message("Select the requested Safari page and try reading again. No unique selected tab was exposed.")
        }
        let url = string(document, "AXURL")
        let title = readableDocumentTitle(title: string(document, kAXTitleAttribute),
                                          description: string(document, kAXDescriptionAttribute))
        if let failure = pageIdentityFailure(url: url, title: title, expected: expected) {
            throw RelayError.message(failure)
        }
        return Identity(pid: pid, window: window, document: document, tab: tab, url: url, title: title)
    }

    static func permitsDocumentIdentity(windowIdentifier: String, selectedTabCount: Int,
                                        documentCount: Int, focusedDocumentMatches: Bool?,
                                        traversalComplete: Bool) -> Bool {
        BrowserAutomation.isOrdinarySafariWindow(windowIdentifier) && selectedTabCount == 0
            && documentCount == 1 && focusedDocumentMatches != false && traversalComplete
    }

    static func isUnselectedSafariContentGroup(windowIdentifier: String, childRoles: [String], complete: Bool) -> Bool {
        BrowserAutomation.isOrdinarySafariWindow(windowIdentifier)
            && BrowserAutomation.isNonTabContentGroup(childRoles: childRoles, complete: complete)
    }

    /// WebKit exposes its accessible page name as AXDescription on some macOS
    /// versions. It is metadata of the same verified document, not a window/tab
    /// label from another page. Identity validation uses this value on both reads.
    static func readableDocumentTitle(title: String, description: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? description : title
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
        matchesRequestedTab(sameProcess: sameProcess, sameWindow: sameWindow, sameTab: sameTab,
                            beforeURL: beforeURL, afterURL: afterURL, expected: expected)
            && sameDocument && beforeURL == afterURL && beforeTitle == afterTitle
            && !beforeTitle.isEmpty && !BrowserAutomation.isSecurityInterruption(afterTitle)
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
