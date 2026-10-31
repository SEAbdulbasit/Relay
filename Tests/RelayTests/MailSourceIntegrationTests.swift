import CryptoKit
import Foundation
import Testing
@testable import Relay

@MainActor
struct MailSourceIntegrationTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func mail(_ body: String) -> Data {
        Data(("From: impostor@example.test\r\nSubject: Synthetic saffron note\r\nContent-Type: multipart/mixed; boundary=outer\r\n\r\n--outer\r\nContent-Type: multipart/alternative; boundary=inner\r\n\r\n--inner\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n" + Data(body.utf8).base64EncodedString() + "\r\n--inner\r\nContent-Type: text/html\r\n\r\n<img src='https://example.test/private'>HTML_ONLY_MARKER\r\n--inner--\r\n--outer\r\nContent-Type: text/plain; name=attachment.txt\r\nContent-Disposition: attachment; filename=attachment.txt\r\n\r\nATTACHMENT_SECRET\r\n--outer--\r\n").utf8)
    }
    @Test func selectedMailDecodesUnicodeAndIndexesRawHashWithoutRenderingOtherParts() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("selected.eml")
        let bytes = mail("Project saffron: Café 🌍 مرحباً.")
        try bytes.write(to: path)
        let grants = [ScopeGrant(path: path.path)]
        let tools = MacTools(); tools.grants = grants
        let result = try await tools.execute(.init(name: "read_file", arguments: ["path": .string(path.path)]))
        #expect(result.verified)
        #expect(result.summary.contains("Café 🌍 مرحباً"))
        #expect(result.summary.contains("Claimed sender: impostor@example.test"))
        #expect(result.summary.contains("not authenticated"))
        #expect(!result.summary.contains("HTML_ONLY_MARKER"))
        #expect(!result.summary.contains("ATTACHMENT_SECRET"))
        let knowledge = LocalKnowledge(persistenceURL: nil)
        await knowledge.index(grants: grants)
        #expect(knowledge.records.count == 1)
        #expect(knowledge.records.first?.contentHash == SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        #expect(knowledge.records.first?.coverageNote?.contains("unverified") == true)
        #expect(knowledge.search(query: "saffron", grants: grants).count == 1)
        #expect(knowledge.search(query: "ATTACHMENT_SECRET", grants: grants).isEmpty)
    }
    @Test func changedAndRevokedMailNeverReturnsAnOldExcerpt() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("current.eml")
        try mail("Unique original body marker").write(to: path)
        let grants = [ScopeGrant(path: path.path)]
        let knowledge = LocalKnowledge(persistenceURL: nil)
        await knowledge.index(grants: grants)
        #expect(knowledge.search(query: "original", grants: grants).count == 1)
        try mail("Replacement body only").write(to: path)
        #expect(knowledge.search(query: "original", grants: grants).isEmpty)
        await knowledge.index(grants: grants)
        #expect(knowledge.search(query: "Replacement", grants: grants).count == 1)
        #expect(knowledge.search(query: "Replacement", grants: []).isEmpty)
        #expect(knowledge.records.isEmpty)
        #expect(FileManager.default.fileExists(atPath: path.path))
    }
    @Test func htmlOnlyExportIsExplicitlyUnsupportedAndOriginalRemainsUntouched() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("html-only.eml")
        let bytes = Data("Content-Type: text/html\r\n\r\n<script>Never render me</script>".utf8)
        try bytes.write(to: path)
        let tools = MacTools(); tools.grants = [.init(path: path.path)]
        await #expect(throws: (any Error).self) { try await tools.execute(.init(name: "read_file", arguments: ["path": .string(path.path)])) }
        let knowledge = LocalKnowledge(persistenceURL: nil)
        await knowledge.index(grants: tools.grants)
        #expect(knowledge.records.isEmpty)
        #expect(try Data(contentsOf: path) == bytes)
    }
}
