import Foundation
import Testing
@testable import RelayJournal

@Suite(.serialized) struct JournalArtifactTests {
    @Test func localArtifactMetadataIsAtomicRestoredAndCleared() async throws {
        let container = temporaryJournal(); defer { cleanup(container) }
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let file = container.appendingPathComponent("owned result.txt"), body = Data("NO_IMAGE_BYTES_OR_HEADER_OBJECT".utf8); try body.write(to: file)
        let reference = try JournalArtifactAccess.capture(visiblePath: file.path, isAuthorized: { $0 == file.path })
        let root = container.appendingPathComponent("journal")
        let journal = try await ConversationJournal.open(directory: root), scope = try await journal.scope()
        let (task, attempt) = try await start(journal, scope: scope)
        let text = try JournalVisibleText("Here is the result.", origin: .assistant, artifacts: [reference])
        #expect(!text.automaticallyEligibleForInference)
        let event = JournalEvent(id: try JournalOpaqueID("artifact-message"), taskID: task, attemptID: attempt, payload: .assistant(text))
        await journal.injectFault(.beforeCommit)
        await assertFailure(.injectedBeforeCommit) { _ = try await journal.appendBatch([event], expectedScope: scope) }
        #expect(try await journal.page(expectedScope: scope).records.count == 2)
        _ = try await journal.appendBatch([event], expectedScope: scope)
        try await journal.close()
        let reopened = try await ConversationJournal.open(directory: root)
        let record = try await reopened.page(expectedScope: scope).records.last!
        guard case let .assistant(restored) = record.event.payload else { throw JournalError.corrupt }
        #expect(restored.artifacts == [reference]); try JournalArtifactAccess.validate(reference, isAuthorized: { $0 == file.path })
        for bytes in try contents(root).values { #expect(bytes.range(of: body) == nil) }
        let next = try await reopened.reset(expectedScope: scope)
        #expect(try await reopened.page(expectedScope: next).records.isEmpty)
        #expect(try Data(contentsOf: file) == body)
        try await reopened.close()
    }
    @Test func revokedChangedAndRetargetedPathsRefuse() throws {
        let root = temporaryJournal(); defer { cleanup(root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let file = root.appendingPathComponent("result.txt"), other = root.appendingPathComponent("other.txt")
        try Data("first".utf8).write(to: file); try Data("other".utf8).write(to: other)
        let reference = try JournalArtifactAccess.capture(visiblePath: file.path, isAuthorized: { _ in true })
        #expect(throws: JournalError.unsafeLocation) { try JournalArtifactAccess.validate(reference, isAuthorized: { _ in false }) }
        try Data("edit!".utf8).write(to: file)
        #expect(throws: JournalError.unsafeLocation) { try JournalArtifactAccess.validate(reference, isAuthorized: { _ in true }) }
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: other)
        #expect(throws: JournalError.unsafeLocation) { try JournalArtifactAccess.validate(reference, isAuthorized: { _ in true }) }
        let unknownLegacy = try JournalArtifactReference(visiblePath: other.path)
        #expect(throws: JournalError.unsafeLocation) { try JournalArtifactAccess.validate(unknownLegacy, isAuthorized: { _ in true }) }
    }
    @Test func deniedGrantNeverReachesMetadataAndProseEncodingStaysCompatible() throws {
        let absent = "/synthetic/not-an-authorized-path", reference = try JournalArtifactReference(visiblePath: absent)
        #expect(throws: JournalError.unsafeLocation) { try JournalArtifactAccess.capture(visiblePath: absent, isAuthorized: { _ in false }) }
        #expect(reference.identityDigest == nil)
        let oldJSON = Data("{\"omissions\":[],\"origin\":\"user\",\"sourceRequirements\":[],\"text\":\"exact café\"}".utf8)
        let text = try JSONDecoder().decode(JournalVisibleText.self, from: oldJSON)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]
        #expect(try encoder.encode(text) == oldJSON)
    }
}
