import Foundation
import SQLite3
import Testing
@testable import Relay

@MainActor struct MessagesArchiveContactsTests {
    @Test func noPermissionOrLookupWithoutOptInOrEligibleIncludedHandles() async throws {
        let fixture = DirectoryFixture()
        let valid = excerpt([message("sender@example.test")])
        let optedOut = try await resolve(valid, enabled: false, fixture)
        #expect(optedOut.isEmpty)

        let missing = excerpt([
            message(nil, sender: "sender@example.test"), // display text is not a Messages handle
            message("202-555-0101"), // no country code
            message("mailto:sender@example.test")
        ])
        let noHandles = try await resolve(missing, enabled: true, fixture)
        #expect(noHandles.isEmpty)
        let permissions = await fixture.permissions
        let queried = await fixture.queries
        #expect(permissions.isEmpty && queried.isEmpty)
    }

    @Test func looksUpOnlyTheBudgetedIncomingRowsAndKeepsTheModelExcerptRaw() async throws {
        let phone = "+12025550101"
        let actual = excerpt([
            message("outside@example.test", body: String(repeating: "x", count: 7_999)),
            message(nil, sender: "Me"),
            message(phone),
            message(phone),
            message("+1 (202) 555-0101")
        ])
        let fixture = DirectoryFixture(responses: [
            .phone(phone): [
                .init(name: "Wrong country", identifiers: ["+442025550101"]),
                .init(name: "Owned Contact", identifiers: ["+1-202-555-0101"])
            ]
        ])
        let names = try await resolve(actual, enabled: true, fixture)
        let queried = await fixture.queries
        #expect(queried == [.phone(phone)])
        #expect(actual.rows.count == 4)
        #expect(names == [
            .init(handle: phone, name: "Owned Contact"),
            .init(handle: "+1 (202) 555-0101", name: "Owned Contact")
        ])
        let rawPromptRows = actual.rows.map(\.text)
        #expect(rawPromptRows.contains { $0.contains(phone) })
        #expect(!rawPromptRows.contains { $0.contains("Owned Contact") || $0.contains("outside@example.test") })
    }

    @Test func fullNormalizedIdentityMustMatchOneContact() async throws {
        let fixture = DirectoryFixture(responses: [
            .email("Alice@example.test"): [
                .init(name: "Not exact", identifiers: ["alice@example.test"]),
                .init(name: "Exact domain", identifiers: ["Alice@EXAMPLE.TEST"])
            ],
            .email("multiple@example.test"): [
                .init(name: "First", identifiers: ["multiple@example.test"]),
                .init(name: "Second", identifiers: ["multiple@EXAMPLE.TEST"])
            ],
            .phone("+442025550101"): [
                .init(name: "Suffix only", identifiers: ["+12025550101", "2025550101"])
            ]
        ])
        let names = try await resolve(excerpt([
            message("Alice@EXAMPLE.TEST"), message("multiple@example.test"), message("+442025550101"),
            message("unknown@example.test")
        ]), enabled: true, fixture)
        #expect(names == [.init(handle: "Alice@EXAMPLE.TEST", name: "Exact domain")])
    }

    @Test func deniedPermissionAndPermissionRevocationLeaveRawAttribution() async throws {
        let selected = excerpt([message("sender@example.test")])
        let denied = DirectoryFixture(grant: false)
        let deniedNames = try await resolve(selected, enabled: true, denied)
        let deniedQueries = await denied.queries
        #expect(deniedNames.isEmpty && deniedQueries.isEmpty)

        let revoked = DirectoryFixture(stillGranted: false, responses: [
            .email("sender@example.test"): [.init(name: "Revoked name", identifiers: ["sender@example.test"])]
        ])
        let revokedNames = try await resolve(selected, enabled: true, revoked)
        let permissions = await revoked.permissions
        let queried = await revoked.queries
        #expect(revokedNames.isEmpty)
        #expect(permissions == [true, false] && queried == [.email("sender@example.test")])
    }

    @Test(arguments: [false, true]) func neverPublishesAfterLookupRevocationOrCancellation(_ cancel: Bool) async throws {
        let selected = excerpt([message("sender@example.test")])
        let revocation = Revocation()
        let task = Task { @MainActor in
            try await MessagesArchiveContacts.attributions(in: selected, enabled: true, directory: .init(
                authorized: { _ in true },
                lookup: { identity in
                    await revocation.recordLookup(identity, revoke: !cancel)
                    if cancel { withUnsafeCurrentTask { $0?.cancel() } }
                    return [.init(name: "Should stay private", identifiers: ["sender@example.test"])]
                }), validateCurrent: {
                    if revocation.revoked { throw CancellationError() }
                })
        }
        do {
            _ = try await task.value
            Issue.record("Revoked or canceled lookup returned contact names.")
        } catch is CancellationError {
            #expect(revocation.lookup == .email("sender@example.test"))
        }
    }

    @Test func selectedSQLiteReadOnlySuppliesRawIncomingHandleOnOptIn() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "chat.db")
        try createDatabase(at: url)
        let now = Date(timeIntervalSince1970: 2 * 978_307_200 + 60)
        let plain = try await ChatArchiveReader.messages(url, chatID: 1, days: 7, now: now)
        let optedIn = try await ChatArchiveReader.messages(url, chatID: 1, days: 7, now: now, includeIncomingHandles: true)
        #expect(plain.entries.allSatisfy { $0.incomingHandle == nil })
        #expect(optedIn.entries.map(\.body) == ["Included", "Outgoing", "Oversized", "Unknown direction"])
        #expect(optedIn.entries.map(\.incomingHandle) == ["sender@example.test", nil, nil, nil])
        #expect(ChatArchiveExcerpt(messages: plain.entries).rows.map(\.text)
            == ChatArchiveExcerpt(messages: optedIn.entries).rows.map(\.text))
    }

    @Test func archiveModelAdmissionRefusesExactConfigurationABAAndStoreStop() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let history = AssistantConversationHistory(stateURL: folder.appending(path: "state.json"))
        let store = AssistantStore(persistenceURL: folder.appending(path: "store.json"), conversationHistory: history)
        await store.waitForConversationTaskToSettle()
        let original = store.configuration
        let beforeSwitch = store.archiveAnswerAuthorization()
        try beforeSwitch()
        store.configuration.backend = .openRouter
        store.configuration = original
        #expect(throws: CancellationError.self) { try beforeSwitch() }
        let beforeStop = store.archiveAnswerAuthorization()
        try beforeStop()
        store.stop(cancelScheduledPreparation: false)
        #expect(throws: CancellationError.self) { try beforeStop() }
        try await history.close()
    }

    private func resolve(_ excerpt: ChatArchiveExcerpt, enabled: Bool, _ fixture: DirectoryFixture)
        async throws -> [MessagesArchiveContacts.Attribution] {
        try await MessagesArchiveContacts.attributions(in: excerpt, enabled: enabled, directory: .init(
            authorized: { await fixture.authorize($0) }, lookup: { await fixture.lookup($0) }
        ), validateCurrent: {})
    }

    private func excerpt(_ messages: [ChatArchiveEntry]) -> ChatArchiveExcerpt {
        ChatArchiveExcerpt(messages: messages)
    }

    private func message(_ handle: String?, sender: String? = nil, body: String = "Owned body") -> ChatArchiveEntry {
        .init(time: "time", sender: sender ?? handle ?? "Participant", body: body, incomingHandle: handle)
    }

    private func createDatabase(at url: URL) throws {
        var database: OpaquePointer?
        let result = sqlite3_open(url.path, &database)
        defer { if let database { sqlite3_close(database) } }
        try #require(result == SQLITE_OK)
        let sql = """
            CREATE TABLE chat(display_name TEXT, chat_identifier TEXT);
            CREATE TABLE message(date INTEGER, is_from_me INTEGER, handle_id INTEGER, text TEXT);
            CREATE TABLE chat_message_join(chat_id INTEGER, message_id INTEGER);
            CREATE TABLE handle(id TEXT);
            INSERT INTO chat VALUES ('Selected','selected'),('Other','other');
            INSERT INTO handle VALUES ('sender@example.test'), ('outgoing@example.test'),
              (replace(hex(zeroblob(130)), '0', 'x') || '@example.test'), ('other@example.test');
            INSERT INTO message VALUES (978307200,0,1,'Included'),(978307201,1,2,'Outgoing'),
              (978307202,0,3,'Oversized'),(978307203,NULL,1,'Unknown direction'),
              (978307204,0,4,'Other conversation'),(42,0,4,'Out of range');
            INSERT INTO chat_message_join VALUES (1,1),(1,2),(1,3),(1,4),(2,5),(1,6);
            """
        try #require(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
    }

    @MainActor private final class Revocation {
        var revoked = false
        var lookup: MessagesArchiveContacts.Identity?
        func recordLookup(_ identity: MessagesArchiveContacts.Identity, revoke: Bool) {
            lookup = identity
            revoked = revoke
        }
    }

    private actor DirectoryFixture {
        let grant: Bool, stillGranted: Bool
        let responses: [MessagesArchiveContacts.Identity: [MessagesArchiveContacts.Candidate]]
        private(set) var permissions: [Bool] = []
        private(set) var queries: [MessagesArchiveContacts.Identity] = []

        init(grant: Bool = true, stillGranted: Bool = true,
             responses: [MessagesArchiveContacts.Identity: [MessagesArchiveContacts.Candidate]] = [:]) {
            self.grant = grant
            self.stillGranted = stillGranted
            self.responses = responses
        }

        func authorize(_ mayRequest: Bool) -> Bool {
            permissions.append(mayRequest)
            return mayRequest ? grant : stillGranted
        }

        func lookup(_ identity: MessagesArchiveContacts.Identity) -> [MessagesArchiveContacts.Candidate]? {
            queries.append(identity)
            return responses[identity]
        }
    }
}
