import Foundation
import Observation
import CryptoKit
import PDFKit

nonisolated struct KnowledgeLimits: Sendable {
    var maxFiles = 200
    var maxFileBytes = 2_097_152
    var maxTotalBytes = 10_485_760
    var maxTextBytes = 65_536
    var maxScannedEntries = 2_000
    var maxPDFPages = 100
}

nonisolated struct KnowledgeRecord: Codable, Identifiable, Sendable, Equatable {
    var id: String { sourcePath }
    let sourcePath: String
    let title: String
    let text: String
    let modifiedAt: Date
    let contentHash: String
    let byteCount: Int
    var coverageNote: String? = nil
}

nonisolated struct KnowledgeSearchResult: Identifiable, Sendable {
    var id: String { sourcePath }
    let sourcePath: String
    let title: String
    let excerpt: String
    let score: Int
    var matchKind = "Keyword match"
    var coverageNote: String? = nil
}

/// Explicit, local source excerpts. This index is separate from approved preference memory.
/// No watcher, implicit home-directory scan, model call, embedding service or network is used.
@Observable @MainActor
final class LocalKnowledge {
    private(set) var records: [KnowledgeRecord] = [] {
        didSet { if records != oldValue { onRecordsChanged?(records) } }
    }
    @ObservationIgnored var onRecordsChanged: (([KnowledgeRecord]) -> Void)?
    @ObservationIgnored var onExplicitForget: ((String?) -> Void)?
    private(set) var status = "No sources indexed. Choose files or folders, then index explicitly."
    private(set) var isIndexing = false
    @ObservationIgnored private let persistenceURL: URL?
    @ObservationIgnored private let limits: KnowledgeLimits
    @ObservationIgnored private var generation = 0

    static var defaultPersistenceURL: URL {
        URL.applicationSupportDirectory.appending(path: "Relay", directoryHint: .isDirectory).appending(path: "knowledge.json")
    }

    init(persistenceURL: URL? = LocalKnowledge.defaultPersistenceURL, limits: KnowledgeLimits = .init()) {
        self.persistenceURL = persistenceURL
        // Callers may lower limits for a small scope/test, never raise the hard safety caps.
        var bounded = limits
        bounded.maxFiles = max(0, min(limits.maxFiles, 200))
        bounded.maxFileBytes = max(0, min(limits.maxFileBytes, 2_097_152))
        bounded.maxTotalBytes = max(0, min(limits.maxTotalBytes, 10_485_760))
        bounded.maxTextBytes = max(0, min(limits.maxTextBytes, 65_536))
        bounded.maxScannedEntries = max(0, min(limits.maxScannedEntries, 2_000))
        bounded.maxPDFPages = max(0, min(limits.maxPDFPages, 100))
        self.limits = bounded
        restore()
    }

    func cancel() {
        generation += 1
        isIndexing = false
        status = "Indexing canceled. Previously indexed sources are unchanged."
    }

    /// Atomically replaces the index only after a bounded, explicit scan completes.
    /// A canceled scan never publishes its partial work.
    func index(grants: [ScopeGrant]) async {
        _ = await scan(grants: grants, refreshing: false)
    }

    /// Refreshes the explicitly selected roots and keeps records outside those roots.
    func refresh(grants: [ScopeGrant]) async throws {
        guard !isIndexing else { throw RelayError.message("Wait for local indexing to finish before refreshing sources.") }
        guard await scan(grants: grants, refreshing: true) else {
            try Task.checkCancellation()
            throw RelayError.message(status)
        }
    }

    private func scan(grants: [ScopeGrant], refreshing: Bool) async -> Bool {
        guard !isIndexing, !Task.isCancelled else { return false }
        let roots = grants.compactMap { grant -> URL? in
            guard let url = try? ToolPolicy.scopedURL(grant.path, grants: grants), Self.allowedSource(url),
                  !refreshing || (Self.refreshPathMatches(grant.path, url: url) && Self.isLocalRefreshSource(url)) else { return nil }
            return url
        }.sorted { $0.path < $1.path }
        if refreshing, roots.isEmpty {
            status = "None of the selected refresh sources is available at its approved path."
            return false
        }
        let explicitlySelected = Set(roots)
        generation += 1
        let run = generation
        isIndexing = true
        status = "Indexing selected sources on this Mac…"
        let manager = FileManager.default
        let preserved = refreshing ? records.filter { record in
            !roots.contains { root in record.sourcePath == root.path || record.sourcePath.hasPrefix(root.path + "/") }
        } : []
        var next = preserved
        var seen = Set(next.map(\.sourcePath))
        var scanned = 0
        var totalBytes = next.reduce(0) { $0 + $1.byteCount }
        var skipped = refreshing ? grants.count - roots.count : 0
        var capped = false
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey]
        for root in roots {
            guard run == generation, !Task.isCancelled else { finishCancellation(run); return false }
            let isDirectory = (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            let enumerator = isDirectory ? manager.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) : nil
            var single: URL? = isDirectory ? nil : root
            while let candidate = single ?? (enumerator?.nextObject() as? URL) {
                single = nil
                await Task.yield()
                guard run == generation, !Task.isCancelled else { finishCancellation(run); return false }
                scanned += 1
                guard scanned <= limits.maxScannedEntries, next.count < limits.maxFiles else { capped = true; break }
                let inspected = try? candidate.resourceValues(forKeys: Set(keys))
                guard Self.allowedSource(candidate), let values = inspected,
                      values.isSymbolicLink != true, values.isPackage != true,
                      let url = try? ToolPolicy.scopedURL(candidate.path, grants: grants),
                      !refreshing || (Self.refreshPathMatches(candidate.path, url: url) && Self.isLocalRefreshSource(url)) else {
                    // Foundation may apply skipDescendants to the following real folder if
                    // called on a symlink/file leaf. Prune only an actual rejected directory.
                    if inspected?.isDirectory == true, inspected?.isSymbolicLink != true { enumerator?.skipDescendants() }
                    skipped += 1; continue
                }
                if values.isDirectory == true { continue }
                guard values.isRegularFile == true, Self.supportedExtensions.contains(url.pathExtension.lowercased()), seen.insert(url.path).inserted else { skipped += 1; continue }
                let size = values.fileSize ?? Int.max
                guard size >= 0, size <= limits.maxFileBytes, size <= limits.maxTotalBytes - totalBytes else { skipped += 1; capped = true; continue }
                guard let data = Self.boundedData(url, maximum: limits.maxFileBytes), data.count == size,
                      data.count <= limits.maxTotalBytes - totalBytes,
                      let extracted = extract(data, source: url, explicitlySelected: explicitlySelected.contains(url)), !extracted.text.isEmpty,
                      let currentURL = try? ToolPolicy.scopedURL(candidate.path, grants: grants), currentURL == url,
                      let after = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                      after.contentModificationDate == values.contentModificationDate, after.fileSize == size else { skipped += 1; continue }
                totalBytes += data.count
                next.append(KnowledgeRecord(sourcePath: url.path, title: url.lastPathComponent, text: extracted.text,
                                            modifiedAt: values.contentModificationDate ?? .distantPast,
                                            contentHash: Self.hash(data), byteCount: data.count, coverageNote: extracted.coverageNote))
            }
            if capped && (scanned > limits.maxScannedEntries || next.count >= limits.maxFiles) { break }
        }
        guard run == generation, !Task.isCancelled else { finishCancellation(run); return false }
        // Searches can discard a stale record during a yielded refresh. Keep that
        // decision rather than restoring an unrelated snapshot from before the scan.
        let kept = Set(preserved.map(\.sourcePath))
        let current = Set(records.map(\.sourcePath))
        let sorted = next.filter { !kept.contains($0.sourcePath) || current.contains($0.sourcePath) }
            .sorted { $0.sourcePath < $1.sourcePath }
        isIndexing = false
        if refreshing, !persist(records: sorted) { return false }
        records = sorted
        let count = records.count
        let withCoverage = records.count { $0.coverageNote != nil }
        status = "Indexed \(count) \(count == 1 ? "source" : "sources") locally. \(skipped) skipped."
        if withCoverage > 0 {
            status += withCoverage == 1 ? " 1 source has a coverage note." : " \(withCoverage) sources have coverage notes."
        }
        if capped { status += " Scan limits reached. Select a smaller scope for complete coverage." }
        return refreshing || persist()
    }

    /// Revalidates scope and file content before returning source text. Changed, deleted or
    /// revoked records are forgotten, never returned as current knowledge or silently reindexed.
    func search(query: String, grants: [ScopeGrant]) -> [KnowledgeSearchResult] {
        purgeStale(grants: grants)
        guard query.utf8.count <= 256 else { status = "Search needs a query up to 256 UTF-8 bytes."; return [] }
        let tokens = Self.tokens(query)
        guard !tokens.isEmpty else { return [] }
        return records.compactMap { record in
            let text = record.text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            let title = record.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            let matches = tokens.filter { text.contains($0) || title.contains($0) }
            guard !matches.isEmpty else { return nil }
            let score = matches.reduce(0) { $0 + (title.contains($1) ? 5 : 0) + (text.contains($1) ? 1 : 0) }
            return KnowledgeSearchResult(sourcePath: record.sourcePath, title: record.title,
                                         excerpt: Self.excerpt(record.text, tokens: tokens) + (record.coverageNote.map { "\n[Coverage: " + $0 + "]" } ?? ""), score: score)
        }.sorted { $0.score == $1.score ? $0.sourcePath < $1.sourcePath : $0.score > $1.score }.prefix(10).map { $0 }
    }

    func removeSource(path: String) {
        cancelActiveScan()
        guard let url = try? ToolPolicy.canonicalURL(path) else { return }
        onExplicitForget?(url.path)
        records.removeAll { $0.sourcePath == url.path || $0.sourcePath.hasPrefix(url.path + "/") }
        status = "Source forgotten from the local index. Original files are unchanged."
        persist()
    }

    func clear() {
        cancelActiveScan()
        onExplicitForget?(nil)
        records.removeAll()
        status = "Local index cleared. Original files and approved memory are unchanged."
        persist()
    }

    /// Call on grant changes as well as search; this only removes records, never adds sources.
    func purgeStale(grants: [ScopeGrant]) {
        let before = records.count
        records.removeAll { !isFresh($0, grants: grants) }
        if records.count != before {
            status = "Forgot \(before - records.count) changed, deleted or no-longer-authorized sources. Reindex explicitly to refresh."
            persist()
        }
    }

    /// Check only the in-flight source before and after model work. If the source changed,
    /// remove its obsolete record without re-reading the whole index on every generation step.
    func revalidate(_ record: KnowledgeRecord, grants: [ScopeGrant]) -> Bool {
        guard let index = records.firstIndex(where: { $0.sourcePath == record.sourcePath }),
              records[index] == record else { return false }
        guard isFresh(record, grants: grants) else {
            records.remove(at: index)
            status = "Forgot a changed, deleted or no-longer-authorized source. Reindex explicitly to refresh."
            persist()
            return false
        }
        return true
    }

    private func isFresh(_ record: KnowledgeRecord, grants: [ScopeGrant]) -> Bool {
        guard Self.allowedSource(URL(fileURLWithPath: record.sourcePath)),
              let url = try? ToolPolicy.scopedURL(record.sourcePath, grants: grants), url.path == record.sourcePath,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
              values.isRegularFile == true, values.fileSize == record.byteCount,
              values.contentModificationDate == record.modifiedAt,
              let data = Self.boundedData(url, maximum: limits.maxFileBytes) else { return false }
        return Self.hash(data) == record.contentHash
    }

    /// Returns Markdown for a user-chosen local destination; never writes or transmits it itself.
    func exportMarkdown() -> String {
        "# Relay local source index\n\nLexical source excerpts; not approved preference memory. Content reflects the last authorized indexing operation.\n\n" + records.map {
            "## \($0.title)\n\nSource: \($0.sourcePath)\n\nModified: \($0.modifiedAt.ISO8601Format())\n\nCoverage: \($0.coverageNote ?? "Complete extracted text within the declared index limits")\n\n\($0.text)\n"
        }.joined(separator: "\n")
    }

    private static let supportedExtensions: Set<String> = ["txt", "md", "csv", "json", "pdf", "eml"]
    private static func allowedSource(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let blocked = ["/", "/Users", NSHomeDirectory(), "/System", "/Library", NSHomeDirectory() + "/Library"]
        if blocked.contains(path) { return false }
        if path.hasPrefix("/System/") || path.hasPrefix("/Library/") || path.hasPrefix(NSHomeDirectory() + "/Library/") { return false }
        return !url.pathComponents.dropFirst().contains(where: { $0.hasPrefix(".") })
    }
    private static func isLocalRefreshSource(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.volumeIsLocalKey, .isUbiquitousItemKey]) else { return false }
        return values.volumeIsLocal == true && values.isUbiquitousItem != true
    }
    static func refreshPathMatches(_ selectedPath: String, url: URL) -> Bool {
        // Foundation presents built-in macOS aliases such as /private/var as /var.
        // Compare the resolved URL with both representations, without resolving the
        // selected path anew on this side of the comparison.
        url.path == selectedPath || url.resolvingSymlinksInPath().standardizedFileURL.path == selectedPath
    }
    private static func boundedData(_ url: URL, maximum: Int) -> Data? {
        guard maximum > 0 else { return nil }
        return try? LocalStateFile.read(url, maximumBytes: maximum)
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func tokens(_ text: String) -> [String] {
        Array(Set(text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))).sorted()
    }
    private static func excerpt(_ text: String, tokens: [String]) -> String {
        let start = tokens.compactMap { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive])?.lowerBound }.min() ?? text.startIndex
        let lower = text.index(start, offsetBy: -100, limitedBy: text.startIndex) ?? text.startIndex
        let upper = text.index(lower, offsetBy: 500, limitedBy: text.endIndex) ?? text.endIndex
        return (lower > text.startIndex ? "…" : "") + String(text[lower..<upper]) + (upper < text.endIndex ? "…" : "")
    }
    private func extract(_ data: Data, source: URL, explicitlySelected: Bool) -> (text: String, coverageNote: String?)? {
        let raw: String
        var notes: [String] = []
        let ext = source.pathExtension.lowercased()
        if ext == "eml" {
            guard let mail = try? MailExportReader.parse(data) else { return nil }
            raw = mail.sourceText
            if let coverage = mail.coverageNote { notes.append(coverage) }
        } else if ext == "pdf" {
            guard let document = PDFDocument(data: data), !document.isLocked else { return nil }
            var pages: [String] = []
            var pagesRead = 0
            for index in 0..<min(document.pageCount, limits.maxPDFPages) {
                pagesRead = index + 1
                if let text = document.page(at: index)?.string { pages.append(text) }
                if pages.reduce(0, { $0 + $1.utf8.count }) >= limits.maxTextBytes { break }
            }
            raw = pages.joined(separator: "\n")
            notes.append("PDF text layers only; image content and scanned pages were not OCR-indexed.")
            if pagesRead < document.pageCount { notes.append("Only the first \(pagesRead) of \(document.pageCount) PDF pages were extracted; remaining pages were not indexed.") }
        } else {
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            if ext == "txt", explicitlySelected,
               let transcript = WhatsAppExportReader.excerpt(text: text, fileName: source.lastPathComponent, maximumBytes: limits.maxTextBytes) {
                return (transcript.text, transcript.coverage)
            }
            raw = text
        }
        guard limits.maxTextBytes > 0 else { return nil }
        if raw.utf8.count > limits.maxTextBytes { notes.append("Text is truncated at \(limits.maxTextBytes) UTF-8 bytes; omitted text is not searchable.") }
        let bytes = raw.utf8.prefix(limits.maxTextBytes)
        // Decoding replacement at a truncated scalar would alter the source; back off to UTF-8.
        var bounded = Data(bytes)
        while !bounded.isEmpty {
            if let text = String(data: bounded, encoding: .utf8) { return (text, notes.isEmpty ? nil : notes.joined(separator: " ")) }
            bounded.removeLast()
        }
        return nil
    }
    private func cancelActiveScan() { generation += 1; isIndexing = false }
    private func finishCancellation(_ run: Int) {
        if run == generation { isIndexing = false; status = "Indexing canceled. Previously indexed sources are unchanged." }
    }
    private struct SavedIndex: Codable { let version: Int; let records: [KnowledgeRecord] }
    @discardableResult private func persist(records snapshot: [KnowledgeRecord]? = nil) -> Bool {
        guard let persistenceURL else { return true }
        do {
            let data = try JSONEncoder().encode(SavedIndex(version: 2, records: snapshot ?? records))
            guard data.count <= 20_971_520 else { throw RelayError.message("The encoded index exceeded its storage limit. The previous saved index was preserved.") }
            try FileManager.default.createDirectory(at: persistenceURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try LocalPrivateFileWriter.write(data: data, to: persistenceURL, maximumBytes: 20_971_520)
            return true
        } catch { status = "Could not save the local index: \(error.localizedDescription)"; return false }
    }
    private func restore() {
        guard let persistenceURL, FileManager.default.fileExists(atPath: persistenceURL.path) else { return }
        guard let data = Self.boundedData(persistenceURL, maximum: 20_971_520),
              let saved = try? JSONDecoder().decode(SavedIndex.self, from: data), [1, 2].contains(saved.version),
              saved.records.count <= limits.maxFiles,
              Set(saved.records.map(\.sourcePath)).count == saved.records.count,
              saved.records.allSatisfy({ $0.sourcePath.hasPrefix("/") && Self.supportedExtensions.contains(URL(fileURLWithPath: $0.sourcePath).pathExtension.lowercased()) && Self.allowedSource(URL(fileURLWithPath: $0.sourcePath)) && $0.text.utf8.count <= limits.maxTextBytes && $0.byteCount >= 0 && $0.byteCount <= limits.maxFileBytes }),
              saved.records.reduce(0, { $0 + $1.byteCount }) <= limits.maxTotalBytes else {
            status = "Local index could not be read safely. No sources loaded; index explicitly to rebuild."; return
        }
        records = saved.records.map { value in
            var record = value
            if saved.version == 1 { record.coverageNote = "Coverage was not recorded by the previous version. Reindex to establish it." }
            return record
        }
        status = "Loaded \(records.count) local sources. Search rechecks their scope and freshness."
    }
}
