import CoreGraphics
import Foundation
import Testing
@testable import Relay

@MainActor struct SummaryConversationSnapshotTests {
    typealias Subject = SummaryConversationSnapshot
    private func n(_ parent: Int, _ role: String = "AXGroup", id: String = "", classes: [String] = [],
                   description: String = "", value: String = "", title: String = "", subrole: String = "",
                   y: Double = 0, h: Double = 30, protected: Bool = false, editable: Bool = false,
                   domID: String = "") -> Subject.Node {
        .init(parent:parent,role:role,identifier:id,classes:classes,description:description,value:value,title:title,
              subrole:subrole,frame:CGRect(x:0,y:y,width:500,height:h),protected:protected,editable:editable,domID:domID)
    }
    private func wa(_ bodies: [(String, Double)]) -> [Subject.Node] {
        [n(-1,"AXWindow",h:500),n(0,id:"ChatMessagesTableView",h:500),
         n(0,"AXButton",id:"NavigationBar_HeaderViewButton",description:"Orchard team",h:40),
         n(0,"AXTextArea",id:"ChatBar_ComposerTextView",value:"UNSENT DRAFT",y:480,editable:true)]
         + bodies.map { n(1,"AXStaticText",id:"WAMessageBubbleTableViewCell",description:$0.0,y:$0.1) }
    }

    @Test func whatsAppStartsAtVisibleWholeMessageAndKeepsNewerLoadedTextOnly() throws {
        var nodes = wa([("Earlier private preview",0),("Asha, First complete message, 10:00",80),("Asha, Final decision Thursday, 10:05",700)])
        nodes += [n(0,"AXStaticText",value:"OTHER CHAT SIDEBAR",y:100),n(1,"AXHeading",description:"3 unread messages",y:0)]
        let result = try Subject.select(nodes,profile:.whatsApp)
        #expect(result.title == "Orchard team")
        #expect(result.text == "Asha, First complete message, 10:00\nAsha, Final decision Thursday, 10:05")
        #expect(result.offscreenMessages == 1)
        #expect(!result.text.contains("private preview") && !result.text.contains("SIDEBAR") && !result.text.contains("UNSENT"))
        #expect(result.coverage.contains("complete first visible message"))
    }
    @Test func whatsAppUnreadDividerIsNotAMessageAndCannotDiscardDateContextOrMatchingBubbleText() throws {
        var nodes = wa([("Asha, First complete message, 10:00",80)])
        nodes += [n(1,"AXHeading",description:"Friday, 7 November",y:160),
            n(1,"AXHeading",description:"UNREAD MESSAGES",y:180),
            n(1,"AXStaticText",id:"WAMessageBubbleTableViewCell",description:"3 unread messages",y:210),
            n(1,"AXStaticText",id:"WAMessageBubbleTableViewCell",description:"You, Final decision Thursday, 10:05",y:250)]
        let result = try Subject.select(nodes,profile:.whatsApp)
        #expect(result.text == "Asha, First complete message, 10:00\nFriday, 7 November\n3 unread messages\nYou, Final decision Thursday, 10:05")
        #expect(result.items.filter(\.message).count == 3 && result.items.filter { !$0.message }.map(\.text) == ["Friday, 7 November"])
        #expect(!result.text.contains("UNREAD MESSAGES"))
    }
    @Test func messagesPreservesSenderTimeWithoutDuplicatingBalloonText() throws {
        let nodes = [n(-1,"AXWindow",h:500),n(0,id:"TranscriptCollectionView",h:500),
            n(0,"AXButton",id:"ConversationTitle",description:"Asha",h:40),
            n(0,"AXTextArea",id:"MessageEntryView",value:"DO NOT SEND",y:480,editable:true),
            n(1,description:"Asha, We approved Thursday, 10:00",y:80),
            n(4,"AXTextArea",id:"CKBalloonTextView",value:"We approved Thursday",y:80),
            n(1,description:"You, I will review it, 10:03",y:700),
            n(0,"AXStaticText",value:"Other contact preview",y:100)]
        let result = try Subject.select(nodes,profile:.messages)
        #expect(result.text == "Asha, We approved Thursday, 10:00\nYou, I will review it, 10:03")
        #expect(result.items.first?.anchor == "We approved Thursday")
        #expect(!result.text.contains("DO NOT SEND") && result.offscreenMessages == 1)
    }
    @Test func claudeUsesWholePartlyVisibleArticleAndExcludesComposerAndEarlierArticles() throws {
        let nodes = [n(-1,"AXWindow",h:500),n(0,classes:["epitaxy-chat-panel-body"],h:300),
            n(1,description:"Message one",subrole:"AXDocumentArticle",h:1),n(2,"AXStaticText",value:"Earlier article",h:1),
            n(1,description:"Message two",subrole:"AXDocumentArticle",h:250),
            n(4,"AXStaticText",value:"Beginning above the viewport",h:1),n(4,"AXStaticText",value:"Visible end of the same message",y:40),
            n(1,description:"Message three",subrole:"AXDocumentArticle",y:700,h:0),n(7,"AXStaticText",value:"Newest final decision Thursday",y:700,h:0),
            n(1,"AXTextArea",classes:["ProseMirror"],value:"UNSENT COMPOSER",y:100,editable:true),
            n(0,"AXStaticText",value:"SIDEBAR TITLE",y:80)]
        let result = try Subject.select(nodes,profile:.claude)
        #expect(result.text.contains("Beginning above the viewport") && result.text.contains("Visible end of the same message"))
        #expect(result.text.contains("Newest final decision Thursday"))
        #expect(!result.text.contains("Earlier article") && !result.text.contains("UNSENT") && !result.text.contains("SIDEBAR"))
        #expect(result.items.count == 2 && result.offscreenMessages == 1)
    }
    @Test func anonymousClaudeArticleRetainsTextWithoutInventingASpeaker() throws {
        let nodes = [n(-1,"AXWindow",h:500),n(0,classes:["epitaxy-chat-panel-body"],h:300),
            n(1,description:"Article with unavailable speaker",subrole:"AXDocumentArticle",y:40,h:100),
            n(2,"AXStaticText",value:"I approved the Thursday release.",y:40)]
        let result = try Subject.select(nodes,profile:.claude)
        #expect(result.text == "I approved the Thursday release.")
        #expect(result.items.count == 1 && result.items.first?.sender == nil)
        #expect(result.coverage.contains("their speakers are unknown"))
        #expect(!result.text.contains("Claude") && !result.text.contains("You:"))
    }
    @Test func positivelyHeadedUserAndClaudeArticlesPreserveTheirSpeakers() throws {
        let nodes = [n(-1,"AXWindow",h:500),n(0,classes:["epitaxy-chat-panel-body"],h:300),
            n(1,subrole:"AXDocumentArticle",y:40,h:100),
            n(2,"AXHeading",classes:["sr-only"],title:"You said:",h:1),
            n(2,"AXStaticText",value:"Review Monday at 10:00.",y:40),
            n(1,subrole:"AXDocumentArticle",y:160,h:100),
            n(5,"AXHeading",classes:["sr-only"],title:"Claude said:",h:1),
            n(5,"AXStaticText",value:"The review is Monday at 10:00.",y:160)]
        let result = try Subject.select(nodes,profile:.claude)
        #expect(result.text == "You\nReview Monday at 10:00.\nClaude\nThe review is Monday at 10:00.")
        #expect(result.items.map(\.sender) == ["You", "Claude"])
        #expect(!result.coverage.contains("speakers are unknown"))
    }
    @Test(arguments: [Subject.Profile.chatGPT, .codex])
    func aiMessageHeadingsAreBoundariesButNeverHiddenSourceText(_ profile: Subject.Profile) throws {
        let nodes = [n(-1,"AXWindow",h:500),n(0,classes:["thread-scroll-container"],description:"Conversation",h:300),
            n(1,"AXHeading",classes:["sr-only"],title:"You said:",h:1),n(1,"AXStaticText",value:"Earlier user message",h:1),
            n(1,"AXHeading",classes:["sr-only"],title:"ChatGPT said:",h:1),
            n(1,"AXStaticText",value:"Complete beginning above viewport",h:1),n(1,"AXStaticText",value:"Visible answer ending",y:40),
            n(1,"AXHeading",classes:["sr-only"],title:"You said:",y:700,h:0),n(1,"AXStaticText",value:"Newest user question",y:700,h:0),
            n(1,classes:["group/activity-header"],y:90),n(9,"AXStaticText",value:"TOOL COMMAND POISON",y:90),
            n(1,"AXTextArea",classes:["ProseMirror"],value:"DRAFT POISON",y:200,editable:true)]
        let result = try Subject.select(nodes,profile:profile)
        #expect(result.items.count == 2)
        #expect(result.text == "Assistant:\nComplete beginning above viewport\nVisible answer ending\nYou:\nNewest user question")
        #expect(!result.text.contains("Earlier user") && !result.text.contains("POISON") && !result.text.contains("ChatGPT said:"))
    }
    @Test func slackRetainsWholeMessageSenderTimeAndReportsVirtualization() throws {
        let nodes = [n(-1,"AXWindow",h:500),n(0,classes:["p-message_pane"],h:300),
            n(1,"AXList",classes:["sr-only"],description:"Orchard channel",h:0),
            n(2,h:1,domID:"message-list_old"),n(3,classes:["c-message_kit__hover"],h:1),n(4,"AXStaticText",value:"Earlier Slack message",h:1),
            n(2,h:100,domID:"message-list_chosen"),n(6,classes:["c-message_kit__hover"],h:100),
            n(7,"AXButton",classes:["c-message__sender_button"],title:"Asha",h:1),
            n(7,"AXLink",classes:["c-timestamp"],title:"10:00",h:1),
            n(7,"AXStaticText",value:"Beginning above viewport",h:1),n(7,"AXStaticText",value:"Visible final decision Thursday",y:40),
            n(7,classes:["c-message_kit__reaction_bar"],y:90),n(12,"AXStaticText",value:"REACTION POISON",y:90)]
        let result = try Subject.select(nodes,profile:.slack)
        #expect(result.text == "Asha · 10:00\nBeginning above viewport\nVisible final decision Thursday")
        #expect(result.items.first?.identity == "message-list_chosen")
        #expect(result.truncated && result.coverage.contains("virtualizes unloaded history"))
        #expect(!result.text.contains("POISON") && !result.text.contains("Earlier Slack"))
    }
    @Test func outputBudgetKeepsCompleteBoundaryAndNewestMessagesWithDeclaredGap() throws {
        let first = "Asha, Opening decision: review Monday, 10:00"
        let last = "You, Final decision: ship Thursday Café 🌍, 11:00"
        let middle = String(repeating:"Intervening conversation ",count:80)
        var limits = Subject.Limits(); limits.maximumTextBytes = 240
        let result = try Subject.select(wa([(first,80),(middle,100),(last,700)]),profile:.whatsApp,limits:limits)
        #expect(result.items.map(\.text) == [first,last])
        #expect(result.text.contains(first) && result.text.contains(last) && result.text.contains("Intervening loaded messages omitted"))
        #expect(result.truncated && result.text.utf8.count <= 240 && !result.text.contains("�"))
        #expect(result.coverage.contains("no message body was cut"))
    }
    @Test func oversizedBoundaryRefusesInsteadOfCuttingItsFinalDecision() {
        let nodes = wa([(String(repeating:"Huge message ",count:1_000) + "FINAL DECISION",80),("Newest reply",700)])
        #expect(throws:Subject.Failure.oversizedMessage) { try Subject.select(nodes,profile:.whatsApp) }
    }
    @Test func noVisibleMessageAmbiguityWrongProfileAndProtectedContainersFailClosed() {
        #expect(throws:Subject.Failure.noVisibleMessage) { try Subject.select(wa([("Only offscreen",700)]),profile:.whatsApp) }
        #expect(throws:Subject.Failure.missingTranscript) { try Subject.select(wa([("Visible",80)]),profile:.messages) }
        var ambiguous = wa([("Visible",80)]); ambiguous.append(n(0,id:"ChatMessagesTableView",h:300))
        #expect(throws:Subject.Failure.ambiguousTranscript) { try Subject.select(ambiguous,profile:.whatsApp) }
        var protected = wa([("Visible",80)]); protected[1].protected = true
        #expect(throws:Subject.Failure.missingTranscript) { try Subject.select(protected,profile:.whatsApp) }
        #expect(Subject.profile(bundleID:"com.example.Chat") == nil)
        #expect(Subject.profile(bundleID:"com.openai.chat") == .chatGPT && Subject.profile(bundleID:"com.openai.codex") == .codex)
    }
    @Test func invalidParentCyclesBytesDepthDeadlineAndCancellationStayBounded() async throws {
        var invalid = wa([("Visible",80)]); invalid[1] = n(1,id:"ChatMessagesTableView",h:300)
        #expect(throws:Subject.Failure.invalidTree) { try Subject.select(invalid,profile:.whatsApp) }
        let valid = wa([("Visible",80)])
        var limit = Subject.Limits(); limit.maximumNodes = 1
        #expect(throws:Subject.Failure.limit) { try Subject.select(valid,profile:.whatsApp,limits:limit) }
        limit = .init(); limit.maximumInputBytes = 3
        #expect(throws:Subject.Failure.limit) { try Subject.select(valid,profile:.whatsApp,limits:limit) }
        limit = .init(); limit.maximumDepth = 0
        #expect(throws:Subject.Failure.limit) { try Subject.select(valid,profile:.whatsApp,limits:limit) }
        limit = .init(); limit.maximumSeconds = 0
        #expect(throws:Subject.Failure.limit) { try Subject.select(valid,profile:.whatsApp,limits:limit) }
        let pending = Task { try Subject.select(valid,profile:.whatsApp) }; pending.cancel()
        await #expect(throws:CancellationError.self) { try await pending.value }
    }
}
