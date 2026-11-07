import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import Relay

/// Inert metadata/tree fixtures only. No app bundle is installed, renamed or
/// queried, and no real conversation or document body is inspected.
@MainActor struct SummaryConversationIdentityTests {
    private let firstURL = "claude://claude.ai/chat/1A9FA11E-3BC7-4F02-9869-E5A610305001"
    private let secondURL = "claude://claude.ai/chat/1A9FA11E-3BC7-4F02-9869-E5A610305002"
    private let tree = SummaryNativeDocumentCapture.Tree(nodes: [])

    @MainActor private final class State {
        var raw: String
        var root = NSObject()
        var header = "A generic unchanged conversation window"
        var reads = 0
        var active = true
        init(raw: String) { self.raw = raw }
        func boundary() throws -> SummaryConversationCaptureBoundary.Boundary {
            guard let identity = SummaryConversationIdentity.qualifiedDocumentShape(profile: .claude, raw: raw) else {
                throw SummaryConversationCaptureBoundary.Failure.missingIdentity
            }
            return .init(identity: identity, transcriptRoot: root, headerAnchor: header)
        }
    }

    @Test func genericWindowAndSameTitleCannotHideAThreadSwitchDuringTheBodyRead() {
        let state = State(raw: firstURL)
        #expect(throws: SummaryConversationCaptureBoundary.Failure.changedConversation) {
            try SummaryConversationCaptureBoundary.freeze(profile: .claude, isActive: { state.active }, maximumSeconds: 0.25,
                inspect: { try state.boundary() }, read: {
                    state.reads += 1
                    state.raw = secondURL
                    return tree
                })
        }
        #expect(state.reads == 1 && state.header == "A generic unchanged conversation window")
    }

    @Test func changedTranscriptRootRefusesEvenWhenTheValidIdentityAndTitleMatch() {
        let state = State(raw: firstURL), original = state.root
        #expect(throws: SummaryConversationCaptureBoundary.Failure.changedConversation) {
            try SummaryConversationCaptureBoundary.freeze(profile: .claude, isActive: { true }, maximumSeconds: 0.25,
                inspect: { try state.boundary() }, read: { state.reads += 1; state.root = NSObject(); return tree })
        }
        #expect(state.reads == 1 && state.root !== original)
    }

    @Test func missingStableIdentityRefusesBeforeAnyBodyRead() {
        let state = State(raw: "Asha and the Orchard team")
        #expect(throws: SummaryConversationCaptureBoundary.Failure.missingIdentity) {
            try SummaryConversationCaptureBoundary.freeze(profile: .claude, isActive: { true }, maximumSeconds: 0.25,
                inspect: { try state.boundary() }, read: { state.reads += 1; return tree })
        }
        #expect(state.reads == 0)
    }

    @Test func sameAppProvidedIdentityAndRetainedRootProduceOneImmutableCapture() throws {
        let state = State(raw: firstURL)
        let frozen = try SummaryConversationCaptureBoundary.freeze(profile: .claude, isActive: { true }, maximumSeconds: 0.25,
            inspect: { try state.boundary() }, read: { state.reads += 1; return tree })
        try frozen.validate()
        #expect(state.reads == 1 && frozen.tree.nodes.isEmpty)
        // Equivalent documented route spelling identifies the same UUID; no
        // display name or generated token participates in that identity.
        state.raw = firstURL.replacingOccurrences(of: "claude://", with: "https://")
        try frozen.validate()
        state.raw = secondURL
        #expect(throws: SummaryConversationCaptureBoundary.Failure.changedConversation) { try frozen.validate() }
        #expect(state.reads == 1, "Validation must remain metadata-only, without a second source read.")
    }

    @Test func changedHeaderAndIncompleteScanCannotPublishCapturedText() {
        let state = State(raw: firstURL)
        #expect(throws: SummaryConversationCaptureBoundary.Failure.changedConversation) {
            try SummaryConversationCaptureBoundary.freeze(profile: .claude, isActive: { true }, maximumSeconds: 0.25,
                inspect: { try state.boundary() }, read: { state.reads += 1; state.header = "Changed metadata"; return tree })
        }
        #expect(throws: SummaryConversationCaptureBoundary.Failure.incomplete) {
            try SummaryConversationCaptureBoundary.freeze(profile: .claude, isActive: { true }, maximumSeconds: 0.25,
                inspect: { try state.boundary() }, read: { .init(nodes: [], limited: true) })
        }
    }

    @Test func namesConstantAXIdentifiersMalformedURLsAndOtherProfilesCannotBecomeThreadIDs() {
        for raw in ["Orchard team", "TranscriptCollectionView", "sha256:00000000000000000000000000000000",
                    "claude://claude.ai/new", "https://claude.ai/project/1A9FA11E-3BC7-4F02-9869-E5A610305001",
                    firstURL + "?q=private", firstURL + "#thread", firstURL + "/",
                    "https://user:secret@claude.ai/chat/1A9FA11E-3BC7-4F02-9869-E5A610305001",
                    "https://claude.ai.example.invalid/chat/1A9FA11E-3BC7-4F02-9869-E5A610305001",
                    "https://claude.ai/chat/not-a-uuid"] {
            #expect(SummaryConversationIdentity.qualifiedDocumentShape(profile: .claude, raw: raw) == nil)
        }
        for profile in [SummaryConversationSnapshot.Profile.messages, .whatsApp, .chatGPT, .codex, .slack] {
            #expect(SummaryConversationIdentity.qualifiedDocumentShape(profile: profile, raw: firstURL) == nil)
        }
    }

    @Test func documentedURLShapeNeedsTheActualTranscriptAndDocumentMetadataEvidence() throws {
        #expect(SummaryConversationIdentity.qualifiedDocumentShape(profile: .claude, raw: firstURL) != nil)
        #expect(throws: SummaryConversationCaptureBoundary.Failure.missingIdentity) {
            try SummaryConversationAXIdentity.admit(profile: .claude, candidates: [])
        }
        #expect(throws: SummaryConversationCaptureBoundary.Failure.missingIdentity) {
            try SummaryConversationAXIdentity.admit(profile: .claude,
                candidates: [.init(transcriptRoot: nil, documentMetadata: [firstURL], headerAnchor: "Same title")])
        }
        let root = NSObject()
        #expect(throws: SummaryConversationCaptureBoundary.Failure.missingIdentity) {
            try SummaryConversationAXIdentity.admit(profile: .claude,
                candidates: [.init(transcriptRoot: root, documentMetadata: ["https://claude.ai/new"], headerAnchor: "Same title")])
        }
        #expect(throws: SummaryConversationCaptureBoundary.Failure.missingIdentity) {
            try SummaryConversationAXIdentity.admit(profile: .claude,
                candidates: [.init(transcriptRoot: root, documentMetadata: [firstURL, secondURL], headerAnchor: "Same title")])
        }
        let admitted = try SummaryConversationAXIdentity.admit(profile: .claude,
            candidates: [.init(transcriptRoot: root, documentMetadata: [firstURL], headerAnchor: "Same title")])
        #expect(admitted.identity == SummaryConversationIdentity.qualifiedDocumentShape(profile: .claude, raw: firstURL))
        // A runtime metadata candidate is possible conditionally; this inert
        // fixture does not establish availability in any installed application.
        #expect(CFEqual(admitted.transcriptRoot, root))
    }

    @Test func staleValidTranscriptCannotHideNewMalformedOrConflictingCurrentDocumentRoutes() throws {
        let root = NSObject()
        for conflicting in ["claude://claude.ai/new", "https://claude.ai/new", secondURL,
                            "https://claude.ai/project/1A9FA11E-3BC7-4F02-9869-E5A610305003",
                            "not a current document URL", firstURL + "?q=replacement"] {
            #expect(throws: SummaryConversationCaptureBoundary.Failure.missingIdentity) {
                try SummaryConversationAXIdentity.admit(profile: .claude, candidates: [
                    .init(transcriptRoot: root, documentMetadata: [firstURL, conflicting], headerAnchor: "Unchanged name")])
            }
        }
        let admitted = try SummaryConversationAXIdentity.admit(profile: .claude, candidates: [
            .init(transcriptRoot: root, documentMetadata: ["", firstURL, "", firstURL], headerAnchor: "Unchanged name")])
        #expect(admitted.identity == SummaryConversationIdentity.qualifiedDocumentShape(profile: .claude, raw: firstURL))
    }

    @Test func inactiveOrExpiredCaptureCannotTouchTheSource() {
        let state = State(raw: firstURL)
        for active in [false, true] {
            #expect(throws: active ? SummaryConversationCaptureBoundary.Failure.limit : .inactive) {
                try SummaryConversationCaptureBoundary.freeze(profile: .claude, isActive: { active }, maximumSeconds: 0,
                    inspect: { try state.boundary() }, read: { state.reads += 1; return tree })
            }
        }
        #expect(state.reads == 0)
    }

    @Test func nativeOversizedRequestedBudgetStillPacksWholeMessagesWithinTheSourceLimit() async throws {
        let frame = CGRect(x: 0, y: 0, width: 500, height: 500)
        let binding = SummaryNativeDocumentCapture.Binding(application: .init(processID: 4321,
            launchedAt: Date(timeIntervalSince1970: 1_700_000_000), bundleID: SummaryConversationSnapshot.Profile.claude.bundleID,
            bundleURL: URL(fileURLWithPath: "/SYNTHETIC/DeclaredProfile.app")), applicationName: "Inert declared profile",
            window: .init(token: "inert-window", title: "Synthetic article tree", document: "", frame: frame))
        let first = "FIRST WHOLE MESSAGE " + String(repeating: "a", count: 2_900)
        let middle = "MIDDLE WHOLE MESSAGE " + String(repeating: "b", count: 6_000)
        let final = "FINAL WHOLE MESSAGE " + String(repeating: "c", count: 2_900)
        let value = SummaryNativeDocumentCapture.Tree(nodes: [
            .init(parent: -1, role: "AXWindow", frame: frame),
            .init(parent: 0, role: "AXGroup", classes: ["epitaxy-chat-panel-body"], frame: frame),
            .init(parent: 1, role: "AXGroup", subrole: "AXDocumentArticle", frame: frame),
            .init(parent: 2, role: "AXStaticText", value: first, frame: frame),
            .init(parent: 1, role: "AXGroup", subrole: "AXDocumentArticle", frame: frame),
            .init(parent: 4, role: "AXStaticText", value: middle, frame: frame),
            .init(parent: 1, role: "AXGroup", subrole: "AXDocumentArticle", frame: frame),
            .init(parent: 6, role: "AXStaticText", value: final, frame: frame)])
        var limits = SummaryNativeDocumentCapture.Limits(); limits.maximumTextBytes = 26_000
        // This trusted inert tree seam tests packing, not production profile
        // admission. No installed Claude process is impersonated or queried.
        let request = try SummaryNativeDocumentCapture.prepare(mode: .conversation(.claude), binding: binding,
            provider: .init(inspect: { binding }, read: { value }), isActive: { true }, limits: limits)
        let snapshot = try await SummaryNativeDocumentCapture.capture(request)
        let source = try DocumentSummarySource.native(snapshot)
        #expect(source.text.utf8.count <= DocumentSummarySource.maximumTextBytes)
        #expect(source.text.contains(first) && source.text.contains(final) && !source.text.contains(middle))
        #expect(source.text.contains("Intervening loaded messages omitted") && source.truncated)
        #expect(snapshot.messages.map(\.text) == [first, final])
    }
}
