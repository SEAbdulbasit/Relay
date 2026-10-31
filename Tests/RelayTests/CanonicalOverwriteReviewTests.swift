import Foundation
import Testing
@testable import Relay

@MainActor
struct CanonicalOverwriteReviewTests {
    @Test func missingParentDotDotCannotBypassReviewForTextDOCXOrXLSX() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tools = MacTools(); tools.grants = [.init(path: root.path, writable: true)]
        for ext in ["txt", "docx", "xlsx"] {
            let target = root.appendingPathComponent("existing." + ext)
            let original = Data("Original must remain until reviewed: \(ext)".utf8)
            try original.write(to: target)
            let raw = root.path + "/nonexistent/../existing." + ext
            #expect(!FileManager.default.fileExists(atPath: raw))
            #expect(try ToolPolicy.scopedURL(raw, grants: tools.grants, writing: true).path == ToolPolicy.canonicalURL(target.path).path)
            let request: ToolCall
            switch ext {
            case "txt": request = .init(name: "write_file", arguments: ["path": .string(raw), "content": .string("Reviewed replacement")])
            case "docx": request = .init(name: "create_document", arguments: ["path": .string(raw), "format": .string("docx"), "title": .string("Reviewed"), "body": .string("Reviewed replacement")])
            default: request = .init(name: "create_spreadsheet", arguments: ["path": .string(raw), "sheet_name": .string("Reviewed"), "rows_json": .string("[[\"Reviewed replacement\"]]")])
            }
            let reason = try #require(tools.reviewReason(for: request))
            #expect(reason.contains(try ToolPolicy.canonicalURL(target.path).path))
            #expect(!reason.contains("nonexistent/.."))
            await #expect(throws: (any Error).self) { try await tools.execute(request) }
            #expect(try Data(contentsOf: target) == original)
            try tools.prepareReview(request); try tools.authorize(request)
            #expect(try await tools.execute(request).verified)
            #expect(try Data(contentsOf: target) != original)
            await #expect(throws: (any Error).self) { try await tools.execute(request) }
        }
    }
}
