import Foundation

/// Opaque protocol identifiers preserve literal UTF-8, including canonically
/// equivalent but byte-distinct Unicode. Call sites enforce their size bounds.
nonisolated struct LMStudioProtocolID: Hashable, Sendable, ExpressibleByStringLiteral {
    private let bytes: Data
    init(_ value: String) { bytes = Data(value.utf8) }
    init(stringLiteral value: String) { self.init(value) }
    var string: String { String(decoding: bytes, as: UTF8.self) }

    static func same(_ lhs: String, _ rhs: String) -> Bool { lhs.utf8.elementsEqual(rhs.utf8) }
    static func contains(_ values: [String], _ value: String) -> Bool {
        values.contains { same($0, value) }
    }
}
