import Foundation
import CryptoKit
@preconcurrency import NaturalLanguage

nonisolated struct SemanticEmbeddingDescriptor: Sendable, Equatable {
    let language: String
    let revision: Int
    let dimension: Int
}

/// Implementations must load models only in prepare(), never in vector(). Actor isolation
/// serializes access: Apple documents that one NLEmbedding is unsafe for concurrent queries.
protocol SemanticEmbeddingBackend: Actor {
    func prepare(language: String) async throws -> SemanticEmbeddingDescriptor?
    func vector(for text: String) async throws -> [Double]?
    func clear() async
}

nonisolated struct SemanticPreparationResult: Sendable {
    enum State: Sendable { case ready, unavailable, cancelled }
    let state: State
    let model: SemanticEmbeddingDescriptor?
    let status: String
}
nonisolated struct SemanticKnowledgeHit: Sendable {
    let sourcePath: String
    let sourceContentHash: String
    let chunk: String
    let chunkIndex: Int
    let score: Double
    let coverageNote: String?
}
nonisolated struct SemanticSearchCoverage: Sendable {
    let suppliedSources: Int
    let consideredSources: Int
    let candidateChunks: Int
    let rankedChunks: Int
    let cacheHits: Int
    let partial: Bool
    let note: String
}
nonisolated struct SemanticSearchResponse: Sendable {
    enum Mode: Sendable { case semantic, lexicalFallback, cancelled }
    let mode: Mode
    let model: SemanticEmbeddingDescriptor?
    let hits: [SemanticKnowledgeHit]
    let coverage: SemanticSearchCoverage
    let status: String
}

/// Off until explicit preparation succeeds. No initializer or query calls an embedding
/// factory, asset API, permission API, network API or filesystem reader. All vectors remain
/// in memory. The caller owns scope/freshness checks before AND after asynchronous ranking.
actor SemanticKnowledgeSearch {
    static let maximumChunks = 256
    static let maximumChunksPerSource = 4
    static let maximumChunkCharacters = 600
    static let maximumChunkBytes = 2_400
    static let maximumSources = 200
    static let maximumDimension = 4_096
    static let preparationProbe = "A short local semantic search preparation check."

    private let backend: any SemanticEmbeddingBackend
    private var model: SemanticEmbeddingDescriptor?
    private var generation = 0
    private var vectors: [String: [Double]] = [:]
    private var vectorOrder: [String] = []
    var preparedModel: SemanticEmbeddingDescriptor? { model }
    var cachedVectorCount: Int { vectors.count }

    init(backend: (any SemanticEmbeddingBackend)? = nil) {
        self.backend = backend ?? NativeSentenceEmbeddingBackend()
    }

    /// This is the only operation allowed to initialize the OS embedding factory. It is an
    /// explicit UI preparation, not an automatic asset request; strict air-gap behavior of
    /// OS-managed assets still requires separate runtime qualification.
    func prepare(language: String) async -> SemanticPreparationResult {
        generation += 1
        let expected = generation
        model = nil
        clearVectors()
        await backend.clear()
        do {
            try gate(expected)
            let language = try Self.normalizedLanguage(language)
            guard let candidate = try await backend.prepare(language: language) else {
                return try await unavailable(expected, "No native sentence embedding is available for this language. Lexical search remains available; no hosted fallback is used.")
            }
            try gate(expected)
            guard (1...Self.maximumDimension).contains(candidate.dimension), candidate.revision >= 0,
                  (try? Self.normalizedLanguage(candidate.language)) == language else {
                return try await unavailable(expected, "The native model metadata did not match the requested language or bounded dimensions. Use lexical search.")
            }
            let probe = try await backend.vector(for: Self.preparationProbe)
            try gate(expected)
            guard Self.unitVector(probe, dimension: candidate.dimension) != nil else {
                return try await unavailable(expected, "The native model did not pass its synthetic vector check. Use lexical search.")
            }
            model = candidate
            return .init(state: .ready, model: candidate, status: "Native sentence ranking prepared for \(candidate.language), revision \(candidate.revision). Quality and strict offline behavior are not certified by this probe.")
        } catch {
            if generation == expected {
                model = nil
                clearVectors()
                await backend.clear()
            }
            let cancelled = Task.isCancelled || generation != expected || error is CancellationError
            return .init(state: cancelled ? .cancelled : .unavailable, model: nil,
                         status: cancelled ? "Semantic preparation canceled. Lexical search remains available." : "Semantic preparation failed. Lexical search remains available; no hosted fallback is used.")
        }
    }

    /// Clears user-derived vectors and invalidates in-flight searches without reloading an
    /// already prepared model. Call on source revocation/change before publishing new results.
    func invalidateSourceCache() {
        generation += 1
        clearVectors()
    }

    /// Turns semantic ranking off and releases the held model. A later query cannot reload it.
    func clear() async {
        generation += 1
        model = nil
        clearVectors()
        await backend.clear()
    }

    func search(query: String, records: [KnowledgeRecord]) async -> SemanticSearchResponse {
        let expected = generation
        guard let held = model else {
            return response(.lexicalFallback, model: nil, supplied: records.count, status: "Semantic ranking is not prepared. Using explicit lexical fallback.")
        }
        guard query.utf8.count <= 256, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !query.contains("\0") else {
            return response(.lexicalFallback, model: held, supplied: records.count, status: "Semantic queries need 1–256 UTF-8 bytes without NUL. Use a shorter lexical query.")
        }
        do {
            try gate(expected)
            let batch = Self.makeChunks(records)
            guard !batch.chunks.isEmpty else {
                return response(.lexicalFallback, model: held, supplied: records.count, considered: batch.considered, partial: batch.partial,
                                status: "No bounded current source passages were supplied. Lexical search remains available.")
            }
            let queryVector = try await backend.vector(for: query)
            try gate(expected)
            guard let queryUnit = Self.unitVector(queryVector, dimension: held.dimension) else {
                return response(.lexicalFallback, model: held, supplied: records.count, considered: batch.considered, partial: true,
                                status: "The held local model could not represent this query. Using lexical fallback.")
            }
            var hits: [SemanticKnowledgeHit] = []
            var cacheHits = 0
            var failures = 0
            for chunk in batch.chunks {
                try gate(expected)
                let key = Self.cacheKey(chunk, model: held)
                let unit: [Double]
                if let cached = vectors[key] { unit = cached; cacheHits += 1 }
                else {
                    let vector = try await backend.vector(for: chunk.text)
                    try gate(expected)
                    guard let validated = Self.unitVector(vector, dimension: held.dimension) else { failures += 1; continue }
                    unit = validated
                    cache(unit, key: key)
                }
                let score = zip(queryUnit, unit).reduce(0.0) { $0 + $1.0 * $1.1 }
                guard score.isFinite else { failures += 1; continue }
                hits.append(.init(sourcePath: chunk.path, sourceContentHash: chunk.hash, chunk: chunk.text,
                                  chunkIndex: chunk.index, score: min(1, max(-1, score)), coverageNote: chunk.coverageNote))
            }
            try gate(expected)
            let ranked = hits.count
            hits.sort { first, second in
                if first.score != second.score { return first.score > second.score }
                if first.sourcePath != second.sourcePath { return first.sourcePath < second.sourcePath }
                return first.chunkIndex < second.chunkIndex
            }
            var paths = Set<String>()
            let unique = hits.filter { paths.insert($0.sourcePath).inserted }.prefix(10)
            let partial = batch.partial || failures > 0
            return .init(mode: ranked == 0 ? .lexicalFallback : .semantic, model: held, hits: Array(unique),
                         coverage: .init(suppliedSources: records.count, consideredSources: batch.considered, candidateChunks: batch.chunks.count,
                                         rankedChunks: ranked, cacheHits: cacheHits, partial: partial,
                                         note: Self.coverageNote(partial: partial)),
                         status: ranked == 0 ? "No valid local passage vectors were produced. Using lexical fallback." : "Ranked local source passages. Cosine scores describe ordering, not confidence or task completion; merge with lexical results.")
        } catch {
            if Task.isCancelled || expected != generation || error is CancellationError {
                return response(.cancelled, model: nil, supplied: records.count, status: "Semantic ranking canceled or invalidated. No stale results were published.")
            }
            return response(.lexicalFallback, model: held, supplied: records.count, partial: true,
                            status: "The held local model could not finish ranking. Using lexical fallback; no hosted model was called.")
        }
    }

    private func unavailable(_ expected: Int, _ message: String) async throws -> SemanticPreparationResult {
        try gate(expected)
        model = nil
        await backend.clear()
        try gate(expected)
        return .init(state: .unavailable, model: nil, status: message)
    }
    private func gate(_ expected: Int) throws {
        try Task.checkCancellation()
        guard expected == generation else { throw CancellationError() }
    }
    private func clearVectors() { vectors.removeAll(); vectorOrder.removeAll() }
    private func cache(_ vector: [Double], key: String) {
        if vectors[key] == nil {
            if vectorOrder.count >= Self.maximumChunks, let oldest = vectorOrder.first {
                vectors.removeValue(forKey: oldest); vectorOrder.removeFirst()
            }
            vectorOrder.append(key)
        }
        vectors[key] = vector
    }
    private func response(_ mode: SemanticSearchResponse.Mode, model: SemanticEmbeddingDescriptor?, supplied: Int,
                          considered: Int = 0, partial: Bool = false, status: String) -> SemanticSearchResponse {
        .init(mode: mode, model: model, hits: [],
              coverage: .init(suppliedSources: supplied, consideredSources: considered, candidateChunks: 0, rankedChunks: 0, cacheHits: 0,
                              partial: partial, note: Self.coverageNote(partial: partial)), status: status)
    }
    private static func coverageNote(partial: Bool) -> String {
        "Only supplied source text is considered; at most 200 sources, 256 passages, four passages per source, 600 characters/2,400 UTF-8 bytes per passage." +
            (partial ? " Coverage is partial; lexical search should retain the rest of the authorized index." : "")
    }

    private struct Chunk {
        let path: String
        let hash: String
        let index: Int
        let text: String
        let coverageNote: String?
    }
    private struct Batch { let chunks: [Chunk]; let considered: Int; let partial: Bool }
    private static func makeChunks(_ records: [KnowledgeRecord]) -> Batch {
        var groups: [[Chunk]] = []
        var paths = Set<String>()
        var partial = records.count > maximumSources
        for record in records.prefix(maximumSources) {
            guard record.sourcePath.hasPrefix("/"), record.sourcePath.utf8.count <= 4_096, !record.sourcePath.contains("\0"),
                  record.sourcePath.split(separator: "/", omittingEmptySubsequences: false).dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  !record.evidenceFingerprint.isEmpty, record.evidenceFingerprint.utf8.count <= 128, !record.evidenceFingerprint.contains("\0"),
                  record.text.utf8.count <= 65_536, paths.insert(record.sourcePath).inserted else { partial = true; continue }
            var cursor = record.text.startIndex
            var chunks: [Chunk] = []
            var segment = 0
            while cursor < record.text.endIndex, segment < maximumChunksPerSource {
                var end = cursor
                var bytes = 0
                var characters = 0
                while end < record.text.endIndex, characters < maximumChunkCharacters {
                    let next = record.text.index(after: end)
                    let size = record.text[end..<next].utf8.count
                    guard size <= maximumChunkBytes - bytes else { break }
                    bytes += size; characters += 1; end = next
                }
                if end == cursor { cursor = record.text.index(after: cursor); partial = true; segment += 1; continue }
                let text = String(record.text[cursor..<end])
                if text.contains("\0") { partial = true }
                else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    chunks.append(Chunk(path: record.sourcePath, hash: record.evidenceFingerprint, index: segment, text: text, coverageNote: record.coverageNote))
                }
                cursor = end; segment += 1
            }
            if cursor < record.text.endIndex { partial = true }
            groups.append(chunks)
        }
        // Fair first pass across sources, then additional passages; do not let the first
        // long files consume all 256 slots before later authorized sources are considered.
        var selected: [Chunk] = []
        for passage in 0..<maximumChunksPerSource {
            for group in groups where passage < group.count {
                guard selected.count < maximumChunks else { return Batch(chunks: selected, considered: groups.count, partial: true) }
                selected.append(group[passage])
            }
        }
        return Batch(chunks: selected, considered: groups.count, partial: partial)
    }
    private static func unitVector(_ value: [Double]?, dimension: Int) -> [Double]? {
        guard let value, value.count == dimension, value.allSatisfy(\.isFinite) else { return nil }
        let normSquared = value.reduce(0.0) { $0 + $1 * $1 }
        guard normSquared.isFinite, normSquared > 1e-24 else { return nil }
        let norm = sqrt(normSquared)
        return value.map { $0 / norm }
    }
    private static func cacheKey(_ chunk: Chunk, model: SemanticEmbeddingDescriptor) -> String {
        let text = "sentence-v1\0\(model.language)\0\(model.revision)\0\(model.dimension)\0\(chunk.path)\0\(chunk.hash)\0\(chunk.index)\0\(chunk.text)"
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func normalizedLanguage(_ language: String) throws -> String {
        guard language.utf8.count <= 32 else { throw RelayError.message("The language identifier is too long. No model was prepared.") }
        let components = language.replacingOccurrences(of: "_", with: "-").split(separator: "-", omittingEmptySubsequences: false)
        guard language.utf8.count <= 32, (1...3).contains(components.count), let first = components.first,
              (2...8).contains(first.count), first.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }),
              components.allSatisfy({ (1...8).contains($0.count) && $0.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) }) }) else {
            throw RelayError.message("Choose an explicit Natural Language language identifier. No model was prepared.")
        }
        return components.enumerated().map { index, component in
            let value = String(component)
            if index == 0 { return value.lowercased() }
            if value.count == 4, value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }) {
                return value.prefix(1).uppercased() + value.dropFirst().lowercased()
            }
            if value.count == 2 { return value.uppercased() }
            return value.lowercased()
        }.joined(separator: "-")
    }
}

/// No asset availability probe or factory is executed by init, vector or clear. Only the
/// user-triggered prepare method below may ask the OS for an existing sentence model.
private actor NativeSentenceEmbeddingBackend: SemanticEmbeddingBackend {
    private var embedding: NLEmbedding?
    func prepare(language: String) -> SemanticEmbeddingDescriptor? {
        embedding = nil
        guard let candidate = NLEmbedding.sentenceEmbedding(for: NLLanguage(rawValue: language)),
              let actualLanguage = candidate.language?.rawValue else { return nil }
        embedding = candidate
        return .init(language: actualLanguage, revision: candidate.revision, dimension: candidate.dimension)
    }
    func vector(for text: String) -> [Double]? { embedding?.vector(for: text) }
    func clear() { embedding = nil }
}
