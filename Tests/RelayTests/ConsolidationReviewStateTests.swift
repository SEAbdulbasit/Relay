import Foundation
import Testing
@testable import Relay

@MainActor
struct ConsolidationReviewStateTests {
    @Test func ordinarySourceDriftRetainsExactUnsavedEditsButBlocksSave() throws {
        let state = ConsolidationReviewState()
        state.receive(try draft())
        state.title = "My unsaved title — e\u{301} 🌍"
        state.body += "\n\nMy unsaved correction — شكرًا."
        let title = state.title, body = state.body
        state.invalidate(.sourcesChanged, isAuthorized: { _ in true })
        #expect(state.phase == .stale && !state.canSave && state.canCopy)
        #expect(state.title.utf16.elementsEqual(title.utf16) && state.body.utf16.elementsEqual(body.utf16))
        #expect(state.message?.contains("unsaved edits are retained") == true)
        // A failed rebuild publishes no new draft and therefore leaves this buffer intact.
        state.revalidateAuthorization { _ in true }
        #expect(state.body.utf16.elementsEqual(body.utf16))
        state.receive(try draft(suffix: "new"))
        #expect(state.phase == .ready && state.canSave)
        #expect(!state.body.contains("My unsaved correction"))
    }

    @Test(arguments: [GeneratedKnowledgeVault.ConsolidationInvalidation.stopped, .dismissed, .sourcesChanged, .saved])
    func stopRevokeCloseAndSaveClearDerivedTextWithAnExplicitReason(reason: GeneratedKnowledgeVault.ConsolidationInvalidation) throws {
        let state = ConsolidationReviewState()
        state.receive(try draft())
        state.body += "Unsaved private edit."
        state.invalidate(reason, isAuthorized: { _ in false })
        #expect(state.phase == .cleared && state.sourceDraft == nil)
        #expect(state.title.isEmpty && state.body.isEmpty && !state.canCopy && !state.canSave)
        #expect(state.message?.isEmpty == false)
    }

    @Test func revocationAfterEarlierOrdinaryDriftClearsTheRetainedEditBuffer() throws {
        let state = ConsolidationReviewState()
        state.receive(try draft())
        state.body += "User edit must not keep revoked source quotes alive."
        state.invalidate(.sourcesChanged, isAuthorized: { _ in true })
        #expect(state.phase == .stale && !state.body.isEmpty)
        state.revalidateAuthorization { _ in false }
        #expect(state.phase == .cleared && state.body.isEmpty && state.title.isEmpty && state.sourceDraft == nil)
        #expect(state.message?.contains("access changed") == true)
        let initial = ConsolidationReviewState()
        initial.invalidate(.dismissed, isAuthorized: { _ in true })
        #expect(initial.phase == .initial)
    }

    @Test func canonicalAuthorizationDistinguishesContentDriftFromRevocationDeletionAndRetargetedSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "relay-review-scope-" + UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Match LocalKnowledge's policy canonical spelling; Foundation may keep
        // /var here while the selected-scope policy resolves it to /private/var.
        let canonical = try ToolPolicy.canonicalURL(root.path)
        let first = canonical.appending(path: "original.md"), other = canonical.appending(path: "other.md")
        try Data("Original source".utf8).write(to: first)
        try Data("Other source".utf8).write(to: other)
        let record = KnowledgeRecord(sourcePath: first.path, title: "Original", text: "Original source",
            modifiedAt: Date(), contentHash: String(repeating: "1", count: 64), byteCount: 15)
        let revision = CrossSourceKnowledge.Revision(record)
        let grants = [ScopeGrant(path: first.path)]
        #expect(revision.isAuthorized(grants: grants))
        try Data("Content changed but remains in the same authorized source.".utf8).write(to: first)
        #expect(revision.isAuthorized(grants: grants), "Ordinary content drift must allow the user to recover unsaved edits.")
        #expect(!revision.isAuthorized(grants: []))
        try FileManager.default.removeItem(at: first)
        #expect(!revision.isAuthorized(grants: grants))
        try FileManager.default.createSymbolicLink(at: first, withDestinationURL: other)
        #expect(!revision.isAuthorized(grants: [ScopeGrant(path: other.path)]), "A differently granted target must not authorize the original source's edit buffer.")
    }

    private func draft(suffix: String = "original") throws -> CrossSourceKnowledge.Draft {
        let records = ["a", "b"].enumerated().map { index, name in
            KnowledgeRecord(sourcePath: "/synthetic/\(name).md", title: name,
                text: "[[Project: Marigold]]\nExplicit source excerpt \(suffix) \(name).",
                modifiedAt: Date(timeIntervalSince1970: 1), contentHash: String(repeating: String(index + 1), count: 64), byteCount: 100)
        }
        let entity = try #require(CrossSourceKnowledge.entities(in: records).first)
        let input = try CrossSourceKnowledge.input(entityURL: entity.id, records: records)
        return try input.draft(from: .init(content: "{\"highlights\":[1,2]}", toolCalls: []))
    }
}
