import AppKit
import ApplicationServices
import Foundation

/// Native AppleEvents + Accessibility browser tab discovery, focus switching, and Chromium
/// Bookmarks/Favorites management. Never uses Chrome's disabled `execute javascript` AppleEvent.
@MainActor
enum BrowserTabAutomation {
    nonisolated struct TabInfo: Sendable, Equatable {
        let browserName: String
        let bundleID: String
        let windowID: String
        let windowIndex: Int
        let tabID: String
        let tabIndex: Int
        let isActiveTab: Bool
        let title: String
        let url: String
        let isVideoTab: Bool
        let isAudible: Bool
    }

    private nonisolated static let chromiumScriptableBrowsers: [BrowserAutomation.Browser] = [
        .chrome, .brave, .edge
    ]

    private nonisolated static let allTabInspectableBrowsers: [BrowserAutomation.Browser] = [
        .chrome, .safari, .brave, .edge, .arc
    ]

    private nonisolated static let videoHostKeywords = [
        "youtube.com", "youtu.be", "vimeo.com", "twitch.tv",
        "netflix.com", "dailymotion.com", "loom.com", "bilibili.com",
        "nebula.tv", "rumble.com", "ted.com", "coursera.org", "udemy.com"
    ]

    nonisolated static func isVideoCandidate(url rawURL: String, title: String) -> Bool {
        let loweredTitle = title.lowercased()
        if title.contains("▶") || title.contains("🔊") || loweredTitle.contains("audio playing") {
            return true
        }
        guard let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased() else {
            return false
        }
        if host == "youtu.be" || host == "www.youtu.be" {
            return url.path.count > 1
        }
        if host.hasSuffix("youtube.com") {
            let path = url.path.lowercased()
            return path.hasPrefix("/watch") || path.hasPrefix("/shorts/") || path.hasPrefix("/live/")
                || rawURL.lowercased().contains("v=")
        }
        if host.contains("vimeo.com") || host.contains("twitch.tv") || host.contains("loom.com")
            || host.contains("dailymotion.com") || host.contains("bilibili.com")
            || host.contains("nebula.tv") || host.contains("rumble.com") {
            return url.path.count > 1
        }
        if host.contains("netflix.com") {
            return url.path.lowercased().hasPrefix("/watch")
        }
        return videoHostKeywords.contains { host.contains($0) } && url.path.count > 1
    }

    nonisolated static func bestPlayingTab(in tabs: [TabInfo]) -> TabInfo? {
        let validTabs = tabs.filter { (try? validatedWebURL($0.url)) != nil }
        guard !validTabs.isEmpty else { return nil }
        return validTabs.max { lhs, rhs in
            priorityScore(for: lhs) < priorityScore(for: rhs)
        }
    }

    private nonisolated static func priorityScore(for tab: TabInfo) -> Int {
        var score = 0
        if tab.isAudible { score += 100 }
        if tab.isVideoTab { score += 50 }
        if tab.isActiveTab { score += 10 }
        if tab.bundleID.caseInsensitiveCompare(BrowserAutomation.Browser.chrome.rawValue) == .orderedSame {
            score += 2
        }
        return score
    }

    private nonisolated static func validatedWebURL(_ raw: String) throws -> URL {
        guard !raw.isEmpty, raw.utf8.count <= 4096,
              !raw.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0)
              }),
              let components = URLComponents(string: raw),
              ["https", "http"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              let url = components.url else {
            throw RelayError.message("Expected an HTTP or HTTPS URL.")
        }
        return url
    }

    private static func targetBrowsers(matching rawBrowser: String?, workspace: NSWorkspace) throws -> [BrowserAutomation.Browser] {
        if let rawBrowser, !rawBrowser.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [try BrowserAutomation.validatedBrowser(rawBrowser)]
        }
        let runningIDs = Set(workspace.runningApplications.filter { !$0.isTerminated }.compactMap { $0.bundleIdentifier?.lowercased() })
        let runningSupported = allTabInspectableBrowsers.filter { runningIDs.contains($0.rawValue.lowercased()) }
        guard !runningSupported.isEmpty else {
            throw RelayError.message("No supported browser (Chrome, Safari, Brave, Edge, or Arc) is currently running.")
        }
        return runningSupported
    }

    static func inspectTabs(browserName: String?, workspace: NSWorkspace = .shared) async throws -> ToolResult {
        let browsers = try targetBrowsers(matching: browserName, workspace: workspace)
        var allTabs: [TabInfo] = []
        var errors: [String] = []
        for browser in browsers {
            guard isRunning(browser, workspace: workspace) else {
                if browserName != nil {
                    throw RelayError.message("\(browser.name) is not currently running.")
                }
                continue
            }
            do {
                let tabs = try await readTabs(for: browser, workspace: workspace)
                allTabs.append(contentsOf: tabs)
            } catch {
                errors.append("\(browser.name): \(error.localizedDescription)")
            }
        }
        if allTabs.isEmpty, let firstError = errors.first {
            throw RelayError.message(firstError)
        }
        guard !allTabs.isEmpty else {
            throw RelayError.message("No open tabs were found in the running browser windows.")
        }

        let recommended = bestPlayingTab(in: allTabs)
        var lines: [String] = []
        if let recommended {
            lines.append("Recommended playing/active tab: [\(recommended.browserName)] window=\(recommended.windowIndex) tab=\(recommended.tabIndex) active=\(recommended.isActiveTab) video=\(recommended.isVideoTab) audible=\(recommended.isAudible) | Title: \(recommended.title) | URL: \(recommended.url)")
        }
        lines.append("Open tabs (\(allTabs.count)):")
        for tab in allTabs.prefix(40) {
            lines.append("- [\(tab.browserName)] window=\(tab.windowIndex) tab=\(tab.tabIndex) active=\(tab.isActiveTab) video=\(tab.isVideoTab) audible=\(tab.isAudible) | Title: \(tab.title) | URL: \(tab.url)")
        }
        if allTabs.count > 40 {
            lines.append("… \(allTabs.count - 40) more tabs omitted.")
        }
        return ToolResult(
            summary: MacTools.boundedText(lines.joined(separator: "\n"), utf8Limit: 11_500),
            evidence: "Inspected \(allTabs.count) open browser tab(s) across \(Set(allTabs.map(\.browserName)).sorted().joined(separator: ", ")) via native AppleEvents.",
            verified: true
        )
    }

    static func focusTab(browserName: String?, urlSubstring: String?, windowIndex: Int?, tabIndex: Int?, workspace: NSWorkspace = .shared) async throws -> ToolResult {
        let browsers = try targetBrowsers(matching: browserName, workspace: workspace)
        var allTabs: [TabInfo] = []
        for browser in browsers where isRunning(browser, workspace: workspace) {
            if let tabs = try? await readTabs(for: browser, workspace: workspace) {
                allTabs.append(contentsOf: tabs)
            }
        }
        guard !allTabs.isEmpty else {
            throw RelayError.message("No open browser tabs were found to focus.")
        }
        guard let target = resolveTargetTab(in: allTabs, urlSubstring: urlSubstring, windowIndex: windowIndex, tabIndex: tabIndex) else {
            throw RelayError.message("No open browser tab matched the requested video or URL.")
        }
        guard let browser = BrowserAutomation.Browser(rawValue: target.bundleID) else {
            throw RelayError.message("Unsupported browser identifier \(target.bundleID).")
        }
        let verifiedURL = try await focusAppleEventTab(browser: browser, windowIndex: target.windowIndex, tabIndex: target.tabIndex, workspace: workspace)
        return ToolResult(
            summary: "Focused tab “\(target.title)” (\(verifiedURL)) in \(target.browserName) (window \(target.windowIndex), tab \(target.tabIndex)).",
            evidence: "Switched active browser tab via AppleEvents and verified active tab URL readback matched \(verifiedURL).",
            verified: true
        )
    }

    static func bookmarkTab(browserName: String?, url rawURL: String?, title rawTitle: String?, folderName: String?, workspace: NSWorkspace = .shared) async throws -> ToolResult {
        let explicitBrowser = try browserName.flatMap { trimmed($0) }.map { try BrowserAutomation.validatedBrowser($0) }
        var gatheredTabs: [TabInfo] = []
        let candidateBrowsers = explicitBrowser.map { [$0] } ?? allTabInspectableBrowsers.filter { isRunning($0, workspace: workspace) }
        for browser in candidateBrowsers where isRunning(browser, workspace: workspace) {
            if let tabs = try? await readTabs(for: browser, workspace: workspace) {
                gatheredTabs.append(contentsOf: tabs)
            }
        }

        let targetTab: TabInfo?
        let resolvedURL: URL
        let resolvedTitle: String
        let targetBrowser: BrowserAutomation.Browser

        if let rawURL = trimmed(rawURL) {
            resolvedURL = try validatedWebURL(rawURL)
            targetTab = gatheredTabs.first { $0.url.caseInsensitiveCompare(resolvedURL.absoluteString) == .orderedSame }
                ?? gatheredTabs.first { $0.url.localizedCaseInsensitiveContains(rawURL) }
            targetBrowser = explicitBrowser
                ?? targetTab.flatMap { BrowserAutomation.Browser(rawValue: $0.bundleID) }
                ?? preferredChromiumBrowser(workspace: workspace)
            resolvedTitle = trimmed(rawTitle) ?? trimmed(targetTab?.title) ?? resolvedURL.host ?? resolvedURL.absoluteString
        } else {
            guard let picked = bestPlayingTab(in: gatheredTabs) else {
                throw RelayError.message("No open web page or playing video tab was found to bookmark.")
            }
            targetTab = picked
            resolvedURL = try validatedWebURL(picked.url)
            targetBrowser = explicitBrowser ?? BrowserAutomation.Browser(rawValue: picked.bundleID) ?? .chrome
            resolvedTitle = trimmed(rawTitle) ?? trimmed(picked.title) ?? resolvedURL.host ?? resolvedURL.absoluteString
        }

        if chromiumScriptableBrowsers.contains(targetBrowser) {
            guard isRunning(targetBrowser, workspace: workspace) else {
                throw RelayError.message("\(targetBrowser.name) must be open to add a bookmark directly to its bookmarks bar.")
            }
            return try await createChromiumBookmark(
                browser: targetBrowser,
                url: resolvedURL,
                title: resolvedTitle,
                requestedFolder: trimmed(folderName)
            )
        }

        // For Safari / Arc when user specifically only uses Safari/Arc: focus tab and trigger Add Bookmark menu if possible.
        if let tab = targetTab {
            _ = try? await focusAppleEventTab(browser: targetBrowser, windowIndex: tab.windowIndex, tabIndex: tab.tabIndex, workspace: workspace)
        }
        if AXIsProcessTrusted(), let app = NSRunningApplication.runningApplications(withBundleIdentifier: targetBrowser.rawValue).first,
           let menuResult = tryPressAddBookmarkMenu(for: app, browser: targetBrowser, title: resolvedTitle, url: resolvedURL) {
            return menuResult
        }
        throw RelayError.message("Direct AppleEvents bookmark creation is supported in Google Chrome, Brave, and Microsoft Edge. Found “\(resolvedTitle)” (\(resolvedURL.absoluteString)) in \(targetBrowser.name); press Command-D in \(targetBrowser.name) to add it to Bookmarks/Favorites.")
    }

    private static func resolveTargetTab(in tabs: [TabInfo], urlSubstring: String?, windowIndex: Int?, tabIndex: Int?) -> TabInfo? {
        if let windowIndex, let tabIndex,
           let exact = tabs.first(where: { $0.windowIndex == windowIndex && $0.tabIndex == tabIndex }) {
            return exact
        }
        if let query = trimmed(urlSubstring) {
            if let match = tabs.first(where: { $0.url.localizedCaseInsensitiveContains(query) || $0.title.localizedCaseInsensitiveContains(query) }) {
                return match
            }
        }
        return bestPlayingTab(in: tabs)
    }

    private static func preferredChromiumBrowser(workspace: NSWorkspace) -> BrowserAutomation.Browser {
        for browser in chromiumScriptableBrowsers where isRunning(browser, workspace: workspace) {
            return browser
        }
        for browser in chromiumScriptableBrowsers where workspace.urlForApplication(withBundleIdentifier: browser.rawValue) != nil {
            return browser
        }
        return .chrome
    }

    private static func isRunning(_ browser: BrowserAutomation.Browser, workspace: NSWorkspace) -> Bool {
        workspace.runningApplications.contains {
            !$0.isTerminated && $0.bundleIdentifier?.caseInsensitiveCompare(browser.rawValue) == .orderedSame
        }
    }

    private static func trimmed(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func readTabs(for browser: BrowserAutomation.Browser, workspace: NSWorkspace) async throws -> [TabInfo] {
        let appID = browser.rawValue
        let source: String
        if browser == .safari {
            source = """
            on run_relay()
                tell application id "\(appID)"
                    set windowList to every window
                    set outDesc to {}
                    repeat with wIdx from 1 to (count of windowList)
                        set w to item wIdx of windowList
                        set wID to ""
                        try
                            set wID to (id of w) as text
                        end try
                        set activeIdx to 0
                        try
                            set curTab to current tab of w
                            set tabList to every tab of w
                            repeat with tIdx from 1 to (count of tabList)
                                set t to item tIdx of tabList
                                if t is curTab then set activeIdx to tIdx
                            end repeat
                        end try
                        set tabList to {}
                        try
                            set tabList to every tab of w
                        end try
                        repeat with tIdx from 1 to (count of tabList)
                            set t to item tIdx of tabList
                            set tTitle to ""
                            set tURL to ""
                            try
                                set tTitle to (name of t) as text
                            end try
                            try
                                set tURL to (URL of t) as text
                            end try
                            set end of outDesc to {wID, wIdx, (tIdx as text), tIdx, (tIdx = activeIdx), tTitle, tURL}
                        end repeat
                    end repeat
                    return outDesc
                end tell
            end run_relay
            """
        } else {
            let readWindowMode = browser == .arc ? "" : """
                        try
                            set wMode to (mode of w) as text
                        end try
            """
            source = """
            on run_relay()
                tell application id "\(appID)"
                    set windowList to every window
                    set outDesc to {}
                    repeat with wIdx from 1 to (count of windowList)
                        set w to item wIdx of windowList
                        set wMode to "normal"
            \(readWindowMode)
                        if wMode is not "incognito" then
                            set wID to ""
                            try
                                set wID to (id of w) as text
                            end try
                            set activeIdx to 0
                            try
                                set activeIdx to (active tab index of w) as integer
                            end try
                            set tabList to {}
                            try
                                set tabList to every tab of w
                            end try
                            repeat with tIdx from 1 to (count of tabList)
                                set t to item tIdx of tabList
                                set tID to ""
                                set tTitle to ""
                                set tURL to ""
                                try
                                    set tID to (id of t) as text
                                end try
                                try
                                    set tTitle to (title of t) as text
                                end try
                                try
                                    set tURL to (URL of t) as text
                                end try
                                set end of outDesc to {wID, wIdx, tID, tIdx, (tIdx = activeIdx), tTitle, tURL}
                            end repeat
                        end if
                    end repeat
                    return outDesc
                end tell
            end run_relay
            """
        }

        struct RawTabRow: Sendable {
            let windowID: String
            let windowIndex: Int
            let tabID: String
            let tabIndex: Int
            let isActiveTab: Bool
            let title: String
            let url: String
        }
        let rows: [RawTabRow] = try await runAppleScriptSubroutine(
            source: source,
            handler: "run_relay",
            arguments: [],
            browserName: browser.name
        ) { descriptor in
            let count = descriptor.numberOfItems
            guard count > 0 else { return [] }
            var parsed: [RawTabRow] = []
            parsed.reserveCapacity(count)
            for idx in 1...count {
                guard let row = descriptor.atIndex(idx), row.numberOfItems >= 7 else { continue }
                parsed.append(RawTabRow(
                    windowID: row.atIndex(1)?.stringValue ?? "",
                    windowIndex: Int(row.atIndex(2)?.int32Value ?? 1),
                    tabID: row.atIndex(3)?.stringValue ?? "",
                    tabIndex: Int(row.atIndex(4)?.int32Value ?? 1),
                    isActiveTab: row.atIndex(5)?.booleanValue ?? false,
                    title: row.atIndex(6)?.stringValue ?? "",
                    url: row.atIndex(7)?.stringValue ?? ""
                ))
            }
            return parsed
        }
        var audibleTitles: [String] = []
        if AXIsProcessTrusted(), let app = workspace.runningApplications.first(where: {
            !$0.isTerminated && $0.bundleIdentifier?.caseInsensitiveCompare(browser.rawValue) == .orderedSame
        }) {
            audibleTitles = audibleTabLabels(for: app.processIdentifier)
        }

        return rows.map { row in
            let isAudible = matchesAudibleTitle(row.title, audibleLabels: audibleTitles)
            return TabInfo(
                browserName: browser.name,
                bundleID: browser.rawValue,
                windowID: row.windowID,
                windowIndex: row.windowIndex,
                tabID: row.tabID,
                tabIndex: row.tabIndex,
                isActiveTab: row.isActiveTab,
                title: row.title,
                url: row.url,
                isVideoTab: isVideoCandidate(url: row.url, title: row.title),
                isAudible: isAudible
            )
        }
    }

    private static func focusAppleEventTab(browser: BrowserAutomation.Browser, windowIndex: Int, tabIndex: Int, workspace: NSWorkspace) async throws -> String {
        let appID = browser.rawValue
        let source: String
        if browser == .safari {
            source = """
            on focus_relay(wIdxStr, tIdxStr)
                set wIdx to wIdxStr as integer
                set tIdx to tIdxStr as integer
                tell application id "\(appID)"
                    set w to window wIdx
                    set current tab of w to tab tIdx of w
                    set index of w to 1
                    activate
                    return (URL of current tab of front window) as text
                end tell
            end focus_relay
            """
        } else {
            source = """
            on focus_relay(wIdxStr, tIdxStr)
                set wIdx to wIdxStr as integer
                set tIdx to tIdxStr as integer
                tell application id "\(appID)"
                    set w to window wIdx
                    set active tab index of w to tIdx
                    set index of w to 1
                    activate
                    return (URL of active tab of front window) as text
                end tell
            end focus_relay
            """
        }
        let focusedURL: String = try await runAppleScriptSubroutine(
            source: source,
            handler: "focus_relay",
            arguments: [String(windowIndex), String(tabIndex)],
            browserName: browser.name
        ) { descriptor in
            descriptor.stringValue ?? ""
        }
        if let app = workspace.runningApplications.first(where: { !$0.isTerminated && $0.bundleIdentifier?.caseInsensitiveCompare(browser.rawValue) == .orderedSame }) {
            app.activate(options: [.activateAllWindows])
        }
        return focusedURL
    }

    private static func createChromiumBookmark(browser: BrowserAutomation.Browser, url: URL, title: String, requestedFolder: String?) async throws -> ToolResult {
        let targetFolder = requestedFolder ?? ""
        let appID = browser.rawValue
        // Pure AppleEvents (no shell script): compare ignoring case using AppleScript's native `ignoring case`.
        let cleanSource = """
        on bookmark_relay(targetTitle, targetURL, folderName)
            tell application id "\(appID)"
                set barFolder to bookmarks bar
                set containerFolder to barFolder
                set containerName to "Bookmarks Bar"
                if folderName is not "" then
                    set isBarAlias to false
                    ignoring case
                        if folderName is "bookmarks bar" or folderName is "bookmarks" then
                            set isBarAlias to true
                        end if
                    end ignoring
                    if not isBarAlias then
                        set matchedFolder to missing value
                        ignoring case
                            repeat with f in bookmark folders of barFolder
                                if (title of f) is folderName then
                                    set matchedFolder to f
                                    exit repeat
                                end if
                            end repeat
                        end ignoring
                        if matchedFolder is missing value then
                            set isGenericFav to false
                            ignoring case
                                if folderName is "favorites" or folderName is "favourites" then
                                    set isGenericFav to true
                                end if
                            end ignoring
                            if not isGenericFav then
                                set matchedFolder to make new bookmark folder at end of bookmark folders of barFolder with properties {title:folderName}
                            end if
                        end if
                        if matchedFolder is not missing value then
                            set containerFolder to matchedFolder
                            set containerName to (title of matchedFolder) as text
                        end if
                    end if
                end if

                repeat with existingItem in bookmark items of containerFolder
                    set exURL to ""
                    try
                        set exURL to (URL of existingItem) as text
                    end try
                    if exURL is targetURL then
                        set exID to (id of existingItem) as text
                        set exTitle to (title of existingItem) as text
                        return {"existing", containerName, exID, exTitle, exURL}
                    end if
                end repeat

                set createdItem to make new bookmark item at end of bookmark items of containerFolder with properties {title:targetTitle, URL:targetURL}
                set readID to (id of createdItem) as text
                set readTitle to (title of createdItem) as text
                set readURL to (URL of createdItem) as text
                return {"created", containerName, readID, readTitle, readURL}
            end tell
        end bookmark_relay
        """
        let fields: [String] = try await runAppleScriptSubroutine(
            source: cleanSource,
            handler: "bookmark_relay",
            arguments: [title, url.absoluteString, targetFolder],
            browserName: browser.name
        ) { descriptor in
            (1...5).map { descriptor.atIndex($0)?.stringValue ?? "" }
        }
        let status = fields[0]
        let container = fields[1].isEmpty ? "Bookmarks Bar" : fields[1]
        let readID = fields[2]
        let readTitle = fields[3].isEmpty ? title : fields[3]
        let readURL = fields[4]
        guard !readID.isEmpty, readURL == url.absoluteString || BrowserAutomation.matchesDestination(readURL, expected: url) else {
            throw RelayError.message("Bookmark creation in \(browser.name) could not be verified by readback.")
        }
        if status == "existing" {
            return ToolResult(
                summary: "“\(readTitle)” (\(readURL)) is already saved in \(browser.name) \(container).",
                evidence: "Verified existing bookmark item id=\(readID) in \(browser.name) \(container) via native AppleEvents readback.",
                verified: true
            )
        }
        return ToolResult(
            summary: "Added “\(readTitle)” (\(readURL)) to \(browser.name) \(container).",
            evidence: "Created and verified bookmark item id=\(readID) in \(browser.name) \(container) via native AppleEvents readback.",
            verified: true
        )
    }

    private static func tryPressAddBookmarkMenu(for app: NSRunningApplication, browser: BrowserAutomation.Browser, title: String, url: URL) -> ToolResult? {
        app.activate(options: [.activateAllWindows])
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.2)
        var menuBarValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXMenuBarAttribute as CFString, &menuBarValue) == .success,
              let menuBarValue else { return nil }
        let menuBar = unsafeDowncast(menuBarValue, to: AXUIElement.self)
        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(menuBar, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let items = childrenValue as? [AXUIElement] else { return nil }
        for menuBarItem in items {
            var titleRef: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(menuBarItem, kAXTitleAttribute as CFString, &titleRef)
            guard let menuTitle = titleRef as? String,
                  ["Bookmarks", "Bookmarks & Tabs"].contains(where: { menuTitle.localizedCaseInsensitiveContains($0) }) else { continue }
            var subChildrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(menuBarItem, kAXChildrenAttribute as CFString, &subChildrenRef) == .success,
               let subMenus = subChildrenRef as? [AXUIElement] {
                for menu in subMenus {
                    var menuItemsRef: CFTypeRef?
                    if AXUIElementCopyAttributeValue(menu, kAXChildrenAttribute as CFString, &menuItemsRef) == .success,
                       let menuItems = menuItemsRef as? [AXUIElement] {
                        for item in menuItems {
                            var itemTitleRef: CFTypeRef?
                            _ = AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &itemTitleRef)
                            let itemTitle = (itemTitleRef as? String ?? "").lowercased()
                            if itemTitle.hasPrefix("add bookmark") || itemTitle.hasPrefix("bookmark this") {
                                if AXUIElementPerformAction(item, kAXPressAction as CFString) == .success {
                                    return ToolResult(
                                        summary: "Opened “Add Bookmark” in \(browser.name) for “\(title)” (\(url.absoluteString)).",
                                        evidence: "Pressed native Bookmark menu item in \(browser.name) after focusing the target tab.",
                                        verified: false
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
        return nil
    }

    private static func audibleTabLabels(for pid: pid_t) -> [String] {
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 0.1)
        guard let windows = axChildrenOrAttr(root, kAXWindowsAttribute) else { return [] }
        var labels: [String] = []
        for window in windows.prefix(6) {
            var queue: [(AXUIElement, Int)] = [(window, 0)]
            var cursor = 0
            while cursor < queue.count && cursor < 160 {
                let (element, depth) = queue[cursor]
                cursor += 1
                AXUIElementSetMessagingTimeout(element, 0.02)
                let role = axString(element, kAXRoleAttribute)
                if ["AXRadioButton", "AXTab", "AXButton"].contains(role) {
                    let title = axString(element, kAXTitleAttribute)
                    let desc = axString(element, kAXDescriptionAttribute)
                    let help = axString(element, kAXHelpAttribute)
                    let combined = [title, desc, help].joined(separator: " ").lowercased()
                    if combined.contains("audio playing") || combined.contains("playing audio") || combined.contains("mute") {
                        if !title.isEmpty { labels.append(title) }
                        if !desc.isEmpty { labels.append(desc) }
                    }
                }
                if depth < 5, let children = axChildrenOrAttr(element, kAXChildrenAttribute) {
                    queue.append(contentsOf: children.prefix(40).map { ($0, depth + 1) })
                }
            }
        }
        return labels
    }

    private static func matchesAudibleTitle(_ title: String, audibleLabels: [String]) -> Bool {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, !audibleLabels.isEmpty else { return false }
        let prefix = String(trimmedTitle.prefix(24))
        return audibleLabels.contains { label in
            label.localizedCaseInsensitiveContains(trimmedTitle)
                || trimmedTitle.localizedCaseInsensitiveContains(label)
                || (!prefix.isEmpty && label.localizedCaseInsensitiveContains(prefix))
        }
    }

    private static func axChildrenOrAttr(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? [AXUIElement]
    }

    private static func axString(_ element: AXUIElement, _ attribute: String) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return "" }
        return value as? String ?? ""
    }

    nonisolated private static func runAppleScriptSubroutine<T: Sendable>(
        source: String,
        handler: String,
        arguments: [String],
        browserName: String,
        parse: @Sendable @escaping (NSAppleEventDescriptor) throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        return try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard let script = NSAppleScript(source: source) else {
                throw RelayError.message("Could not prepare Automation script for \(browserName).")
            }
            var compileError: NSDictionary?
            guard script.compileAndReturnError(&compileError) else {
                let message = (compileError?[NSAppleScript.errorMessage] as? String) ?? "Failed to compile Automation script."
                throw RelayError.message("\(browserName) automation error: \(message)")
            }
            let listDescriptor = NSAppleEventDescriptor.list()
            for (offset, arg) in arguments.enumerated() {
                listDescriptor.insert(NSAppleEventDescriptor(string: arg), at: offset + 1)
            }
            // kASAppleScriptSuite ('ascr'), kASSubroutineEvent ('psbr'), keyASSubroutineName ('snam')
            let event = NSAppleEventDescriptor(
                eventClass: AEEventClass(0x61736372),
                eventID: AEEventID(0x70736272),
                targetDescriptor: NSAppleEventDescriptor.currentProcess(),
                returnID: AEReturnID(kAutoGenerateReturnID),
                transactionID: AETransactionID(kAnyTransactionID)
            )
            event.setParam(NSAppleEventDescriptor(string: handler), forKeyword: AEKeyword(0x736e616d))
            event.setParam(listDescriptor, forKeyword: AEKeyword(keyDirectObject))
            var errorInfo: NSDictionary?
            let reply = script.executeAppleEvent(event, error: &errorInfo)
            if let errorInfo {
                let code = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
                if code == -1743 {
                    throw RelayError.message("Allow Relay to control \(browserName) in System Settings → Privacy & Security → Automation, then try again.")
                }
                let message = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "Automation error \(code)"
                throw RelayError.message("\(browserName) automation failed: \(message)")
            }
            return try parse(reply)
        }.value
    }
}
