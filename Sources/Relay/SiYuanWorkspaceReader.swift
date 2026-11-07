import CryptoKit
import Darwin
import Foundation

/// An explicitly selected workspace only. Never reads the user's workspace registry,
/// installed apps, sync history, encryption keys, plugins or asset bodies.
@MainActor enum SiYuanWorkspaceReader {
    struct Limits {
        var maximumNotes = 1_000
        var maximumEntries = 10_000
        var maximumSourceBytes = 33_554_432
        var maximumTextBytes = 16_777_216
        var maximumNoteBytes = 65_536
        var maximumSeconds: TimeInterval = 30
    }
    struct Snapshot {
        let records: [KnowledgeRecord]
        let coverage: String
        let sourceBytes: Int
        let entries: Int
    }
    enum Failure: Error, LocalizedError {
        case invalidWorkspace, scope, limit
        var errorDescription: String? {
            switch self {
            case .invalidWorkspace: "The selected SiYuan workspace could not be validated. No generic folder fallback was used."
            case .scope: "The SiYuan workspace or one of its dependencies left the selected scope."
            case .limit: "The SiYuan workspace reached its bounded read budget. Choose a smaller workspace."
            }
        }
    }
    static let maximumNotes = 1_000
    static let maximumSourceBytes = 33_554_432
    static let maximumTextBytes = 16_777_216
    // Known bundled notebook identifiers, not a scan of an installed app.
    static let guideIDs: Set<String> = ["20210808180117-6v0mkxr", "20210808180117-czj9bvb", "20211226090932-5lcq56f", "20240530133126-axarxgx"]

    /// Structural recognition also catches a damaged config so a workspace cannot
    /// silently fall back to generic recursive .sy/JSON indexing.
    static func recognizes(_ root: URL) -> Bool {
        let fm = FileManager.default
        let data = root.appendingPathComponent("data")
        guard fm.fileExists(atPath: data.path) else { return false }
        var info = stat()
        if root.appendingPathComponent("conf/conf.json").path.withCString({ lstat($0, &info) }) == 0 { return true }
        // A damaged/missing workspace config cannot expose notebook bodies via
        // generic fallback. Ordinary projects with conf/ and data/ still work.
        guard let entries = fm.enumerator(at: data, includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles, .skipsPackageDescendants]) else { return false }
        var inspected = 0
        while let entry = entries.nextObject() as? URL {
            inspected += 1
            if inspected > 10_000 { return true } // Too large to establish a generic folder safely.
            if SiYuanJSON.validID(entry.lastPathComponent),
               entry.appendingPathComponent(".siyuan/conf.json").path.withCString({ lstat($0, &info) }) == 0 { return true }
        }
        return false
    }

    static func snapshot(root selected: URL, grants: [ScopeGrant], limits requested: Limits = .init(),
                         isCurrent: @escaping @MainActor () -> Bool = { true }) async throws -> Snapshot {
        let root = try ToolPolicy.canonicalURL(selected.path)
        guard grants.contains(where: { (try? ToolPolicy.canonicalURL($0.path)) == root }), recognizes(root) else { throw Failure.scope }
        var limits = requested
        limits.maximumNotes = max(0, min(requested.maximumNotes, maximumNotes))
        limits.maximumEntries = max(0, min(requested.maximumEntries, 10_000))
        limits.maximumSourceBytes = max(0, min(requested.maximumSourceBytes, maximumSourceBytes))
        limits.maximumTextBytes = max(0, min(requested.maximumTextBytes, maximumTextBytes))
        limits.maximumNoteBytes = max(0, min(requested.maximumNoteBytes, 65_536))
        limits.maximumSeconds = requested.maximumSeconds.isFinite ? max(0, min(requested.maximumSeconds, 30)) : 30
        var worker = Worker(root: root, grants: grants, limits: limits, isCurrent: isCurrent)
        return try await worker.run()
    }

    static func identity(root: String, documentID: String) -> String {
        "siyuan:" + digest(Data(root.utf8)) + ":" + documentID
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// Restore-time metadata checks never open dependency files.
    static func validMetadata(_ record: KnowledgeRecord) -> Bool {
        guard let root = record.workspaceRoot, root.hasPrefix("/"), root.utf8.count <= 4096,
              let identity = record.sourceIdentity, let deps = record.sourceDependencies, (2...32).contains(deps.count),
              Set(deps.map(\.path)).count == deps.count, record.sourcePath.hasPrefix(root + "/data/"),
              record.sourcePath.hasSuffix(".sy") else { return false }
        let relative = String(record.sourcePath.dropFirst((root + "/data/").count)).split(separator: "/").map(String.init)
        guard (2...10).contains(relative.count), relative.dropLast().allSatisfy(SiYuanJSON.validID),
              let file = relative.last, SiYuanJSON.validID(String(file.dropLast(3))),
              identity == Self.identity(root: root, documentID: String(file.dropLast(3))),
              deps.contains(where: { $0.path == root + "/conf/conf.json" }),
              deps.contains(where: { $0.path == root + "/data/" + relative[0] + "/.siyuan/conf.json" }) else { return false }
        return deps.allSatisfy { dependency in
            guard dependency.path.utf8.count <= 4096, dependency.modifiedAt.timeIntervalSince1970.isFinite,
                  dependency.byteCount >= -1, dependency.byteCount <= 2_097_152,
                  (dependency.byteCount == -1 && dependency.contentHash == "missing")
                    || dependency.contentHash.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else { return false }
            if dependency.path == root + "/conf/conf.json" { return dependency.byteCount >= 0 }
            if dependency.path == root + "/data/" + relative[0] + "/.siyuan/conf.json" { return dependency.byteCount >= 0 }
            let avPrefix = root + "/data/storage/av/"
            if dependency.path.hasPrefix(avPrefix), dependency.path.hasSuffix(".json") {
                return SiYuanJSON.validID(String(dependency.path.dropFirst(avPrefix.count).dropLast(5)))
            }
            // Only the ancestor documents that determine this exact breadcrumb.
            let ancestorPaths = (1..<relative.count - 1).map { index in
                root + "/data/" + relative.prefix(index).joined(separator: "/") + "/" + relative[index] + ".sy"
            }
            return dependency.byteCount >= 0 && ancestorPaths.contains(dependency.path)
        }
    }

    static func dependenciesAreCurrent(_ record: KnowledgeRecord, grants: [ScopeGrant], cache: inout [KnowledgeDependency: Bool]) -> Bool {
        guard validMetadata(record), let root = record.workspaceRoot,
              grants.contains(where: { (try? ToolPolicy.canonicalURL($0.path))?.path == root }),
              (try? ToolPolicy.canonicalURL(root))?.path == root else { return false }
        for dependency in record.sourceDependencies ?? [] {
            if let valid = cache[dependency] { if !valid { return false }; continue }
            let url = URL(fileURLWithPath: dependency.path)
            let valid: Bool
            if (try? secureURL(url, root: URL(fileURLWithPath: root), grants: grants)) != url { valid = false }
            else if dependency.byteCount == -1 { valid = missing(url) }
            else if let data = try? LocalStateFile.read(url, maximumBytes: 2_097_152), data.count == dependency.byteCount,
                    let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                valid = date == dependency.modifiedAt && digest(data) == dependency.contentHash
            } else { valid = false }
            cache[dependency] = valid
            if !valid { return false }
        }
        return true
    }

    private static func secureURL(_ url: URL, root: URL, grants: [ScopeGrant]) throws -> URL {
        guard url.path == root.path || url.path.hasPrefix(root.path + "/"),
              try ToolPolicy.canonicalURL(url.path).path == url.path,
              try ToolPolicy.scopedURL(url.path, grants: grants).path == url.path else { throw Failure.scope }
        return url
    }
    private static func missing(_ url: URL) -> Bool {
        var info = stat()
        return url.path.withCString { lstat($0, &info) } != 0 && errno == ENOENT
    }

    private struct Read {
        let data: Data
        let receipt: KnowledgeDependency
    }
    private struct Worker {
        let root: URL
        let grants: [ScopeGrant]
        let limits: Limits
        let isCurrent: @MainActor () -> Bool
        let began = ProcessInfo.processInfo.systemUptime
        var files: [String: Read] = [:]
        var readBytes = 0
        var entries = 0
        var textBytes = 0
        var skipped = 0
        var capped = false
        var selectionCapped = false
        var candidateBytes = 0
        var candidates: [(record: KnowledgeRecord, updated: Date)] = []
        var documentIDs: Set<String> = []

        func check() throws {
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            guard ProcessInfo.processInfo.systemUptime - began < limits.maximumSeconds else { throw Failure.limit }
        }
        mutating func read(_ url: URL, maximum: Int = 2_097_152) throws -> Read {
            try check()
            if let cached = files[url.path] { return cached }
            _ = try secureURL(url, root: root, grants: grants)
            let data = try LocalStateFile.read(url, maximumBytes: maximum)
            guard data.count <= limits.maximumSourceBytes - readBytes,
                  let date = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { throw Failure.limit }
            let result = Read(data: data, receipt: .init(path: url.path, contentHash: digest(data), byteCount: data.count, modifiedAt: date))
            readBytes += data.count
            files[url.path] = result
            return result
        }
        mutating func list(_ url: URL) throws -> [URL] {
            try check()
            _ = try secureURL(url, root: root, grants: grants)
            let metadata = try url.resourceValues(forKeys: [.isDirectoryKey, .volumeIsLocalKey, .isUbiquitousItemKey])
            guard metadata.isDirectory == true, metadata.volumeIsLocal == true, metadata.isUbiquitousItem != true,
                  let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil,
                    options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles, .skipsPackageDescendants]) else { throw Failure.invalidWorkspace }
            var result: [URL] = []
            while let item = enumerator.nextObject() as? URL {
                try check()
                entries += 1
                guard entries <= limits.maximumEntries else { capped = true; break }
                result.append(item)
            }
            return result.sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        mutating func run() async throws -> Snapshot {
            let conf = try read(root.appendingPathComponent("conf/conf.json"), maximum: 65_536)
            _ = try SiYuanJSON.object(conf.data, maximumBytes: 65_536)
            let notebooks = try list(root.appendingPathComponent("data"))
            do { for notebook in notebooks where SiYuanJSON.validID(notebook.lastPathComponent) && !guideIDs.contains(notebook.lastPathComponent) {
                try check()
                let book: Read
                let settings: [String: Any]
                do {
                    book = try read(notebook.appendingPathComponent(".siyuan/conf.json"), maximum: 65_536)
                    settings = try SiYuanJSON.object(book.data, maximumBytes: 65_536)
                    if try SiYuanJSON.boolean(settings["closed"]) == true || SiYuanJSON.boolean(settings["encrypted"]) == true
                        || (settings["boxCrypt"] != nil && !(settings["boxCrypt"] is NSNull)) { skipped += 1; continue }
                } catch is CancellationError { throw CancellationError() }
                catch Failure.limit { throw Failure.limit }
                catch { skipped += 1; continue }
                let name = SiYuanJSON.prefix((try SiYuanJSON.string(settings["name"]) ?? "SiYuan"), bytes: 512)
                try await walk(notebook, trail: [name], ancestors: [conf.receipt, book.receipt], depth: 0)
            } } catch Failure.limit { capped = true }
            try check()
            let sorted = candidates.sorted { a, b in
                a.updated == b.updated ? (a.record.sourceIdentity ?? "") < (b.record.sourceIdentity ?? "") : a.updated > b.updated
            }
            var kept: [KnowledgeRecord] = []
            for candidate in sorted {
                guard kept.count < limits.maximumNotes, candidate.record.text.utf8.count <= limits.maximumTextBytes - textBytes else { capped = true; continue }
                textBytes += candidate.record.text.utf8.count
                kept.append(candidate.record)
            }
            var coverage = "SiYuan selected workspace only: open plaintext notebooks; bundled guides, closed/encrypted notebooks, title-only notes, assets, history, repo and temp content excluded. \(skipped) unavailable or ineligible entries skipped."
            if capped || selectionCapped { coverage += " Coverage is partial: bounded at \(limits.maximumNotes) notes, \(limits.maximumEntries) directory entries, \(limits.maximumSourceBytes) source bytes and \(limits.maximumTextBytes) UTF-8 text bytes." }
            kept = kept.map { record in var result = record; result.coverageNote = (result.coverageNote ?? "") + " " + coverage; return result }
            return Snapshot(records: kept, coverage: coverage, sourceBytes: readBytes, entries: entries)
        }
        mutating func walk(_ directory: URL, trail: [String], ancestors: [KnowledgeDependency], depth: Int) async throws {
            try check()
            guard depth <= 8, !capped else { capped = true; return }
            for url in try list(directory) where url.pathExtension == "sy" && SiYuanJSON.validID(url.deletingPathExtension().lastPathComponent) {
                await Task.yield()
                try check()
                let source: Read
                let parsed: SiYuanDocumentReader.Document
                do {
                    source = try read(url)
                    var bound = SiYuanDocumentReader.Limits(); bound.maximumTextBytes = limits.maximumNoteBytes
                    parsed = try SiYuanDocumentReader.read(source.data, limits: bound)
                } catch is CancellationError { throw CancellationError() }
                catch Failure.limit { throw Failure.limit }
                catch { skipped += 1; continue }
                let title = parsed.title ?? url.deletingPathExtension().lastPathComponent
                guard documentIDs.insert(url.deletingPathExtension().lastPathComponent).inserted else { throw Failure.invalidWorkspace }
                let breadcrumb = trail + [title]
                var dependencies = ancestors
                var views: [String: SiYuanAttributeViewReader.Document] = [:]
                var gaps: [String] = []
                for id in parsed.attributeViewIDs.prefix(16) {
                    let av = root.appendingPathComponent("data/storage/av/" + id + ".json")
                    if missing(av) {
                        dependencies.append(.init(path: av.path, contentHash: "missing", byteCount: -1, modifiedAt: .distantPast))
                        gaps.append("A referenced database is missing; its rows were omitted.")
                        continue
                    }
                    do {
                        let database = try read(av)
                        dependencies.append(database.receipt)
                        do { views[id] = try SiYuanAttributeViewReader.read(database.data, expectedID: id) }
                        catch is CancellationError { throw CancellationError() }
                        catch { gaps.append("An encrypted, unsupported or malformed database was not decoded; its rows were omitted.") }
                    } catch is CancellationError { throw CancellationError() }
                    catch Failure.limit { throw Failure.limit }
                    catch { throw Failure.scope } // A link/unreadable dependency cannot acquire a current receipt.
                }
                if parsed.attributeViewIDs.count > 16 { gaps.append("Only the first 16 database references were inspected; remaining rows were omitted.") }
                var bound = SiYuanDocumentReader.Limits(); bound.maximumTextBytes = limits.maximumNoteBytes
                let document = views.isEmpty ? parsed : try SiYuanDocumentReader.read(source.data, limits: bound, attributeViews: views)
                if !document.text.isEmpty {
                    let text = SiYuanJSON.prefix("SiYuan: " + breadcrumb.joined(separator: " › ") + "\n\n" + document.text, bytes: limits.maximumNoteBytes)
                    let coverage = document.coverage + " " + gaps.joined(separator: " ") + (text.utf8.count < ("SiYuan: " + breadcrumb.joined(separator: " › ") + "\n\n" + document.text).utf8.count ? " Breadcrumb and note text were truncated at the UTF-8 note limit." : "")
                    var record = KnowledgeRecord(sourcePath: url.path, title: title, text: text,
                        modifiedAt: source.receipt.modifiedAt, contentHash: source.receipt.contentHash,
                        byteCount: source.data.count, coverageNote: coverage, sourceDependencies: dependencies,
                        workspaceRoot: root.path, sourceIdentity: identity(root: root.path, documentID: url.deletingPathExtension().lastPathComponent))
                    let object = try SiYuanJSON.object(source.data, maximumBytes: 2_097_152)
                    let stamp = ((object["Properties"] as? [String: Any])?["updated"] as? String) ?? ""
                    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyyMMddHHmmss"; formatter.isLenient = false
                    let updated = max(formatter.date(from: stamp) ?? source.receipt.modifiedAt,
                                      dependencies.filter { $0.path.contains("/storage/av/") }.map(\.modifiedAt).max() ?? .distantPast)
                    record.sourceUpdatedAt = min(updated, Date())
                    candidates.append((record, record.sourceUpdatedAt ?? updated))
                    candidateBytes += record.text.utf8.count
                    // Retain only the newest bounded window while listing; source
                    // order or an old import cannot make candidate memory unbounded.
                    while candidates.count > limits.maximumNotes || candidateBytes > limits.maximumTextBytes {
                        guard let oldest = candidates.indices.min(by: { a, b in
                            candidates[a].updated == candidates[b].updated
                                ? (candidates[a].record.sourceIdentity ?? "") > (candidates[b].record.sourceIdentity ?? "")
                                : candidates[a].updated < candidates[b].updated
                        }) else { throw Failure.invalidWorkspace }
                        candidateBytes -= candidates.remove(at: oldest).record.text.utf8.count
                        selectionCapped = true
                    }
                }
                let child = directory.appendingPathComponent(url.deletingPathExtension().lastPathComponent)
                if FileManager.default.fileExists(atPath: child.path) {
                    try await walk(child, trail: breadcrumb, ancestors: ancestors + [source.receipt], depth: depth + 1)
                }
            }
        }
    }
}
