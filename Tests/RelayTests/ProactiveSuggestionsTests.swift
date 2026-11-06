import Foundation
import CryptoKit
import Testing
@testable import Relay

@MainActor
struct ProactiveSuggestionsTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func record(_ text: String, path: String = "/synthetic/notes.md", hash: String = "hash-a") -> KnowledgeRecord {
        KnowledgeRecord(sourcePath: path, title: "Notes", text: text, modifiedAt: now, contentHash: hash, byteCount: text.utf8.count)
    }
    private func persistenceURL() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-suggestions-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("state.json")
    }

    private func hashedRecord(_ text: String, path: String) -> KnowledgeRecord {
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return record(text, path: path, hash: digest)
    }

    @Test func defaultOffDoesNotPrepareOrReadSourcesAndOptInDoesNotAutoRun() {
        let suggestions = ProactiveSuggestions(persistenceURL: nil)
        #expect(!suggestions.enabled)
        suggestions.prepare(records: [record("TODO: Review sample")], now: now)
        #expect(suggestions.suggestions.isEmpty)
        suggestions.setEnabled(true)
        #expect(suggestions.suggestions.isEmpty)
        suggestions.prepare(records: [record("TODO: Review sample")], now: now)
        #expect(suggestions.suggestions.count == 1)
        #expect(suggestions.suggestions[0].sourcePaths == ["/synthetic/notes.md"])
        #expect(suggestions.suggestions[0].excerpt == "TODO: Review sample")
        #expect(suggestions.suggestions[0].createdAt == now)
        suggestions.setEnabled(false)
        #expect(suggestions.suggestions.isEmpty)
    }

    @Test func onlyExplicitActionLinesAreProposedWithoutInferringPeopleOrDates() {
        let suggestions = ProactiveSuggestions(persistenceURL: nil)
        suggestions.setEnabled(true)
        suggestions.prepare(records: [record("Discussed work with Maya yesterday.\n- TODO: Review notes\nACTION: Check the draft\n- [ ] Read the document\n- [x] Already done\nThe TODO: mention is prose.")], now: now)
        #expect(suggestions.suggestions.map(\.title) == ["Review notes", "Check the draft", "Read the document"])
        #expect(suggestions.suggestions.allSatisfy { !$0.reason.contains("Maya") && !$0.reason.contains("deadline") })
    }

    @Test func deadlinesRankAcrossTheWholeBoundedScanWithoutInterpretingPlainDates() {
        let first = record((0..<42).map { "TODO: Undated task \($0)" }.joined(separator: "\n"), path: "/synthetic/a.md")
        let later = record("""
            TODO: Review meeting notes for 2026-11-01
            TODO: Check an invalid day due 2026-02-30
            TODO: Check ambiguous timing due 2026-11-01 deadline: 2026-11-03
            TODO: Check an incomplete tag [due: 2026-11-01
            TODO: Confirm the launch [deadline: 2026-11-12]
            TODO: Send the internal draft due 2026-11-08
            TODO: Prepare test notes due:2026-11-08
            """, path: "/synthetic/z.md")
        let suggestions = ProactiveSuggestions(persistenceURL: nil)
        suggestions.setEnabled(true)
        suggestions.prepare(records: [first, later], now: now)
        let cards = suggestions.suggestions
        #expect(cards.count == 40)
        #expect(cards.prefix(3).map(\.dueDay) == ["2026-11-08", "2026-11-08", "2026-11-12"])
        #expect(cards.prefix(3).map(\.title) == [
            "Send the internal draft due 2026-11-08", "Prepare test notes due:2026-11-08", "Confirm the launch [deadline: 2026-11-12]",
        ])
        #expect(cards.dropFirst(3).allSatisfy { $0.dueDay == nil })
        let orderedIDs = cards.map(\.id)
        suggestions.prepare(records: [later, first], now: now.addingTimeInterval(60))
        #expect(suggestions.suggestions.map(\.id) == orderedIDs)
    }

    @Test func identicalCopiesRetainTheDraftsExactSourceWhileUnrelatedMatchingActionsStaySeparate() throws {
        let url = try persistenceURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let text = "Launch project\nTODO: Review notes [due: 2026-11-08]"
        let copy = hashedRecord(text, path: "/synthetic/a.md")
        let original = hashedRecord(text, path: "/synthetic/z.md")
        let unrelated = hashedRecord("Different project\nTODO: Review notes [due: 2026-11-08]", path: "/synthetic/b.md")
        let first = ProactiveSuggestions(persistenceURL: url)
        first.setEnabled(true)
        first.setScheduledDraftsEnabled(true)
        first.prepare(records: [original], now: now)
        let id = try #require(first.suggestions.first?.id)
        #expect(first.publishScheduledDraft("Review the launch notes.", for: id, now: now))

        let restored = ProactiveSuggestions(persistenceURL: url)
        restored.restorePreparedDrafts(records: [unrelated, copy, original], now: now.addingTimeInterval(60))
        #expect(restored.suggestions.count == 2)
        let matched = try #require(restored.suggestions.first(where: { $0.id == id }))
        #expect(matched.sourcePaths == [original.sourcePath])
        #expect(matched.matchingSourcePaths == [copy.sourcePath])
        #expect(restored.preparedDrafts[id] == "Review the launch notes.")

        restored.purge(records: [original, unrelated], now: now.addingTimeInterval(120))
        #expect(restored.suggestions.first(where: { $0.id == id })?.matchingSourcePaths.isEmpty == true)
        restored.prepare(records: [copy, unrelated], now: now.addingTimeInterval(180))
        #expect(restored.suggestions.count == 2)
        #expect(restored.preparedDrafts.isEmpty)
    }

    @Test func snoozeAndDismissFollowIdenticalEvidenceAcrossAuthorizedCopies() throws {
        let url = try persistenceURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let text = "Current project\nTODO: Review notes"
        let original = hashedRecord(text, path: "/synthetic/a.md")
        let copy = hashedRecord(text, path: "/synthetic/b.md")
        let updated = hashedRecord(text + "\nRevised project scope", path: "/synthetic/c.md")
        let first = ProactiveSuggestions(persistenceURL: url)
        first.setEnabled(true)
        first.prepare(records: [original, copy], now: now)
        let id = try #require(first.suggestions.first?.id)
        #expect(first.snooze(id, days: 1, now: now))

        let restored = ProactiveSuggestions(persistenceURL: url)
        restored.prepare(records: [copy, updated], now: now.addingTimeInterval(60))
        #expect(restored.snoozedCount == 1)
        #expect(restored.suggestions.flatMap(\.sourcePaths) == [updated.sourcePath])
        restored.dismiss(id)
        let reopened = ProactiveSuggestions(persistenceURL: url)
        reopened.prepare(records: [copy, updated], now: now.addingTimeInterval(86_400))
        #expect(reopened.snoozedCount == 0)
        #expect(reopened.suggestions.flatMap(\.sourcePaths) == [updated.sourcePath])
    }

    @Test func legacyPathDismissalStillHidesTheSameEvidenceWhenACopyIsIndexed() throws {
        let url = try persistenceURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let source = hashedRecord("TODO: Review notes", path: "/synthetic/z.md")
        let copy = hashedRecord(source.text, path: "/synthetic/a.md")
        let original = ProactiveSuggestions(persistenceURL: nil)
        original.setEnabled(true)
        original.prepare(records: [source], now: now)
        let id = try #require(original.suggestions.first?.id)
        let previousPreferences: [String: Any] = ["version": 1, "enabled": true, "dismissedIDs": [id]]
        try JSONSerialization.data(withJSONObject: previousPreferences).write(to: url)

        let restored = ProactiveSuggestions(persistenceURL: url)
        restored.prepare(records: [copy, source], now: now)
        #expect(restored.suggestions.isEmpty)
    }

    @Test func dedupAndDismissalsPersistButSourceTextDoesNot() throws {
        let url = try persistenceURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let suggestions = ProactiveSuggestions(persistenceURL: url)
        suggestions.setEnabled(true)
        let source = record("TODO: PRIVATE_SOURCE_MARKER\nTODO: PRIVATE_SOURCE_MARKER")
        suggestions.prepare(records: [source, source], now: now)
        #expect(suggestions.suggestions.count == 1)
        let id = try #require(suggestions.suggestions.first?.id)
        suggestions.dismiss(id)
        #expect(suggestions.suggestions.first?.dismissed == true)
        let restored = ProactiveSuggestions(persistenceURL: url)
        #expect(restored.enabled)
        #expect(restored.suggestions.isEmpty)
        restored.prepare(records: [source], now: now)
        #expect(restored.suggestions.isEmpty)
        #expect(!(try String(contentsOf: url, encoding: .utf8)).contains("PRIVATE_SOURCE_MARKER"))
        restored.clear()
        restored.prepare(records: [source], now: now)
        #expect(restored.suggestions.count == 1)
    }

    @Test func scheduledDraftRestoresOnlyAfterTheExactCurrentSourceIsRebuilt() throws {
        let url = try persistenceURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let source = record("TODO: SOURCE_QUOTATION_MARKER")
        let first = ProactiveSuggestions(persistenceURL: url)
        first.setEnabled(true)
        first.setScheduledDraftsEnabled(true)
        first.prepare(records: [source], now: now)
        let id = try #require(first.suggestions.first?.id)
        #expect(first.publishScheduledDraft("Open the review document.", for: id, now: now))
        #expect(!(try String(contentsOf: url, encoding: .utf8)).contains("SOURCE_QUOTATION_MARKER"))

        let restored = ProactiveSuggestions(persistenceURL: url)
        #expect(restored.preparedDrafts.isEmpty)
        restored.restorePreparedDrafts(records: [source], now: now.addingTimeInterval(60))
        #expect(restored.preparedDrafts[id] == "Open the review document.")
        restored.purge(records: [record(source.text, hash: "new-version")], now: now.addingTimeInterval(120))
        #expect(restored.preparedDrafts.isEmpty)
        let reopened = ProactiveSuggestions(persistenceURL: url)
        reopened.restorePreparedDrafts(records: [source], now: now.addingTimeInterval(180))
        #expect(reopened.preparedDrafts.isEmpty)
    }

    @Test func restoredDraftExpiresFromItsOriginalCreationEvenAfterCardRebuild() throws {
        let url = try persistenceURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let source = record("TODO: Check draft")
        let first = ProactiveSuggestions(persistenceURL: url)
        first.setEnabled(true)
        first.setScheduledDraftsEnabled(true)
        first.prepare(records: [source], now: now)
        let id = try #require(first.suggestions.first?.id)
        #expect(!first.publishScheduledDraft("  ", for: id, now: now))
        #expect(!first.publishScheduledDraft(String(repeating: "a", count: 2_001), for: id, now: now))
        #expect(first.publishScheduledDraft("Check the draft.", for: id, now: now))

        let restored = ProactiveSuggestions(persistenceURL: url)
        restored.restorePreparedDrafts(records: [source], now: now.addingTimeInterval(3_600))
        #expect(restored.preparedDrafts[id] == "Check the draft.")
        restored.purge(records: [source], now: now.addingTimeInterval(86_400))
        #expect(restored.preparedDrafts.isEmpty)
        #expect(restored.suggestions.count == 1)
    }

    @Test func revokedChangedAndExpiredSourcesCannotKeepOldSuggestions() {
        let suggestions = ProactiveSuggestions(persistenceURL: nil)
        suggestions.setEnabled(true)
        let source = record("TODO: Review source")
        suggestions.prepare(records: [source], now: now)
        suggestions.purge(records: [], now: now)
        #expect(suggestions.suggestions.isEmpty)
        suggestions.prepare(records: [source], now: now)
        suggestions.purge(records: [record("TODO: Review source", hash: "changed")], now: now)
        #expect(suggestions.suggestions.isEmpty)
        suggestions.prepare(records: [source], now: now)
        suggestions.purge(records: [source], now: now.addingTimeInterval(86_400))
        #expect(suggestions.suggestions.isEmpty)
        suggestions.prepare(records: [], now: now)
        #expect(suggestions.suggestions.isEmpty)
    }

    @Test func utf8AndScanLimitsAreBoundedWithoutBrokenScalars() {
        let suggestions = ProactiveSuggestions(persistenceURL: nil)
        suggestions.setEnabled(true)
        let long = "TODO: " + String(repeating: "🌍", count: 200)
        suggestions.prepare(records: [record(long)], now: now)
        #expect(suggestions.suggestions.first?.title.utf8.count ?? Int.max <= 120)
        #expect(suggestions.suggestions.first?.excerpt.utf8.count ?? Int.max <= 400)
        #expect(suggestions.suggestions.allSatisfy { !$0.title.contains("�") && !$0.excerpt.contains("�") })
        let many = (0..<100).map { "TODO: Task \($0)" }.joined(separator: "\n")
        suggestions.prepare(records: [record(many)], now: now)
        #expect(suggestions.suggestions.count == 40)
        #expect(suggestions.status.contains("not exhaustive"))
        suggestions.prepare(records: [record("TODO: bad", path: "/synthetic/../escape.md")], now: now)
        #expect(suggestions.suggestions.isEmpty)
    }

    @Test func corruptPersistenceFailsClosed() throws {
        let url = try persistenceURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try Data("broken JSON".utf8).write(to: url)
        let suggestions = ProactiveSuggestions(persistenceURL: url)
        #expect(!suggestions.enabled)
        #expect(suggestions.suggestions.isEmpty)
        #expect(suggestions.errorMessage != nil)
        let invalid: [String: Any] = ["version": 1, "enabled": true, "dismissedIDs": ["not-a-valid-digest"]]
        try JSONSerialization.data(withJSONObject: invalid).write(to: url)
        #expect(!ProactiveSuggestions(persistenceURL: url).enabled)
    }
    @Test func tomorrowSnoozeUsesLocalCalendarAndReturnsOnlyOnNextBriefAfterExpiry() throws {
        let source = record("TODO: Review tomorrow")
        let suggestions = ProactiveSuggestions(persistenceURL: nil)
        suggestions.setEnabled(true)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let beforeDST = try #require(ISO8601DateFormatter().date(from: "2026-03-07T15:00:00Z"))
        let expected = try #require(ISO8601DateFormatter().date(from: "2026-03-08T14:00:00Z"))
        suggestions.prepare(records: [source], now: beforeDST)
        let id = try #require(suggestions.suggestions.first?.id)
        #expect(suggestions.snooze(id, days: 1, now: beforeDST, calendar: calendar))
        #expect(suggestions.suggestions.isEmpty)
        #expect(suggestions.snoozedCount == 1)
        #expect(suggestions.snoozedUntil(id, now: beforeDST) == expected)
        #expect(expected.timeIntervalSince(beforeDST) == 23 * 3_600)
        suggestions.prepare(records: [source], now: expected.addingTimeInterval(-1))
        #expect(suggestions.suggestions.isEmpty)
        #expect(suggestions.status.contains("No suggestions to show"))
        #expect(suggestions.status.contains("1 suggestion is snoozed"))
        suggestions.prepare(records: [source], now: expected)
        #expect(suggestions.suggestions.first?.id == id)
        #expect(suggestions.snoozedCount == 0)
    }

    @Test func snoozePersistsOnlyMetadataAndDismissalAlwaysWins() throws {
        let url = try persistenceURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let source = record("TODO: PRIVATE_SNOOZE_QUOTATION")
        let suggestions = ProactiveSuggestions(persistenceURL: url)
        suggestions.setEnabled(true)
        suggestions.prepare(records: [source], now: now)
        let id = try #require(suggestions.suggestions.first?.id)
        #expect(suggestions.snooze(id, days: 7, now: now))
        let saved = try String(contentsOf: url, encoding: .utf8)
        #expect(!saved.contains("PRIVATE_SNOOZE_QUOTATION"))
        #expect(!saved.contains(source.sourcePath))
        let restored = ProactiveSuggestions(persistenceURL: url)
        #expect(restored.enabled)
        #expect(restored.suggestions.isEmpty)
        #expect(restored.snoozedCount == 1)
        restored.prepare(records: [source], now: now.addingTimeInterval(60))
        #expect(restored.suggestions.isEmpty)
        restored.dismiss(id) // Dismissal of a hidden snoozed identity is permanent too.
        #expect(restored.snoozedCount == 0)
        let afterExpiry = now.addingTimeInterval(8 * 86_400)
        restored.prepare(records: [source], now: afterExpiry)
        #expect(restored.suggestions.isEmpty)
        let reopened = ProactiveSuggestions(persistenceURL: url)
        reopened.clearSnoozes()
        reopened.prepare(records: [source], now: afterExpiry)
        #expect(reopened.suggestions.isEmpty)
        reopened.clear()
        reopened.prepare(records: [source], now: afterExpiry)
        #expect(reopened.suggestions.count == 1)
    }

    @Test func snoozeMetadataIsPurgedForRevokedChangedAndClockRollbackSources() throws {
        let source = record("TODO: Original")
        let suggestions = ProactiveSuggestions(persistenceURL: nil)
        suggestions.setEnabled(true)
        suggestions.prepare(records: [source], now: now)
        let id = try #require(suggestions.suggestions.first?.id)
        #expect(suggestions.snooze(id, days: 1, now: now))
        suggestions.purge(records: [], now: now)
        #expect(suggestions.snoozedCount == 0)
        suggestions.prepare(records: [source], now: now)
        #expect(suggestions.snooze(id, days: 1, now: now))
        let changed = record("TODO: UPDATED_SOURCE", hash: "different-hash")
        suggestions.prepare(records: [changed], now: now.addingTimeInterval(10))
        #expect(suggestions.snoozedCount == 0)
        #expect(suggestions.suggestions.first?.id != id)
        #expect(suggestions.suggestions.first?.title == "UPDATED_SOURCE")
        suggestions.prepare(records: [source], now: now)
        #expect(suggestions.snooze(id, days: 1, now: now))
        suggestions.prepare(records: [source], now: now.addingTimeInterval(-60))
        #expect(suggestions.snoozedCount == 0)
        #expect(suggestions.suggestions.first?.id == id)
    }

    @Test func snoozeRejectsInvalidDurationsStaleCardsAndCorruptOrUnboundedPersistence() throws {
        let url = try persistenceURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let source = record("TODO: Check bounds")
        let suggestions = ProactiveSuggestions(persistenceURL: url)
        suggestions.setEnabled(true)
        suggestions.prepare(records: [source], now: now)
        let id = try #require(suggestions.suggestions.first?.id)
        for days in [0, 8, Int.max] { #expect(!suggestions.snooze(id, days: days, now: now)) }
        #expect(!suggestions.snooze(id, days: 1, now: Date(timeIntervalSinceReferenceDate: .infinity)))
        #expect(!suggestions.snooze(id, days: 1, now: now.addingTimeInterval(86_400)))
        #expect(suggestions.snoozedCount == 0)
        #expect(suggestions.snooze(id, days: 7, now: now))
        let saved = try JSONSerialization.jsonObject(with: LocalStateFile.read(url, maximumBytes: 262_144))
        var corrupt = try #require(saved as? [String: Any])
        var entries = try #require(corrupt["snoozes"] as? [[String: Any]])
        entries[0]["until"] = now.addingTimeInterval(9 * 86_400).timeIntervalSinceReferenceDate
        corrupt["snoozes"] = entries
        try JSONSerialization.data(withJSONObject: corrupt).write(to: url)
        #expect(!ProactiveSuggestions(persistenceURL: url).enabled)
        // Restoring the original bounded entry then duplicating it also fails closed.
        corrupt = try #require(saved as? [String: Any])
        entries = try #require(corrupt["snoozes"] as? [[String: Any]])
        corrupt["snoozes"] = Array(repeating: entries[0], count: 257)
        try JSONSerialization.data(withJSONObject: corrupt).write(to: url)
        #expect(!ProactiveSuggestions(persistenceURL: url).enabled)
    }

    @Test func previousPreferenceSchemaLoadsWithoutImplicitPreparationOrSnooze() throws {
        let url = try persistenceURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try Data(#"{"version":1,"enabled":true,"dismissedIDs":[]}"#.utf8).write(to: url)
        let restored = ProactiveSuggestions(persistenceURL: url)
        #expect(restored.enabled)
        #expect(restored.snoozedCount == 0)
        #expect(restored.suggestions.isEmpty)
        restored.prepare(records: [record("TODO: Rebuild explicit brief")], now: now)
        #expect(restored.suggestions.count == 1)
    }

    @Test func deterministicPIIScanBlocksSSNLuhnCardsAndPassportsFromSuggestions() {
        #expect(PIIScan.containsHighRiskPII("SSN 123-45-6789"))
        #expect(PIIScan.containsHighRiskPII("Card: 4532 0151 1283 0366"))
        #expect(PIIScan.containsHighRiskPII("Passport No: A12345678"))
        #expect(!PIIScan.containsHighRiskPII("Invoice #2026-1042 due Friday"))

        let suggestions = ProactiveSuggestions(persistenceURL: nil)
        suggestions.setEnabled(true)
        let mixed = record("""
        TODO: File tax form for 123-45-6789
        TODO: Pay vendor card 4532 0151 1283 0366
        TODO: Renew Passport #A12345678
        TODO: Send Q4 architecture summary to team
        """)
        suggestions.prepare(records: [mixed], now: now)
        #expect(suggestions.suggestions.map(\.title) == ["Send Q4 architecture summary to team"])
    }

}
