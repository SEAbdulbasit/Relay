import Foundation
import Observation
import CryptoKit

nonisolated struct Suggestion: Identifiable, Sendable {
    let id: String
    let title: String
    let reason: String
    let sourcePaths: [String]
    let excerpt: String
    let sourceContentHash: String
    let createdAt: Date
    let dueDay: String?
    let copyID: String?
    var matchingSourcePaths: [String]
    var dismissed: Bool
}

/// Deterministic high-risk PII backstop (Sentient OS pattern) that blocks Social Security
/// Numbers, Luhn-validated 13–19 digit payment card numbers, and passport identifiers from
/// surfacing in proactive suggestions or unredacted summaries.
nonisolated enum PIIScan {
    private static let ssnRegex = try? NSRegularExpression(
        pattern: #"\b(?!000|666|9\d\d)\d{3}[-\s](?!00)\d{2}[-\s](?!0000)\d{4}\b"#
    )
    private static let cardCandidateRegex = try? NSRegularExpression(
        pattern: #"\b(?:\d[ -]*?){13,19}\b"#
    )
    private static let passportRegex = try? NSRegularExpression(
        pattern: #"(?i)\bpassport(?:\s*(?:no\.?|number|#))?[:\s#]+[A-Z0-9]{6,9}\b"#
    )

    static func containsHighRiskPII(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        if ssnRegex?.firstMatch(in: text, range: range) != nil { return true }
        if passportRegex?.firstMatch(in: text, range: range) != nil { return true }
        if let matches = cardCandidateRegex?.matches(in: text, range: range) {
            for match in matches {
                guard let swiftRange = Range(match.range, in: text) else { continue }
                let digits = text[swiftRange].compactMap(\.wholeNumberValue)
                if (13...19).contains(digits.count) && passesLuhn(digits) {
                    return true
                }
            }
        }
        return false
    }

    static func passesLuhn(_ digits: [Int]) -> Bool {
        guard (13...19).contains(digits.count), digits.contains(where: { $0 != 0 }) else { return false }
        var sum = 0
        for (index, digit) in digits.reversed().enumerated() {
            if index % 2 == 1 {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
        }
        return sum % 10 == 0
    }
}

/// Builds reviewable TODO cards from scope-checked index records and retains optional local drafts.
@Observable @MainActor
final class ProactiveSuggestions {
    private(set) var enabled = false
    private(set) var suggestions: [Suggestion] = []
    private(set) var scheduledDraftsEnabled = false
    var preparedDrafts: [Suggestion.ID: String] {
        var visible: [Suggestion.ID: String] = [:]
        for card in suggestions where !card.dismissed {
            visible[card.id] = savedDrafts[card.id]?.text
        }
        return visible
    }
    private(set) var status = "Suggestions are off. Nothing is watched or prepared automatically."
    private(set) var errorMessage: String?
    @ObservationIgnored private let persistenceURL: URL?
    @ObservationIgnored private var dismissedIDs: [String] = []
    private var snoozes: [Snooze] = []
    private var savedDrafts: [Suggestion.ID: PreparedDraft] = [:]
    var snoozedCount: Int { snoozes.count }

    static var defaultPersistenceURL: URL {
        URL.applicationSupportDirectory.appending(path: "Relay", directoryHint: .isDirectory).appending(path: "suggestion-preferences.json")
    }

    init(persistenceURL: URL? = ProactiveSuggestions.defaultPersistenceURL) {
        self.persistenceURL = persistenceURL
        restore()
    }

    func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        enabled = value
        suggestions = []
        savedDrafts = [:]
        status = value ? "Ready for a manual brief from selected indexed sources. Nothing runs automatically." : "Suggestions are off. Nothing is watched or prepared automatically."
        persist()
    }

    func setScheduledDraftsEnabled(_ value: Bool) {
        guard scheduledDraftsEnabled != value else { return }
        scheduledDraftsEnabled = value
        if !value { savedDrafts = [:] }
        persist()
    }

    @discardableResult
    func publishScheduledDraft(_ draft: String, for id: Suggestion.ID, now: Date = Date()) -> Bool {
        let draft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard enabled, scheduledDraftsEnabled, Self.validDate(now), Self.validDraftText(draft),
              savedDrafts[id] != nil || savedDrafts.count < 2,
              let card = suggestions.first(where: { $0.id == id && !$0.dismissed }),
              Self.isRecent(card.createdAt, now: now) else { return false }
        savedDrafts[id] = PreparedDraft(text: draft, createdAt: now)
        persist()
        return true
    }

    /// The owner supplies revalidated, authorized records after launch. Saved draft text
    /// stays hidden until the exact source hash and action are represented by a current card.
    func restorePreparedDrafts(records: [KnowledgeRecord], now: Date = Date()) {
        guard enabled, scheduledDraftsEnabled, !savedDrafts.isEmpty else { return }
        prepare(records: records, now: now)
    }

    func retainPreparedDrafts(for ids: Set<Suggestion.ID>) {
        if pruneDrafts(visibleIDs: ids) { persist() }
    }

    /// Each explicit run replaces the prior brief. Missing/revoked and changed sources cannot
    /// retain their old suggestions. The caller must supply scope-checked, current records.
    func prepare(records: [KnowledgeRecord], now: Date = Date()) {
        guard enabled else {
            suggestions = []
            status = "Turn on suggestions before preparing a manual brief. Nothing was scanned."
            return
        }
        guard Self.validDate(now) else { errorMessage = "The current date is invalid; no brief was prepared."; return }
        let changedSnoozes = pruneSnoozes(records: records, now: now)
        let hiddenIDs = Set(dismissedIDs + snoozes.flatMap { [$0.id, $0.decisionID] })
        let currentIDs = Set(suggestions.lazy.filter { !$0.dismissed }.map(\.id))
        var groups: [BriefCandidate] = []
        var groupOffsets: [Data: Int] = [:]
        var totalScannedBytes = 0
        var limited = records.count > 100
        for record in records.prefix(100).sorted(by: { $0.sourcePath < $1.sourcePath }) {
            guard Self.validSource(record), totalScannedBytes < 524_288 else { limited = true; continue }
            let canCompareCopies = Self.validDigest(record.contentHash)
            let identityPrefix = canCompareCopies ? "copy\0" + record.contentHash : Self.sourceKey(path: record.sourcePath, hash: record.contentHash)
            let allowance = min(32_768, 524_288 - totalScannedBytes)
            let text = Self.prefix(record.text, bytes: allowance)
            totalScannedBytes += text.utf8.count
            if text.utf8.count < record.text.utf8.count { limited = true }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.count > 300 { limited = true }
            for raw in lines.prefix(300) {
                let line = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
                guard line.utf8.count <= 1_024,
                      let action = Self.explicitAction(line),
                      !action.isEmpty, !PIIScan.containsHighRiskPII(line) else { continue }
                let key = Data((identityPrefix + "\0" + line).utf8)
                if let offset = groupOffsets[key] {
                    if groups[offset].paths.last != record.sourcePath { groups[offset].paths.append(record.sourcePath) }
                } else {
                    groupOffsets[key] = groups.count
                    groups.append(BriefCandidate(paths: [record.sourcePath], line: line, action: action,
                                                 contentHash: record.contentHash, dueDay: Self.explicitDueDay(in: action),
                                                 copyEvidence: canCompareCopies ? key : nil))
                }
            }
        }
        let ordered = groups.enumerated().sorted { left, right in
            switch (left.element.dueDay, right.element.dueDay) {
            case let (earlier?, later?) where earlier != later: return earlier < later
            case (_?, nil): return true
            case (nil, _?): return false
            default: return left.offset < right.offset
            }
        }
        var next: [Suggestion] = []
        for (_, candidate) in ordered {
            guard let card = suggestion(from: candidate, hiding: hiddenIDs, currentIDs: currentIDs, now: now) else { continue }
            if next.count == 40 { limited = true; break }
            next.append(card)
        }
        suggestions = next
        let changedDrafts = pruneDrafts(visibleIDs: Set(next.map(\.id)), now: now)
        status = next.isEmpty ? "No suggestions to show in this brief." : "Prepared \(next.count) local \(next.count == 1 ? "suggestion" : "suggestions"). Review a suggestion before putting it in your draft; nothing was executed."
        if limited { status += " Scan limits applied; this brief is not exhaustive." }
        if !snoozes.isEmpty { status += " \(snoozes.count) \(snoozes.count == 1 ? "suggestion is" : "suggestions are") snoozed until a later brief." }
        if changedSnoozes || changedDrafts { persist() }
    }

    private struct BriefCandidate {
        var paths: [String]
        let line: String
        let action: String
        let contentHash: String
        let dueDay: String?
        let copyEvidence: Data?
    }

    private func suggestion(from candidate: BriefCandidate, hiding hiddenIDs: Set<String>, currentIDs: Set<String>, now: Date) -> Suggestion? {
        let copyID = candidate.copyEvidence.map(Self.digest)
        guard copyID.map({ !hiddenIDs.contains($0) }) ?? true else { return nil }
        let sources = candidate.paths.map { path in
            (path: path, id: Self.identifier(path: path, hash: candidate.contentHash, line: candidate.line))
        }
        guard !sources.contains(where: { hiddenIDs.contains($0.id) }),
              let primary = sources.first(where: { savedDrafts[$0.id] != nil }) ??
                            sources.first(where: { currentIDs.contains($0.id) }) ?? sources.first else { return nil }
        return Suggestion(id: primary.id, title: Self.prefix(candidate.action, bytes: 120),
                          reason: "Explicit action line in \(URL(fileURLWithPath: primary.path).lastPathComponent). Source text is a draft suggestion, not permission to act.",
                          sourcePaths: [primary.path], excerpt: Self.prefix(candidate.line, bytes: 400),
                          sourceContentHash: candidate.contentHash, createdAt: now, dueDay: candidate.dueDay,
                          copyID: copyID, matchingSourcePaths: candidate.paths.filter { $0 != primary.path }, dismissed: false)
    }

    /// Snooze is a review decision only. It hides this source/content identity until the next
    /// explicitly prepared brief after the chosen local date; no timer or action is scheduled.
    @discardableResult
    func snooze(_ id: String, days: Int, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        errorMessage = nil
        guard enabled, (1...7).contains(days), Self.validDate(now),
              let suggestion = suggestions.first(where: { $0.id == id && !$0.dismissed }),
              !dismissedIDs.contains(id), suggestion.sourcePaths.count == 1,
              suggestion.createdAt <= now, now.timeIntervalSince(suggestion.createdAt) < 86_400,
              let until = calendar.date(byAdding: .day, value: days, to: now), Self.validDate(until), until > now,
              until.timeIntervalSince(now) <= 8 * 86_400 else {
            errorMessage = "Choose a current, undismissed suggestion and a snooze from one through seven local days."
            return false
        }
        guard snoozes.contains(where: { $0.id == id }) || snoozes.count < 256 else {
            errorMessage = "The 256-snooze limit is reached. Clear snoozes before adding more."
            return false
        }
        let fingerprint = Self.sourceFingerprint(path: suggestion.sourcePaths[0], hash: suggestion.sourceContentHash)
        snoozes.removeAll { $0.id == id }
        let copy = suggestion.copyID.map { CopiedEvidence(id: $0, contentHash: suggestion.sourceContentHash) }
        snoozes.append(Snooze(id: id, sourceFingerprint: fingerprint, snoozedAt: now, until: until, days: days, copy: copy))
        suggestions.removeAll { $0.id == id }
        savedDrafts.removeValue(forKey: id)
        status = "Suggestion snoozed for \(days) local \(days == 1 ? "day" : "days"). It can return in the next prepared brief after that date. Nothing was scheduled or executed."
        persist()
        return true
    }

    func snoozedUntil(_ id: String, now: Date = Date()) -> Date? {
        guard Self.validDate(now), !dismissedIDs.contains(id) else { return nil }
        return snoozes.first(where: { $0.id == id && !dismissedIDs.contains($0.decisionID) && $0.snoozedAt <= now && $0.until > now })?.until
    }

    func clearSnoozes() {
        snoozes = []
        status = "Snoozes cleared. Current source suggestions can return when you explicitly prepare another brief."
        persist()
    }

    func dismiss(_ id: String) {
        guard !dismissedIDs.contains(id) else { return }
        let index = suggestions.firstIndex(where: { $0.id == id && !$0.dismissed })
        let snooze = snoozes.first { $0.id == id }
        guard index != nil || snooze != nil else { return }
        let decisionID = index.flatMap { suggestions[$0].copyID } ?? snooze?.decisionID ?? id
        if let index { suggestions[index].dismissed = true }
        savedDrafts.removeValue(forKey: id)
        snoozes.removeAll { $0.id == id || $0.decisionID == decisionID }
        if !dismissedIDs.contains(decisionID) { dismissedIDs.append(decisionID) }
        if dismissedIDs.count > 2_000 { dismissedIDs.removeFirst(dismissedIDs.count - 2_000) }
        status = "Suggestion dismissed. Nothing was executed."
        persist()
    }

    /// Explicit freshness housekeeping only; no timer or source access. Draft suggestions
    /// expire after a day, independently of any explicit deadline in the source.
    func purge(records: [KnowledgeRecord], now: Date = Date()) {
        guard Self.validDate(now) else { errorMessage = "The current date is invalid; freshness was not checked."; return }
        let changedSnoozes = pruneSnoozes(records: records, now: now)
        let current = Set(records.prefix(200).filter(Self.validSource).map { Self.sourceKey(path: $0.sourcePath, hash: $0.contentHash) })
        let before = suggestions.count
        suggestions = suggestions.compactMap { suggestion in
            let age = now.timeIntervalSince(suggestion.createdAt)
            guard (0..<86_400).contains(age), let source = suggestion.sourcePaths.first, suggestion.sourcePaths.count == 1,
                  current.contains(Self.sourceKey(path: source, hash: suggestion.sourceContentHash)) else { return nil }
            var fresh = suggestion
            fresh.matchingSourcePaths.removeAll { !current.contains(Self.sourceKey(path: $0, hash: suggestion.sourceContentHash)) }
            return fresh
        }
        let changedDrafts = pruneDrafts(visibleIDs: Set(suggestions.filter { !$0.dismissed }.map(\.id)), now: now)
        if suggestions.count != before || changedSnoozes || changedDrafts { status = "Expired or no-longer-current brief items removed." }
        if changedSnoozes || changedDrafts { persist() }
    }

    /// Clears local suggestions and dismissal history. The opt-in setting remains unchanged.
    func clear() {
        suggestions = []
        savedDrafts = [:]
        dismissedIDs = []
        snoozes = []
        status = "Suggestions, snoozes and dismissal history cleared. Source files are unchanged."
        persist()
    }

    nonisolated private struct Snooze: Codable {
        let id: String
        let sourceFingerprint: String
        let snoozedAt: Date
        let until: Date
        let days: Int
        let copy: CopiedEvidence?
        var decisionID: String { copy?.id ?? id }
    }
    nonisolated private struct CopiedEvidence: Codable {
        let id: String
        let contentHash: String
    }
    nonisolated private struct PreparedDraft: Codable {
        let text: String
        let createdAt: Date
    }

    private func pruneDrafts(visibleIDs: Set<Suggestion.ID>, now: Date = Date()) -> Bool {
        let before = savedDrafts.count
        savedDrafts = savedDrafts.filter { visibleIDs.contains($0.key) && Self.isRecent($0.value.createdAt, now: now) }
        return before != savedDrafts.count
    }

    nonisolated private static func isRecent(_ date: Date, now: Date) -> Bool {
        date <= now && now.timeIntervalSince(date) < 86_400
    }

    nonisolated private static func validDraftText(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 2_000 && !value.contains("\0") && !PIIScan.containsHighRiskPII(value)
    }

    private func pruneSnoozes(records: [KnowledgeRecord], now: Date) -> Bool {
        let validRecords = records.prefix(200).filter(Self.validSource)
        let current = Set(validRecords.map { Self.sourceFingerprint(path: $0.sourcePath, hash: $0.contentHash) })
        let currentHashes = Set(validRecords.map(\.contentHash))
        let before = snoozes.count
        let dismissed = Set(dismissedIDs)
        snoozes.removeAll { snooze in
            let sameEvidence = current.contains(snooze.sourceFingerprint) ||
                (snooze.copy.map { currentHashes.contains($0.contentHash) } ?? false)
            return snooze.snoozedAt > now || snooze.until <= now || dismissed.contains(snooze.id) ||
                dismissed.contains(snooze.decisionID) || !sameEvidence
        }
        return before != snoozes.count
    }
    nonisolated private static func validDate(_ date: Date) -> Bool {
        date.timeIntervalSinceReferenceDate.isFinite && date >= .distantPast && date <= .distantFuture
    }
    nonisolated private static func validDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }
    nonisolated private static func validSnooze(_ value: Snooze) -> Bool {
        validDigest(value.id) && validDigest(value.sourceFingerprint) && (1...7).contains(value.days) &&
            validDate(value.snoozedAt) && validDate(value.until) && value.until > value.snoozedAt &&
            value.until.timeIntervalSince(value.snoozedAt) <= 8 * 86_400 &&
            (value.copy.map { validDigest($0.id) && validDigest($0.contentHash) } ?? true)
    }
    nonisolated private static func sourceFingerprint(path: String, hash: String) -> String {
        digest(Data(sourceKey(path: path, hash: hash).utf8))
    }

    nonisolated private static func explicitAction(_ line: String) -> String? {
        var content = line
        if content.hasPrefix("- [ ] ") || content.hasPrefix("* [ ] ") {
            return String(content.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if content.hasPrefix("- ") || content.hasPrefix("* ") { content = String(content.dropFirst(2)) }
        for prefix in ["TODO:", "ACTION:"] where content.uppercased().hasPrefix(prefix) {
            return String(content.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }
    nonisolated private static func validSource(_ record: KnowledgeRecord) -> Bool {
        record.sourcePath.hasPrefix("/") && !record.sourcePath.contains("\0") && record.sourcePath.utf8.count <= 4_096 &&
            record.sourcePath.split(separator: "/", omittingEmptySubsequences: false).dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) &&
            !record.contentHash.isEmpty && record.contentHash.utf8.count <= 128
    }
    nonisolated private static func sourceKey(path: String, hash: String) -> String { path + "\0" + hash }
    nonisolated private static func identifier(path: String, hash: String, line: String) -> String {
        digest(Data((sourceKey(path: path, hash: hash) + "\0" + line).utf8))
    }
    nonisolated private static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    private static let duePattern = try? NSRegularExpression(
        pattern: #"(?i)(?:\[\s*(?:due|deadline)\s*:\s*([0-9]{4}-[0-9]{2}-[0-9]{2})\s*\]|\b(?:due|deadline)(?:\s*:\s*|\s+)([0-9]{4}-[0-9]{2}-[0-9]{2}))"#
    )
    private static func explicitDueDay(in action: String) -> String? {
        let range = NSRange(action.startIndex..<action.endIndex, in: action)
        guard let matches = duePattern?.matches(in: action, range: range), matches.count == 1,
              let match = matches.first, NSMaxRange(match.range) == NSMaxRange(range),
              let matchRange = Range(match.range, in: action) else { return nil }
        let bracketed = match.range(at: 1).location != NSNotFound
        if !bracketed, action[..<matchRange.lowerBound].trimmingCharacters(in: .whitespaces).hasSuffix("[") { return nil }
        guard let dayRange = Range(match.range(at: bracketed ? 1 : 2), in: action) else { return nil }
        let day = String(action[dayRange])
        return DailyPreparationPolicy.validDayKey(day) ? day : nil
    }
    nonisolated private static func prefix(_ value: String, bytes: Int) -> String {
        var data = Data(value.utf8.prefix(max(0, bytes)))
        while !data.isEmpty {
            if let text = String(data: data, encoding: .utf8) { return text }
            data.removeLast()
        }
        return ""
    }
    nonisolated private struct SavedPreferences: Codable {
        let version: Int
        let enabled: Bool
        let dismissedIDs: [String]
        let snoozes: [Snooze]?
        let scheduledDraftsEnabled: Bool?
        let preparedDrafts: [String: PreparedDraft]?
    }
    private func persist() {
        errorMessage = nil
        guard let persistenceURL else { return }
        do {
            let data = try JSONEncoder().encode(SavedPreferences(version: 1, enabled: enabled, dismissedIDs: dismissedIDs, snoozes: snoozes,
                                                                scheduledDraftsEnabled: scheduledDraftsEnabled,
                                                                preparedDrafts: savedDrafts.isEmpty ? nil : savedDrafts))
            guard data.count <= 262_144 else { throw RelayError.message("Suggestion metadata exceeds its local storage limit.") }
            try FileManager.default.createDirectory(at: persistenceURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try LocalPrivateFileWriter.write(data: data, to: persistenceURL, maximumBytes: 262_144)
        } catch {
            errorMessage = error.localizedDescription
            status += " Preferences could not be saved; this change may not survive relaunch."
        }
    }
    private func restore() {
        guard let persistenceURL, FileManager.default.fileExists(atPath: persistenceURL.path) else { return }
        do {
            let data = try LocalStateFile.read(persistenceURL, maximumBytes: 262_144)
            guard data.count <= 262_144 else { throw RelayError.message("Suggestion preferences exceed their size limit.") }
            let saved = try JSONDecoder().decode(SavedPreferences.self, from: data)
            guard saved.version == 1, saved.dismissedIDs.count <= 2_000,
                  saved.dismissedIDs.allSatisfy(Self.validDigest),
                  (saved.snoozes?.count ?? 0) <= 256,
                  (saved.snoozes ?? []).allSatisfy(Self.validSnooze),
                  Set((saved.snoozes ?? []).map(\.id)).count == (saved.snoozes?.count ?? 0),
                  Set((saved.snoozes ?? []).map(\.decisionID)).count == (saved.snoozes?.count ?? 0),
                  (saved.preparedDrafts?.count ?? 0) <= 2,
                  (saved.preparedDrafts ?? [:]).allSatisfy({ Self.validDigest($0.key) &&
                      Self.validDate($0.value.createdAt) && Self.validDraftText($0.value.text) }) else {
                throw RelayError.message("Suggestion preferences are invalid.")
            }
            enabled = saved.enabled
            scheduledDraftsEnabled = saved.scheduledDraftsEnabled ?? false
            dismissedIDs = Array(Set(saved.dismissedIDs)).sorted()
            let dismissed = Set(dismissedIDs)
            snoozes = (saved.snoozes ?? []).filter { !dismissed.contains($0.id) && !dismissed.contains($0.decisionID) }
            if enabled, scheduledDraftsEnabled {
                let hidden = dismissed.union(snoozes.map(\.id))
                savedDrafts = (saved.preparedDrafts ?? [:]).filter { !hidden.contains($0.key) }
            }
            status = enabled ? "Ready for a manual brief. No prior source text or suggestions were restored." : "Suggestions are off. Nothing is watched or prepared automatically."
        } catch {
            enabled = false; suggestions = []; dismissedIDs = []; snoozes = []; savedDrafts = [:]
            errorMessage = error.localizedDescription
            status = "Suggestion preferences could not be read safely. Suggestions remain off."
        }
    }
}
