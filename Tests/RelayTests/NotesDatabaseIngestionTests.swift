import Foundation
import Testing
@testable import Relay

/// Actual owned SQLite, gzip/protobuf, file snapshots and atomic private
/// checkpoints. No Notes app/store, Automation, account, SDK or grant is used.
@MainActor @Suite struct NotesDatabaseIngestionTests {
    nonisolated private enum TestFailure: Error { case injected, waiting }
    private func until(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate() {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw TestFailure.waiting }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    @Test func actualBackupDecodesAttributedItemsAndExcludesProtectedDeletedAndUnavailableRows() async throws {
        let fixture = try await NotesDatabaseFixture.make([
            .init(id: "owned-note", title: "Exact title", text: "  Cafe\u{301} 🌍\nExact body\n"),
            .init(id: "locked", raw: Data([0xff]), protected: 1),
            .init(id: "deleted", raw: Data([0xff]), deleted: 1),
            .init(id: "not-downloaded", text: nil)])
        do {
            let worker = NotesDatabaseIngestion(checkpointRoot: fixture.cache)
            let result = try await worker.importBackup(fixture.database)
            let item = try #require(result.items.first), attribution = try #require(item.notesAttribution)
            #expect(result.items.count == 1 && result.skipped == 3)
            #expect(Data(item.text.utf8) == Data("  Cafe\u{301} 🌍\nExact body\n".utf8))
            #expect(item.title == "Exact title" && attribution.noteID == "owned-note")
            #expect(attribution.folder == "Owned project folder" && attribution.createdAt == Date(timeIntervalSinceReferenceDate: 42))
            #expect(attribution.updatedAt == Date(timeIntervalSinceReferenceDate: 84))
            #expect(result.notesImport?.excluded == 2 && result.notesImport?.undownloaded == 1)
            #expect(result.notesImport?.malformed == 0 && result.notesImport?.resumed == 0)
            #expect(result.scope == nil)
            let source = try #require(result.notesBackup); try source.validateCurrent()
            let files = try await fixture.checkpointFiles()
            #expect(files.count == 2, "Protected/deleted bodies must not be decoded or checkpointed.")
            await fixture.remove()
        } catch { await fixture.remove(); throw error }
    }

    @Test func actualColumnFallbackAndByteDistinctIDsPreserveSeparateAttribution() async throws {
        let ids = ["caf\u{e9}", "cafe\u{301}"]
        let fixture = try await NotesDatabaseFixture.make(ids.map { .init(id: $0) }, creationColumn: "ZCREATIONDATE1")
        do {
            let result = try await NotesDatabaseIngestion(checkpointRoot: fixture.cache).importBackup(fixture.database)
            #expect(result.items.count == 2 && Set(result.items.map(\.id)).count == 2)
            #expect(Set(result.items.compactMap { $0.notesAttribution.map { Data($0.noteID.utf8) } }) == Set(ids.map { Data($0.utf8) }))
            await fixture.remove()
        } catch { await fixture.remove(); throw error }
    }

    @Test func malformedNoteCannotTurnAMatchedGoodBodyIntoCompleteCoverage() async throws {
        let fixture = try await NotesDatabaseFixture.make([.init(id: "good", text: "Readable owned text"), .init(id: "malformed", raw: Data([0x1f, 0x8b, 8]))])
        do {
            let result = try await NotesDatabaseIngestion(checkpointRoot: fixture.cache).importBackup(fixture.database)
            #expect(result.items.count == 1 && result.items[0].text == "Readable owned text")
            #expect(result.notesImport?.malformed == 1 && result.skipped == 1)
            #expect(result.notesImport?.description.contains("1 undecodable") == true)
            await fixture.remove()
        } catch { await fixture.remove(); throw error }
    }

    nonisolated private final class LostAcknowledgment: @unchecked Sendable {
        private let lock = NSLock()
        private var armed = true
        func observe(_ event: NotesImportCheckpoint.Event) throws {
            guard case .didCommit = event else { return }
            let fail = lock.withLock { () -> Bool in
                guard armed else { return false }; armed = false; return true
            }
            if fail { throw TestFailure.injected }
        }
    }
    @Test func actualPerItemCommitAndProgressResumeTogetherAfterLostAcknowledgmentAndReopen() async throws {
        let fixture = try await NotesDatabaseFixture.make([.init(id: "first"), .init(id: "second")])
        do {
            let fault = LostAcknowledgment()
            let interrupted = NotesDatabaseIngestion(checkpointRoot: fixture.cache, checkpointObserver: { try fault.observe($0) })
            await #expect(throws: NotesDatabaseIngestion.Failure.checkpoint) { try await interrupted.importBackup(fixture.database) }
            let before = try await fixture.checkpointFiles(); #expect(before.count == 1)
            let reopened = NotesDatabaseIngestion(checkpointRoot: fixture.cache)
            let result = try await reopened.importBackup(fixture.database)
            #expect(result.items.count == 2 && Set(result.items.map(\.id)).count == 2)
            #expect(result.notesImport?.resumed == 1)
            let after = try await fixture.checkpointFiles(); #expect(after.count == 2)
            let third = try await reopened.importBackup(fixture.database)
            #expect(third.notesImport?.resumed == 2 && third.items == result.items)
            await fixture.remove()
        } catch { await fixture.remove(); throw error }
    }

    @Test func changedActualBackupRevokesItsProofAndCannotReuseAnOldBodyCheckpoint() async throws {
        let fixture = try await NotesDatabaseFixture.make([.init(id: "same-note", text: "Original actual body")])
        do {
            let worker = NotesDatabaseIngestion(checkpointRoot: fixture.cache)
            let old = try await worker.importBackup(fixture.database), proof = try #require(old.notesBackup)
            try await fixture.replaceFirstBody("Current actual body")
            #expect(throws: Relay.LocalStateFileError.changedDuringRead) { try proof.validateCurrent() }
            let fresh = try await worker.importBackup(fixture.database)
            #expect(fresh.notesImport?.resumed == 0 && fresh.items.first?.text == "Current actual body")
            #expect(fresh.notesBackup?.sourceDigest != proof.sourceDigest)
            await fixture.remove()
        } catch { await fixture.remove(); throw error }
    }

    @Test func aForeignCheckpointWithMatchingTextCannotAuthorizeAnotherBackupNamespace() async throws {
        let first = try await NotesDatabaseFixture.make([.init(id: "same-id", text: "Same extracted text")])
        let second = try await NotesDatabaseFixture.make([.init(id: "same-id", text: "Same extracted text")])
        do {
            let worker = NotesDatabaseIngestion(checkpointRoot: first.cache)
            _ = try await worker.importBackup(first.database)
            let a = try await first.checkpointFiles(); let sourceFile = try #require(a.first)
            let fresh = try await worker.importBackup(second.database)
            #expect(fresh.notesImport?.resumed == 0)
            let b = try await first.checkpointFiles(); let foreignDestination = try #require(b.first { !a.contains($0) })
            let foreign = try Relay.LocalStateFile.read(sourceFile, maximumBytes: NotesImportCheckpoint.maximumRecordBytes)
            try LocalPrivateFileWriter.write(data: foreign, to: foreignDestination, maximumBytes: NotesImportCheckpoint.maximumRecordBytes)
            await #expect(throws: NotesDatabaseIngestion.Failure.checkpoint) { try await worker.importBackup(second.database) }
            await first.remove(); await second.remove()
        } catch { await first.remove(); await second.remove(); throw error }
    }

    @Test func unsupportedSchemaAndLiveJournalRefuseBeforeAnyCheckpoint() async throws {
        let invalid = try await NotesDatabaseFixture.make([.init(id: "plausible")], omitProtection: true)
        let live = try await NotesDatabaseFixture.make([.init(id: "live")])
        do {
            await #expect(throws: NotesDatabaseIngestion.Failure.schema) {
                try await NotesDatabaseIngestion(checkpointRoot: invalid.cache).importBackup(invalid.database)
            }
            try Data().write(to: URL(fileURLWithPath: live.database.path + "-wal"))
            await #expect(throws: NotesDatabaseIngestion.Failure.liveJournal) {
                try await NotesDatabaseIngestion(checkpointRoot: live.cache).importBackup(live.database)
            }
            let a = try await invalid.checkpointFiles(), b = try await live.checkpointFiles()
            #expect(a.isEmpty && b.isEmpty)
            await invalid.remove(); await live.remove()
        } catch { await invalid.remove(); await live.remove(); throw error }
    }

    @Test func cancellingAnActualPausedCommitCannotRemintItsPhysicalOwnerAndCanResumeAfterSettlement() async throws {
        let fixture = try await NotesDatabaseFixture.make([.init(id: "one"), .init(id: "two")])
        let gate = NotesImportGate()
        let worker = NotesDatabaseIngestion(checkpointRoot: fixture.cache, checkpointObserver: { gate.observe($0) })
        let pending = Task { try await worker.importBackup(fixture.database) }
        do {
            try await until { gate.entered }
            pending.cancel()
            await #expect(throws: NotesDatabaseIngestion.Failure.busy) { try await worker.importBackup(fixture.database) }
            gate.release()
            await #expect(throws: CancellationError.self) { try await pending.value }
            let resumed = try await worker.importBackup(fixture.database)
            #expect(resumed.items.count == 2 && resumed.notesImport?.resumed == 1)
            await fixture.remove()
        } catch { pending.cancel(); gate.release(); _ = await pending.result; await fixture.remove(); throw error }
    }

    @Test func realSourceImportMakesAttributedTextQueryableAndForgetRemovesDurableProgress() async throws {
        let fixture = try await NotesDatabaseFixture.make([.init(id: "queryable", title: "Project plan", text: "Owned launch deadline is Friday.")])
        do {
            var automationReads = 0
            let worker = NotesDatabaseIngestion(checkpointRoot: fixture.cache)
            let sources = NativePersonalSources(capture: { _, _ in automationReads += 1; throw CancellationError() },
                refresh: nil, automaticRefresh: false, notesImporter: worker)
            await sources.importNotesBackup(fixture.database)
            #expect(sources.items(for: .notes).count == 1 && !sources.canRefresh(.notes))
            let result = try sources.read(kind: .notes, query: "Owned project folder")
            #expect(result.summary.contains("Owned launch deadline is Friday.") && result.summary.contains("Note ID: queryable"))
            #expect(result.summary.contains("Folder: Owned project folder") && result.summary.contains("Created:"))
            #expect(automationReads == 0 && result.summary.contains("chosen backup, not the live Notes app"))
            let cleanup = try #require(sources.forget(.notes)); await cleanup.value
            #expect(sources.items(for: .notes).isEmpty && !sources.isCapturing)
            #expect(throws: RelayError.self) { try sources.read(kind: .notes) }
            let files = try await fixture.checkpointFiles(); #expect(files.isEmpty)
            #expect(FileManager.default.fileExists(atPath: fixture.database.path))
            await fixture.remove()
        } catch { await fixture.remove(); throw error }
    }

    @Test func interruptedFirstImportStillExposesForgetAndRemovesItsActualSavedProgress() async throws {
        let fixture = try await NotesDatabaseFixture.make([.init(id: "saved-before-lost-ack")])
        do {
            let fault = LostAcknowledgment()
            let worker = NotesDatabaseIngestion(checkpointRoot: fixture.cache, checkpointObserver: { try fault.observe($0) })
            let sources = NativePersonalSources(capture: { _, _ in Issue.record("Backup import must not open Notes Automation."); throw CancellationError() },
                refresh: nil, automaticRefresh: false, notesImporter: worker)
            await sources.importNotesBackup(fixture.database)
            let before = try await fixture.checkpointFiles()
            #expect(sources.items(for: .notes).isEmpty && before.count == 1)
            #expect(sources.hasNotesImportCache && !sources.isCapturing)
            let cleanup = try #require(sources.forget(.notes))
            await cleanup.value
            let after = try await fixture.checkpointFiles()
            #expect(after.isEmpty && !sources.hasNotesImportCache && !sources.isCapturing)
            #expect(FileManager.default.fileExists(atPath: fixture.database.path))
            await fixture.remove()
        } catch { await fixture.remove(); throw error }
    }

    @Test func encodedCheckpointExpansionDoesNotChangeTheAdmittedTextByteLimit() async throws {
        let text = "Body" + String(repeating: "\u{1}", count: NotesBodyDecoder.maximumTextBytes - 4)
        let fixture = try await NotesDatabaseFixture.make([.init(id: "escaped-body", text: text)])
        do {
            let worker = NotesDatabaseIngestion(checkpointRoot: fixture.cache)
            let first = try await worker.importBackup(fixture.database)
            #expect(first.items.first?.text.utf8.count == NotesBodyDecoder.maximumTextBytes)
            #expect(first.items.first?.text == text && first.items.first?.textLimited == false)
            let resumed = try await worker.importBackup(fixture.database)
            #expect(resumed.notesImport?.resumed == 1 && resumed.items == first.items)
            let files = try await fixture.checkpointFiles()
            let file = try #require(files.first)
            let stored = try Relay.LocalStateFile.read(file, maximumBytes: NotesImportCheckpoint.maximumRecordBytes)
            #expect(stored.count > 16_384 && stored.count <= NotesImportCheckpoint.maximumRecordBytes)
            await fixture.remove()
        } catch { await fixture.remove(); throw error }
    }

    @Test func reopenedSourceCanForgetDurableItemsWithoutSelectingOrRestoringTheBackup() async throws {
        let fixture = try await NotesDatabaseFixture.make([.init(id: "durable-before-relaunch", text: "PRIVATE_SAVED_NOTES_BODY")])
        do {
            var first: NativePersonalSources? = NativePersonalSources(capture: { _, _ in throw CancellationError() },
                refresh: nil, automaticRefresh: false, notesImporter: NotesDatabaseIngestion(checkpointRoot: fixture.cache))
            await first?.importNotesBackup(fixture.database)
            #expect(first?.items(for: .notes).count == 1)
            first = nil
            let before = try await fixture.checkpointFiles(); #expect(before.count == 1)
            var captures = 0
            let reopened = NativePersonalSources(capture: { _, _ in captures += 1; throw CancellationError() },
                refresh: nil, automaticRefresh: false, notesImporter: NotesDatabaseIngestion(checkpointRoot: fixture.cache))
            #expect(reopened.items(for: .notes).isEmpty && !reopened.hasNotesImportCache)
            let cleanup = reopened.forgetSavedNotesImports()
            let samePendingCleanup = reopened.forgetSavedNotesImports()
            await cleanup.value; await samePendingCleanup.value
            let after = try await fixture.checkpointFiles()
            #expect(after.isEmpty && reopened.items(for: .notes).isEmpty && !reopened.isCapturing)
            #expect(!reopened.hasNotesImportCache && captures == 0)
            #expect(throws: RelayError.self) { try reopened.read(kind: .notes) }
            #expect(FileManager.default.fileExists(atPath: fixture.database.path))
            #expect(reopened.status(for: .notes).contains("Original backups are unchanged"))
            await fixture.remove()
        } catch { await fixture.remove(); throw error }
    }

    @Test func savedImportForgetRefusesAnUnownedEntryAndKeepsCleanupAvailable() async throws {
        let fixture = try await NotesDatabaseFixture.make([.init(id: "owned-before-unexpected-entry")])
        do {
            let worker = NotesDatabaseIngestion(checkpointRoot: fixture.cache)
            _ = try await worker.importBackup(fixture.database)
            let files = try await fixture.checkpointFiles(), actual = try #require(files.first)
            let unexpected = actual.deletingLastPathComponent().appending(path: "unexpected.txt")
            try Data("OWNED_SENTINEL_NOT_A_CHECKPOINT".utf8).write(to: unexpected)
            let source = NativePersonalSources(capture: { _, _ in throw CancellationError() }, refresh: nil,
                automaticRefresh: false, notesImporter: NotesDatabaseIngestion(checkpointRoot: fixture.cache))
            await source.forgetSavedNotesImports().value
            #expect(source.hasNotesImportCache && !source.isCapturing)
            #expect(FileManager.default.fileExists(atPath: unexpected.path) && FileManager.default.fileExists(atPath: actual.path))
            try FileManager.default.removeItem(at: unexpected)
            await source.forgetSavedNotesImports().value
            let after = try await fixture.checkpointFiles()
            #expect(after.isEmpty && !source.hasNotesImportCache)
            #expect(FileManager.default.fileExists(atPath: fixture.database.path))
            await fixture.remove()
        } catch { await fixture.remove(); throw error }
    }

    @Test func actualItemWindowIsBoundedAndExplicitlyPartialRatherThanSkippingAHiddenTail() async throws {
        let rows = (0...NotesDatabaseIngestion.maximumNotes).map { NotesDatabaseFixture.Row(id: "owned-\($0)", text: "Bounded body") }
        let fixture = try await NotesDatabaseFixture.make(rows)
        do {
            let result = try await NotesDatabaseIngestion(checkpointRoot: fixture.cache).importBackup(fixture.database)
            #expect(result.items.count == NotesDatabaseIngestion.maximumNotes)
            #expect(result.notesImport?.scanned == 1_000 && result.notesImport?.capped == true)
            #expect(result.notesImport?.description.contains("Partial coverage") == true)
            await fixture.remove()
        } catch { await fixture.remove(); throw error }
    }
}
