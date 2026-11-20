import Foundation
import SQLite3
import Testing
@testable import Relay

struct MessagesAttributedBodyTests {
    @Test func decodesTheDocumentedMutableMessagesSpecimen() {
        // The public typedstream specimen in Christopher Sardegna's format
        // analysis. Its body was created by the author for the article.
        let data = Data([
            0x04, 0x0b, 0x73, 0x74, 0x72, 0x65, 0x61, 0x6d, 0x74, 0x79, 0x70, 0x65, 0x64, 0x81, 0xe8, 0x03,
            0x84, 0x01, 0x40, 0x84, 0x84, 0x84, 0x19, 0x4e, 0x53, 0x4d, 0x75, 0x74, 0x61, 0x62, 0x6c, 0x65,
            0x41, 0x74, 0x74, 0x72, 0x69, 0x62, 0x75, 0x74, 0x65, 0x64, 0x53, 0x74, 0x72, 0x69, 0x6e, 0x67,
            0x00, 0x84, 0x84, 0x12, 0x4e, 0x53, 0x41, 0x74, 0x74, 0x72, 0x69, 0x62, 0x75, 0x74, 0x65, 0x64,
            0x53, 0x74, 0x72, 0x69, 0x6e, 0x67, 0x00, 0x84, 0x84, 0x08, 0x4e, 0x53, 0x4f, 0x62, 0x6a, 0x65,
            0x63, 0x74, 0x00, 0x85, 0x92, 0x84, 0x84, 0x84, 0x0f, 0x4e, 0x53, 0x4d, 0x75, 0x74, 0x61, 0x62,
            0x6c, 0x65, 0x53, 0x74, 0x72, 0x69, 0x6e, 0x67, 0x01, 0x84, 0x84, 0x08, 0x4e, 0x53, 0x53, 0x74,
            0x72, 0x69, 0x6e, 0x67, 0x01, 0x95, 0x84, 0x01, 0x2b, 0x0a, 0x4e, 0x6f, 0x74, 0x65, 0x72, 0x20,
            0x74, 0x65, 0x73, 0x74, 0x86, 0x84, 0x02, 0x69, 0x49, 0x01, 0x0a, 0x92, 0x84, 0x84, 0x84, 0x0c,
            0x4e, 0x53, 0x44, 0x69, 0x63, 0x74, 0x69, 0x6f, 0x6e, 0x61, 0x72, 0x79, 0x00, 0x95, 0x84, 0x01,
            0x69, 0x01, 0x92, 0x84, 0x98, 0x98, 0x1d, 0x5f, 0x5f, 0x6b, 0x49, 0x4d, 0x4d, 0x65, 0x73, 0x73,
            0x61, 0x67, 0x65, 0x50, 0x61, 0x72, 0x74, 0x41, 0x74, 0x74, 0x72, 0x69, 0x62, 0x75, 0x74, 0x65,
            0x4e, 0x61, 0x6d, 0x65, 0x86, 0x92, 0x84, 0x84, 0x84, 0x08, 0x4e, 0x53, 0x4e, 0x75, 0x6d, 0x62,
            0x65, 0x72, 0x00, 0x84, 0x84, 0x07, 0x4e, 0x53, 0x56, 0x61, 0x6c, 0x75, 0x65, 0x00, 0x95, 0x84,
            0x01, 0x2a, 0x84, 0x9b, 0x9b, 0x00, 0x86, 0x86, 0x86
        ])
        #expect(MessagesAttributedBody.decode(data) == "Noter test")
    }

    @Test func preservesUnicodeAndCapsOutputAtTheSameScalarBoundaryAsPlainText() {
        let message = String(repeating: "é𐐷", count: 70) + "\nمرحبا"
        #expect(MessagesAttributedBody.decode(BodyFixture.make(message)) == message)
        let long = String(repeating: "🌍", count: 9_000)
        #expect(MessagesAttributedBody.decode(BodyFixture.make(long)) == String(repeating: "🌍", count: 2_000))
    }

    @Test func rejectsIncompleteOrUnsupportedArchivesEvenWhenTheyContainValidLookingText() {
        let complete = BodyFixture.make("Keep this only if the complete archive is valid 🌍")
        for length in complete.indices {
            #expect(MessagesAttributedBody.decode(Data(complete.prefix(length))) == nil)
        }
        var appended = complete
        appended.append(0x86)
        #expect(MessagesAttributedBody.decode(appended) == nil)
        #expect(MessagesAttributedBody.decode(BodyFixture.make("wrong range", utf16Count: 1)) == nil)
        #expect(MessagesAttributedBody.decode(BodyFixture.make("attachment \u{fffc}")) == nil)
        #expect(MessagesAttributedBody.decode(BodyFixture.make("embedded\0null")) == nil)
        #expect(MessagesAttributedBody.decode(BodyFixture.make("valid backing text", key: "NSLink")) == nil)
        #expect(MessagesAttributedBody.decode(BodyFixture.make("invalid byte", utf8Override: [0xc3, 0x28])) == nil)
        #expect(MessagesAttributedBody.decode(BodyFixture.make("multiple runs", runIndex: 2)) == nil)
        #expect(MessagesAttributedBody.decode(Data(repeating: 0, count: 65_537)) == nil)
    }

    @Test func readsModernBodiesWithPlainTextPriorityAndCountsOnlyInScopeOmissions() async throws {
        let url = try database(sql: """
            INSERT INTO message VALUES
              (978307199,0,1,'Plain preferred',\(BodyFixture.sql("Losing attributed body"))),
              (978307200000000000,0,1,NULL,\(BodyFixture.sql("Modern é𐐷"))),
              (978307201,1,NULL,'',\(BodyFixture.sql("Modern empty plain"))),
              (978307202,1,NULL,NULL,X'040b73747265616d7479706564'),
              (978307203,0,1,NULL,zeroblob(65537)),
              (978307204,0,1,NULL,'not a SQLite blob'),
              (978307205,0,1,NULL,X''),
              (978307206,0,1,NULL,\(BodyFixture.sql("Other conversation"))),
              (42,0,1,NULL,\(BodyFixture.sql("Out of range"))),
              (978307207,0,1,NULL,NULL);
            INSERT INTO chat_message_join VALUES (1,1),(1,2),(1,3),(1,4),(1,5),(1,6),(1,7),(2,8),(1,9),(1,10);
            """)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let original = try Data(contentsOf: url)
        let read = try await ChatArchiveReader.messages(url, chatID: 1, days: 7, now: Self.now)
        #expect(read.entries.map(\.body) == ["Plain preferred", "Modern é𐐷", "Modern empty plain"])
        #expect(read.entries.map(\.sender) == ["Synthetic Participant", "Synthetic Participant", "Me"])
        #expect(read.omittedAttributedBodies == 4)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func omittedBodiesDoNotExpandTheLatestEightyCandidateWindow() async throws {
        let url = try database(sql: """
            INSERT INTO message VALUES
              (978307199,0,1,'Older beyond the window',NULL),
              (978307281,0,1,NULL,X'00');
            INSERT INTO chat_message_join VALUES (1,1),(1,2);
            WITH RECURSIVE samples(i) AS (VALUES(1) UNION ALL SELECT i + 1 FROM samples WHERE i < 80)
              INSERT INTO message SELECT 978307200 + i,0,1,'Plain ' || i,NULL FROM samples;
            INSERT INTO chat_message_join SELECT 1,rowid FROM message WHERE rowid > 2;
            """)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let read = try await ChatArchiveReader.messages(url, chatID: 1, days: 7, now: Self.now.addingTimeInterval(60))
        #expect(read.entries.count == 79)
        #expect(read.entries.first?.body == "Plain 2")
        #expect(read.entries.last?.body == "Plain 80")
        #expect(read.omittedAttributedBodies == 1)
    }

    @Test func unsupportedOnlySelectionRefusesWithoutReturningEmbeddedText() async throws {
        let url = try database(sql: """
            INSERT INTO message VALUES (978307200,0,1,NULL,\(BodyFixture.sql("Unvalidated", key: "NSLink")));
            INSERT INTO chat_message_join VALUES (1,1);
            """)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            _ = try await ChatArchiveReader.messages(url, chatID: 1, days: 7, now: Self.now)
            Issue.record("The selection had no supported message body.")
        } catch {
            #expect(error.localizedDescription == "No supported message text was available. Skipped 1 unsupported message body.")
        }
    }

    private static let now = Date(timeIntervalSince1970: 2 * 978_307_200 + 60)

    private func database(sql: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let url = directory.appending(path: "chat.db")
            var handle: OpaquePointer?
            let opened = sqlite3_open(url.path, &handle)
            defer { if let handle { sqlite3_close(handle) } }
            try #require(opened == SQLITE_OK)
            let schema = """
                CREATE TABLE chat(display_name TEXT, chat_identifier TEXT);
                CREATE TABLE message(date INTEGER, is_from_me INTEGER, handle_id INTEGER, text TEXT, attributedBody BLOB);
                CREATE TABLE chat_message_join(chat_id INTEGER, message_id INTEGER);
                CREATE TABLE handle(id TEXT);
                INSERT INTO chat VALUES ('Selected','selected'),('Other','other');
                INSERT INTO handle VALUES ('Synthetic Participant');
                """
            try #require(sqlite3_exec(handle, schema + "\n" + sql, nil, nil, nil) == SQLITE_OK)
            return url
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}

/// A synthetic compact typedstream archive. Writes literal declarations and
/// remembers the two reference spaces independently of the decoder.
private nonisolated struct BodyFixture {
    private var bytes: [UInt8] = [4, 11] + Array("streamtyped".utf8) + [0x81, 0xe8, 0x03]
    private var stringNames: [String] = []
    private var archiveSlots: [String?] = []

    static func make(_ body: String, utf16Count: Int? = nil, key: String = "__kIMMessagePartAttributeName",
                     utf8Override: [UInt8]? = nil, runIndex: Int = 1) -> Data {
        var fixture = BodyFixture()
        fixture.object([("NSAttributedString", 0), ("NSObject", 0)])
        fixture.object([("NSString", 1)], superclass: "NSObject")
        fixture.shared("+")
        fixture.stringBytes(utf8Override ?? Array(body.utf8))
        fixture.bytes.append(0x86)
        fixture.shared("iI")
        fixture.integer(runIndex)
        fixture.integer(utf16Count ?? body.utf16.count)
        fixture.object([("NSDictionary", 0)], superclass: "NSObject")
        fixture.shared("i")
        fixture.integer(1)
        fixture.object([], superclass: "NSString")
        fixture.shared("+")
        fixture.stringBytes(Array(key.utf8))
        fixture.bytes.append(0x86)
        fixture.object([("NSNumber", 0), ("NSValue", 0)], superclass: "NSObject")
        fixture.shared("*")
        fixture.bytes.append(0x84)
        fixture.archiveSlots.append(nil)
        fixture.shared("i")
        fixture.shared("i")
        fixture.integer(0)
        fixture.bytes += [0x86, 0x86, 0x86]
        return Data(fixture.bytes)
    }

    static func sql(_ body: String, key: String = "__kIMMessagePartAttributeName") -> String {
        "X'" + make(body, key: key).map { String(format: "%02x", $0) }.joined() + "'"
    }

    private mutating func object(_ declarations: [(String, Int)], superclass: String? = nil) {
        shared("@")
        bytes.append(0x84)
        archiveSlots.append(nil)
        for (name, version) in declarations {
            bytes.append(0x84)
            shared(name)
            integer(version)
            archiveSlots.append(name)
        }
        if let superclass, let index = archiveSlots.firstIndex(of: superclass) {
            bytes.append(0x92 + UInt8(index))
        } else {
            bytes.append(0x85)
        }
    }

    private mutating func shared(_ value: String) {
        if let index = stringNames.firstIndex(of: value) {
            bytes.append(0x92 + UInt8(index))
        } else {
            bytes.append(0x84)
            stringBytes(Array(value.utf8))
            stringNames.append(value)
        }
    }

    private mutating func stringBytes(_ value: [UInt8]) {
        integer(value.count)
        bytes += value
    }

    private mutating func integer(_ value: Int) {
        if value < 128 {
            bytes.append(UInt8(value))
        } else {
            let width = value < 32_768 ? 2 : 4
            bytes.append(width == 2 ? 0x81 : 0x82)
            for index in 0..<width { bytes.append(UInt8(truncatingIfNeeded: value >> (index * 8))) }
        }
    }
}
