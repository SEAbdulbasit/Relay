import Foundation

/// Resolve website browser selection before history, review and execution see a tool call.
@MainActor
enum BrowserTaskRouting {
    private struct Intent {
        var selected: Set<BrowserAutomation.Browser> = []
        var excluded: Set<BrowserAutomation.Browser> = []

        var browser: BrowserAutomation.Browser? {
            if selected.count > 1 || excluded.count > 1 { return nil }
            if let requested = selected.first { return requested }
            return excluded.contains(.chrome) ? .safari : .chrome
        }

        mutating func merge(_ latest: Intent) {
            if !latest.selected.isEmpty {
                selected = latest.selected
                excluded.subtract(latest.selected)
            }
            excluded.formUnion(latest.excluded)
            selected.subtract(latest.excluded)
        }
    }

    static func browser(for objective: String) -> BrowserAutomation.Browser? {
        intent(for: objective).browser
    }

    static func route(_ reply: ModelReply, objective: String) -> ModelReply {
        let intent = intent(for: objective)
        var reply = reply
        let originalCount = reply.toolCalls.count
        reply.toolCalls.removeAll { call in
            if let target = desktopBrowser(for: call), intent.excluded.contains(target) { return true }
            return intent.excluded.count > 1 && isWebsiteCall(call)
        }
        if originalCount != reply.toolCalls.count {
            reply.content = intent.excluded.count > 1
                ? "Chrome and Safari are both excluded. Choose one if you want me to continue in a browser."
                : "That action would use a browser you excluded, so I did not run it."
        }
        // When a request deliberately names both browsers, keep each structured target.
        guard let browser = intent.browser else { return reply }
        reply.toolCalls = reply.toolCalls.map { original in
            var call = original
            switch call.name {
            case "open_url":
                guard Set(call.arguments.keys) == ["url"], call.arguments["url"]?.string != nil else { return call }
                call.name = "browser_navigate"
                call.arguments["browser"] = .string(browser.rawValue)
            case "open_app":
                guard Set(call.arguments.keys) == ["app"],
                      let name = call.arguments["app"]?.string,
                      let url = MacTools.webAppFallbackURL(name) else { return call }
                call.name = "browser_navigate"
                call.arguments = ["url": .string(url.absoluteString), "browser": .string(browser.rawValue)]
            case "browser_navigate", "search_web", "read_browser_page":
                let target = call.name == "search_web" ? "query" : "url"
                // Do not repair malformed or unsupported model arguments before normal validation.
                guard Set(call.arguments.keys) == [target, "browser"],
                      call.arguments[target]?.string != nil,
                      let originalBrowser = call.arguments["browser"]?.string,
                      (try? BrowserAutomation.validatedBrowser(originalBrowser)) != nil else { return call }
                call.arguments["browser"] = .string(browser.rawValue)
            default:
                // Generic desktop observations and app launches may be separate requested steps.
                break
            }
            return call
        }
        return reply
    }

    private static func desktopBrowser(for call: ToolCall) -> BrowserAutomation.Browser? {
        switch call.name {
        case "open_app": return call.arguments["app"]?.string.flatMap { try? BrowserAutomation.validatedBrowser($0) }
        case "observe_app": return call.arguments["bundle_id"]?.string.flatMap { try? BrowserAutomation.validatedBrowser($0) }
        default: return nil
        }
    }

    private static func isWebsiteCall(_ call: ToolCall) -> Bool {
        switch call.name {
        case "browser_navigate", "search_web", "read_browser_page", "open_url": return true
        case "open_app": return call.arguments["app"]?.string.flatMap(MacTools.webAppFallbackURL) != nil
        default: return false
        }
    }

    private static func intent(for objective: String) -> Intent {
        // Mask quoted text before splitting, so a quoted newline cannot imitate steering.
        let prose = objective
            .replacingOccurrences(of: #"(?<!\p{L})'[^'\r\n]*'(?!\p{L})|‘[^’]*’|“[^”]*”|"[^"]*"|`[^`]*`"#, with: " ", options: .regularExpression)
        return prose.components(separatedBy: "\nLatest user constraint: ").reduce(into: Intent()) {
            $0.merge(parseIntent($1))
        }
    }

    private static func parseIntent(_ objective: String) -> Intent {
        // Keep URLs out of intent matching. The original objective and tool payloads remain untouched.
        let prose = objective.lowercased()
            .replacingOccurrences(of: #"(?:[a-z][a-z0-9+.-]*://|www\.)[^\s<>,;]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?<![\w.])com\.apple\.safari(?![\w./])"#, with: "safari", options: .regularExpression)
            .replacingOccurrences(of: #"(?<![\w.])com\.google\.chrome(?![\w./])"#, with: "chrome", options: .regularExpression)
            .replacingOccurrences(of: #"(?:[a-z0-9-]+\.)+[a-z]{2,}(?::[0-9]+)?(?:[/#?][^\s<>,;]*)?"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "don't", with: "dont")
            .replacingOccurrences(of: "don’t", with: "dont")
        let selectors: Set<Substring> = ["in", "on", "with", "via", "using", "use", "open", "launch", "prefer", "preferably", "choose", "select"]
        let negations: Set<Substring> = ["not", "never", "dont", "avoid", "without", "except"]
        let conjunctions: Set<Substring> = ["and", "then", "or"]
        var intent = Intent()
        for clause in prose.split(whereSeparator: { ".;!?,\r\n".contains($0) }) {
            let words = clause.split { !$0.isLetter && !$0.isNumber }
            var previousMention: Int?
            var previousIntent: (index: Int, excluded: Bool)?
            for index in words.indices {
                let word = words[index]
                guard word == "safari" || word == "chrome" else { continue }
                defer { previousMention = index }
                var prefix = words[(previousMention.map { $0 + 1 } ?? 0)..<index]
                if word == "chrome", prefix.last == "google" { prefix = prefix.dropLast() }
                if word == "safari", prefix.last == "apple" { prefix = prefix.dropLast() }
                if prefix.last == "the" { prefix = prefix.dropLast() }
                let continuesList = prefix.last.map(conjunctions.contains) == true
                    && previousIntent != nil && previousIntent?.index == previousMention
                let directExclusion = prefix.last.map(negations.contains) == true
                    || prefix.suffix(2).elementsEqual(["instead", "of"])
                let explicit = prefix.last.map(selectors.contains) == true
                    || prefix.suffix(2).elementsEqual(["switch", "to"])
                    || directExclusion || continuesList
                    || (index <= 1 && prefix.isEmpty && words.dropFirst(index + 1).allSatisfy { ["please", "only", "browser"].contains($0) })
                guard explicit else { continue }
                let excluded = directExclusion || prefix.contains(where: negations.contains)
                    || (continuesList && previousIntent?.excluded == true)
                let browser: BrowserAutomation.Browser = word == "safari" ? .safari : .chrome
                if excluded {
                    intent.selected.remove(browser)
                    intent.excluded.insert(browser)
                } else {
                    intent.excluded.remove(browser)
                    intent.selected.insert(browser)
                }
                previousIntent = (index, excluded)
            }
        }
        return intent
    }
}
