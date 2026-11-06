import Foundation
import SQLite3
import Testing
@testable import Relay

struct ChatArchiveReaderTests {
    @Test func parsesBothExportFormatsAndDoesNotAttributeSystemNotices() throws {
        let entries = try ChatArchiveReader.parseWhatsApp("""
        [6/11/26, 2:15:00 PM] A: Hello 🌍
        A wrapped line
        [6/11/26, 2:15:01 PM] Messages are encrypted
        6/11/2026, 14:16 - B: مرحبا
        """)
        #expect(entries.map(\.sender) == ["A", "B"])
        #expect(entries.map(\.body) == ["Hello 🌍\nA wrapped line", "مرحبا"])
    }

    @Test func readsOnlyTheSelectedConversationAndDateFromARealSQLiteFixture() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "chat.db")
        var database: OpaquePointer?
        try #require(sqlite3_open(url.path, &database) == SQLITE_OK)
        let sql = """
            CREATE TABLE chat(display_name TEXT, chat_identifier TEXT);
            CREATE TABLE message(date INTEGER, is_from_me INTEGER, handle_id INTEGER, text TEXT);
            CREATE TABLE chat_message_join(chat_id INTEGER, message_id INTEGER);
            CREATE TABLE handle(id TEXT);
            INSERT INTO chat VALUES('One','one'),('Other','two');
            INSERT INTO handle VALUES('Synthetic Person');
            INSERT INTO message VALUES(978307200000000000,0,1,'selected');
            INSERT INTO message VALUES(978307200,0,1,'other conversation');
            INSERT INTO message VALUES(10,1,1,'too old');
            INSERT INTO message VALUES(978307200000000000,0,1,NULL);
            INSERT INTO chat_message_join VALUES(1,1),(2,2),(1,3),(1,4);
            """
        let created = sqlite3_exec(database, sql, nil, nil, nil)
        sqlite3_close(database)
        try #require(created == SQLITE_OK)
        let before = try Data(contentsOf: url)
        let choices = try await ChatArchiveReader.messagesConversations(url)
        #expect(Set(choices.map(\.label)) == ["One", "Other"])
        let selected = try await ChatArchiveReader.messages(url, chatID: 1, days: 7, now: Date(timeIntervalSince1970: 2 * 978_307_200 + 60))
        #expect(selected.map(\.body) == ["selected"])
        #expect(selected.map(\.sender) == ["Synthetic Person"])
        #expect(try Data(contentsOf: url) == before)
        let journal = directory.appending(path: "chat.db-wal")
        try Data([0]).write(to: journal)
        await #expect(throws: (any Error).self) { try await ChatArchiveReader.messagesConversations(url) }
    }
}
