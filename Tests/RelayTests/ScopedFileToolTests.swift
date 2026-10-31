import Foundation
import Testing
@testable import Relay

@MainActor
struct ScopedFileToolTests {
    private func workspace() throws -> (URL, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("destination"), withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.txt")
        try Data("Synthetic move 🌍".utf8).write(to: source)
        return (root, source, root.appendingPathComponent("destination/renamed.txt"))
    }
    private func preview(_ tools: MacTools, source: URL, destination: URL) async throws -> ToolCall {
        let result = try await tools.execute(ToolCall(name: "preview_file_move", arguments: ["source": .string(source.path), "destination": .string(destination.path)]))
        let first = try #require(result.summary.split(separator: "\n").first)
        let id = first.replacingOccurrences(of: "preview_id: ", with: "")
        #expect(UUID(uuidString: id) != nil)
        return ToolCall(name: "move_file", arguments: ["preview_id": .string(id)])
    }
    @Test func moveNeedsExactReviewIsOneUseAndCanBeReversedWithFreshReview() async throws {
        let (root, source, destination) = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let tools = MacTools(); tools.grants = [.init(path: root.path, writable: true)]
        let call = try await preview(tools, source: source, destination: destination)
        await #expect(throws: (any Error).self) { try await tools.execute(call) }
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(tools.reviewReason(for: call)?.contains(destination.path) == true)
        try tools.prepareReview(call); try tools.authorize(call)
        let result = try await tools.execute(call)
        #expect(result.verified)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(try String(contentsOf: destination, encoding: .utf8) == "Synthetic move 🌍")
        await #expect(throws: (any Error).self) { try await tools.execute(call) }
        let reverse = try await preview(tools, source: destination, destination: source)
        try tools.prepareReview(reverse); try tools.authorize(reverse)
        #expect(try await tools.execute(reverse).verified)
        #expect(try String(contentsOf: source, encoding: .utf8) == "Synthetic move 🌍")
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
    @Test func revocationAndStopInvalidateMoveTickets() async throws {
        let (root, source, destination) = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let tools = MacTools(); let grants = [ScopeGrant(path: root.path, writable: true)]; tools.grants = grants
        let first = try await preview(tools, source: source, destination: destination)
        try tools.prepareReview(first)
        tools.grants = []
        #expect(throws: (any Error).self) { try tools.authorize(first) }
        tools.grants = grants
        let stopped = try await preview(tools, source: source, destination: destination)
        try tools.prepareReview(stopped); try tools.authorize(stopped)
        tools.invalidateApprovals()
        await #expect(throws: (any Error).self) { try await tools.execute(stopped) }
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
    @Test func changedSourceAndOccupiedDestinationNeverOverwrite() async throws {
        let (root, source, destination) = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let tools = MacTools(); tools.grants = [.init(path: root.path, writable: true)]
        let call = try await preview(tools, source: source, destination: destination)
        try tools.prepareReview(call); try tools.authorize(call)
        try Data("Changed after review".utf8).write(to: source)
        await #expect(throws: (any Error).self) { try await tools.execute(call) }
        #expect(try String(contentsOf: source, encoding: .utf8) == "Changed after review")
        try Data("Keep destination".utf8).write(to: destination)
        await #expect(throws: (any Error).self) { try await tools.execute(ToolCall(name: "preview_file_move", arguments: ["source": .string(source.path), "destination": .string(destination.path)])) }
        #expect(try String(contentsOf: destination, encoding: .utf8) == "Keep destination")
    }
    @Test func recursiveSearchOnlyReportsSelectedScope() async throws {
        let (root, _, destination) = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("Match".utf8).write(to: destination)
        let tools = MacTools(); tools.grants = [.init(path: root.path, writable: false)]
        let result = try await tools.execute(ToolCall(name: "search_files", arguments: ["query": .string("renamed")]))
        #expect(result.verified)
        #expect(result.summary.contains(destination.path))
        tools.grants = []
        await #expect(throws: (any Error).self) { try await tools.execute(ToolCall(name: "search_files", arguments: ["query": .string("renamed")])) }
    }
}
