import CryptoKit
import Foundation

/// Mail ingestion pipeline components: mailbox filters, MIME header filters,
/// unavailable-body retry scheduler, and Envelope Index generation recovery (SRC-14).
nonisolated enum MailIngestion {

    // MARK: - 1. Mailbox Filters (SRC-14)

    public enum MailboxFilter {
        /// Hidden mailboxes: trash, bin, deleted items, drafts across major localizations.
        /// Messages in these mailboxes are excluded from reading and indexing.
        private static let hiddenNames: Set<String> = [
            "trash", "bin", "deleted messages", "deleted items", "draft", "drafts", "corbeille",
            "brouillons", "papierkorb", "entwürfe", "papelera", "borradores", "cestino", "bozze",
            "lixo", "rascunhos", "prullenmand", "concepten", "ゴミ箱", "下書き", "草稿", "废纸篓",
            "휴지통", "임시보관함"
        ]

        /// Excluded mailboxes: junk, spam, trash, bin, drafts, promotions, bulk mail across major localizations.
        private static let excludedNames: Set<String> = [
            "junk", "junk mail", "junk e-mail", "spam", "trash", "bin", "deleted messages",
            "deleted items", "draft", "drafts", "promotions", "category_promotions", "bulk mail",
            "indésirables", "courrier indésirable", "corbeille", "brouillons", "papierkorb", "entwürfe",
            "werbung", "unerwünscht", "correo no deseado", "papelera", "borradores", "cestino", "bozze",
            "lixo", "rascunhos", "reclame", "ongewenst", "prullenmand", "concepten", "迷惑メール", "ゴミ箱",
            "下書き", "垃圾邮件", "垃圾郵件", "草稿", "废纸篓", "스팸", "휴지통", "임시보관함"
        ]

        public static func isHidden(mailboxName: String) -> Bool {
            let normalized = mailboxName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return hiddenNames.contains(normalized)
        }

        public static func isExcluded(mailboxName: String) -> Bool {
            let normalized = mailboxName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return excludedNames.contains(normalized)
        }
    }

    // MARK: - 2. MIME Header Filters (SRC-14)

    public enum MIMEFilter {
        /// Excludes bulk, mailing list, and spam messages based on RFC822 / MIME headers.
        public static func isExcluded(headers: [String: String]) -> Bool {
            let lowerHeaders = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })

            // 1. Mailing list and unsubscribe headers
            if lowerHeaders["list-unsubscribe"] != nil || lowerHeaders["list-id"] != nil {
                return true
            }

            // 2. Precedence header: bulk, list, junk
            let precedence = lowerHeaders["precedence", default: ""].lowercased()
            if ["bulk", "list", "junk"].contains(where: { precedence.contains($0) }) {
                return true
            }

            // 3. Spam detection headers: x-spam-flag, x-spam-status, x-junk, x-spam
            for key in ["x-spam-flag", "x-spam-status", "x-junk", "x-spam"] {
                let value = lowerHeaders[key, default: ""].trimmingCharacters(in: .whitespaces).lowercased()
                if value.hasPrefix("yes") || value == "true" || value == "1" {
                    return true
                }
            }

            return false
        }
    }

    // MARK: - 3. Mail Ingestion Row Model

    public struct Row: Sendable, Equatable, Identifiable {
        public let id: Int64
        public let account: String
        public let messageID: String
        public let date: Date
        public let mailbox: String
        public let headers: [String: String]
        public let bodyText: String?
        public let excluded: Bool
        public let previewJunk: Bool

        public init(id: Int64, account: String, messageID: String, date: Date, mailbox: String,
                    headers: [String: String] = [:], bodyText: String? = nil) {
            self.id = id
            self.account = account
            self.messageID = messageID
            self.date = date
            self.mailbox = mailbox
            self.headers = headers
            self.bodyText = bodyText

            let mailboxHidden = MailboxFilter.isHidden(mailboxName: mailbox)
            let mailboxExcluded = MailboxFilter.isExcluded(mailboxName: mailbox)
            let mimeExcluded = MIMEFilter.isExcluded(headers: headers)

            let isJunk = mailboxExcluded || mimeExcluded
            self.excluded = mailboxHidden || isJunk
            self.previewJunk = isJunk && !mailboxHidden
        }
    }

    // MARK: - 4. Stable Position Ordering

    public struct Position: Codable, Comparable, Sendable {
        public let date: Date
        public let rowID: Int64

        public init(date: Date, rowID: Int64) {
            self.date = date
            self.rowID = rowID
        }

        public init(_ row: Row) {
            self.date = row.date
            self.rowID = row.id
        }

        public static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.date != rhs.date { return lhs.date < rhs.date }
            return lhs.rowID < rhs.rowID
        }
    }

    // MARK: - 5. Ingestion Checkpoint with Retry & Recovery (SRC-14)

    public struct Checkpoint: Codable, Sendable, Equatable {
        public var version: Int = 2
        public var generation: String
        public var salt: String
        public var highWater: Int64
        public var backfillBefore: Int64?
        public var backfillFloor: Position? = nil
        public var deferred: Set<Int64> = []
        public var skippedRows: Set<Int64>? = nil
        public var retrySchedule: [String: RetryEntry]? = nil
        public var retryAfter: Int64 = 0

        public struct RetryEntry: Codable, Sendable, Equatable {
            public let attempts: Int
            public let due: Date

            public init(attempts: Int, due: Date) {
                self.attempts = attempts
                self.due = due
            }
        }

        public init(generation: String, top: Int64 = 0, salt: String = UUID().uuidString) {
            self.generation = generation
            self.salt = salt
            self.highWater = top
            self.backfillBefore = top
        }

        public enum Phase: String, Sendable, Equatable {
            case discovery, backfill, retry, reconcile
        }

        public struct WorkItem: Sendable, Equatable {
            public let row: Row
            public let phase: Phase

            public init(row: Row, phase: Phase) {
                self.row = row
                self.phase = phase
            }
        }

        /// Index-generation recovery: Rebuilds of Mail's Envelope Index assign a new UUID.
        /// When detected, traversal resets to the new generation while preserving identity salt.
        public mutating func recoverIndexGeneration(newGeneration: String, rows: [Row]) {
            let top = rows.map(\.id).max() ?? 0
            if generation != newGeneration || top < highWater {
                let savedSalt = salt
                self = Checkpoint(generation: newGeneration, top: top, salt: savedSalt)
            }
        }

        /// Prepares next batch of work prioritizing:
        /// 1. Discovery of fresh messages above highWater
        /// 2. Due retries for previously unavailable bodies (bounded turn)
        /// 3. Backfill of historical messages descending through date
        public mutating func prepare(generation: String, rows: [Row], now: Date, limit: Int = 100) -> [WorkItem] {
            recoverIndexGeneration(newGeneration: generation, rows: rows)

            let rows = rows.filter { skippedRows?.contains($0.id) != true }
            let existing = Set(rows.filter { !$0.excluded || $0.previewJunk }.map(\.id))
            deferred.formIntersection(existing)
            retrySchedule = retrySchedule?.filter { Int64($0.key).map(deferred.contains) == true }

            let budget = max(0, limit)
            let fresh = rows.filter { $0.id > highWater }.sorted { $0.id < $1.id }
                .prefix(budget).map { WorkItem(row: $0, phase: .discovery) }
            var work = Array(fresh)
            var occupied = Set(work.map { $0.row.id })

            // Reserve bounded retry turn before backfill so unavailable bodies do not wait for all history
            let retries = rows.filter {
                deferred.contains($0.id) &&
                !occupied.contains($0.id) &&
                (retrySchedule?[String($0.id)]?.due ?? .distantPast) <= now
            }.sorted { $0.id < $1.id }
            let rotated = retries.filter { $0.id > retryAfter } + retries.filter { $0.id <= retryAfter }
            let retryWork = rotated.prefix(min(50, budget - work.count)).map { WorkItem(row: $0, phase: .retry) }
            work += retryWork
            occupied.formUnion(work.map { $0.row.id })

            // Backfill phase descending through date order
            if backfillBefore != nil {
                let candidates = rows.filter { needsBackfill($0) && !occupied.contains($0.id) }
                    .sorted { Position($0) > Position($1) }
                    .prefix(budget - work.count).map { WorkItem(row: $0, phase: .backfill) }
                work += candidates
            }

            return work
        }

        private func needsBackfill(_ row: Row) -> Bool {
            guard skippedRows?.contains(row.id) != true, let before = backfillBefore, row.id <= before else { return false }
            return backfillFloor.map { Position(row) < $0 } ?? true
        }

        /// Records execution result for a work item:
        /// - If body was unavailable, adds to deferred retry cache with exponential backoff.
        /// - If body was available (or excluded), clears deferred retry entry.
        public mutating func recordResult(for work: WorkItem, bodyAvailable: Bool, now: Date = Date()) {
            let key = String(work.row.id)
            if !bodyAvailable {
                deferred.insert(work.row.id)
                let attempts = min(4, max(0, retrySchedule?[key]?.attempts ?? 0)) + 1
                let delays: [TimeInterval] = [300, 1800, 7200, 43200, 86400]
                if retrySchedule == nil { retrySchedule = [:] }
                retrySchedule?[key] = RetryEntry(attempts: attempts, due: now.addingTimeInterval(delays[attempts - 1]))
            } else {
                deferred.remove(work.row.id)
                retrySchedule?.removeValue(forKey: key)
            }

            switch work.phase {
            case .discovery:
                if work.row.id > highWater { highWater = work.row.id }
            case .backfill:
                backfillFloor = Position(work.row)
            case .retry:
                retryAfter = work.row.id
            case .reconcile:
                break
            }
        }
    }
}
