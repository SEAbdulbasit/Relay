import Testing
import Foundation
import Darwin
@testable import RelayJournal

func legacyFixture(unknown: Bool = false) throws -> Data {
    var root: [String: Any] = [
        "messages": [
            ["id": UUID().uuidString, "role":"user", "text":"Literal sk-example prose, café and cafe\u{301}; email person@example.test about task-notes.", "date":42.0, "artifacts":["/synthetic/omitted-artifact"]],
            ["id": UUID().uuidString, "role":"assistant", "text":"Original exact answer.", "date":43.0],
            ["id": UUID().uuidString, "role":"user", "text":"Another request", "date":44.0]
        ],
        "activity":[["id":UUID().uuidString, "name":"owned", "detail":"OMITTED_ACTIVITY_TOKEN_VALUE", "status":"recorded", "date":40.0]], "grants":[], "memories":[],
        "configuration":["backend":"liteRTLM", "modelPath":"/synthetic/OMITTED_MODEL_PATH"],
        "modelMessages":[["role":"tool", "toolCalls":[], "content":"Authorization: Bearer OMITTED_HEADER_VALUE data:image/png;base64,OMITTED_IMAGE_VALUE"]],
        "interrupted":true, "activeObjective":"OMITTED_OBJECTIVE", "activeContextStart":0
    ]
    if unknown { root["schemaVersion"] = 999 }
    return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
}

@Suite(.serialized) struct LegacyJournalTests {
    @Test func importRestartRetryDigestAndOriginalBytes() async throws {
        let container = temporaryJournal(), root = container.appendingPathComponent("journal"); defer { cleanup(container) }
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let url = container.appendingPathComponent("legacy.json"), bytes = try legacyFixture(); try bytes.write(to: url)
        let snapshot = try await JournalLegacySnapshot.read(url)
        #expect(snapshot.events.count == 5); #expect(snapshot.omittedActivityCount == 1); #expect(snapshot.omittedModelMessageCount == 1)
        let journal = try await ConversationJournal.open(directory: root, initialization: .importing(snapshot.manifest)), scope = try await journal.scope()
        #expect(try await !journal.isReady())
        await assertFailure(.notReady) { _ = try await journal.page(expectedScope: scope) }
        try await journal.importLegacyBatch(Array(snapshot.events.prefix(2)), manifest: snapshot.manifest, expectedScope: scope)
        await assertFailure(.notReady) { try await journal.finishLegacyImport(manifest: snapshot.manifest, expectedScope: scope) }
        try await journal.close()
        let resumed = try await ConversationJournal.open(directory: root, initialization: .importing(snapshot.manifest))
        for batch in try snapshot.batches() { try await resumed.importLegacyBatch(batch, manifest: snapshot.manifest, expectedScope: scope) }
        try await resumed.finishLegacyImport(manifest: snapshot.manifest, expectedScope: scope)
        try await resumed.finishLegacyImport(manifest: snapshot.manifest, expectedScope: scope)
        let records = try await resumed.page(expectedScope: scope).records
        #expect(records.map(\.event) == snapshot.events)
        #expect(records[2].event.payload == .finished(.historicalUnknown)); #expect(records.last?.event.payload == .finished(.interrupted))
        if case let .user(text) = records[0].event.payload {
            #expect(!text.automaticallyEligibleForInference); #expect(text.omissions.contains(.legacyActivity))
            #expect(text.omissions.contains(.legacyModelContext)); #expect(text.artifacts.map(\.visiblePath) == ["/synthetic/omitted-artifact"])
            #expect(text.artifacts[0].identityDigest == nil)
            #expect(Data(text.text.utf8).contains(Data("cafe\u{301}".utf8)))
        } else { Issue.record("Missing exact legacy user text") }
        #expect(try Data(contentsOf: url) == bytes)
        for value in try contents(root).values {
            for omitted in ["OMITTED_ACTIVITY_TOKEN_VALUE", "OMITTED_HEADER_VALUE", "OMITTED_IMAGE_VALUE", "OMITTED_MODEL_PATH", "OMITTED_OBJECTIVE"] { #expect(value.range(of: Data(omitted.utf8)) == nil) }
        }
        let cleared = try await resumed.reset(expectedScope: scope)
        await assertFailure(.notReady) { try await resumed.importLegacyBatch(snapshot.events, manifest: snapshot.manifest, expectedScope: cleared) }
        #expect(try await resumed.page(expectedScope: cleared).records.isEmpty)
        #expect(try Data(contentsOf: url) == bytes)
        try await resumed.close()
    }
    @Test func changedSourceAndWrongEventManifestRefuse() async throws {
        let root = temporaryJournal(); defer { cleanup(root) }
        let snapshot = try JournalLegacySnapshot.decode(legacyFixture())
        let journal = try await ConversationJournal.open(directory: root, initialization: .importing(snapshot.manifest)), scope = try await journal.scope()
        let changed = try JournalLegacyManifest(digest: Data(repeating: 9, count: 32), expectedEvents: snapshot.events.count, eventsDigest: snapshot.manifest.eventsDigest)
        await assertFailure(.notReady) { try await journal.importLegacyBatch(snapshot.events, manifest: changed, expectedScope: scope) }
        let forged = try JournalLegacyManifest(digest: snapshot.manifest.digest, expectedEvents: snapshot.events.count, eventsDigest: Data(repeating: 1, count: 32))
        await assertFailure(.notReady) { try await journal.importLegacyBatch(snapshot.events, manifest: forged, expectedScope: scope) }
        var wrongEvents = snapshot.events
        let first = wrongEvents[0]
        wrongEvents[0] = JournalEvent(id: first.id, taskID: first.taskID, attemptID: nil, payload: .user(try JournalVisibleText("Wrong import", origin: .legacyUnknown)))
        try await journal.importLegacyBatch(wrongEvents, manifest: snapshot.manifest, expectedScope: scope)
        await assertFailure(.conflictingID) { try await journal.finishLegacyImport(manifest: snapshot.manifest, expectedScope: scope) }
        #expect(try await !journal.isReady()); try await journal.close()
    }
    @Test(arguments: ["newer", "corrupt", "null", "oversized"]) func rejectedLegacyRemainsUnchanged(_ kind: String) async throws {
        let root = temporaryJournal(); defer { cleanup(root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let url = root.appendingPathComponent("legacy.json"), bytes: Data
        switch kind {
        case "newer": bytes = try legacyFixture(unknown: true)
        case "null": bytes = Data("{\"messages\":null}".utf8)
        case "oversized": bytes = Data(repeating: 32, count: 32 * 1024 * 1024 + 1)
        default: bytes = Data("{broken json".utf8)
        }
        try bytes.write(to: url)
        await assertFailure { _ = try await JournalLegacySnapshot.read(url) }
        #expect(try Data(contentsOf: url) == bytes)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Conversation.sqlite").path))
    }
    @Test func excludedTypesAreExplicitButUserProseStaysExact() throws {
        let literal = "Preserve literal sk-example, Authorization: example, person@example.test, desk-notes and 👨🏽‍💻."
        let value = try JournalVisibleText(literal, origin: .user, omissions: [.credentialField,.requestHeader,.imageBody])
        let event = JournalEvent(id: try JournalOpaqueID("typed"), taskID: UUID(), attemptID: nil, payload: .user(value))
        let encoded = try journalEncoded(event), decoded = try JSONDecoder().decode(JournalEvent.self, from: encoded)
        guard case let .user(text) = decoded.payload else { Issue.record("Missing visible text"); return }
        #expect(Data(text.text.utf8) == Data(literal.utf8)); #expect(text.omissions == [.credentialField,.requestHeader,.imageBody])
        #expect(!String(decoding: encoded, as: UTF8.self).contains("OMITTED_SECRET"))
    }
    @Test(arguments: ["grants", "memories", "activity", "configuration", "modelMessages", "interrupted", "activeContextStart"]) func malformedKnownLegacyFieldsRefuse(_ key: String) throws {
        var root = try JSONSerialization.jsonObject(with: legacyFixture()) as! [String: Any]
        if key == "configuration" { root[key] = ["backend":NSNull()] }
        else if key == "interrupted" { root[key] = 1 }
        else if key == "activeContextStart" { root[key] = true }
        else { root[key] = [42] }
        let bytes = try JSONSerialization.data(withJSONObject: root)
        #expect(throws: (any Error).self) { try JournalLegacySnapshot.decode(bytes) }
    }
}
