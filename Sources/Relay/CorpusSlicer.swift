import Foundation

/// Item in the knowledge/summary corpus to be sliced and staged.
public struct CorpusItem: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var text: String
    public var itemDate: Date?
    public var sourceID: String?
    public var kind: String

    public init(id: String, title: String, text: String, itemDate: Date? = nil, sourceID: String? = nil, kind: String = "note") {
        self.id = id
        self.title = title
        self.text = text
        self.itemDate = itemDate
        self.sourceID = sourceID
        self.kind = kind
    }
}

/// Slices a corpus into byte-budgeted parts so prompts do not exceed context caps.
/// Deterministic and item-boundary respecting: entries are walked in order and a slice
/// closes when the next entry's rendered cost would cross the budget or when maximum items is reached.
/// Never splits an item across slices; an oversized single entry gets its own slice.
/// Also owns the staging snapshot (.relay-corpus.json) for deterministic resume across restarts.
public enum CorpusSlicer {
    public static let defaultBudget = 700_000
    public static var budget: Int { defaultBudget }
    public static var mergeBudget: Int { min(100_000, defaultBudget) }
    public static let maximumItems = 120
    private static let snapshotName = ".relay-corpus.json"

    /// Filters items to a recent lookback window (undated active notes included after dated recent items)
    /// and bounds them to the first byte/item budget slice (`PRO-01`).
    public static func recentWindow(
        _ items: [CorpusItem],
        lookbackDays: Int = 7,
        referenceDate: Date = Date(),
        budget: Int = defaultBudget,
        maximumItems: Int = maximumItems
    ) -> [CorpusItem] {
        guard !items.isEmpty else { return [] }
        let cutoff = referenceDate.addingTimeInterval(-Double(max(1, lookbackDays)) * 86_400)
        let datedRecent = items
            .filter { ($0.itemDate ?? .distantPast) >= cutoff }
            .sorted { ($0.itemDate ?? .distantPast) > ($1.itemDate ?? .distantPast) }
        let undated = items.filter { $0.itemDate == nil }
        let ordered = datedRecent + undated
        return slice(ordered, budget: budget, maximumItems: maximumItems).first ?? []
    }

    /// Shared date style — one formatter per batch.
    public static func dateFormatter() -> DateFormatter {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .none
        return df
    }

    /// Renders one corpus entry consistently for measurement and prompts.
    public static func render(_ item: CorpusItem, index: Int, df: DateFormatter) -> String {
        let source = item.sourceID ?? item.kind
        let dateStr = item.itemDate.map { " · \(df.string(from: $0))" } ?? ""
        return "#\(index + 1) · [\(source)] \(item.title)\(dateStr)\n\(item.text)"
    }

    /// Walk entries in order, closing a slice when the next entry would cross the budget.
    /// Never splits an entry; an oversized single entry gets its own slice.
    public static func slice(
        _ items: [CorpusItem],
        budget: Int = mergeBudget,
        maximumItems: Int = maximumItems
    ) -> [[CorpusItem]] {
        guard !items.isEmpty else { return [] }
        let df = dateFormatter()
        var slices: [[CorpusItem]] = []
        var current: [CorpusItem] = []
        var bytes = 0

        for (i, item) in items.enumerated() {
            let cost = render(item, index: i, df: df).utf8.count + 2 // + the "\n\n" joiner
            if !current.isEmpty && (bytes + cost > budget || current.count >= max(1, maximumItems)) {
                slices.append(current)
                current = []
                bytes = 0
            }
            current.append(item)
            bytes += cost
        }
        if !current.isEmpty {
            slices.append(current)
        }
        return slices
    }

    // MARK: - Staging Snapshot (Resume Determinism)

    /// Persist the sliced corpus inside the staging directory for resume determinism.
    public static func saveCorpus(_ items: [CorpusItem], in staging: URL) throws {
        let data = try JSONEncoder().encode(items)
        try data.write(to: staging.appendingPathComponent(snapshotName), options: .atomic)
    }

    /// Load the staged corpus snapshot.
    public static func loadCorpus(from staging: URL) -> [CorpusItem]? {
        guard let data = try? Data(contentsOf: staging.appendingPathComponent(snapshotName)) else { return nil }
        return try? JSONDecoder().decode([CorpusItem].self, from: data)
    }

    /// Remove the snapshot before swapping staging into live vault.
    public static func deleteCorpus(in staging: URL) {
        try? FileManager.default.removeItem(at: staging.appendingPathComponent(snapshotName))
    }
}

/// Same-volume backup copy of the last completed vault batch.
/// Restore only after the writing process stops; never copy a timed-out batch into the live vault.
public struct VaultSliceCheckpoint: Sendable {
    public let staging: URL
    public let backup: URL

    public init(staging: URL) throws {
        self.staging = staging
        self.backup = staging.deletingLastPathComponent().appendingPathComponent(staging.lastPathComponent + "-checkpoint-" + UUID().uuidString)
        do {
            try FileManager.default.copyItem(at: staging, to: backup)
        } catch {
            try? FileManager.default.removeItem(at: backup)
            throw error
        }
    }

    public func restore() throws {
        _ = try FileManager.default.replaceItemAt(staging, withItemAt: backup)
    }

    public func discard() {
        try? FileManager.default.removeItem(at: backup)
    }
}
