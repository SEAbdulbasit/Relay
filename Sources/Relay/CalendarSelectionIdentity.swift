import CryptoKit
import Foundation

/// Calendar identifiers are opaque protocol bytes, not normalized display text.
/// Set<String> remains the UI surface; a second canonical alias must refuse
/// before insertion because that collection cannot represent both members.
nonisolated enum CalendarSelectionIdentity {
    enum Failure: LocalizedError, Equatable {
        case conflictingIdentifier
        var errorDescription: String? {
            "Those calendars cannot be selected together. Uncheck one before choosing the other."
        }
    }
    static func keys<S: Sequence>(_ ids: S) -> Set<Data> where S.Element == String {
        Set(ids.map { Data($0.utf8) })
    }
    static func same(_ first: Set<String>, _ second: Set<String>) -> Bool {
        keys(first) == keys(second)
    }
    static func contains(_ ids: Set<String>, id: String) -> Bool {
        keys(ids).contains(Data(id.utf8))
    }
    static func inserting(_ id: String, into ids: Set<String>) throws -> Set<String> {
        if contains(ids, id: id) { return ids }
        // Canonical equality is used ONLY to detect an unrepresentable pair.
        guard !ids.contains(where: { $0 == id }) else { throw Failure.conflictingIdentifier }
        var result = ids; result.insert(id); return result
    }
    static func removing(_ id: String, from ids: Set<String>) -> Set<String> {
        let key = Data(id.utf8)
        return Set(ids.filter { Data($0.utf8) != key })
    }
    static func unavailable(_ ids: Set<String>, available: [String]) -> Set<String> {
        let availableKeys = keys(available)
        return Set(ids.filter { !availableKeys.contains(Data($0.utf8)) })
    }
    static func retaining(_ ids: Set<String>, available: [String]) -> Set<String> {
        let availableKeys = keys(available)
        return Set(ids.filter { availableKeys.contains(Data($0.utf8)) })
    }
    static func digest<S: Sequence>(_ ids: S) -> String where S.Element == String {
        let sorted = ids.sorted()
        let joined = sorted.joined(separator: "\u{0}")
        return SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// The actual SwiftUI input boundary must carry byte equality, not a bare
/// Set<String> that a child-view comparison can canonically equate and retain.
/// Immutable keys cannot diverge from the copied selection. This is UI state,
/// never permission or a calendar read receipt.
nonisolated struct CalendarSelectionValue: Sendable, Equatable {
    let ids: Set<String>
    private let byteKeys: Set<Data>

    init(_ ids: Set<String>) {
        self.ids = ids; byteKeys = CalendarSelectionIdentity.keys(ids)
    }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.byteKeys == rhs.byteKeys }
    func draft(catalogEpoch: UUID) -> CalendarSelectionDraft {
        CalendarSelectionDraft(catalogEpoch: catalogEpoch, selectedIDs: ids)
    }
}
