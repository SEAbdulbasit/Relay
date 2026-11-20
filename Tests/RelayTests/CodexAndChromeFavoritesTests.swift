import Foundation
import Testing
@testable import Relay

@Suite(.serialized)
@MainActor
struct CodexAndChromeFavoritesTests {
    @Test func proposesFollowthroughDetectsGoAheadHandoffsWithoutFalsePositives() {
        #expect(AssistantStore.proposesFollowthrough("I found the YouTube tab in Chrome. Want me to go ahead and bookmark it?"))
        #expect(AssistantStore.proposesFollowthrough("I found the playing video. Say \"go ahead\" and I will add it to Favorites."))
        #expect(AssistantStore.proposesFollowthrough("Can I go ahead and add this video to your bookmarks bar?"))
        #expect(AssistantStore.proposesFollowthrough("Waiting for your go-ahead to proceed with the remaining step."))
        #expect(AssistantStore.proposesFollowthrough("Shall I add that video to Favorites now?"))

        #expect(!AssistantStore.proposesFollowthrough("Added \"Lo-fi Beats - YouTube\" to Chrome's Bookmarks Bar and verified it is saved."))
        #expect(!AssistantStore.proposesFollowthrough("> Want me to go ahead and bookmark it?"))
        #expect(!AssistantStore.proposesFollowthrough("```\nSay \"go ahead\" to continue\n```"))
    }

    @Test func canAutoApproveRoutineActionSkipsRoutinePromptsAndPreservesConsequentialGates() {
        let tools = MacTools()
        let safeNavigate = ToolCall(
            name: "browser_navigate",
            arguments: ["browser": .string("Chrome"), "url": .string("https://example.com")]
        )
        let safeOpenURL = ToolCall(
            name: "open_url",
            arguments: ["url": .string("https://www.youtube.com/watch?v=dQw4w9WgXcQ")]
        )
        let unverifiedPress = ToolCall(
            name: "press_control",
            arguments: ["bundle_id": .string("com.google.Chrome"), "element_id": .string("b1"), "label": .string("Bookmark This Tab")]
        )
        #expect(tools.canAutoApproveRoutineAction(safeNavigate, reviewReason: "Open Chrome and visit https://example.com"))
        #expect(tools.canAutoApproveRoutineAction(safeOpenURL, reviewReason: "Open https://www.youtube.com/watch?v=dQw4w9WgXcQ in browser"))
        // Fail closed when press_control has no live AX context yet:
        #expect(!tools.canAutoApproveRoutineAction(unverifiedPress, reviewReason: "Press button \"Bookmark This Tab\" in Google Chrome"))
        // Label exclusion policy allows routine chrome actions and blocks consequential labels:
        #expect(!MacTools.isExcludedControlLabel("Bookmark This Tab"))
        #expect(MacTools.isExcludedControlLabel("Send"))
        #expect(MacTools.isExcludedControlLabel("Delete Permanently"))
        #expect(MacTools.isExcludedControlLabel("Complete Purchase"))

        let sendMail = ToolCall(name: "send_mail", arguments: [:])
        let commitCalendar = ToolCall(name: "commit_calendar_event", arguments: [:])
        let moveFile = ToolCall(name: "move_file", arguments: [:])
        let stageAttachment = ToolCall(name: "stage_attachment", arguments: [:])
        let mcpRead = ToolCall(name: MainAgentMCPTools.readName, arguments: [:])
        let excludedPress = ToolCall(
            name: "press_control",
            arguments: ["bundle_id": .string("com.apple.mail"), "element_id": .string("send1"), "label": .string("Send")]
        )
        let deletePress = ToolCall(
            name: "press_control",
            arguments: ["bundle_id": .string("com.apple.finder"), "element_id": .string("del1"), "label": .string("Delete Permanently")]
        )
        let purchasePress = ToolCall(
            name: "press_control",
            arguments: ["bundle_id": .string("com.google.Chrome"), "element_id": .string("buy1"), "label": .string("Complete Purchase")]
        )
        let overwriteFile = ToolCall(name: "write_file", arguments: ["path": .string("/tmp/a.txt"), "content": .string("hi")])

        #expect(!tools.canAutoApproveRoutineAction(sendMail, reviewReason: "Send email via Apple Mail"))
        #expect(!tools.canAutoApproveRoutineAction(commitCalendar, reviewReason: "Create calendar event"))
        #expect(!tools.canAutoApproveRoutineAction(moveFile, reviewReason: "Move file"))
        #expect(!tools.canAutoApproveRoutineAction(stageAttachment, reviewReason: "Attach file"))
        #expect(!tools.canAutoApproveRoutineAction(mcpRead, reviewReason: "Read remote MCP resource"))
        #expect(!tools.canAutoApproveRoutineAction(excludedPress, reviewReason: "[Consequential action — verify recipient]"))
        #expect(!tools.canAutoApproveRoutineAction(deletePress, reviewReason: "[Consequential action — confirm delete]"))
        #expect(!tools.canAutoApproveRoutineAction(purchasePress, reviewReason: "[Consequential action — purchase]"))
        #expect(!tools.canAutoApproveRoutineAction(overwriteFile, reviewReason: "Overwrite /tmp/a.txt"))
    }

    @Test func codexCLIRunRecoversFromGoAheadPromptAndAutoApprovesRoutineBrowserSteps() async {
        var turn = 0
        var dispatched: [String] = []
        var sawCodexBackend = false
        var sawFollowthroughNudge = false

        let store = AssistantStore(
            persistenceURL: nil,
            complete: { messages, _, config in
                turn += 1
                if config.backend == .codexCLI {
                    sawCodexBackend = true
                }
                switch turn {
                case 1:
                    return ModelReply(
                        content: "I can inspect Chrome and add the playing video to Favorites. Want me to go ahead?",
                        toolCalls: []
                    )
                case 2:
                    sawFollowthroughNudge = messages.last?.content.contains("Reconsider your proposed handoff") == true
                    return ModelReply(
                        content: "",
                        toolCalls: [ToolCall(id: "tabs-1", name: "inspect_browser_tabs", arguments: ["browser": .string("Chrome")])]
                    )
                case 3:
                    return ModelReply(
                        content: "",
                        toolCalls: [ToolCall(
                            id: "bm-1",
                            name: "bookmark_browser_tab",
                            arguments: [
                                "browser": .string("Chrome"),
                                "url": .string("https://www.youtube.com/watch?v=test123"),
                                "title": .string("Playing Video - YouTube"),
                                "folder": .string("Favorites")
                            ]
                        )]
                    )
                case 4:
                    return ModelReply(
                        content: "",
                        toolCalls: [ToolCall(
                            id: "nav-1",
                            name: "browser_navigate",
                            arguments: ["browser": .string("Chrome"), "url": .string("https://www.youtube.com/watch?v=test123")]
                        )]
                    )
                default:
                    return ModelReply(
                        content: "Added \"Playing Video - YouTube\" to Chrome's Bookmarks Bar and verified it is saved.",
                        toolCalls: []
                    )
                }
            },
            execute: { call in
                dispatched.append(call.name)
                switch call.name {
                case "inspect_browser_tabs":
                    return ToolResult(
                        summary: "Found 1 video tab in Google Chrome.",
                        evidence: "[1:1 active, video, audio playing] Playing Video - YouTube — https://www.youtube.com/watch?v=test123",
                        verified: true
                    )
                case "bookmark_browser_tab":
                    return ToolResult(
                        summary: "Added \"Playing Video - YouTube\" to Chrome's Bookmarks Bar -> Favorites.",
                        evidence: "Verified Chrome bookmark entry exists in Favorites.",
                        verified: true
                    )
                case "browser_navigate":
                    return ToolResult(
                        summary: "Navigated Chrome to https://www.youtube.com/watch?v=test123.",
                        evidence: "Chrome tab opened.",
                        verified: true
                    )
                default:
                    return ToolResult(summary: "Unexpected \(call.name)", evidence: "", verified: true)
                }
            }
        )
        defer { store.stop() }

        store.configuration.backend = .codexCLI
        store.draft = "There is a video playing on Chrome, add it to favorites."
        store.send()
        await store.waitForConversationTaskToSettle()

        #expect(sawCodexBackend)
        #expect(sawFollowthroughNudge)
        #expect(dispatched == ["inspect_browser_tabs", "bookmark_browser_tab", "browser_navigate"])
        #expect(store.pendingReview == nil)
        #expect(store.phase == .idle)
        #expect(store.errorMessage == nil)
    }

    @Test func disablingAutoApproveRestoresReviewPromptAndConsequentialToolsAlwaysAsk() async {
        var turn = 0
        let store = AssistantStore(
            persistenceURL: nil,
            complete: { _, _, _ in
                turn += 1
                if turn == 1 {
                    return ModelReply(
                        content: "",
                        toolCalls: [ToolCall(
                            id: "nav-manual",
                            name: "browser_navigate",
                            arguments: ["browser": .string("Chrome"), "url": .string("https://example.com")]
                        )]
                    )
                }
                return ModelReply(content: "Done.", toolCalls: [])
            },
            execute: { call in
                ToolResult(summary: "Executed \(call.name)", evidence: "Verified", verified: true)
            }
        )
        defer {
            store.setAutoApproveRoutineActions(true)
            store.stop()
        }

        store.configuration.backend = .codexCLI
        store.setAutoApproveRoutineActions(false)
        store.draft = "Open example.com in Chrome."
        store.send()

        for _ in 0..<200 where store.pendingReview == nil && store.isRunning {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.phase == .awaitingReview)
        #expect(store.pendingReview?.call.name == "browser_navigate")
        store.denyReview()
        await store.waitForConversationTaskToSettle()
        #expect(store.pendingReview == nil)
    }

    @Test func sendMailStillRequiresReviewWhenCodexCLIAndAutoApproveAreEnabled() async {
        let directTools = MacTools()
        let sendCall = ToolCall(
            id: "mail-send-1",
            name: "send_mail",
            arguments: ["review_id": .string("00000000-0000-0000-0000-000000000123")]
        )
        #expect(!directTools.canAutoApproveRoutineAction(sendCall, reviewReason: "Submit exact Mail draft"))

        let messageJSON = #"{"sender":"sender@example.com","to":[{"address":"recipient@example.com","name":"Recipient"}],"cc":[],"bcc":[],"subject":"Quarterly update","body":"Please review attached notes."}"#
        let store = AssistantStore(
            persistenceURL: nil,
            complete: { _, _, _ in
                ModelReply(
                    content: "",
                    toolCalls: [ToolCall(
                        id: "mail-1",
                        name: "create_mail_draft",
                        arguments: ["message_json": .string(messageJSON)]
                    )]
                )
            },
            execute: { _ in
                ToolResult(summary: "Draft created", evidence: "Verified", verified: true)
            }
        )
        defer { store.stop() }

        store.configuration.backend = .codexCLI
        store.setAutoApproveRoutineActions(true)
        store.draft = "Prepare the email draft."
        store.send()

        for _ in 0..<200 where store.pendingReview == nil && store.isRunning {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.phase == .awaitingReview)
        #expect(store.pendingReview?.call.name == "create_mail_draft")
        store.denyReview()
        await store.waitForConversationTaskToSettle()
    }

    @Test func bestPlayingTabPrioritizesAudibleTabThenActiveVideoTab() {
        let docsTab = BrowserTabAutomation.TabInfo(
            browserName: "Google Chrome",
            bundleID: "com.google.Chrome",
            windowID: "1",
            windowIndex: 1,
            tabID: "t1",
            tabIndex: 1,
            isActiveTab: true,
            title: "Project Notes",
            url: "https://docs.google.com/document/d/abc",
            isVideoTab: false,
            isAudible: false
        )
        let activeVideoTab = BrowserTabAutomation.TabInfo(
            browserName: "Google Chrome",
            bundleID: "com.google.Chrome",
            windowID: "1",
            windowIndex: 1,
            tabID: "t2",
            tabIndex: 2,
            isActiveTab: true,
            title: "Tutorial Video - YouTube",
            url: "https://www.youtube.com/watch?v=abc123",
            isVideoTab: true,
            isAudible: false
        )
        let audibleBackgroundVideo = BrowserTabAutomation.TabInfo(
            browserName: "Google Chrome",
            bundleID: "com.google.Chrome",
            windowID: "1",
            windowIndex: 1,
            tabID: "t3",
            tabIndex: 3,
            isActiveTab: false,
            title: "🔊 Live Concert",
            url: "https://www.youtube.com/watch?v=live999",
            isVideoTab: true,
            isAudible: true
        )

        #expect(BrowserTabAutomation.isVideoCandidate(url: "https://youtu.be/abc123", title: "Clip"))
        #expect(BrowserTabAutomation.isVideoCandidate(url: "https://www.youtube.com/watch?v=xyz", title: "Talk"))
        #expect(!BrowserTabAutomation.isVideoCandidate(url: "https://www.youtube.com/", title: "YouTube"))

        #expect(BrowserTabAutomation.bestPlayingTab(in: [docsTab, activeVideoTab, audibleBackgroundVideo]) == audibleBackgroundVideo)
        #expect(BrowserTabAutomation.bestPlayingTab(in: [docsTab, activeVideoTab]) == activeVideoTab)
    }
}
