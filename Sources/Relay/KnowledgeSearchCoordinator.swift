import Foundation
import Observation

/// Main-actor scope boundary around an optional, explicitly prepared local ranker.
/// Indexing and keyword search never initialize language assets.
@Observable @MainActor
final class KnowledgeSearchCoordinator {
    enum State { case off, preparing, ready, unavailable }
    private(set) var state: State = .off
    var language = "en"
    private(set) var status = "Keyword search is ready. Meaning-based search is off."
    private(set) var coverage: String?
    private(set) var activeSearches = 0
    var isBusy: Bool { state == .preparing || activeSearches > 0 }
    var currentGrants: () -> [ScopeGrant] = { [] }
    private let knowledge: LocalKnowledge
    private let service: SemanticKnowledgeSearch
    @ObservationIgnored private var controlTask: Task<Void, Never>?
    @ObservationIgnored private var cacheTask: Task<Void, Never>?
    private var controlGeneration = 0
    private var sourceGeneration = 0
    private var knownSources: [String: String] = [:]

    init(knowledge: LocalKnowledge, service: SemanticKnowledgeSearch = SemanticKnowledgeSearch()) {
        self.knowledge = knowledge; self.service = service
    }

    /// Explicit setup only; source passages are never provided to the preparation probe.
    func prepare() {
        controlGeneration += 1; sourceGeneration += 1
        let expected = controlGeneration, requestedLanguage = language
        let previous = controlTask, invalidation = cacheTask
        previous?.cancel()
        state = .preparing; coverage = nil
        status = "Checking local language support… Keyword search is still available."
        controlTask = Task { [weak self] in
            await previous?.value; await invalidation?.value
            guard let self, !Task.isCancelled, self.controlGeneration == expected else { return }
            let result = await self.service.prepare(language: requestedLanguage)
            guard !Task.isCancelled, self.controlGeneration == expected else { return }
            switch result.state {
            case .ready:
                self.state = .ready
                let name = Locale.current.localizedString(forLanguageCode: result.model?.language ?? requestedLanguage) ?? requestedLanguage
                self.status = "Meaning-based search is ready for \(name). Keyword matches remain included."
            case .unavailable:
                self.state = .unavailable
                self.status = "Local meaning-based search could not be prepared for this language. Keyword search stays available."
            case .cancelled:
                self.state = .off; self.status = "Preparation stopped. Keyword search stays available."
            }
            self.controlTask = nil
        }
    }

    func turnOff() {
        controlGeneration += 1; sourceGeneration += 1
        let previous = controlTask, invalidation = cacheTask
        previous?.cancel()
        state = .off; coverage = nil; knownSources = [:]; status = "Meaning-based search is off. Keyword search stays available."
        let service = service
        controlTask = Task { await previous?.value; await invalidation?.value; await service.clear() }
    }

    /// Cancel searches without requiring a prepared public model to be loaded again.
    func stop() {
        if state == .preparing { turnOff() }
        else { invalidateSources() }
    }

    func invalidateSources() {
        sourceGeneration += 1; coverage = nil; knownSources = [:]
        guard state == .ready || activeSearches > 0 else { return }
        let previous = cacheTask, service = service
        cacheTask = Task { await previous?.value; await service.invalidateSourceCache() }
    }

    func search(query: String, constrainedTo callGrants: [ScopeGrant]? = nil) async throws -> [KnowledgeSearchResult] {
        try Task.checkCancellation()
        let grants = currentGrants()
        let constraint = callGrants ?? grants
        let lexical = knowledge.search(query: query, grants: grants).filter { (try? ToolPolicy.scopedURL($0.sourcePath, grants: constraint)) != nil }
        let sourceStamp = Dictionary(uniqueKeysWithValues: knowledge.records.map { ($0.sourcePath, $0.contentHash) })
        if sourceStamp != knownSources { invalidateSources(); knownSources = sourceStamp }
        let expected = sourceGeneration
        guard state == .ready, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return lexical }
        let records = knowledge.records.filter { (try? ToolPolicy.scopedURL($0.sourcePath, grants: constraint)) != nil }
        let invalidation = cacheTask
        activeSearches += 1
        defer { activeSearches -= 1 }
        await invalidation?.value
        try Task.checkCancellation()
        guard expected == sourceGeneration, state == .ready else { throw CancellationError() }
        let response = await service.search(query: query, records: records)
        try Task.checkCancellation()
        guard expected == sourceGeneration, state == .ready, response.mode != .cancelled else { throw CancellationError() }
        // The source may be changed/deleted/revoked during the actor hop. Rehash through
        // the index and obtain grants again before either excerpts or paths are returned.
        let currentLexical = knowledge.search(query: query, grants: currentGrants()).filter { (try? ToolPolicy.scopedURL($0.sourcePath, grants: constraint)) != nil }
        let current = Dictionary(uniqueKeysWithValues: knowledge.records.map { ($0.sourcePath, $0) })
        let currentStamp = current.mapValues(\.contentHash)
        guard currentStamp == sourceStamp else {
            invalidateSources(); knownSources = currentStamp
            throw RelayError.message("Selected sources changed while searching. Search again with the current sources; no old passages were returned.")
        }
        guard response.mode == .semantic else {
            coverage = "Keyword results were used for this query."
            return currentLexical
        }
        var seen = Set<String>(), combined: [KnowledgeSearchResult] = []
        let exact = query.trimmingCharacters(in: .whitespacesAndNewlines)
        for result in currentLexical where result.title.compare(exact, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame || result.sourcePath.compare(exact, options: [.caseInsensitive]) == .orderedSame || result.sourcePath.hasSuffix("/" + exact) {
            if seen.insert(result.sourcePath).inserted { combined.append(result) }
        }
        for hit in response.hits where hit.score > 0 {
            guard let record = current[hit.sourcePath], record.contentHash == hit.sourceContentHash,
                  (try? ToolPolicy.scopedURL(hit.sourcePath, grants: constraint)) != nil,
                  seen.insert(hit.sourcePath).inserted else { continue }
            combined.append(.init(sourcePath: hit.sourcePath, title: record.title, excerpt: hit.chunk,
                                  score: Int((hit.score * 1_000).rounded()), matchKind: "Meaning-based candidate",
                                  coverageNote: hit.coverageNote))
        }
        for result in currentLexical where seen.insert(result.sourcePath).inserted { combined.append(result) }
        coverage = "Meaning-based search considered \(response.coverage.consideredSources) sources and \(response.coverage.rankedChunks) passages. Keyword matches are also retained."
        if response.coverage.partial { coverage = (coverage ?? "") + " Passage limits applied; this search is not exhaustive." }
        return Array(combined.prefix(20))
    }

    func waitForPreparation() async { await controlTask?.value }
    isolated deinit { controlTask?.cancel(); cacheTask?.cancel() }
}
