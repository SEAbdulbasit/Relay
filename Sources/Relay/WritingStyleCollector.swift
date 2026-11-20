import CryptoKit
import Darwin
import Foundation
import Observation
import SQLite3

/// One-time sent-message writing style snapshot collector and guardian (`DTP-04`, `DTP-05`).
///
/// Builds `KnowledgeVault/writingstyle.md` at most ONCE from explicitly opted-in 1:1 outgoing
/// messages/emails. Never overwrites an existing file (even if edited to empty by the user),
/// never silently truncates oversized user edits, never publishes an empty/partial blocker when
/// sources fail or scope drifts, and preserves `writingstyle.md` across atomic vault swaps.
@Observable @MainActor
public final class WritingStyleCollector {
    public static let shared = WritingStyleCollector()
    public static let fileName = "writingstyle.md"
    public static let maximumBytes = 48_000

    public enum Medium: String, Codable, Sendable, CaseIterable, Equatable {
        case iMessage = "iMessage"
        case whatsApp = "WhatsApp"
        case email = "email"
    }

    public struct OutgoingSample: Codable, Sendable, Equatable, Identifiable {
        public let id: String
        public let sourceID: String
        public let medium: Medium
        public let recipient: String
        public let recipientCount: Int
        public let isOutgoing: Bool
        public let isGroupThread: Bool
        public let text: String
        public let sentAt: Date?

        public init(
            id: String,
            sourceID: String,
            medium: Medium,
            recipient: String,
            recipientCount: Int = 1,
            isOutgoing: Bool = true,
            isGroupThread: Bool = false,
            text: String,
            sentAt: Date? = nil
        ) {
            self.id = id
            self.sourceID = sourceID
            self.medium = medium
            self.recipient = recipient
            self.recipientCount = recipientCount
            self.isOutgoing = isOutgoing
            self.isGroupThread = isGroupThread
            self.text = text
            self.sentAt = sentAt
        }
    }

    public enum PublishOutcome: Sendable, Equatable {
        case published(sampleCount: Int, byteCount: Int)
        case alreadyExists
        case noOptedInSources
        case noEligibleSamples
    }

    public enum Failure: LocalizedError, Equatable {
        case busy
        case scopeChanged
        case tooLarge(actualBytes: Int, maximumBytes: Int)
        case unreadable(String)
        case writeFailed(String)

        public var errorDescription: String? {
            switch self {
            case .busy:
                return "Writing style collection is already running. Wait for it to finish and try again."
            case .scopeChanged:
                return "Your selected message or mail sources changed while reading examples. No writing style file was written."
            case .tooLarge(let actual, let maximum):
                return "Your writing style examples (\(actual) bytes) exceed the \(maximum)-byte ceiling. Shorten `writingstyle.md` manually; Relay never truncates your samples silently."
            case .unreadable(let detail):
                return "Could not safely read `writingstyle.md`: \(detail)"
            case .writeFailed(let detail):
                return "Could not save `writingstyle.md`: \(detail)"
            }
        }
    }

    public private(set) var isCollecting = false
    public private(set) var status = "Writing style examples have not been collected yet."
    public private(set) var lastOutcome: PublishOutcome?
    private var snapshotStateVersion = 0
    @ObservationIgnored private let vaultRootProvider: @MainActor () -> URL
    @ObservationIgnored private var activeTask: Task<PublishOutcome, Error>?

    public init(vaultRoot: URL? = nil) {
        if let vaultRoot {
            self.vaultRootProvider = { vaultRoot }
        } else {
            self.vaultRootProvider = { KnowledgeVaultManager.shared.vaultDirectory }
        }
        refreshStatus()
    }

    public var vaultRoot: URL { vaultRootProvider() }
    public var writingStyleURL: URL { Self.fileURL(in: vaultRoot) }
    public var hasSnapshot: Bool {
        _ = snapshotStateVersion
        guard Self.exists(in: vaultRoot) else { return false }
        if let snapshot = try? Self.readSnapshot(in: vaultRoot) {
            return !snapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    /// Loads the user-owned `writingstyle.md` contents for editing, returning `""` when no file exists yet.
    public func loadEditableSnapshot() throws -> String {
        try Self.readSnapshot(in: vaultRoot) ?? ""
    }

    /// Saves explicit user edits to `writingstyle.md` without silent truncation and refreshes observable snapshot state.
    public func saveEditableSnapshot(_ content: String) throws {
        try Self.saveUserEditedSnapshot(content, in: vaultRoot)
        refreshStatus()
    }

    public func refreshStatus() {
        snapshotStateVersion &+= 1
        let root = vaultRoot
        guard Self.exists(in: root) else {
            status = "No `writingstyle.md` snapshot yet. Opt into 1:1 sent messages or create one manually."
            return
        }
        do {
            if let snapshot = try Self.readSnapshot(in: root) {
                if snapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    status = "`writingstyle.md` is present (currently empty — your edits are preserved)."
                } else {
                    status = "`writingstyle.md` is ready (\(snapshot.utf8.count) bytes, editable, never overwritten automatically)."
                }
            }
        } catch {
            status = error.localizedDescription
        }
    }

    public func cancelAndDrain() async {
        activeTask?.cancel()
        _ = try? await activeTask?.value
        activeTask = nil
        isCollecting = false
    }

    /// Sentient 3.1 lifecycle teardown entry point (`System/Uninstall.swift` / Reset).
    /// Cancels any in-flight `writingstyle.md` setup task and awaits drain so no late file write lands after reset.
    public func cancelSetupAndDrain() async {
        await cancelAndDrain()
    }

    /// Collects 1:1 outgoing examples from opted-in sources and publishes `writingstyle.md` ONCE.
    /// - Never overwrites an existing `writingstyle.md`.
    /// - Never writes an empty or partial file if scope drifts, collection fails, or zero 1:1 samples match.
    @discardableResult
    public func collectOnceIfNeeded(
        optedInSources: Set<String>,
        maxPerMedium: Int = 15,
        currentScopeToken: @escaping () -> String,
        fetchSamples: @escaping () async throws -> [OutgoingSample]
    ) async throws -> PublishOutcome {
        guard !isCollecting, activeTask == nil else { throw Failure.busy }
        let root = vaultRoot
        if Self.exists(in: root) {
            let outcome = PublishOutcome.alreadyExists
            lastOutcome = outcome
            refreshStatus()
            return outcome
        }
        guard !optedInSources.isEmpty else {
            let outcome = PublishOutcome.noOptedInSources
            lastOutcome = outcome
            status = "Select an opted-in 1:1 message or email source to collect writing examples."
            return outcome
        }

        let initialScope = currentScopeToken()
        isCollecting = true
        status = "Reading opted-in 1:1 sent messages on this Mac…"
        let task = Task { @MainActor () -> PublishOutcome in
            try Task.checkCancellation()
            let rawSamples = try await fetchSamples()
            try Task.checkCancellation()
            guard currentScopeToken() == initialScope else {
                throw Failure.scopeChanged
            }
            if Self.exists(in: root) {
                return .alreadyExists
            }
            let eligible = Self.filterEligibleSamples(
                rawSamples,
                optedInSources: optedInSources,
                maxPerMedium: maxPerMedium
            )
            guard !eligible.isEmpty else {
                return .noEligibleSamples
            }
            let rendered = Self.render(eligible)
            let byteCount = rendered.utf8.count
            guard byteCount <= Self.maximumBytes else {
                throw Failure.tooLarge(actualBytes: byteCount, maximumBytes: Self.maximumBytes)
            }
            guard currentScopeToken() == initialScope else {
                throw Failure.scopeChanged
            }
            let didCreate = try Self.publishExclusively(rendered, in: root)
            return didCreate ? .published(sampleCount: eligible.count, byteCount: byteCount) : .alreadyExists
        }
        activeTask = task
        defer {
            activeTask = nil
            isCollecting = false
        }

        do {
            let outcome = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            lastOutcome = outcome
            switch outcome {
            case .published(let count, let bytes):
                snapshotStateVersion &+= 1
                status = "Saved \(count) one-time writing \(count == 1 ? "example" : "examples") (\(bytes) bytes) to `writingstyle.md`."
            case .alreadyExists:
                refreshStatus()
            case .noOptedInSources:
                status = "No opted-in sent-message sources selected."
            case .noEligibleSamples:
                status = "No eligible 1:1 outgoing messages were found yet; `writingstyle.md` was left unwritten so you can retry later."
            }
            return outcome
        } catch is CancellationError {
            status = "Writing style collection stopped. Nothing was written."
            throw CancellationError()
        } catch {
            status = error.localizedDescription
            throw error
        }
    }

    /// Convenience bridge to `LiveLocalSourcesCoordinator` (`store.nativeSources.liveSources`).
    /// Collects one-time 1:1 outgoing samples across opted-in iMessage, WhatsApp, and Apple Mail.
    @discardableResult
    func collectOnceFromLiveSources(
        _ liveSources: LiveLocalSourcesCoordinator,
        extraEmailSamples: [OutgoingSample] = []
    ) async throws -> PublishOutcome {
        let messagingSources: Set<LiveLocalSourceKind> = [.imessage, .whatsapp, .appleMail]
        var optedIn = Set(liveSources.enabledSources.intersection(messagingSources).map(\.rawValue))
        for extra in extraEmailSamples {
            optedIn.insert(extra.sourceID)
        }
        let scopeSnapshot = { @MainActor () -> String in
            let enabled = liveSources.enabledSources.map(\.rawValue).sorted().joined(separator: ",")
            let im = liveSources.selectedIMessageChatGUIDs.sorted().joined(separator: ",")
            let wa = liveSources.selectedWhatsAppChatJIDs.sorted().joined(separator: ",")
            let mail = liveSources.selectedMailAccountIDs.sorted().joined(separator: ",")
            return "\(enabled)|\(im)|\(wa)|\(mail)"
        }
        return try await collectOnceIfNeeded(
            optedInSources: optedIn,
            maxPerMedium: 15,
            currentScopeToken: scopeSnapshot,
            fetchSamples: { @MainActor in
                let rawLive = await liveSources.collectWritingSamples()
                let mapped: [OutgoingSample] = rawLive.enumerated().compactMap { idx, item in
                    let medium: Medium
                    switch item.source {
                    case .imessage: medium = .iMessage
                    case .whatsapp: medium = .whatsApp
                    case .appleMail: medium = .email
                    case .notes: return nil
                    }
                    return OutgoingSample(
                        id: "\(item.source.rawValue)-\(idx)-\(item.sentAt?.timeIntervalSince1970 ?? 0)",
                        sourceID: item.source.rawValue,
                        medium: medium,
                        recipient: item.recipient,
                        recipientCount: 1,
                        isOutgoing: true,
                        isGroupThread: false,
                        text: item.text,
                        sentAt: item.sentAt
                    )
                }
                return mapped + extraEmailSamples
            }
        )
    }

    // MARK: - File Operations & Vault Swap Preservation

    public static func fileURL(in vaultRoot: URL) -> URL {
        vaultRoot.standardizedFileURL.appendingPathComponent(fileName, isDirectory: false)
    }

    public static func exists(in vaultRoot: URL) -> Bool {
        let url = fileURL(in: vaultRoot)
        var metadata = stat()
        guard url.path.withCString({ lstat($0, &metadata) }) == 0 else { return false }
        let mode = metadata.st_mode & S_IFMT
        return mode == S_IFREG
    }

    /// Reads the exact user-owned `writingstyle.md` without silent truncation (`DTP-05`).
    /// Returns `nil` when absent, `""` when intentionally emptied by the user, or throws `Failure`
    /// if unreadable, symlinked, or larger than `maximumBytes`.
    public static func readSnapshot(
        in vaultRoot: URL,
        maximumBytes: Int = maximumBytes
    ) throws -> String? {
        let url = fileURL(in: vaultRoot)
        var metadata = stat()
        if url.path.withCString({ lstat($0, &metadata) }) != 0 {
            if errno == ENOENT { return nil }
            throw Failure.unreadable("file metadata could not be inspected")
        }
        let kind = metadata.st_mode & S_IFMT
        guard kind == S_IFREG else {
            throw Failure.unreadable("writingstyle.md must be a regular local file")
        }
        guard metadata.st_nlink == 1 else {
            throw Failure.unreadable("writingstyle.md cannot have multiple hard links")
        }
        guard metadata.st_size >= 0 else {
            throw Failure.unreadable("invalid file size")
        }
        if metadata.st_size > maximumBytes {
            throw Failure.tooLarge(actualBytes: Int(metadata.st_size), maximumBytes: maximumBytes)
        }
        let data: Data
        do {
            data = try LocalStateFile.read(url, maximumBytes: max(1, maximumBytes))
        } catch LocalStateFileError.sizeLimitExceeded {
            throw Failure.tooLarge(actualBytes: Int(metadata.st_size), maximumBytes: maximumBytes)
        } catch {
            if metadata.st_size == 0 {
                return ""
            }
            throw Failure.unreadable(error.localizedDescription)
        }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            throw Failure.unreadable("writingstyle.md is not valid UTF-8 text")
        }
        return text
    }

    /// Saves explicit user edits to `writingstyle.md` (Settings / Magic Reply editor).
    /// Reports `Failure.tooLarge` rather than truncating user text (`DTP-05`).
    public static func saveUserEditedSnapshot(
        _ content: String,
        in vaultRoot: URL,
        maximumBytes: Int = maximumBytes
    ) throws {
        guard !content.contains("\0") else {
            throw Failure.unreadable("writingstyle.md cannot contain null bytes")
        }
        let bytes = Data(content.utf8)
        guard bytes.count <= maximumBytes else {
            throw Failure.tooLarge(actualBytes: bytes.count, maximumBytes: maximumBytes)
        }
        let root = vaultRoot.standardizedFileURL
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let destination = fileURL(in: root)
        do {
            try LocalPrivateFileWriter.write(
                data: bytes,
                to: destination,
                maximumBytes: maximumBytes,
                createOnly: false
            )
        } catch {
            throw Failure.writeFailed(error.localizedDescription)
        }
    }

    /// Formats a bounded prompt block from `writingstyle.md` for Magic Reply / Proactive drafting
    /// without mutating or silently ignoring file-level corruption/size errors.
    /// When `maxPromptBytes` is smaller than a valid file, whole sample entries are included so no
    /// sentence is cut mid-thought.
    public static func promptExamplesBlock(
        in vaultRoot: URL,
        maxPromptBytes: Int = 12_000
    ) throws -> String? {
        guard let raw = try readSnapshot(in: vaultRoot) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.utf8.count <= maxPromptBytes {
            return trimmed
        }
        let blocks = trimmed.components(separatedBy: "\n\n")
        var selected: [String] = []
        var used = 0
        for block in blocks {
            let cost = block.utf8.count + (selected.isEmpty ? 0 : 2)
            if !selected.isEmpty && used + cost > maxPromptBytes { break }
            if selected.isEmpty && cost > maxPromptBytes {
                return GeneratedKnowledgeVault.boundedUTF8(block, limit: maxPromptBytes)
            }
            selected.append(block)
            used += cost
        }
        return selected.isEmpty ? nil : selected.joined(separator: "\n\n")
    }

    /// Exclusive atomic link (`link(2)`): creates `writingstyle.md` iff it does not already exist.
    /// Returns `true` if this call created `writingstyle.md`, `false` if one already existed.
    @discardableResult
    public static func publishExclusively(
        _ content: String,
        in vaultRoot: URL,
        maximumBytes: Int = maximumBytes
    ) throws -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !content.contains("\0") else {
            throw Failure.unreadable("writing samples contained invalid null bytes")
        }
        let data = Data(content.utf8)
        guard data.count <= maximumBytes else {
            throw Failure.tooLarge(actualBytes: data.count, maximumBytes: maximumBytes)
        }
        let fm = FileManager.default
        let root = vaultRoot.standardizedFileURL
        try fm.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if exists(in: root) { return false }

        let tempURL = root.appendingPathComponent(".writingstyle-tmp-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tempURL) }
        guard fm.createFile(
            atPath: tempURL.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw Failure.writeFailed("could not stage temporary writing samples")
        }
        let destination = fileURL(in: root)
        if Darwin.link(tempURL.path, destination.path) == 0 {
            return true
        }
        if errno == EEXIST, exists(in: root) {
            return false
        }
        throw Failure.writeFailed(String(cString: strerror(errno)))
    }

    /// Preserves the live `writingstyle.md` into `staging` before any atomic vault swap,
    /// discarding any staged `writingstyle.md` a model might have attempted to write.
    public static func preserve(in staging: URL, from liveVault: URL) throws {
        let fm = FileManager.default
        let stagedFile = fileURL(in: staging)
        var stagedStat = stat()
        if stagedFile.path.withCString({ lstat($0, &stagedStat) }) == 0 {
            try fm.removeItem(at: stagedFile)
        }
        if exists(in: liveVault) {
            let liveFile = fileURL(in: liveVault)
            try fm.copyItem(at: liveFile, to: stagedFile)
        }
    }

    // MARK: - Deterministic 1:1 Outgoing Sample Filtering & Rendering

    public static func filterEligibleSamples(
        _ candidates: [OutgoingSample],
        optedInSources: Set<String>,
        maxPerMedium: Int = 15
    ) -> [OutgoingSample] {
        guard !optedInSources.isEmpty, maxPerMedium > 0 else { return [] }
        let valid = candidates.filter { sample in
            guard optedInSources.contains(sample.sourceID),
                  sample.isOutgoing,
                  !sample.isGroupThread,
                  sample.recipientCount == 1 else { return false }
            let cleanRecipient = sample.recipient.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanText = sample.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanRecipient.isEmpty,
                  !cleanRecipient.contains(where: \.isNewline),
                  !isAutomatedRecipient(cleanRecipient),
                  !cleanText.isEmpty,
                  !cleanText.contains("\0"),
                  cleanText.utf8.count <= 4_000,
                  !PIIScan.containsHighRiskPII(cleanText),
                  !containsSecretToken(cleanText) else { return false }
            return true
        }

        var result: [OutgoingSample] = []
        for medium in Medium.allCases {
            let bucket = valid
                .filter { $0.medium == medium }
                .sorted { lhs, rhs in
                    switch (lhs.sentAt, rhs.sentAt) {
                    case let (l?, r?) where l != r:
                        return l > r
                    case (_?, nil):
                        return true
                    case (nil, _?):
                        return false
                    default:
                        return (lhs.sourceID + "\0" + lhs.id) < (rhs.sourceID + "\0" + rhs.id)
                    }
                }
            var seenIDs = Set<String>()
            var countByBucket: [String: Int] = [:]
            for item in bucket {
                let dedupeKey = item.sourceID + "\0" + item.id
                guard seenIDs.insert(dedupeKey).inserted else { continue }
                let capKey = (medium == .email) ? item.sourceID : medium.rawValue
                let used = countByBucket[capKey, default: 0]
                guard used < maxPerMedium else { continue }
                countByBucket[capKey] = used + 1
                result.append(item)
            }
        }
        return result
    }

    public static func render(_ samples: [OutgoingSample]) -> String {
        samples.map { sample in
            let recipient = sample.recipient
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .newlines)
                .joined(separator: " ")
            let text = sample.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return "To \(recipient) (\(sample.medium.rawValue))\n\(text)"
        }.joined(separator: "\n\n")
    }

    // MARK: - Local SQLite & EML 1:1 Outgoing Readers

    /// Reads 1:1 outgoing iMessage/SMS samples (`is_from_me = 1`, single-participant non-group chats)
    /// from an explicitly chosen/authorized `chat.db` or standalone Messages archive.
    public static func extractFromMessagesDatabase(
        at dbURL: URL,
        sourceID: String = "imessage",
        allowedChatIdentifiers: Set<String>? = nil,
        contactNames: [String: String] = [:],
        limit: Int = 15
    ) throws -> [OutgoingSample] {
        guard limit > 0 else { return [] }
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(dbURL.path, &db, flags, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw Failure.unreadable("Messages database could not be opened read-only")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1_500)

        let hasAttributedBody: Bool = {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "PRAGMA main.table_xinfo('message')", -1, &stmt, nil) == SQLITE_OK else { return false }
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let ptr = sqlite3_column_text(stmt, 1),
                   String(cString: ptr).lowercased() == "attributedbody" {
                    return true
                }
            }
            return false
        }()

        let attrColumn = hasAttributedBody ? "m.attributedBody" : "NULL"
        let sql = """
            SELECT m.guid,
                   c.chat_identifier,
                   COALESCE(NULLIF(c.display_name, ''), h.id, c.chat_identifier),
                   c.style,
                   (SELECT COUNT(*) FROM chat_handle_join chj WHERE chj.chat_id = c.ROWID) AS participant_count,
                   m.text,
                   \(attrColumn),
                   CASE WHEN abs(m.date) > 100000000000 THEN m.date / 1000000000 ELSE m.date END AS msg_ts
              FROM message m
              JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
              JOIN chat c ON c.ROWID = cmj.chat_id
              LEFT JOIN chat_handle_join chj1 ON chj1.chat_id = c.ROWID
              LEFT JOIN handle h ON h.ROWID = chj1.handle_id
             WHERE m.is_from_me = 1
               AND COALESCE(m.associated_message_type, 0) = 0
             ORDER BY msg_ts DESC, m.ROWID DESC
             LIMIT \(min(max(limit * 6, 30), 400));
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw Failure.unreadable("Messages schema was not recognized")
        }
        defer { sqlite3_finalize(stmt) }

        let appleEpoch: TimeInterval = 978_307_200
        var samples: [OutgoingSample] = []
        var seenMessageGUIDs = Set<String>()

        while sqlite3_step(stmt) == SQLITE_ROW {
            let guid = columnString(stmt, 0) ?? UUID().uuidString
            guard seenMessageGUIDs.insert(guid).inserted else { continue }
            let chatIdentifier = columnString(stmt, 1) ?? ""
            if let allowed = allowedChatIdentifiers, !allowed.contains(chatIdentifier) {
                continue
            }
            let rawRecipient = columnString(stmt, 2) ?? chatIdentifier
            let style = sqlite3_column_int(stmt, 3)
            let participantCount = Int(sqlite3_column_int(stmt, 4))
            let isGroup = (style == 43) || participantCount > 1 || chatIdentifier.hasPrefix("chat")

            var body = columnString(stmt, 5)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if body.isEmpty, sqlite3_column_type(stmt, 6) == SQLITE_BLOB {
                let byteCount = Int(sqlite3_column_bytes(stmt, 6))
                if (1...MessagesAttributedBody.maximumArchiveBytes).contains(byteCount),
                   let rawBytes = sqlite3_column_blob(stmt, 6) {
                    body = MessagesAttributedBody.decode(Data(bytes: rawBytes, count: byteCount))?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                }
            }
            guard !body.isEmpty else { continue }
            let ts = sqlite3_column_int64(stmt, 7)
            let sentDate = ts > 0 ? Date(timeIntervalSince1970: appleEpoch + TimeInterval(ts)) : nil
            let resolvedRecipient = contactNames[rawRecipient] ?? rawRecipient

            samples.append(OutgoingSample(
                id: guid,
                sourceID: sourceID,
                medium: .iMessage,
                recipient: resolvedRecipient,
                recipientCount: max(1, participantCount),
                isOutgoing: true,
                isGroupThread: isGroup,
                text: body,
                sentAt: sentDate
            ))
            if samples.count >= limit * 2 { break }
        }
        return filterEligibleSamples(samples, optedInSources: [sourceID], maxPerMedium: limit)
    }

    /// Reads 1:1 outgoing WhatsApp samples (`ZISFROMME = 1`, `@s.whatsapp.net` non-group JIDs)
    /// from an explicitly authorized `ChatStorage.sqlite`.
    public static func extractFromWhatsAppDatabase(
        at dbURL: URL,
        sourceID: String = "whatsapp",
        allowedJIDs: Set<String>? = nil,
        limit: Int = 15
    ) throws -> [OutgoingSample] {
        guard limit > 0 else { return [] }
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(dbURL.path, &db, flags, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw Failure.unreadable("WhatsApp database could not be opened read-only")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1_500)

        let sql = """
            SELECT m.ZSTANZAID,
                   cs.ZCONTACTJID,
                   COALESCE(NULLIF(cs.ZPARTNERNAME, ''), cs.ZCONTACTJID),
                   COALESCE(cs.ZSESSIONTYPE, 0),
                   m.ZTEXT,
                   m.ZMESSAGEDATE
              FROM ZWAMESSAGE m
              JOIN ZWACHATSESSION cs ON cs.Z_PK = m.ZCHATSESSION
             WHERE m.ZISFROMME = 1
               AND m.ZTEXT IS NOT NULL
               AND length(m.ZTEXT) > 0
             ORDER BY m.ZMESSAGEDATE DESC, m.Z_PK DESC
             LIMIT \(min(max(limit * 6, 30), 400));
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw Failure.unreadable("WhatsApp schema was not recognized")
        }
        defer { sqlite3_finalize(stmt) }

        let appleEpoch: TimeInterval = 978_307_200
        var samples: [OutgoingSample] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let stanzaID = columnString(stmt, 0) ?? UUID().uuidString
            let jid = columnString(stmt, 1) ?? ""
            if let allowed = allowedJIDs, !allowed.contains(jid) { continue }
            let partnerName = columnString(stmt, 2) ?? jid
            let sessionType = sqlite3_column_int(stmt, 3)
            let isGroup = sessionType != 0 || jid.contains("@g.us") || jid.contains("@broadcast") || jid.contains("@newsletter")
            guard let text = columnString(stmt, 4)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { continue }
            let rawDate = sqlite3_column_double(stmt, 5)
            let sentAt = rawDate > 0 ? Date(timeIntervalSince1970: appleEpoch + rawDate) : nil
            samples.append(OutgoingSample(
                id: stanzaID,
                sourceID: sourceID,
                medium: .whatsApp,
                recipient: partnerName,
                recipientCount: isGroup ? 2 : 1,
                isOutgoing: true,
                isGroupThread: isGroup,
                text: text,
                sentAt: sentAt
            ))
            if samples.count >= limit * 2 { break }
        }
        return filterEligibleSamples(samples, optedInSources: [sourceID], maxPerMedium: limit)
    }

    /// Reads 1:1 outgoing sent email samples from `.eml` / `.emlx` files inside an explicitly
    /// authorized Sent mailbox directory (single `To:` recipient, empty `Cc:`/`Bcc:`, stripping quoted replies).
    public static func extractFromSentMailDirectory(
        at directoryURL: URL,
        sourceID: String = "apple-mail",
        limit: Int = 15
    ) throws -> [OutgoingSample] {
        guard limit > 0 else { return [] }
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var candidateFiles: [(url: URL, modified: Date)] = []
        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            guard ext == "eml" || ext == "emlx" else { continue }
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else { continue }
            candidateFiles.append((fileURL, values.contentModificationDate ?? .distantPast))
        }
        candidateFiles.sort { $0.modified > $1.modified }

        var samples: [OutgoingSample] = []
        for entry in candidateFiles.prefix(max(limit * 4, 30)) {
            guard let rawData = try? LocalStateFile.read(entry.url, maximumBytes: 256_000),
                  let rawText = String(data: rawData, encoding: .utf8) ?? String(data: rawData, encoding: .isoLatin1) else {
                continue
            }
            if let parsed = parseSentEML(rawText, defaultID: entry.url.lastPathComponent, sourceID: sourceID, fallbackDate: entry.modified) {
                samples.append(parsed)
                if samples.count >= limit * 2 { break }
            }
        }
        return filterEligibleSamples(samples, optedInSources: [sourceID], maxPerMedium: limit)
    }

    // MARK: - Private Helpers

    private static func parseSentEML(
        _ rawText: String,
        defaultID: String,
        sourceID: String,
        fallbackDate: Date?
    ) -> OutgoingSample? {
        var payload = rawText.replacingOccurrences(of: "\r\n", with: "\n")
        // Apple Mail `.emlx` starts with an ASCII byte count line before RFC822 headers.
        if let firstNewline = payload.firstIndex(of: "\n") {
            let firstLine = payload[..<firstNewline].trimmingCharacters(in: .whitespaces)
            if !firstLine.isEmpty, firstLine.allSatisfy(\.isNumber) {
                payload = String(payload[payload.index(after: firstNewline)...])
            }
        }
        guard let splitRange = payload.range(of: "\n\n") else { return nil }
        let headerSection = String(payload[..<splitRange.lowerBound])
        var bodySection = String(payload[splitRange.upperBound...])
        if let plistMarker = bodySection.range(of: "<?xml version=\"1.0\" encoding=\"UTF-8\"?>") {
            bodySection = String(bodySection[..<plistMarker.lowerBound])
        }

        var headers: [String: String] = [:]
        var currentKey: String?
        for line in headerSection.components(separatedBy: "\n") {
            if let first = line.first, (first == " " || first == "\t"), let key = currentKey {
                headers[key, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let val = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                currentKey = key
                headers[key] = val
            }
        }

        if MailIngestion.MIMEFilter.isExcluded(headers: headers) { return nil }
        let cc = headers["cc", default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        let bcc = headers["bcc", default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        guard cc.isEmpty, bcc.isEmpty else { return nil }

        let toField = headers["to", default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !toField.isEmpty else { return nil }
        let recipients = toField.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard recipients.count == 1, let singleRecipient = recipients.first else { return nil }

        let unquotedLines = bodySection
            .components(separatedBy: "\n")
            .prefix { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("-----Original Message-----") { return false }
                if trimmed.hasPrefix("On ") && trimmed.hasSuffix("wrote:") { return false }
                return true
            }
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }
        let cleanedBody = unquotedLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedBody.isEmpty else { return nil }

        let messageID = headers["message-id"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? defaultID
        return OutgoingSample(
            id: messageID,
            sourceID: sourceID,
            medium: .email,
            recipient: singleRecipient,
            recipientCount: 1,
            isOutgoing: true,
            isGroupThread: false,
            text: cleanedBody,
            sentAt: fallbackDate
        )
    }

    private static func columnString(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let ptr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: ptr)
    }

    private static func isAutomatedRecipient(_ recipient: String) -> Bool {
        let lower = recipient.lowercased()
        let blockedTokens = ["noreply", "no-reply", "donotreply", "do-not-reply", "mailer-daemon", "postmaster@"]
        return blockedTokens.contains { lower.contains($0) }
    }

    private static let secretRegex = try? NSRegularExpression(
        pattern: #"(?i)(?<![a-z0-9_])(?:sk-(?:proj-|svcacct-)?[a-z0-9_-]{16,}|ghp_[a-z0-9]{20,}|github_pat_[a-z0-9_]{20,}|xox[baprs]-[a-z0-9-]{16,})(?![a-z0-9_])"#
    )

    private static func containsSecretToken(_ text: String) -> Bool {
        let lower = text.lowercased()
        if ["-----begin ", "private key", "recovery phrase", "api_key=", "bearer eyj"].contains(where: lower.contains) {
            return true
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return secretRegex?.firstMatch(in: text, range: range) != nil
    }
}
