import Foundation
import Testing
@testable import Relay

@MainActor
struct KnowledgeSearchCoordinatorTests {
    private actor Backend: SemanticEmbeddingBackend {
        var prepares = 0
        var texts: [String] = []
        var holdSource = false
        var sourceWaiting = false
        private var waiting: CheckedContinuation<Void, Never>?
        func prepare(language: String) -> SemanticEmbeddingDescriptor? {
            prepares += 1; return .init(language: language, revision: 1, dimension: 2)
        }
        func vector(for text: String) async -> [Double]? {
            texts.append(text)
            if holdSource && text.contains("Reset your login") {
                sourceWaiting = true
                await withCheckedContinuation { waiting = $0 }
            }
            return text.contains("Bake bread") ? [0, 1] : [1, 0]
        }
        func clear() { }
        func suspendSource() { holdSource = true }
        func releaseSource() { holdSource = false; waiting?.resume(); waiting = nil }
    }
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func indexed(_ root: URL, backend: Backend) async throws -> (LocalKnowledge, SemanticKnowledgeSearch, KnowledgeSearchCoordinator) {
        try Data("Reset your login secret.".utf8).write(to: root.appendingPathComponent("account.txt"))
        try Data("Bake bread in the oven.".utf8).write(to: root.appendingPathComponent("recipe.txt"))
        let knowledge = LocalKnowledge(persistenceURL: nil)
        await knowledge.index(grants: [.init(path: root.path)])
        let semantic = SemanticKnowledgeSearch(backend: backend)
        let search = KnowledgeSearchCoordinator(knowledge: knowledge, service: semantic)
        search.currentGrants = { [.init(path: root.path)] }
        return (knowledge, semantic, search)
    }
    @Test func keywordOnlyQueriesNeverPrepareNativeAssetsAndSemanticProbeIsExplicit() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let backend = Backend(), (knowledge, _, search) = try await indexed(root, backend: backend)
        #expect(try await search.search(query: "login").count == 1)
        #expect(await backend.prepares == 0)
        #expect(await backend.texts.isEmpty)
        #expect(knowledge.search(query: "password", grants: [.init(path: root.path)]).isEmpty)
        search.prepare(); await search.waitForPreparation()
        #expect(search.state == .ready)
        let found = try await search.search(query: "change password")
        #expect(found.first?.title == "account.txt")
        #expect(found.first?.matchKind == "Meaning-based candidate")
        #expect(found.first?.excerpt == "Reset your login secret.")
        search.turnOff(); await search.waitForPreparation()
        #expect(try await search.search(query: "login").count == 1)
        #expect(await backend.prepares == 1)
    }
    @Test func exactFilenameKeepsPriorityOverSemanticSimilarity() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let backend = Backend(), (_, _, search) = try await indexed(root, backend: backend)
        search.prepare(); await search.waitForPreparation()
        let results = try await search.search(query: "recipe.txt")
        #expect(results.first?.title == "recipe.txt")
        #expect(results.first?.matchKind == "Keyword match")
    }
    @Test func toolScopeCannotBeBroadenedByCoordinatorProvider() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let backend = Backend(), (knowledge, _, search) = try await indexed(root, backend: backend)
        search.prepare(); await search.waitForPreparation()
        let tools = MacTools(); tools.knowledge = knowledge; tools.knowledgeSearch = search
        tools.grants = [.init(path: root.appendingPathComponent("recipe.txt").path)]
        let result = try await tools.execute(.init(name: "search_knowledge", arguments: ["query": .string("change password")]))
        #expect(!result.summary.contains("Reset your login"))
        #expect(!result.summary.contains("account.txt"))
        #expect(!(await backend.texts).contains("Reset your login secret."))
    }
    @Test func revokedScopeWhileVectorIsPendingCannotPublishOldSource() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let backend = Backend(), (_, _, search) = try await indexed(root, backend: backend)
        var grants = [ScopeGrant(path: root.path)]
        search.currentGrants = { grants }
        search.prepare(); await search.waitForPreparation()
        await backend.suspendSource()
        let query = Task { try await search.search(query: "change password") }
        for _ in 0..<200 {
            if await backend.sourceWaiting { break }
            await Task.yield()
        }
        #expect(await backend.sourceWaiting)
        grants = []
        await backend.releaseSource()
        await #expect(throws: (any Error).self) { try await query.value }
        #expect(try await search.search(query: "login").isEmpty)
    }
    @Test func changedFileWhileVectorIsPendingCannotPublishOldHashOrText() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let backend = Backend(), (_, _, search) = try await indexed(root, backend: backend)
        search.prepare(); await search.waitForPreparation()
        await backend.suspendSource()
        let query = Task { try await search.search(query: "change password") }
        for _ in 0..<200 {
            if await backend.sourceWaiting { break }
            await Task.yield()
        }
        #expect(await backend.sourceWaiting)
        try Data("Changed source text".utf8).write(to: root.appendingPathComponent("account.txt"))
        await backend.releaseSource()
        await #expect(throws: (any Error).self) { try await query.value }
    }
}
