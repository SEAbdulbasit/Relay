import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Relay

@MainActor struct SummaryNativeDocumentCaptureTests {
    typealias Subject = SummaryNativeDocumentCapture
    typealias Node = SummaryConversationSnapshot.Node
    private static let frame = CGRect(x:0,y:0,width:500,height:500)
    private static func binding(title: String = "Example document", document: String = "", token: String = "window-A",
                                bundle: String = "com.apple.TextEdit", process: Int32 = 4321, launch: Date = .init(timeIntervalSince1970:1_700_000_000),
                                rect: CGRect = frame) -> Subject.Binding {
        .init(application:.init(processID:process,launchedAt:launch,bundleID:bundle,bundleURL:URL(fileURLWithPath:"/SYNTHETIC/App.app")),
              applicationName:"Synthetic App",window:.init(token:token,title:title,document:document,frame:rect))
    }
    private static func doc(_ text: String) -> Subject.Tree {
        .init(nodes:[.init(parent:-1,role:"AXWindow",frame:frame),.init(parent:0,role:"AXDocument",frame:frame),
            .init(parent:1,role:"AXTextArea",value:text,frame:frame,editable:true)])
    }
    @MainActor private final class State {
        var binding = SummaryNativeDocumentCaptureTests.binding()
        var tree = SummaryNativeDocumentCaptureTests.doc("Original document text")
        var active = true
        var reads = 0, inspections = 0
        var hold = false, waiting = false
        var afterRead: (() -> Void)?
        var changeAtInspection: Int?
        private var continuation: CheckedContinuation<Void,Never>?
        var provider: Subject.Provider { .init(inspect:{ [self] in
            inspections += 1
            if inspections == changeAtInspection { binding = SummaryNativeDocumentCaptureTests.binding(title:"Replacement document") }
            return binding
        },read:{ [self] in try await read() }) }
        func read() async throws -> Subject.Tree {
            reads += 1
            if hold { waiting = true; await withCheckedContinuation { continuation = $0 } }
            afterRead?()
            return tree
        }
        func release() { continuation?.resume(); continuation = nil }
        func request(limits: Subject.Limits = .init()) throws -> Subject.Request {
            try Subject.prepare(mode:.document,binding:binding,provider:provider,isActive:{ [self] in active },limits:limits)
        }
    }
    private func until(_ predicate: () -> Bool) async throws {
        for _ in 0..<1_000 { if predicate() { return }; await Task.yield() }
        Issue.record("Synthetic read did not reach its expected boundary.")
    }

    @Test func nativeDocumentReadsOneDocumentAndExcludesSidebarToolbarAndProtectedContent() async throws {
        let state = State()
        state.tree = .init(nodes:[.init(parent:-1,role:"AXWindow",frame:Self.frame),
            .init(parent:0,role:"AXDocument",frame:Self.frame),.init(parent:1,role:"AXTextArea",value:"Whole original document",frame:Self.frame,editable:true),
            .init(parent:2,role:"AXStaticText",value:"Duplicate descendant must not appear"),
            .init(parent:0,role:"AXToolbar"),.init(parent:4,role:"AXStaticText",value:"TOOLBAR POISON"),
            .init(parent:0,role:"AXStaticText",value:"SIDEBAR POISON"),
            .init(parent:1,role:"AXTextArea",value:"PROTECTED POISON",protected:true)])
        let result = try await Subject.capture(state.request())
        #expect(result.text == "Whole original document" && state.reads == 1)
        #expect(result.origin.window.token == "window-A" && result.messages.isEmpty && !result.truncated)
        #expect(result.coverage.contains("exact originating native document window"))
    }
    @Test(arguments:["pid","launch","window","title","document","frame","unicode"])
    func changedOriginBeforeCapturePerformsNoSourceRead(_ change: String) async throws {
        let state = State()
        if change == "unicode" { state.binding = Self.binding(title:"Caf\u{00e9}") }
        let request = try state.request()
        switch change {
        case "pid": state.binding = Self.binding(process:9999)
        case "launch": state.binding = Self.binding(launch:Date(timeIntervalSince1970:1_700_000_001))
        case "window": state.binding = Self.binding(token:"window-B")
        case "document": state.binding = Self.binding(document:"file:///SYNTHETIC/Other.txt")
        case "frame": state.binding = Self.binding(rect:CGRect(x:20,y:0,width:500,height:500))
        case "unicode": state.binding = Self.binding(title:"Cafe\u{0301}")
        default: state.binding = Self.binding(title:"Other document")
        }
        await #expect(throws:Subject.Failure.changedOrigin) { try await Subject.capture(request) }
        #expect(state.reads == 0)
    }
    @Test func originChangesDuringReadOrAfterGroupingCannotPublish() async throws {
        let state = State()
        state.afterRead = { state.binding = Self.binding(title:"Changed while reading") }
        await #expect(throws:Subject.Failure.changedOrigin) { try await Subject.capture(state.request()) }
        let afterGrouping = State(); afterGrouping.changeAtInspection = 4
        await #expect(throws:Subject.Failure.changedOrigin) { try await Subject.capture(afterGrouping.request()) }
        #expect(state.reads == 1 && afterGrouping.reads == 1)
    }
    @Test func cancellationAndSessionExitDiscardLateSources() async throws {
        let state = State(); state.hold = true
        let request = try state.request()
        let pending = Task { try await Subject.capture(request) }
        try await until { state.waiting }
        pending.cancel(); state.release()
        await #expect(throws:CancellationError.self) { try await pending.value }
        let inactive = State(); inactive.hold = true
        let request2 = try inactive.request()
        let pending2 = Task { try await Subject.capture(request2) }
        try await until { inactive.waiting }
        inactive.active = false; inactive.release()
        await #expect(throws:Subject.Failure.inactive) { try await pending2.value }
    }
    @Test func immutableChatHandoffNeverRereadsAChangedConversationInTheSameGenericWindow() async throws {
        let state = State()
        state.binding = Self.binding(title:"Messages",bundle:"com.apple.MobileSMS")
        let frozen = Subject.Tree(nodes:[.init(parent:-1,role:"AXWindow",frame:Self.frame),
            .init(parent:0,role:"AXGroup",identifier:"TranscriptCollectionView",frame:Self.frame),
            .init(parent:0,role:"AXButton",identifier:"ConversationTitle",description:"Asha",frame:CGRect(x:0,y:0,width:500,height:40)),
            .init(parent:1,role:"AXGroup",description:"Asha, Original decision Thursday, 10:00",frame:CGRect(x:0,y:80,width:500,height:40))])
        let captured = Date(timeIntervalSince1970:1_700_000_010)
        let request = try Subject.prepareFrozen(mode:.conversation(.messages),binding:state.binding,tree:frozen,
            inspect:{ state.binding },isActive:{ state.active },capturedAt:captured)
        state.tree = Self.doc("OTHER CHAT MUST NEVER BE READ")
        let result = try await Subject.capture(request)
        #expect(result.text == "Asha, Original decision Thursday, 10:00" && result.title == "Asha")
        #expect(result.capturedAt == captured && state.reads == 0)
        #expect(!result.text.contains("OTHER CHAT"))
    }
    @Test func wrongChatProfileAndIncompleteChatTreeRefuseWithoutGenericFallback() async throws {
        let state = State()
        #expect(throws:Subject.Failure.unsupportedProfile) {
            try Subject.prepare(mode:.conversation(.messages),binding:state.binding,provider:state.provider,isActive:{true})
        }
        #expect(state.inspections == 0 && state.reads == 0)
        #expect(throws:Subject.Failure.limit) {
            try Subject.prepareFrozen(mode:.conversation(.messages),binding:Self.binding(bundle:"com.apple.MobileSMS"),
                tree:.init(nodes:[],limited:true),inspect:{ Self.binding(bundle:"com.apple.MobileSMS") },isActive:{true})
        }
    }
    @Test func localPDFDocumentURLIsMetadataOnlyAndRemoteURLsAreNotOpened() async throws {
        let state = State(); state.tree = .init(nodes:[])
        state.binding = Self.binding(title:"Unopened PDF",document:"file:///SYNTHETIC/UNOPENED.pdf")
        let result = try await Subject.capture(state.request())
        #expect(result.requiresPDFRead && result.text.isEmpty && result.documentURL?.path == "/SYNTHETIC/UNOPENED.pdf")
        #expect(result.coverage.contains("No file bytes"))
        state.binding = Self.binding(document:"https://example.invalid/remote.pdf")
        await #expect(throws:Subject.Failure.unavailable) { try await Subject.capture(state.request()) }
    }
    @Test func longNativeDocumentKeepsOpeningAndFinalDecisionWithExplicitGaps() async throws {
        let state = State()
        state.tree = Self.doc("Opening decision: review Monday.\n" + String(repeating:"Middle content ",count:8_000) + "\nFinal decision: ship Thursday Café 🌍.")
        let result = try await Subject.capture(state.request())
        #expect(result.text.contains("Opening decision: review Monday") && result.text.contains("Final decision: ship Thursday Café 🌍"))
        #expect(result.truncated && result.text.utf8.count <= 8_000 && result.text.contains("Source excerpt gap"))
    }
    @Test func ambiguousNativeDocumentsAndMalformedTreeCannotBroadenCapture() async throws {
        let state = State()
        state.tree = .init(nodes:[.init(parent:-1,role:"AXWindow"),.init(parent:0,role:"AXTextArea",value:"A"),.init(parent:0,role:"AXTextArea",value:"B")])
        await #expect(throws:Subject.Failure.unavailable) { try await Subject.capture(state.request()) }
        state.tree = .init(nodes:[.init(parent:0,role:"AXWindow")])
        await #expect(throws:Subject.Failure.unavailable) { try await Subject.capture(state.request()) }
    }
    @Test func independentRequestsNeverShareCaptureOrOriginAndLimitsRemainBounded() async throws {
        let first = State(), second = State()
        second.binding = Self.binding(title:"Second",token:"window-B"); second.tree = Self.doc("Second source")
        let request1 = try first.request(), request2 = try second.request()
        let result2 = try await Subject.capture(request2), result1 = try await Subject.capture(request1)
        #expect(result1.text == "Original document text" && result2.text == "Second source")
        var limits = Subject.Limits(); limits.maximumNodes = 1
        await #expect(throws:Subject.Failure.limit) { try await Subject.capture(first.request(limits:limits)) }
        limits = .init(); limits.maximumInputBytes = 2
        await #expect(throws:Subject.Failure.limit) { try await Subject.capture(first.request(limits:limits)) }
        limits = .init(); limits.maximumSeconds = 0
        await #expect(throws:Subject.Failure.limit) { try await Subject.capture(first.request(limits:limits)) }
    }

    @Test(arguments: ["hidden", "protected", "secure", "toolbar"])
    func excludedElementNeverFetchesSensitiveValuesOrDescendantMetadata(_ exclusion: String) {
        var attributes: [String: AnyObject] = ["AXRole": "AXStaticText" as NSString,
            "AXValue": "PRIVATE VALUE MUST NOT BE FETCHED" as NSString,
            "AXDescription": "PRIVATE DESCRIPTION MUST NOT BE FETCHED" as NSString,
            "AXTitle": "PRIVATE TITLE MUST NOT BE FETCHED" as NSString]
        switch exclusion {
        case "hidden": attributes["AXHidden"] = NSNumber(value: true)
        case "protected": attributes["AXProtectedContent"] = NSNumber(value: true)
        case "secure": attributes["AXSubrole"] = "AXSecureTextField" as NSString
        default: attributes["AXRole"] = "AXToolbar" as NSString
        }
        var reads: [String] = [], editableReads = 0, frameReads = 0
        let entry = Subject.readElement(parent: 0, inside: true, profile: .messages, attribute: { name in
            reads.append(name); return attributes[name]
        }, isValueSettable: { editableReads += 1; return false }, frame: { frameReads += 1; return Self.frame })
        #expect(entry == nil && editableReads == 0 && frameReads == 0)
        #expect(Set(reads).isDisjoint(with: ["AXValue", "AXDescription", "AXTitle", "AXIdentifier", "AXDOMClassList", "AXChildren"]))
    }

    @Test(arguments: ["native-composer", "prose-mirror", "unknown-editable"])
    func chatComposerIsPrunedBeforeReadingAnyUnsentText(_ composer: String) throws {
        var attributes: [String: AnyObject] = ["AXRole": "AXTextArea" as NSString,
            "AXValue": "UNSENT VALUE POISON" as NSString, "AXDescription": "UNSENT DESCRIPTION POISON" as NSString,
            "AXTitle": "UNSENT TITLE POISON" as NSString]
        if composer == "native-composer" { attributes["AXIdentifier"] = "MessageEntryView" as NSString }
        if composer == "prose-mirror" { attributes["AXDOMClassList"] = ["ProseMirror", "thread-scroll-container"] as NSArray }
        var reads: [String] = []
        let entry = try #require(Subject.readElement(parent: 0, inside: true, profile: .messages, attribute: { name in
            reads.append(name); return attributes[name]
        }, isValueSettable: { true }, frame: { Self.frame }))
        #expect(entry.skipsChildren && entry.node.value.isEmpty && entry.node.description.isEmpty && entry.node.title.isEmpty)
        #expect(Set(reads).isDisjoint(with: ["AXValue", "AXDescription", "AXTitle", "AXChildren"]))
    }

    @Test func authorizedDocumentEditorStillReadsItsOwnTextAndSelfAppRefusesBeforeAX() throws {
        var reads: [String] = []
        let entry = try #require(Subject.readElement(parent: 0, inside: true, profile: nil, attribute: { name in
            reads.append(name)
            switch name {
            case "AXRole": return "AXTextArea" as NSString
            case "AXValue": return "Authorized current document text" as NSString
            default: return nil
            }
        }, isValueSettable: { true }, frame: { Self.frame }))
        #expect(entry.node.value == "Authorized current document text" && entry.node.editable && !entry.skipsChildren)
        #expect(reads.contains("AXValue"))
        #expect(!reads.contains("AXDescription"), "Optional native descriptions must not turn a complete document value into a failed or partial capture.")
        #expect(throws: Subject.Failure.unsupportedProfile) {
            try Subject.prepare(application: .current, isActive: { true })
        }
    }
}
