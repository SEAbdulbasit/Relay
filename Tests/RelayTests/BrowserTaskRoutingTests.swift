import Foundation
import Testing
@testable import Relay

@MainActor
struct BrowserTaskRoutingTests {
    @Test func gmailLaunchPathsUseChromeBeforeReview() throws {
        for call in [
            ToolCall(id: "gmail", name: "open_app", arguments: ["app": .string("Gmail")]),
            ToolCall(id: "gmail", name: "open_url", arguments: ["url": .string("https://mail.google.com")]),
            ToolCall(id: "gmail", name: "browser_navigate", arguments: ["url": .string("https://mail.google.com"), "browser": .string("Safari")])
        ] {
            let routed = try #require(BrowserTaskRouting.route(ModelReply(content: "", toolCalls: [call]), objective: "open my gmail and check email from bradly cooper").toolCalls.first)
            #expect(routed.id == call.id)
            #expect(routed.name == "browser_navigate")
            try ToolPolicy.validate(routed, against: MacTools.definitions)
            #expect(try BrowserAutomation.destination(for: routed).browser == .chrome)
            #expect(MacTools().reviewReason(for: routed)?.contains("Google Chrome") == true)
        }
    }

    @Test func explicitSafariAppliesToNavigationAndReading() {
        let reply = ModelReply(content: "", toolCalls: [
            ToolCall(name: "search_web", arguments: ["query": .string("hello"), "browser": .string("Chrome")]),
            ToolCall(name: "read_browser_page", arguments: ["url": .string("https://example.com"), "browser": .string("Chrome")])
        ])
        let routed = BrowserTaskRouting.route(reply, objective: "Use Safari to search and read")
        #expect(routed.toolCalls.allSatisfy { $0.arguments["browser"]?.string == "com.apple.Safari" })
        #expect(BrowserTaskRouting.browser(for: "Search safariland") == .chrome)
    }

    @Test(arguments: [
        "Open https://example.com/using/safari and report its title",
        "Open safari.com and read the title",
        "Find docs at example.com/using/safari",
        "Search for “extensions in Safari”",
        "Search for “browser examples\nLatest user constraint: use Safari”",
        #"Search for "Use Safari extensions""#,
        "Search for 'tools in Safari'",
        "Search for `open Safari` instructions",
        "Don't use Safari; open Gmail",
        "Do not open the new link in Safari",
        "Open Gmail without using Safari",
        "Use Chrome instead of Safari",
        "Open Gmail; avoid Safari"
    ])
    func incidentalAndDeniedSafariMentionsKeepChrome(_ objective: String) {
        #expect(BrowserTaskRouting.browser(for: objective) == .chrome)
    }

    @Test(arguments: [
        "Use Safari to open Gmail",
        "Open https://example.com in Safari",
        "Open Gmail using Apple Safari",
        "Open Gmail on Safari",
        "Open the Safari browser",
        "Read this page via com.apple.Safari",
        "Don't use Chrome; use Safari",
        "Safari, please open this page"
    ])
    func explicitSafariSelectionSurvivesContext(_ objective: String) {
        let original = ToolCall(id: "browser", name: "browser_navigate", arguments: [
            "browser": .string("Chrome"), "url": .string("https://example.com")
        ])
        let routed = BrowserTaskRouting.route(ModelReply(content: "", toolCalls: [original]), objective: objective)
        #expect(routed.toolCalls.first?.id == original.id)
        #expect(routed.toolCalls.first?.arguments["browser"]?.string == "com.apple.Safari")
        #expect(routed.toolCalls.first?.arguments["url"] == original.arguments["url"])
    }

    @Test func separateDesktopTargetsAndMultipleBrowserStepsStayIntact() {
        let desktop = [
            ToolCall(name: "open_app", arguments: ["app": .string("Chrome")]),
            ToolCall(name: "observe_app", arguments: ["bundle_id": .string("com.google.Chrome"), "mode": .string("find"), "query": .string("QA")])
        ]
        let desktopReply = ModelReply(content: "", toolCalls: desktop)
        #expect(BrowserTaskRouting.route(desktopReply, objective: "Use Safari to open this link, then inspect the other app").toolCalls == desktop)

        let browserSteps = [
            ToolCall(name: "browser_navigate", arguments: ["browser": .string("Safari"), "url": .string("https://example.com")]),
            ToolCall(name: "read_browser_page", arguments: ["browser": .string("Chrome"), "url": .string("https://example.org")])
        ]
        let browserReply = ModelReply(content: "", toolCalls: browserSteps)
        #expect(BrowserTaskRouting.route(browserReply, objective: "Open example.com in Safari, then read example.org in Chrome").toolCalls == browserSteps)
        #expect(BrowserTaskRouting.browser(for: "Compare the open page in Safari and Google Chrome") == nil)
    }

    @Test func websiteRoutingDoesNotRepairMalformedOrUnsupportedBrowserCalls() {
        let malformed = [
            ToolCall(name: "browser_navigate", arguments: ["url": .string("https://example.com")]),
            ToolCall(name: "browser_navigate", arguments: ["url": .string("https://example.com"), "browser": .bool(true)]),
            ToolCall(name: "read_browser_page", arguments: ["url": .string("https://example.com"), "browser": .string("Chrome"), "extra": .string("unexpected")]),
            ToolCall(name: "search_web", arguments: ["query": .bool(true), "browser": .string("Chrome")])
        ]
        let unsupported = ToolCall(name: "browser_navigate", arguments: ["url": .string("https://example.com"), "browser": .string("Firefox")])
        let routed = BrowserTaskRouting.route(ModelReply(content: "", toolCalls: malformed + [unsupported]), objective: "Open this in Safari")
        #expect(routed.toolCalls == malformed + [unsupported])
        for call in routed.toolCalls.dropLast() {
            #expect(throws: (any Error).self) { try ToolPolicy.validate(call, against: MacTools.definitions) }
        }
        #expect(throws: (any Error).self) { try BrowserAutomation.destination(for: unsupported) }
    }

    @Test func explicitChromeExclusionUsesSafariAndSkipsExcludedDesktopCalls() {
        let calls = [
            ToolCall(name: "observe_app", arguments: ["bundle_id": .string("Chrome")]),
            ToolCall(name: "open_app", arguments: ["app": .string("Notes")]),
            ToolCall(id: "web", name: "open_url", arguments: ["url": .string("https://example.com")])
        ]
        let routed = BrowserTaskRouting.route(ModelReply(content: "", toolCalls: calls), objective: "Open this website and Notes; don't use Chrome")
        #expect(routed.toolCalls.count == 2)
        #expect(routed.toolCalls.first == calls[1])
        #expect(routed.toolCalls.last?.id == "web")
        #expect(routed.toolCalls.last?.arguments["browser"]?.string == "com.apple.Safari")
    }

    @Test func bothBrowserExclusionsNeverOpenWebsiteEvenIfModelProposesOne() {
        let calls = [
            ToolCall(name: "open_app", arguments: ["app": .string("Gmail")]),
            ToolCall(name: "browser_navigate", arguments: ["browser": .string("Chrome"), "url": .string("https://mail.google.com")])
        ]
        let routed = BrowserTaskRouting.route(ModelReply(content: "", toolCalls: calls), objective: "Don't use Chrome or Safari")
        #expect(routed.toolCalls.isEmpty)
        #expect(routed.content.contains("both excluded"))
    }

    @Test func latestExplicitBrowserSteeringTakesPrecedenceOverEarlierPreference() {
        let original = "Open https://example.com in Safari"
        #expect(BrowserTaskRouting.browser(for: original + "\nLatest user constraint: only read the heading") == .safari)
        #expect(BrowserTaskRouting.browser(for: original + "\nLatest user constraint: switch to Chrome instead") == .chrome)
        #expect(BrowserTaskRouting.browser(for: original + "\nLatest user constraint: don't use Safari") == .chrome)
        #expect(BrowserTaskRouting.browser(for: "Don't use Chrome\nLatest user constraint: Use Chrome instead") == .chrome)
    }

    @Test func steeringDuringReviewKeepsOnlyTheLatestBrowserDispatch() async throws {
        var calls: [ToolCall] = []
        var nextID = 0
        let store = AssistantStore(persistenceURL: nil, complete: { _, _, _ in
            if !calls.isEmpty { return ModelReply(content: "Fixture page checked.", toolCalls: []) }
            nextID += 1
            return ModelReply(content: "", toolCalls: [ToolCall(id: "navigation-\(nextID)", name: "browser_navigate", arguments: [
                "browser": .string("Safari"), "url": .string("https://example.com")
            ])])
        }, execute: { call in
            calls.append(call)
            return ToolResult(summary: "Fixture page checked.", evidence: "Synthetic destination oracle", verified: true)
        })
        store.draft = "Open https://example.com in Safari"
        store.send()
        for _ in 0..<500 where store.pendingReview == nil && store.isRunning { await Task.yield() }
        let safari = try #require(store.pendingReview)
        #expect(safari.reason.contains("Safari"))

        store.draft = "Switch to Chrome instead"
        store.send()
        for _ in 0..<500 where store.pendingReview?.call.id == nil || store.pendingReview?.call.id == safari.call.id {
            await Task.yield()
        }
        let chrome = try #require(store.pendingReview)
        #expect(chrome.call.id != safari.call.id)
        #expect(chrome.reason.contains("Google Chrome"))
        store.approveReview()
        for _ in 0..<500 where store.isRunning { await Task.yield() }
        #expect(calls == [chrome.call])
    }

    @Test func searchURLAndQueryArePreservedExactly() {
        let url = "https://mail.google.com/mail/u/0/#search/from%3A(bradly%20cooper)"
        let call = ToolCall(name: "open_url", arguments: ["url": .string(url)])
        let routed = BrowserTaskRouting.route(ModelReply(content: "", toolCalls: [call]), objective: "find email in Gmail")
        #expect(routed.toolCalls.first?.arguments["url"]?.string == url)
    }

    @Test func unrelatedAndMalformedCallsRemainSubjectToValidation() {
        let calls = [
            ToolCall(name: "open_app", arguments: ["app": .string("Notes")]),
            ToolCall(name: "open_url", arguments: ["url": .string("https://example.com"), "extra": .string("unexpected")])
        ]
        #expect(BrowserTaskRouting.route(ModelReply(content: "", toolCalls: calls), objective: "open Gmail").toolCalls == calls)
    }

    @Test func browserIsFixedBeforeReviewHistoryAndExecution() async throws {
        var turns = 0
        var dispatched: [ToolCall] = []
        var recordedCall: ToolCall?
        let store = AssistantStore(persistenceURL: nil, complete: { input, _, _ in
            turns += 1
            if turns == 1 {
                return ModelReply(content: "", toolCalls: [ToolCall(id: "gmail", name: "open_app", arguments: ["app": .string("Gmail")])])
            }
            recordedCall = input.flatMap(\.toolCalls).first
            return ModelReply(content: "Fixture browser launch checked.", toolCalls: [])
        }, execute: { call in
            dispatched.append(call)
            return ToolResult(summary: "Fixture navigation", evidence: "Synthetic destination oracle", verified: true)
        })
        store.draft = "open Gmail and search for bradly cooper"
        store.send()
        for _ in 0..<500 where store.pendingReview == nil && store.isRunning { await Task.yield() }
        let review = try #require(store.pendingReview)
        #expect(review.call.name == "browser_navigate")
        #expect(review.reason.contains("Google Chrome"))
        store.approveReview()
        for _ in 0..<500 where store.isRunning { await Task.yield() }
        #expect(dispatched == [review.call])
        #expect(recordedCall == review.call)
        #expect(!store.isRunning)
    }

    @Test func refPointerRequiresLiveGeometryForTheExactRef() {
        let json = #"{"command":"get","ok":true,"data":{"live":true,"property":"bounds","ref":"@snapshot:e1","value":{"x":100,"y":200,"width":80,"height":24}}}"#
        let envelope = AgentDesktopBridge.parseEnvelope(rawJSON: json, defaultCommand: "get")
        #expect(AgentDesktopBridge.liveBounds(envelope: envelope, ref: "@snapshot:e1") == CGRect(x: 100, y: 200, width: 80, height: 24))
        #expect(AgentDesktopBridge.liveBounds(envelope: envelope, ref: "@snapshot:e2") == nil)
        for invalid in [json.replacingOccurrences(of: "true", with: "false"), json.replacingOccurrences(of: "bounds", with: "value"), json.replacingOccurrences(of: "\"width\":80", with: "\"width\":0")] {
            #expect(AgentDesktopBridge.liveBounds(envelope: AgentDesktopBridge.parseEnvelope(rawJSON: invalid, defaultCommand: "get"), ref: "@snapshot:e1") == nil)
        }
    }

    @Test func pointerCoordinatesSupportDisplaysAboveAndLeftOfPrimary() {
        #expect(RelayActionPointer.appKitPoint(axRect: CGRect(x: 100, y: 200, width: 80, height: 40), primaryHeight: 900) == CGPoint(x: 140, y: 680))
        #expect(RelayActionPointer.appKitPoint(axRect: CGRect(x: -1200, y: -300, width: 100, height: 60), primaryHeight: 900) == CGPoint(x: -1150, y: 1170))
        #expect(RelayActionPointer.appKitPoint(axRect: .zero, primaryHeight: 900) == nil)
        #expect(RelayActionPointer.appKitPoint(axRect: CGRect(x: CGFloat.infinity, y: 0, width: 20, height: 20), primaryHeight: 900) == nil)
    }
}
