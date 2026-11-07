import Foundation
import Darwin
import SQLite3
import RelayJournal

@main struct JournalCrashFixture {
    static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 3 else { throw JournalError.invalidEvent }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        // This executable is only an owned synthetic test collaborator, not an app action path.
        guard root.lastPathComponent.hasPrefix("relay-journal-tests-"), root.path.hasPrefix(FileManager.default.temporaryDirectory.path) else { throw JournalError.unsafeLocation }
        let stage = arguments[2]
        let journal = try await ConversationJournal.open(directory: root)
        let scope = try await journal.scope(), task = UUID(), attempt = UUID()
        _ = try await journal.acceptRequest(id: JournalOpaqueID("owned-request"), taskID: task, attemptID: attempt,
            text: JournalVisibleText("Synthetic task", origin: .user), expectedScope: scope)
        if stage == "before-intent" { _exit(0) }
        if stage == "uncommitted" {
            var database: OpaquePointer?
            guard sqlite3_open(root.appendingPathComponent("Conversation.sqlite").path, &database) == SQLITE_OK,
                  sqlite3_exec(database, "BEGIN IMMEDIATE; UPDATE journal_state SET generation=randomblob(16)", nil, nil, nil) == SQLITE_OK else { _exit(3) }
            _exit(0)
        }
        let intent = try JournalIntent(proposalID: task, producerEpoch: journal.producerEpoch, toolCallID: JournalOpaqueID("opaque-call"), toolName: "owned_effect", callDigest: Data(repeating: 7, count: 32), effect: .mutation)
        let event = JournalEvent(id: try JournalOpaqueID("owned-intent"), taskID: task, attemptID: attempt, payload: .intent(intent))
        _ = try await journal.commitIntent(event, expectedScope: scope)
        if stage == "after-intent" { _exit(0) }
        let effect = root.appendingPathComponent("independent-effect.txt")
        let descriptor = effect.path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600) }
        guard descriptor >= 0 else { _exit(4) }
        let bytes = Array("one effect".utf8)
        guard bytes.withUnsafeBytes({ Darwin.write(descriptor, $0.baseAddress, $0.count) }) == bytes.count, fsync(descriptor) == 0 else { _exit(5) }
        Darwin.close(descriptor)
        if stage == "after-effect" { _exit(0) }
        let result = JournalEvent(id: try JournalOpaqueID("owned-result"), taskID: task, attemptID: attempt,
            payload: .result(JournalToolOutcome(intent: intent, kind: .returnedVerified, artifacts: [try JournalArtifactReference(visiblePath: effect.path)])))
        _ = try await journal.commitResult(result, expectedScope: scope)
        _exit(0) // Intentionally bypass deinit/checkpoint; committed WAL is part of recovery.
    }
}
