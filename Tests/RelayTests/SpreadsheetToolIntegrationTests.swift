import Foundation
import Testing
@testable import Relay

@MainActor
struct SpreadsheetToolIntegrationTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func call(_ path: URL, rows: String = "[[\"Item\",\"Count\"],[\"Café 🌍\",3],[\"=SUM(A1:A2)\",true]]") -> ToolCall {
        .init(name: "create_spreadsheet", arguments: ["path": .string(path.path), "sheet_name": .string("Local check"), "rows_json": .string(rows)])
    }
    @Test func writesSelectedXLSXAndChecksActualPackageBytes() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let tools = MacTools(); tools.grants = [.init(path: root.path, writable: true)]
        let path = root.appendingPathComponent("check.xlsx")
        let result = try await tools.execute(call(path))
        #expect(result.verified)
        #expect(result.artifactPath == (try ToolPolicy.canonicalURL(path.path).path))
        let bytes = try Data(contentsOf: path)
        #expect(bytes.starts(with: [0x50, 0x4b, 0x03, 0x04]))
        #expect(bytes.range(of: Data("=SUM(A1:A2)".utf8)) != nil)
        #expect(bytes.range(of: Data("<f>".utf8)) == nil)
        #expect(result.evidence.contains("not independently checked"))
    }
    @Test func scopeInvalidDataAndWrongExtensionCannotWrite() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("allowed", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let tools = MacTools(); tools.grants = [.init(path: folder.path)]
        await #expect(throws: (any Error).self) { try await tools.execute(call(folder.appendingPathComponent("readonly.xlsx"))) }
        tools.grants = [.init(path: folder.path, writable: true)]
        for request in [call(root.appendingPathComponent("outside.xlsx")), call(folder.appendingPathComponent("macro.xlsm")), call(folder.appendingPathComponent("bad.xlsx"), rows: "{\"hidden\":true}"), call(folder.appendingPathComponent("bad.xlsx"), rows: "[[[1,2]]]")] {
            await #expect(throws: (any Error).self) { try await tools.execute(request) }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }
    @Test func overwriteIsOneUseAndRejectsChangedDestination() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let tools = MacTools(); tools.grants = [.init(path: root.path, writable: true)]
        let path = root.appendingPathComponent("replace.xlsx")
        _ = try await tools.execute(call(path, rows: "[[\"Original\"]]"))
        let request = call(path)
        #expect(tools.reviewReason(for: request)?.contains("Exact row data") == true)
        await #expect(throws: (any Error).self) { try await tools.execute(request) }
        try tools.prepareReview(request); try tools.authorize(request)
        let external = Data("External replacement".utf8); try external.write(to: path)
        await #expect(throws: (any Error).self) { try await tools.execute(request) }
        #expect(try Data(contentsOf: path) == external)
        try tools.prepareReview(request); try tools.authorize(request)
        #expect(try await tools.execute(request).verified)
        await #expect(throws: (any Error).self) { try await tools.execute(request) }
    }
    @Test func changedPayloadOrStopInvalidatesWorkbookApproval() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let tools = MacTools(); tools.grants = [.init(path: root.path, writable: true)]
        let path = root.appendingPathComponent("review.xlsx")
        _ = try await tools.execute(call(path, rows: "[[\"Keep\"]]"))
        let original = try Data(contentsOf: path)
        var request = call(path)
        try tools.prepareReview(request)
        request.arguments["rows_json"] = .string("[[\"Changed after review\"]]")
        #expect(throws: (any Error).self) { try tools.authorize(request) }
        try tools.prepareReview(request); try tools.authorize(request); tools.invalidateApprovals()
        await #expect(throws: (any Error).self) { try await tools.execute(request) }
        #expect(try Data(contentsOf: path) == original)
    }
}
