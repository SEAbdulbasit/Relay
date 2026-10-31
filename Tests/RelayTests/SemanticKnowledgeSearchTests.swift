import Foundation
import Testing
@testable import Relay

struct SemanticKnowledgeSearchTests {
    private func source(_ text: String, path: String = "/synthetic/notes.txt", hash: String = "hash-a", note: String? = nil) -> KnowledgeRecord {
        .init(sourcePath: path, title: "Synthetic source", text: text, modifiedAt: .distantPast, contentHash: hash, byteCount: text.utf8.count, coverageNote: note)
    }

    @Test func constructionAndUnpreparedQueriesDoNotLoadOrProbeAnything() async {
        let backend = SemanticBackendFixture()
        let service = SemanticKnowledgeSearch(backend: backend)
        let result = await service.search(query: "password", records: [source("A local passage")])
        #expect(result.mode == .lexicalFallback)
        #expect(result.hits.isEmpty)
        #expect(await backend.prepareCount == 0)
        #expect(await backend.vectorCount == 0)
        #expect(await service.preparedModel == nil)
    }

    @Test func explicitPrepareProbesOnceAndQueriesReuseOnlyHeldModelWithBoundedCache() async {
        let backend = SemanticBackendFixture()
        let service = SemanticKnowledgeSearch(backend: backend)
        let ready = await service.prepare(language: "en")
        #expect(ready.state == .ready)
        #expect(await backend.prepareCount == 1)
        #expect(await backend.vectorCount == 1)
        let records = [source("Reset your login secret.", path: "/synthetic/account.txt", hash: "account", note: "Synthetic coverage marker"), source("Bake bread.", path: "/synthetic/cooking.txt", hash: "cooking")]
        let first = await service.search(query: "change password", records: records)
        #expect(first.mode == .semantic)
        #expect(first.hits.first?.sourcePath == "/synthetic/account.txt")
        #expect(first.hits.first?.sourceContentHash == "account")
        #expect(first.hits.first?.chunk == "Reset your login secret.")
        #expect(first.hits.first?.coverageNote == "Synthetic coverage marker")
        #expect(first.hits.allSatisfy { $0.score.isFinite && (-1...1).contains($0.score) })
        #expect(await backend.vectorCount == 4) // One synthetic probe, query, two source vectors.
        let second = await service.search(query: "change password", records: records)
        #expect(second.coverage.cacheHits == 2)
        #expect(await backend.vectorCount == 5) // Query vector only; source vectors are reused.
        #expect(await backend.prepareCount == 1)
        await service.clear()
        let off = await service.search(query: "change password", records: records)
        #expect(off.mode == .lexicalFallback)
        #expect(await backend.vectorCount == 5)
        #expect(await backend.prepareCount == 1)
        #expect(await service.cachedVectorCount == 0)
    }

    @Test func unavailableLanguageInvalidMetadataAndBadProbeRemainLexicalWithoutFallbackModel() async {
        let missing = SemanticBackendFixture(descriptor: nil)
        let missingService = SemanticKnowledgeSearch(backend: missing)
        #expect(await missingService.prepare(language: "zz").state == .unavailable)
        #expect(await missing.vectorCount == 0)
        #expect(await missingService.search(query: "query", records: []).mode == .lexicalFallback)
        let invalid = SemanticBackendFixture(descriptor: .init(language: "en", revision: 1, dimension: 4_097))
        #expect(await SemanticKnowledgeSearch(backend: invalid).prepare(language: "en").state == .unavailable)
        #expect(await invalid.vectorCount == 0)
        let badProbe = SemanticBackendFixture(probe: [0, 0])
        #expect(await SemanticKnowledgeSearch(backend: badProbe).prepare(language: "en").state == .unavailable)
        #expect(await badProbe.vectorCount == 1)
        let malformed = SemanticBackendFixture()
        #expect(await SemanticKnowledgeSearch(backend: malformed).prepare(language: "https://example.com").state == .unavailable)
        #expect(await malformed.prepareCount == 0)
    }

    @Test func badQueryVectorsAndChunkVectorsFailClosedWithoutNonfiniteScores() async {
        let backend = SemanticBackendFixture()
        let service = SemanticKnowledgeSearch(backend: backend)
        _ = await service.prepare(language: "en")
        for vector in [[Double.nan, 1], [Double.infinity, 1], [0, 0], [1], [Double.greatestFiniteMagnitude, 1]] {
            await backend.setVector(vector, text: "bad query")
            let result = await service.search(query: "bad query", records: [source("Some source")])
            #expect(result.mode == .lexicalFallback)
            #expect(result.hits.isEmpty)
        }
        await backend.setVector([1, 0], text: "valid query")
        await backend.setVector([Double.nan, 0], text: "Invalid source vector")
        let invalid = await service.search(query: "valid query", records: [source("Invalid source vector")])
        #expect(invalid.mode == .lexicalFallback)
        #expect(invalid.coverage.partial)
        #expect(await service.cachedVectorCount == 0)
    }

    @Test func cacheInvalidationDuringSuspendedVectorPreventsStalePublication() async throws {
        let backend = SemanticBackendFixture()
        let service = SemanticKnowledgeSearch(backend: backend)
        _ = await service.prepare(language: "en")
        await backend.hold(text: "Held private source")
        let pending = Task { await service.search(query: "query", records: [source("Held private source")]) }
        for _ in 0..<300 {
            if await backend.isHolding { break }
            await Task.yield()
        }
        #expect(await backend.isHolding)
        await service.invalidateSourceCache()
        await backend.releaseHeld()
        let result = await pending.value
        #expect(result.mode == .cancelled)
        #expect(result.hits.isEmpty)
        #expect(await service.cachedVectorCount == 0)
        #expect(await service.preparedModel != nil) // Already held model can serve fresh authorized records.
        #expect(await backend.prepareCount == 1)
    }

    @Test func preparationClearedDuringProbeCannotPublishReadiness() async {
        let backend = SemanticBackendFixture()
        await backend.hold(text: SemanticKnowledgeSearch.preparationProbe)
        let service = SemanticKnowledgeSearch(backend: backend)
        let pending = Task { await service.prepare(language: "en") }
        for _ in 0..<300 {
            if await backend.isHolding { break }
            await Task.yield()
        }
        #expect(await backend.isHolding)
        await service.clear()
        await backend.releaseHeld()
        #expect(await pending.value.state == .cancelled)
        #expect(await service.preparedModel == nil)
    }

    @Test func sourcePassagesAndCacheStayBoundedAndCoverageIsExplicit() async {
        let backend = SemanticBackendFixture()
        let service = SemanticKnowledgeSearch(backend: backend)
        _ = await service.prepare(language: "en")
        let records = (0..<200).map { source(String(repeating: "A", count: 3_000), path: "/synthetic/\($0).txt", hash: "hash-\($0)") }
        let result = await service.search(query: "query", records: records)
        #expect(result.coverage.candidateChunks == 256)
        #expect(result.coverage.consideredSources == 200)
        #expect(result.coverage.partial)
        #expect(result.hits.count <= 10)
        #expect(result.hits.allSatisfy { $0.chunk.count <= 600 && $0.chunk.utf8.count <= 2_400 && $0.chunkIndex < 4 })
        #expect(await service.cachedVectorCount <= 256)
        // Later content hashes cannot accidentally reuse the old source vector.
        let changed = await service.search(query: "query", records: [source("Changed content", hash: "changed")])
        #expect(changed.coverage.cacheHits == 0)
        #expect(changed.hits.first?.sourceContentHash == "changed")
        #expect(await service.cachedVectorCount <= 256)
    }

    @Test func languageIdentifiersAreBoundedAndCanonicalWithoutInventingAssetSupport() async throws {
        #expect(try SemanticKnowledgeSearch.normalizedLanguage("EN") == "en")
        #expect(try SemanticKnowledgeSearch.normalizedLanguage("zh_hant") == "zh-Hant")
        #expect(try SemanticKnowledgeSearch.normalizedLanguage("pt-br") == "pt-BR")
        for invalid in ["", "../en", "en@secret", String(repeating: "x", count: 33)] {
            #expect(throws: (any Error).self) { try SemanticKnowledgeSearch.normalizedLanguage(invalid) }
        }
    }

    @Test func invalidAndEmptyQueriesDoNotRunTheHeldModel() async {
        let backend = SemanticBackendFixture()
        let service = SemanticKnowledgeSearch(backend: backend)
        _ = await service.prepare(language: "en")
        for query in ["", " \n", "nul\0value", String(repeating: "x", count: 257)] {
            #expect(await service.search(query: query, records: [source("Source")]).mode == .lexicalFallback)
        }
        #expect(await backend.vectorCount == 1)
    }
}

/// Synthetic vectors verify lifecycle/ranking mechanics, not Apple's semantic quality.
private actor SemanticBackendFixture: SemanticEmbeddingBackend {
    let descriptor: SemanticEmbeddingDescriptor?
    let probe: [Double]
    var prepareCount = 0
    var vectorCount = 0
    private var replacements: [String: [Double]] = [:]
    private var heldText: String?
    private var continuation: CheckedContinuation<Void, Never>?
    var isHolding: Bool { continuation != nil }
    init(descriptor: SemanticEmbeddingDescriptor? = .init(language: "en", revision: 1, dimension: 2), probe: [Double] = [1, 0]) {
        self.descriptor = descriptor; self.probe = probe
    }
    func prepare(language: String) -> SemanticEmbeddingDescriptor? { prepareCount += 1; return descriptor }
    func vector(for text: String) async -> [Double]? {
        vectorCount += 1
        if text == heldText { await withCheckedContinuation { continuation = $0 } }
        if text == SemanticKnowledgeSearch.preparationProbe { return probe }
        if let replacement = replacements[text] { return replacement }
        return text.contains("Bake") ? [0, 1] : [1, 0]
    }
    func clear() {}
    func setVector(_ value: [Double], text: String) { replacements[text] = value }
    func hold(text: String) { heldText = text }
    func releaseHeld() { heldText = nil; continuation?.resume(); continuation = nil }
}
