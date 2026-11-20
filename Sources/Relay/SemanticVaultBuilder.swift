import CryptoKit
import Darwin
import Foundation
import Observation

/// Structured semantic domains inside `KnowledgeVault/` (`KNW-02`).
public enum SemanticVaultDomain: String, Codable, Sendable, CaseIterable, Equatable {
    case people = "People"
    case projects = "Projects"
    case plans = "Plans"
    case preferences = "Preferences"

    public static func from(raw: String) -> SemanticVaultDomain {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "person", "people", "contacts", "relationships":
            return .people
        case "project", "projects", "work", "initiatives":
            return .projects
        case "plan", "plans", "goals", "upcoming", "schedule", "travel":
            return .plans
        case "preference", "preferences", "habits", "routines", "interests", "taste":
            return .preferences
        default:
            return .projects
        }
    }
}

/// Source attribution trust class enforced during triage and vault synthesis (`TRI-02`).
public enum SourceAttributionRole: String, Codable, Sendable, Equatable {
    case userAuthored = "user_authored"
    case directCorrespondence = "direct_correspondence"
    case groupThread = "group_thread"
    case calendarAgenda = "calendar_agenda"
    case externalReference = "external_reference"

    public var promptGuidance: String {
        switch self {
        case .userAuthored:
            return "Authored by the user (first-person statements belong to the user unless quoting someone else)."
        case .directCorrespondence:
            return "1:1 correspondence: attribute each statement, job, plan, or promise to its actual speaker/sender—never merge the other person's biography into the user."
        case .groupThread:
            return "Group thread: participants talk about their own work and plans; never attribute third-party statements to the user."
        case .calendarAgenda:
            return "Scheduled calendar entry with explicit date/time provenance."
        case .externalReference:
            return "Saved/external document: treat as reference material or topic of interest, NOT the user's own biography."
        }
    }
}

/// Resumable multi-slice Semantic Knowledge Vault synthesizer (`KNW-02..06`, `TRI-02`).
///
/// Transforms triaged source summaries and indexed records into a coherent, user-owned Markdown
/// knowledge base under `KnowledgeVault/`:
/// - `Overview.md`: grounded root personal portrait & cross-domain map
/// - `README.md`: validated vault index linking `[[Overview]]` and domain notes
/// - `People/`, `Projects/`, `Plans/`, `Preferences/`: entity notes with grounded `[[wikilinks]]` and source provenance
///
/// Uses `.relay-vault-staging-<UUID>` sibling directories, per-slice `VaultSliceCheckpoint` backups,
/// `.relay-corpus.json` + `ResumeToken` resumability, `WritingStyleCollector.preserve`,
/// `KnowledgeVaultValidation.validate(verifyWikilinks: true)`, and a live `vaultFingerprint` recheck
/// immediately before atomic `replaceItemAt` swap (`KNW-05`).
@Observable @MainActor
public final class SemanticVaultBuilder {
    public static let shared = SemanticVaultBuilder()
    typealias ModelCompletion = ([ModelMessage]) async throws -> ModelReply

    public static let maximumEntityNotes = 88
    private static let stagingPrefix = ".relay-vault-staging-"
    private static let provenanceFooterMarker = "<!-- relay-provenance -->"

    public struct ResumeToken: Codable, Sendable, Equatable {
        public var stagingPath: String
        public var vaultFingerprint: String
        public var sliceIndex: Int
        public var totalSlices: Int
        public var sliceBudget: Int
        public var sliceItemLimit: Int
        public var acceptedSourceIDs: [String]
        public var createdAt: Date

        public init(
            stagingPath: String,
            vaultFingerprint: String,
            sliceIndex: Int,
            totalSlices: Int,
            sliceBudget: Int,
            sliceItemLimit: Int,
            acceptedSourceIDs: [String],
            createdAt: Date = Date()
        ) {
            self.stagingPath = stagingPath
            self.vaultFingerprint = vaultFingerprint
            self.sliceIndex = sliceIndex
            self.totalSlices = totalSlices
            self.sliceBudget = sliceBudget
            self.sliceItemLimit = sliceItemLimit
            self.acceptedSourceIDs = acceptedSourceIDs
            self.createdAt = createdAt
        }
    }

    public struct BuildReport: Sendable, Equatable {
        public let completedSlices: Int
        public let totalSlices: Int
        public let noteCount: Int
        public var notesWritten: Int { noteCount }
        public let wikilinksVerified: Int
        public let vaultFingerprint: String
        public let resumedFromSlice: Int?
        public let acceptedSourceIDs: [String]

        public init(
            completedSlices: Int,
            totalSlices: Int,
            noteCount: Int,
            wikilinksVerified: Int,
            vaultFingerprint: String,
            resumedFromSlice: Int?,
            acceptedSourceIDs: [String]
        ) {
            self.completedSlices = completedSlices
            self.totalSlices = totalSlices
            self.noteCount = noteCount
            self.wikilinksVerified = wikilinksVerified
            self.vaultFingerprint = vaultFingerprint
            self.resumedFromSlice = resumedFromSlice
            self.acceptedSourceIDs = acceptedSourceIDs
        }
    }

    public enum Failure: LocalizedError, Equatable {
        case busy
        case emptyCorpus
        case vaultModifiedDuringSynthesis
        case invalidModelOutput(String)
        case swapFailed(String)

        public var errorDescription: String? {
            switch self {
            case .busy:
                return "Knowledge Vault synthesis is already in progress."
            case .emptyCorpus:
                return "Choose or connect at least one readable source before building the Knowledge Vault."
            case .vaultModifiedDuringSynthesis:
                return "A note in your Knowledge Vault was edited while synthesis was running. Your edits were preserved and the background update was discarded."
            case .invalidModelOutput(let detail):
                return "Could not validate synthesized vault notes: \(detail)"
            case .swapFailed(let detail):
                return "Could not publish staged Knowledge Vault: \(detail)"
            }
        }
    }

    // MARK: - Observable State

    public private(set) var isBuilding = false
    public private(set) var status = "Ready to synthesize your Knowledge Vault."
    public private(set) var completedSlices = 0
    public private(set) var totalSlices = 0
    public private(set) var lastReport: BuildReport?
    public private(set) var pendingResumeToken: ResumeToken?

    @ObservationIgnored private let vaultRootProvider: @MainActor () -> URL
    @ObservationIgnored private let resumeStateURL: URL
    @ObservationIgnored private var activeTask: Task<BuildReport, Error>?

    public init(vaultRoot: URL? = nil, resumeStateURL: URL? = nil) {
        if let vaultRoot {
            self.vaultRootProvider = { vaultRoot }
        } else {
            self.vaultRootProvider = { KnowledgeVaultManager.shared.vaultDirectory }
        }
        if let resumeStateURL {
            self.resumeStateURL = resumeStateURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
            self.resumeStateURL = appSupport
                .appendingPathComponent("Relay", isDirectory: true)
                .appendingPathComponent("semantic-vault-resume.json", isDirectory: false)
        }
        self.pendingResumeToken = Self.loadResumeToken(at: self.resumeStateURL)
        if let token = self.pendingResumeToken {
            self.status = "Interrupted Knowledge Vault build can resume at slice \(token.sliceIndex + 1) of \(token.totalSlices)."
        }
    }

    public var vaultRoot: URL { vaultRootProvider() }
    public var canResume: Bool { pendingResumeToken != nil && !isBuilding }

    public func cancel() {
        activeTask?.cancel()
    }

    /// Clean teardown for Factory Reset / Uninstall (`SYS-09`, `SYS-10`).
    public func cancelAndDrain() async {
        activeTask?.cancel()
        _ = try? await activeTask?.value
        activeTask = nil
        isBuilding = false
        clearResumeStateAndStaging()
    }

    public func clearResumeStateAndStaging() {
        if let token = pendingResumeToken {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: token.stagingPath))
        }
        try? FileManager.default.removeItem(at: resumeStateURL)
        pendingResumeToken = nil
        pruneOrphanStagingDirectories(near: vaultRoot)
    }

    // MARK: - Corpus Construction Adapters

    /// Builds attribution-tagged `CorpusItem` entries from indexed `KnowledgeRecord`s and native personal sources,
    /// redacting high-risk PII lines (`TRI-02`, `TRI-03`).
    static func makeCorpusItems(
        records: [KnowledgeRecord],
        nativeSources: NativePersonalSources,
        additionalItems: [CorpusItem] = []
    ) -> [CorpusItem] {
        let mapped = Dictionary(
            NativePersonalSourceKind.allCases.map { ($0, nativeSources.items(for: $0)) },
            uniquingKeysWith: { first, _ in first }
        )
        return makeCorpusItems(records: records, nativeItems: mapped, additionalItems: additionalItems)
    }

    static func makeCorpusItems(
        records: [KnowledgeRecord],
        nativeItems: [NativePersonalSourceKind: [NativePersonalSourceItem]] = [:],
        additionalItems: [CorpusItem] = []
    ) -> [CorpusItem] {
        var items: [CorpusItem] = []
        var seenIDs = Set<String>()

        for record in records.sorted(by: { $0.modifiedAt > $1.modifiedAt }) {
            let sanitized = sanitizeSourceText(record.text, maxBytes: 16_000)
            guard !sanitized.isEmpty else { continue }
            let role = inferAttributionRole(path: record.sourcePath, title: record.title, text: sanitized)
            let id = "record:\(record.id)"
            guard seenIDs.insert(id).inserted else { continue }
            let annotated = "[Attribution: \(role.rawValue) — \(role.promptGuidance)]\nSource: \(record.title) (\(record.sourcePath))\n\(sanitized)"
            items.append(CorpusItem(
                id: id,
                title: record.title,
                text: annotated,
                itemDate: record.modifiedAt,
                sourceID: record.sourcePath,
                kind: role.rawValue
            ))
        }

        for kind in NativePersonalSourceKind.allCases {
            guard let sourceEntries = nativeItems[kind] else { continue }
            for entry in sourceEntries {
                let senderLine = entry.sender.map { "Sender: \($0)" }
                let rawBody = [senderLine, Optional(entry.text)]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                let sanitized = sanitizeSourceText(rawBody, maxBytes: 12_000)
                guard !sanitized.isEmpty else { continue }
                let role: SourceAttributionRole
                switch kind {
                case .mail:
                    role = .directCorrespondence
                case .notes:
                    role = .userAuthored
                }
                let id = "native:\(kind.rawValue):\(entry.id)"
                guard seenIDs.insert(id).inserted else { continue }
                let annotated = "[Attribution: \(role.rawValue) — \(role.promptGuidance)]\nSource: \(kind.displayName) — \(entry.title)\n\(sanitized)"
                items.append(CorpusItem(
                    id: id,
                    title: entry.title,
                    text: annotated,
                    itemDate: entry.receivedAt ?? entry.sentAt,
                    sourceID: "apple-\(kind.rawValue)",
                    kind: role.rawValue
                ))
            }
        }

        for extra in additionalItems {
            let sanitized = sanitizeSourceText(extra.text, maxBytes: 16_000)
            guard !sanitized.isEmpty, seenIDs.insert(extra.id).inserted else { continue }
            items.append(CorpusItem(
                id: extra.id,
                title: extra.title,
                text: sanitized,
                itemDate: extra.itemDate,
                sourceID: extra.sourceID,
                kind: extra.kind
            ))
        }

        return items
    }

    // MARK: - Build, Incremental Update & Deterministic Resume

    /// Synthesizes or incrementally updates `KnowledgeVault/` across byte-budgeted `CorpusSlicer` slices.
    /// Automatically resumes an interrupted run if `allowResume` is true and live vault fingerprint is unchanged.
    @discardableResult
    func buildOrUpdate(
        items: [CorpusItem],
        sliceBudget: Int = CorpusSlicer.mergeBudget,
        sliceItemLimit: Int = CorpusSlicer.maximumItems,
        allowResume: Bool = true,
        isSourceCurrent: ((CorpusItem) -> Bool)? = nil,
        complete: @escaping ModelCompletion
    ) async throws -> BuildReport {
        guard !isBuilding, activeTask == nil else { throw Failure.busy }

        let root = vaultRoot.standardizedFileURL
        let parentDir = root.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parentDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let baselineVaultExists = Self.regularDirectoryExists(at: root)
        let baselineFingerprint = baselineVaultExists ? (try KnowledgeVaultValidation.fingerprint(root)) : "EMPTY_VAULT"

        // Determine whether we can resume from an existing staged run (`KNW-06`).
        var stagingURL: URL?
        var activeItems = items
        var startSlice = 0
        var resumedFrom: Int?
        var acceptedIDs: [String] = []

        if allowResume,
           let token = pendingResumeToken,
           token.vaultFingerprint == baselineFingerprint,
           token.sliceBudget == sliceBudget,
           token.sliceItemLimit == sliceItemLimit {
            let candidateStaging = URL(fileURLWithPath: token.stagingPath).standardizedFileURL
            if Self.regularDirectoryExists(at: candidateStaging),
               let savedCorpus = CorpusSlicer.loadCorpus(from: candidateStaging),
               !savedCorpus.isEmpty {
                stagingURL = candidateStaging
                activeItems = savedCorpus
                startSlice = max(0, token.sliceIndex)
                resumedFrom = startSlice
                acceptedIDs = token.acceptedSourceIDs
            } else {
                clearResumeStateAndStaging()
            }
        } else if pendingResumeToken != nil {
            clearResumeStateAndStaging()
        }

        if let isSourceCurrent {
            activeItems = activeItems.filter(isSourceCurrent)
        }
        guard !activeItems.isEmpty else {
            throw Failure.emptyCorpus
        }

        let slices = CorpusSlicer.slice(activeItems, budget: sliceBudget, maximumItems: sliceItemLimit)
        guard !slices.isEmpty else { throw Failure.emptyCorpus }
        if startSlice >= slices.count {
            startSlice = 0
            resumedFrom = nil
        }

        let resolvedStaging: URL
        if let existing = stagingURL {
            resolvedStaging = existing
        } else {
            pruneOrphanStagingDirectories(near: root)
            let fresh = parentDir.appendingPathComponent(Self.stagingPrefix + UUID().uuidString, isDirectory: true)
            if baselineVaultExists {
                try Self.copyDirectoryWithoutSymlinks(from: root, to: fresh)
            } else {
                try FileManager.default.createDirectory(
                    at: fresh,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            try Self.ensureDomainDirectories(in: fresh)
            try CorpusSlicer.saveCorpus(activeItems, in: fresh)
            resolvedStaging = fresh
        }

        isBuilding = true
        totalSlices = slices.count
        completedSlices = startSlice
        status = resumedFrom != nil
            ? "Resuming Knowledge Vault synthesis at slice \(startSlice + 1) of \(slices.count)…"
            : "Synthesizing Knowledge Vault (\(slices.count) \(slices.count == 1 ? "slice" : "slices"))…"

        let task = Task { @MainActor () -> BuildReport in
            var runningAccepted = Set(acceptedIDs)

            for index in startSlice..<slices.count {
                try Task.checkCancellation()
                status = "Synthesizing Knowledge Vault slice \(index + 1) of \(slices.count)…"

                let slice = slices[index].filter { item in
                    isSourceCurrent?(item) ?? true
                }
                if slice.isEmpty {
                    completedSlices = index + 1
                    continue
                }

                let checkpoint = try VaultSliceCheckpoint(staging: resolvedStaging)
                do {
                    let existingManifest = Self.collectStagedNoteManifest(in: resolvedStaging)
                    let messages = Self.buildSynthesisPrompt(
                        slice: slice,
                        sliceIndex: index,
                        totalSlices: slices.count,
                        existingManifest: existingManifest
                    )
                    let reply = try await complete(messages)
                    try Task.checkCancellation()

                    let delta: SynthesisDelta
                    do {
                        delta = try Self.parseSynthesisDelta(reply.content, allowedItems: slice)
                    } catch Failure.invalidModelOutput {
                        let repairMessages = Self.buildJSONRepairPrompt(
                            baseMessages: messages,
                            invalidReply: reply.content
                        )
                        let retryReply = try await complete(repairMessages)
                        try Task.checkCancellation()
                        delta = try Self.parseSynthesisDelta(retryReply.content, allowedItems: slice)
                    }
                    try Self.applyDelta(delta, allowedItems: slice, in: resolvedStaging)
                    checkpoint.discard()

                    for item in slice {
                        runningAccepted.insert(item.id)
                    }
                    completedSlices = index + 1

                    if index + 1 < slices.count {
                        let token = ResumeToken(
                            stagingPath: resolvedStaging.path,
                            vaultFingerprint: baselineFingerprint,
                            sliceIndex: index + 1,
                            totalSlices: slices.count,
                            sliceBudget: sliceBudget,
                            sliceItemLimit: sliceItemLimit,
                            acceptedSourceIDs: runningAccepted.sorted()
                        )
                        Self.saveResumeToken(token, to: self.resumeStateURL)
                        self.pendingResumeToken = token
                    }
                } catch {
                    try? checkpoint.restore()
                    checkpoint.discard()
                    let token = ResumeToken(
                        stagingPath: resolvedStaging.path,
                        vaultFingerprint: baselineFingerprint,
                        sliceIndex: index,
                        totalSlices: slices.count,
                        sliceBudget: sliceBudget,
                        sliceItemLimit: sliceItemLimit,
                        acceptedSourceIDs: runningAccepted.sorted()
                    )
                    Self.saveResumeToken(token, to: self.resumeStateURL)
                    self.pendingResumeToken = token
                    throw error
                }
            }

            try Task.checkCancellation()
            status = "Validating Knowledge Vault coherence & wikilinks…"

            // Finalize Overview.md, README.md, canonicalize wikilinks, clean staging snapshot, preserve writingstyle.md.
            CorpusSlicer.deleteCorpus(in: resolvedStaging)
            try WritingStyleCollector.preserve(in: resolvedStaging, from: root)
            try Self.finalizeIndexesAndWikilinks(in: resolvedStaging)
            try Self.removeEmptyDomainDirectoriesIfNeeded(in: resolvedStaging)

            let validation = try KnowledgeVaultValidation.validate(
                staging: resolvedStaging,
                replacing: baselineVaultExists ? root : nil,
                verifyWikilinks: true
            )

            // KNW-05: Recheck live vault fingerprint immediately before atomic swap!
            let currentLiveExists = Self.regularDirectoryExists(at: root)
            let currentLiveFingerprint = currentLiveExists ? (try KnowledgeVaultValidation.fingerprint(root)) : "EMPTY_VAULT"
            guard currentLiveFingerprint == baselineFingerprint else {
                try? FileManager.default.removeItem(at: resolvedStaging)
                try? FileManager.default.removeItem(at: self.resumeStateURL)
                self.pendingResumeToken = nil
                throw Failure.vaultModifiedDuringSynthesis
            }

            do {
                if currentLiveExists {
                    _ = try FileManager.default.replaceItemAt(root, withItemAt: resolvedStaging)
                } else {
                    try FileManager.default.moveItem(at: resolvedStaging, to: root)
                }
            } catch {
                try? FileManager.default.removeItem(at: resolvedStaging)
                throw Failure.swapFailed(error.localizedDescription)
            }

            try? FileManager.default.removeItem(at: self.resumeStateURL)
            self.pendingResumeToken = nil
            KnowledgeVaultManager.shared.ensureDefaultVaultFilesExist()

            return BuildReport(
                completedSlices: slices.count,
                totalSlices: slices.count,
                noteCount: validation.files,
                wikilinksVerified: validation.wikilinksChecked,
                vaultFingerprint: validation.fingerprint,
                resumedFromSlice: resumedFrom,
                acceptedSourceIDs: runningAccepted.sorted()
            )
        }

        activeTask = task
        defer {
            activeTask = nil
            isBuilding = false
        }

        do {
            let report = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            lastReport = report
            status = "Knowledge Vault updated (\(report.noteCount) notes, \(report.wikilinksVerified) verified wikilinks)."
            return report
        } catch is CancellationError {
            status = "Knowledge Vault synthesis paused at slice \(completedSlices) of \(totalSlices). Resume anytime."
            throw CancellationError()
        } catch {
            status = error.localizedDescription
            throw error
        }
    }

    // MARK: - Synthesis Schema & Prompting (`TRI-02`)

    private struct SynthesisDelta: Codable {
        struct NoteSpec: Codable {
            var domain: String
            var title: String
            var summary: String
            var facts: [String]?
            var openThreads: [String]?
            var relatedTitles: [String]?
            var sourceIDs: [String]?
            var attribution: String?

            enum CodingKeys: String, CodingKey {
                case domain
                case title
                case summary
                case facts
                case openThreads = "open_threads"
                case relatedTitles = "related_titles"
                case sourceIDs = "source_ids"
                case attribution
            }
        }

        var overviewSummary: String?
        var activePriorities: [String]?
        var notes: [NoteSpec]

        enum CodingKeys: String, CodingKey {
            case overviewSummary = "overview_summary"
            case activePriorities = "active_priorities"
            case notes
        }
    }

    private static func buildSynthesisPrompt(
        slice: [CorpusItem],
        sliceIndex: Int,
        totalSlices: Int,
        existingManifest: [String]
    ) -> [ModelMessage] {
        let df = CorpusSlicer.dateFormatter()
        let renderedSlice = slice.enumerated()
            .map { idx, item in
                "SOURCE_ID: \(item.id)\n" + CorpusSlicer.render(item, index: idx, df: df)
            }
            .joined(separator: "\n\n---\n\n")

        let manifestText = existingManifest.isEmpty
            ? "(No existing notes yet — initial slice)"
            : existingManifest.prefix(80).joined(separator: ", ")

        let systemPrompt = """
            You are Relay's Semantic Knowledge Vault synthesizer.
            Organize durable facts from the user's local sources into structured Markdown entity notes across 4 domains:
            - "People": collaborators, family, friends, contacts (with explicit relationship/role to the user).
            - "Projects": active initiatives, products, codebases, research, ongoing work.
            - "Plans": upcoming deadlines, trips, events, milestones, goals.
            - "Preferences": durable habits, communication preferences, tools, tastes, routines.

            STRICT ATTRIBUTION & SAFETY RULES (TRI-02 / TRI-03):
            1. NEVER confuse another person's biography, employer, promise, or task with the user's own!
               - In 1:1 correspondence or group threads, attribute statements explicitly (e.g., "Alex mentioned shipping the API on Friday", NOT "The user is shipping the API on Friday").
               - Saved external articles/bookmarks reflect topical interest only, NEVER the user's personal life.
            2. Ground every note in one or more exact `source_ids` from this slice. Never invent dates, obligations, or relationships.
            3. Reuse exact existing note titles from EXISTING_VAULT_NOTES when updating an entity so slices merge cleanly instead of duplicating notes.
            4. Omit passwords, API keys, government IDs, financial account numbers, or raw credentials.
            5. Return ONLY valid JSON matching this schema (no Markdown code fences, no commentary):
            {
              "overview_summary": "2-4 grounded sentences summarizing durable themes about the user from this slice (or empty string if none).",
              "active_priorities": ["Grounded current priority or focus area"],
              "notes": [
                {
                  "domain": "People | Projects | Plans | Preferences",
                  "title": "Clean Entity Title",
                  "summary": "Concise grounded summary clearly stating who/what this is and how it relates to the user.",
                  "facts": ["Grounded durable fact with clear speaker/actor attribution"],
                  "open_threads": ["Unfinished commitment or upcoming milestone, if any"],
                  "related_titles": ["Exact Title of another related note"],
                  "source_ids": ["exact SOURCE_ID from input"],
                  "attribution": "user | counterparty | reference"
                }
              ]
            }
            """

        let userPrompt = """
            SLICE \(sliceIndex + 1) OF \(totalSlices)
            EXISTING_VAULT_NOTES: \(manifestText)

            CORPUS SLICE:
            \(renderedSlice)
            """

        return [
            ModelMessage(role: "system", content: systemPrompt),
            ModelMessage(role: "user", content: userPrompt)
        ]
    }

    private static func buildJSONRepairPrompt(
        baseMessages: [ModelMessage],
        invalidReply: String
    ) -> [ModelMessage] {
        let excerpt = GeneratedKnowledgeVault.boundedUTF8(
            invalidReply.trimmingCharacters(in: .whitespacesAndNewlines),
            limit: 2_000
        )
        let repairInstruction = """
            Your previous response could not be parsed as valid JSON matching the required schema.
            Return ONLY a single valid JSON object (no Markdown code fences, no commentary before `{` or after `}`) with keys:
            - "overview_summary": string
            - "active_priorities": array of strings
            - "notes": array of grounded note objects, each referencing one or more exact `source_ids` from this slice.
            """
        return baseMessages + [
            ModelMessage(role: "assistant", content: excerpt.isEmpty ? "(empty response)" : excerpt),
            ModelMessage(role: "user", content: repairInstruction)
        ]
    }

    private static func parseSynthesisDelta(
        _ rawText: String,
        allowedItems: [CorpusItem]
    ) throws -> SynthesisDelta {
        let allowedByID = Dictionary(allowedItems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard let jsonString = extractJSONObject(from: rawText),
              let jsonData = jsonString.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(SynthesisDelta.self, from: jsonData) else {
            throw Failure.invalidModelOutput("Slice synthesis response was not valid JSON matching the vault schema.")
        }

        let groundedNotes = decoded.notes.compactMap { note -> SynthesisDelta.NoteSpec? in
            let cleanTitle = sanitizeNoteTitle(note.title)
            let cleanSummary = sanitizeFactLine(note.summary)
            guard !cleanTitle.isEmpty, !cleanSummary.isEmpty else { return nil }
            var seenSourceIDs = Set<String>()
            let validSourceIDs = (note.sourceIDs ?? []).filter { id in
                allowedByID[id] != nil && seenSourceIDs.insert(id).inserted
            }
            guard !validSourceIDs.isEmpty else { return nil }
            var copy = note
            copy.title = cleanTitle
            copy.summary = cleanSummary
            copy.facts = (note.facts ?? []).map(sanitizeFactLine).filter { !$0.isEmpty }
            copy.openThreads = (note.openThreads ?? []).map(sanitizeFactLine).filter { !$0.isEmpty }
            copy.relatedTitles = (note.relatedTitles ?? [])
                .map(sanitizeNoteTitle)
                .filter { !$0.isEmpty && $0.caseInsensitiveCompare(cleanTitle) != .orderedSame }
            copy.sourceIDs = validSourceIDs
            return copy
        }

        return SynthesisDelta(
            overviewSummary: decoded.overviewSummary.map(sanitizeFactLine),
            activePriorities: (decoded.activePriorities ?? []).map(sanitizeFactLine).filter { !$0.isEmpty },
            notes: groundedNotes
        )
    }

    // MARK: - Staged Note Merging & Coherent Wikilink Finalization

    private static func applyDelta(
        _ delta: SynthesisDelta,
        allowedItems: [CorpusItem],
        in staging: URL
    ) throws {
        let itemsByID = Dictionary(allowedItems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        try ensureDomainDirectories(in: staging)

        var existingCount = countEntityNotes(in: staging)

        for spec in delta.notes {
            let domain = SemanticVaultDomain.from(raw: spec.domain)
            let cleanTitle = sanitizeNoteTitle(spec.title)
            guard !cleanTitle.isEmpty,
                  cleanTitle.caseInsensitiveCompare("Overview") != .orderedSame,
                  cleanTitle.caseInsensitiveCompare("README") != .orderedSame,
                  cleanTitle.caseInsensitiveCompare("writingstyle") != .orderedSame else { continue }

            // Reuse existing note path across any domain if a note with the same title already exists (`KNW-04`).
            let targetURL: URL
            if let existingURL = findExistingEntityNote(titled: cleanTitle, in: staging) {
                targetURL = existingURL
            } else {
                guard existingCount < maximumEntityNotes else { continue }
                targetURL = staging
                    .appendingPathComponent(domain.rawValue, isDirectory: true)
                    .appendingPathComponent("\(cleanTitle).md", isDirectory: false)
                existingCount += 1
            }

            let provenanceLines: [String] = (spec.sourceIDs ?? []).compactMap { id in
                guard let item = itemsByID[id] else { return nil }
                let sourceLabel = item.sourceID ?? item.title
                return "- `\(item.title)` (\(sourceLabel))"
            }

            let mergedMarkdown = mergeEntityMarkdown(
                existing: (try? String(contentsOf: targetURL, encoding: .utf8)),
                title: cleanTitle,
                domain: domain,
                spec: spec,
                provenanceLines: provenanceLines
            )
            try writeRegularMarkdown(mergedMarkdown, to: targetURL)
        }

        // Update staged Overview.md with incremental overview summary & priorities (`KNW-03`).
        let overviewURL = staging.appendingPathComponent("Overview.md", isDirectory: false)
        let existingOverview = try? String(contentsOf: overviewURL, encoding: .utf8)
        let updatedOverview = mergeOverviewDraft(
            existing: existingOverview,
            newSummary: delta.overviewSummary,
            newPriorities: delta.activePriorities ?? []
        )
        try writeRegularMarkdown(updatedOverview, to: overviewURL)
    }

    private static func mergeEntityMarkdown(
        existing: String?,
        title: String,
        domain: SemanticVaultDomain,
        spec: SynthesisDelta.NoteSpec,
        provenanceLines: [String]
    ) -> String {
        let relatedLinks = (spec.relatedTitles ?? [])
            .map { "[[\($0)]]" }
            .sorted()

        if let existing, !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Surgical incremental merge (`KNW-04`): preserve existing user/prior sections and append only new bullets!
            var existingLines = Set(
                existing.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            )
            var additions: [String] = []
            for fact in (spec.facts ?? []) {
                let bullet = "- \(fact)"
                if existingLines.insert(bullet).inserted {
                    additions.append(bullet)
                }
            }
            for thread in (spec.openThreads ?? []) {
                let bullet = "- Open thread: \(thread)"
                if existingLines.insert(bullet).inserted {
                    additions.append(bullet)
                }
            }
            for link in relatedLinks where !existing.contains(link) {
                let bullet = "- Related: \(link)"
                if existingLines.insert(bullet).inserted {
                    additions.append(bullet)
                }
            }
            var newProv: [String] = []
            for prov in provenanceLines where !existing.contains(prov) {
                if existingLines.insert(prov).inserted {
                    newProv.append(prov)
                }
            }

            var base = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if !base.hasPrefix("# ") {
                base = "# \(title)\n\n" + base
            }
            if !additions.isEmpty {
                base += "\n\n## Updated Context\n" + additions.joined(separator: "\n")
            }
            if !newProv.isEmpty {
                if base.contains("## Sources") {
                    base += "\n" + newProv.joined(separator: "\n")
                } else {
                    base += "\n\n\(provenanceFooterMarker)\n## Sources\n" + newProv.joined(separator: "\n")
                }
            }
            return base + "\n"
        }

        var sections: [String] = ["# \(title)", "", spec.summary]
        if let facts = spec.facts, !facts.isEmpty {
            sections.append("")
            sections.append("## Key Facts")
            sections.append(contentsOf: facts.map { "- \($0)" })
        }
        if let openThreads = spec.openThreads, !openThreads.isEmpty {
            sections.append("")
            sections.append("## Open Threads")
            sections.append(contentsOf: openThreads.map { "- \($0)" })
        }
        if !relatedLinks.isEmpty {
            sections.append("")
            sections.append("## Related")
            sections.append("- " + relatedLinks.joined(separator: " · "))
        }
        if !provenanceLines.isEmpty {
            sections.append("")
            sections.append(provenanceFooterMarker)
            sections.append("## Sources")
            sections.append(contentsOf: provenanceLines)
        }
        sections.append("")
        return sections.joined(separator: "\n")
    }

    private static func mergeOverviewDraft(
        existing: String?,
        newSummary: String?,
        newPriorities: [String]
    ) -> String {
        let trimmedSummary = (newSummary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var summaryParagraphs: [String] = []
        var priorities: [String] = []

        if let existing, !existing.isEmpty {
            for line in existing.components(separatedBy: .newlines) {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("- "), !t.contains("[[") {
                    priorities.append(String(t.dropFirst(2)))
                } else if !t.isEmpty,
                          !t.hasPrefix("#"),
                          !t.hasPrefix("<!--"),
                          !t.hasPrefix("- [[") {
                    summaryParagraphs.append(t)
                }
            }
        }
        if !trimmedSummary.isEmpty, !summaryParagraphs.contains(trimmedSummary) {
            summaryParagraphs.append(trimmedSummary)
        }
        for item in newPriorities where !priorities.contains(item) {
            priorities.append(item)
        }

        var lines: [String] = ["# Overview", ""]
        if summaryParagraphs.isEmpty {
            lines.append("Grounded personal overview synthesized from your opted-in sources on this Mac.")
        } else {
            lines.append(summaryParagraphs.suffix(4).joined(separator: "\n\n"))
        }
        if !priorities.isEmpty {
            lines.append("")
            lines.append("## Active Focus")
            for p in priorities.suffix(10) {
                lines.append("- \(p)")
            }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// Rebuilds the domain index sections on `Overview.md` and `README.md`, and canonicalizes/strips
    /// any dangling `[[wikilink]]` across every Markdown file in `staging` (`KNW-03`).
    private static func finalizeIndexesAndWikilinks(in staging: URL) throws {
        let notesByDomain = collectDomainNoteTitles(in: staging)

        // Append clean domain directory links to `Overview.md`
        let overviewURL = staging.appendingPathComponent("Overview.md", isDirectory: false)
        let rawOverview = (try? String(contentsOf: overviewURL, encoding: .utf8)) ?? "# Overview\n\nGrounded personal overview.\n"
        let baseOverview = stripGeneratedDomainMap(from: rawOverview)
        var overviewLines = [baseOverview.trimmingCharacters(in: .whitespacesAndNewlines), "", "<!-- relay-domain-map -->", "## Knowledge Map"]
        var totalEntityNotes = 0
        for domain in SemanticVaultDomain.allCases {
            let titles = notesByDomain[domain] ?? []
            guard !titles.isEmpty else { continue }
            totalEntityNotes += titles.count
            overviewLines.append("")
            overviewLines.append("### \(domain.rawValue)")
            for title in titles {
                overviewLines.append("- [[\(title)]]")
            }
        }
        if totalEntityNotes == 0 {
            overviewLines.append("- Connected sources indexed; domain notes will populate as entities emerge.")
        }
        overviewLines.append("")
        try writeRegularMarkdown(overviewLines.joined(separator: "\n"), to: overviewURL)

        // Write `README.md` (`KnowledgeVaultValidation` root index requirement + `[[Overview]]` link).
        let readmeURL = staging.appendingPathComponent("README.md", isDirectory: false)
        var readmeLines: [String] = [
            "# Knowledge Vault",
            "",
            "Start at [[Overview]] for your personal portrait and active priorities.",
            ""
        ]
        for domain in SemanticVaultDomain.allCases {
            let titles = notesByDomain[domain] ?? []
            guard !titles.isEmpty else { continue }
            readmeLines.append("## \(domain.rawValue)")
            for title in titles {
                readmeLines.append("- [[\(domain.rawValue)/\(title)]]")
            }
            readmeLines.append("")
        }
        try writeRegularMarkdown(readmeLines.joined(separator: "\n"), to: readmeURL)

        // Canonicalize/strip any dangling `[[wikilinks]]` across all `.md` files in `staging`
        // (except `writingstyle.md`, which is preserved verbatim!).
        let validTargets = collectResolvableTargets(in: staging)
        let markdownURLs = enumerateMarkdownFiles(in: staging)
        for fileURL in markdownURLs where fileURL.lastPathComponent != WritingStyleCollector.fileName {
            guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            let cleaned = sanitizeDanglingWikilinks(in: text, validTargets: validTargets)
            if cleaned != text {
                try writeRegularMarkdown(cleaned, to: fileURL)
            }
        }
    }

    private static func stripGeneratedDomainMap(from markdown: String) -> String {
        if let markerRange = markdown.range(of: "<!-- relay-domain-map -->") {
            return String(markdown[..<markerRange.lowerBound])
        }
        return markdown
    }

    private static func collectResolvableTargets(in staging: URL) -> (names: Set<String>, pathsWithoutExt: Set<String>, caseMap: [String: String]) {
        let files = enumerateMarkdownFiles(in: staging)
        var names = Set<String>()
        var pathsWithoutExt = Set<String>()
        var caseMap: [String: String] = [:]
        let rootPrefix = staging.standardizedFileURL.path + "/"

        for url in files {
            let std = url.standardizedFileURL.path
            guard std.hasPrefix(rootPrefix) else { continue }
            let relPath = String(std.dropFirst(rootPrefix.count))
            let noExt = (relPath as NSString).deletingPathExtension
            let base = (noExt as NSString).lastPathComponent
            names.insert(base)
            pathsWithoutExt.insert(noExt)
            caseMap[base.lowercased()] = base
            caseMap[noExt.lowercased()] = noExt
        }
        return (names, pathsWithoutExt, caseMap)
    }

    private static func sanitizeDanglingWikilinks(
        in text: String,
        validTargets: (names: Set<String>, pathsWithoutExt: Set<String>, caseMap: [String: String])
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\[\[([^\[\]\n]+)\]\]"#) else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }

        let mutable = NSMutableString(string: text)
        for match in matches.reversed() {
            let inner = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let targetPart = inner.split(separator: "|", maxSplits: 1).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? inner
            let normalized: String
            if let rel = KnowledgeRelationship(target: targetPart) {
                normalized = rel.name
            } else if targetPart.contains(":") {
                normalized = String(targetPart.split(separator: ":", maxSplits: 1)[1]).trimmingCharacters(in: .whitespaces)
            } else {
                normalized = targetPart
            }
            let base = (normalized as NSString).lastPathComponent
            if validTargets.names.contains(base) || validTargets.pathsWithoutExt.contains(normalized) {
                continue
            }
            if let canonical = validTargets.caseMap[normalized.lowercased()] ?? validTargets.caseMap[base.lowercased()] {
                mutable.replaceCharacters(in: match.range, with: "[[\(canonical)]]")
            } else {
                // Replace ungrounded/dangling wikilink with plain readable label (`KNW-03` zero dangling links).
                let display = inner.split(separator: "|", maxSplits: 1).last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? base
                mutable.replaceCharacters(in: match.range, with: display)
            }
        }
        return mutable as String
    }

    // MARK: - Filesystem & Security Helpers

    private static func ensureDomainDirectories(in root: URL) throws {
        for domain in SemanticVaultDomain.allCases {
            let dir = root.appendingPathComponent(domain.rawValue, isDirectory: true)
            try FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }

    private static func removeEmptyDomainDirectoriesIfNeeded(in root: URL) throws {
        let fm = FileManager.default
        for domain in SemanticVaultDomain.allCases {
            let dir = root.appendingPathComponent(domain.rawValue, isDirectory: true)
            if let contents = try? fm.contentsOfDirectory(atPath: dir.path), contents.isEmpty {
                try? fm.removeItem(at: dir)
            }
        }
    }

    private static func writeRegularMarkdown(_ content: String, to url: URL) throws {
        let clean = content.replacingOccurrences(of: "\0", with: "")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try LocalPrivateFileWriter.write(
            data: Data(clean.utf8),
            to: url,
            maximumBytes: 1_500_000,
            createOnly: false
        )
    }

    private static func regularDirectoryExists(at url: URL) -> Bool {
        var metadata = stat()
        guard url.path.withCString({ lstat($0, &metadata) }) == 0 else { return false }
        return (metadata.st_mode & S_IFMT) == S_IFDIR
    }

    private static func copyDirectoryWithoutSymlinks(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let entries = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        for entry in entries {
            var st = stat()
            guard entry.path.withCString({ lstat($0, &st) }) == 0 else { continue }
            let mode = st.st_mode & S_IFMT
            let target = destination.appendingPathComponent(entry.lastPathComponent)
            if mode == S_IFDIR {
                try copyDirectoryWithoutSymlinks(from: entry, to: target)
            } else if mode == S_IFREG {
                let data = try LocalStateFile.read(entry, maximumBytes: 2 * 1_024 * 1_024)
                try LocalPrivateFileWriter.write(data: data, to: target, maximumBytes: 2 * 1_024 * 1_024, createOnly: false)
            }
        }
    }

    private static func collectDomainNoteTitles(in root: URL) -> [SemanticVaultDomain: [String]] {
        let fm = FileManager.default
        var map: [SemanticVaultDomain: [String]] = [:]
        for domain in SemanticVaultDomain.allCases {
            let dir = root.appendingPathComponent(domain.rawValue, isDirectory: true)
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            let titles = files
                .filter { $0.pathExtension.lowercased() == "md" && !$0.lastPathComponent.hasPrefix(".") }
                .map { $0.deletingPathExtension().lastPathComponent }
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            map[domain] = titles
        }
        return map
    }

    private static func collectStagedNoteManifest(in root: URL) -> [String] {
        let map = collectDomainNoteTitles(in: root)
        var list: [String] = []
        for domain in SemanticVaultDomain.allCases {
            for title in map[domain] ?? [] {
                list.append("\(domain.rawValue)/\(title)")
            }
        }
        return list
    }

    private static func countEntityNotes(in root: URL) -> Int {
        collectDomainNoteTitles(in: root).values.reduce(0) { $0 + $1.count }
    }

    private static func findExistingEntityNote(titled title: String, in root: URL) -> URL? {
        let fm = FileManager.default
        for domain in SemanticVaultDomain.allCases {
            let dir = root.appendingPathComponent(domain.rawValue, isDirectory: true)
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            if let match = files.first(where: {
                $0.pathExtension.lowercased() == "md" &&
                $0.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(title) == .orderedSame
            }) {
                return match
            }
        }
        return nil
    }

    private static func enumerateMarkdownFiles(in root: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var urls: [URL] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension.lowercased() == "md",
                  let vals = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  vals.isRegularFile == true,
                  vals.isSymbolicLink != true else { continue }
            urls.append(fileURL)
        }
        return urls
    }

    private func pruneOrphanStagingDirectories(near root: URL) {
        let parent = root.standardizedFileURL.deletingLastPathComponent()
        guard let children = try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil) else { return }
        let protectedPath = pendingResumeToken?.stagingPath
        for child in children where child.lastPathComponent.hasPrefix(Self.stagingPrefix) {
            if let protectedPath, child.standardizedFileURL.path == URL(fileURLWithPath: protectedPath).standardizedFileURL.path {
                continue
            }
            try? FileManager.default.removeItem(at: child)
        }
    }

    // MARK: - Resume Token Persistence

    private static func saveResumeToken(_ token: ResumeToken, to url: URL) {
        guard let data = try? JSONEncoder().encode(token) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? LocalPrivateFileWriter.write(data: data, to: url, maximumBytes: 512_000, createOnly: false)
    }

    private static func loadResumeToken(at url: URL) -> ResumeToken? {
        guard let data = try? LocalStateFile.read(url, maximumBytes: 512_000) else { return nil }
        return try? JSONDecoder().decode(ResumeToken.self, from: data)
    }

    // MARK: - Sanitization & Heuristics

    private static func sanitizeSourceText(_ text: String, maxBytes: Int) -> String {
        let lines = text
            .replacingOccurrences(of: "\0", with: "")
            .components(separatedBy: .newlines)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return false }
                return !PIIScan.containsHighRiskPII(trimmed)
            }
        let joined = lines.joined(separator: "\n")
        return GeneratedKnowledgeVault.boundedUTF8(joined, limit: maxBytes)
    }

    static func inferAttributionRole(path: String, title: String, text: String) -> SourceAttributionRole {
        let lowerPath = path.lowercased()
        let lowerTitle = title.lowercased()
        let lowerText = text.lowercased()
        if lowerPath.hasPrefix("relay-live://imessage")
            || lowerPath.hasPrefix("relay-live://whatsapp")
            || lowerPath.contains("chat.db")
            || lowerPath.contains("whatsapp")
            || lowerTitle.contains("group") {
            let isGroup = lowerTitle.contains("group")
                || lowerText.contains("participants:")
                || lowerText.contains(" · group")
                || lowerText.contains("(group)")
            return isGroup ? .groupThread : .directCorrespondence
        }
        if lowerPath.hasPrefix("relay-live://apple_mail")
            || lowerPath.hasSuffix(".eml")
            || lowerPath.hasSuffix(".emlx")
            || lowerPath.contains("/mail/") {
            return .directCorrespondence
        }
        if lowerPath.hasSuffix(".ics") || lowerTitle.contains("calendar") {
            return .calendarAgenda
        }
        if lowerPath.contains("/downloads/") || lowerPath.hasSuffix(".pdf") || lowerPath.contains("safari") {
            return .externalReference
        }
        return .userAuthored
    }

    public static func sanitizeNoteTitle(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|#[]\n\r\t\0")
        let cleaned = raw
            .components(separatedBy: invalid)
            .joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return String(cleaned.prefix(64)).trimmingCharacters(in: .whitespaces)
    }

    private static func sanitizeFactLine(_ raw: String) -> String {
        let singleLine = raw
            .replacingOccurrences(of: "\0", with: "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !PIIScan.containsHighRiskPII(singleLine) else { return "" }
        return GeneratedKnowledgeVault.boundedUTF8(singleLine, limit: 600)
    }

    internal static func extractJSONObject(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstBrace = trimmed.firstIndex(of: "{"),
              let lastBrace = trimmed.lastIndex(of: "}"),
              firstBrace <= lastBrace else { return nil }
        return String(trimmed[firstBrace...lastBrace])
    }
}
