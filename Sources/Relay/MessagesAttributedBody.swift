import Foundation

/// The single-part plain-text subset of a Messages typedstream archive.
nonisolated enum MessagesAttributedBody {
    static let maximumArchiveBytes = 64 * 1_024
    static let maximumBodyScalars = 2_000

    static func decode(_ data: Data) -> String? {
        guard !data.isEmpty, data.count <= maximumArchiveBytes else { return nil }
        var reader = Reader(bytes: Array(data))
        return try? reader.body()
    }

    private enum ArchiveClass: String {
        case mutableAttributed = "NSMutableAttributedString"
        case attributed = "NSAttributedString"
        case mutableString = "NSMutableString"
        case string = "NSString"
        case object = "NSObject"
        case dictionary = "NSDictionary"
        case number = "NSNumber"
        case value = "NSValue"

        var version: Int { self == .string || self == .mutableString ? 1 : 0 }

        var hierarchy: [Self] {
            switch self {
            case .mutableAttributed: [.mutableAttributed, .attributed, .object]
            case .mutableString: [.mutableString, .string, .object]
            case .number: [.number, .value, .object]
            case .object: [.object]
            default: [self, .object]
            }
        }
    }

    private enum Invalid: Error { case archive }

    private struct Reader {
        let bytes: [UInt8]
        private var offset = 0
        private var shared: [String] = []
        // Objects and C strings reserve slots in the same reference table.
        // This subset only resolves references to previously validated classes.
        private var classes: [ArchiveClass?] = []

        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func body() throws -> String {
            try expect(4)
            guard try unsharedString(limit: 11) == "streamtyped", try integer(upTo: 1_000) == 1_000 else {
                throw Invalid.archive
            }
            let root = try beginObject()
            guard root == .attributed || root == .mutableAttributed else { throw Invalid.archive }
            let stringClass = try beginObject()
            guard stringClass == .string || stringClass == .mutableString else { throw Invalid.archive }
            try expectType("+")
            let value = try unsharedString(limit: MessagesAttributedBody.maximumArchiveBytes)
            try expect(0x86)
            try expectType("iI")
            guard try integer(upTo: 1) == 1,
                  try integer(upTo: MessagesAttributedBody.maximumArchiveBytes) == value.utf16.count,
                  !value.isEmpty, !value.unicodeScalars.contains(where: { $0.value == 0 || $0.value == 0xFFFC }),
                  try beginObject() == .dictionary else { throw Invalid.archive }
            try expectType("i")
            guard try integer(upTo: 1) == 1,
                  try beginObject() == .string else { throw Invalid.archive }
            try expectType("+")
            guard try unsharedString(limit: 64) == "__kIMMessagePartAttributeName" else { throw Invalid.archive }
            try expect(0x86)
            guard try beginObject() == .number else { throw Invalid.archive }
            try expectType("*")
            try expect(0x84)
            try expectType("i")
            classes.append(nil)
            try expectType("i")
            guard try integer(upTo: 0) == 0 else { throw Invalid.archive }
            try expect(0x86) // NSNumber
            try expect(0x86) // NSDictionary
            try expect(0x86) // NSAttributedString
            guard offset == bytes.count else { throw Invalid.archive }
            return String(value.unicodeScalars.prefix(MessagesAttributedBody.maximumBodyScalars))
        }

        private mutating func beginObject() throws -> ArchiveClass {
            try expectType("@")
            try expect(0x84)
            classes.append(nil)
            let priorClasses = classes.count
            var hierarchy: [ArchiveClass] = []
            while offset < bytes.count, bytes[offset] == 0x84 {
                try expect(0x84)
                let name = try sharedString()
                guard hierarchy.count < 3, let kind = ArchiveClass(rawValue: name),
                      try integer(upTo: 1) == kind.version else { throw Invalid.archive }
                hierarchy.append(kind)
                classes.append(kind)
            }
            let parent = try byte()
            if parent != 0x85 {
                let index = try reference(parent, count: priorClasses)
                guard let kind = classes[index] else { throw Invalid.archive }
                hierarchy.append(contentsOf: kind.hierarchy)
            }
            guard let root = hierarchy.first, hierarchy == root.hierarchy else { throw Invalid.archive }
            return root
        }

        private mutating func expectType(_ type: String) throws {
            guard try sharedString() == type else { throw Invalid.archive }
        }

        private mutating func sharedString() throws -> String {
            let marker = try byte()
            if marker == 0x84 {
                let value = try unsharedString(limit: 64)
                shared.append(value)
                return value
            }
            return shared[try reference(marker, count: shared.count)]
        }

        private func reference(_ marker: UInt8, count: Int) throws -> Int {
            // This fixed grammar can never allocate enough entries for a
            // multi-byte reference.
            let index = Int(marker) - 0x92
            guard (0..<count).contains(index) else { throw Invalid.archive }
            return index
        }

        private mutating func unsharedString(limit: Int) throws -> String {
            let length = try integer(upTo: limit)
            guard length <= bytes.count - offset else { throw Invalid.archive }
            let end = offset + length
            guard let value = String(bytes: bytes[offset..<end], encoding: .utf8) else { throw Invalid.archive }
            offset = end
            return value
        }

        private mutating func integer(upTo limit: Int) throws -> Int {
            let marker = try byte()
            let width: Int
            switch marker {
            case 0...127:
                guard Int(marker) <= limit else { throw Invalid.archive }
                return Int(marker)
            case 0x81: width = 2
            case 0x82: width = 4
            case 0x87: width = 8
            default: throw Invalid.archive
            }
            var value: UInt64 = 0
            for index in 0..<width {
                value |= UInt64(try byte()) << (index * 8)
            }
            guard value <= UInt64(limit) else { throw Invalid.archive }
            return Int(value)
        }

        private mutating func expect(_ expected: UInt8) throws {
            guard try byte() == expected else { throw Invalid.archive }
        }

        private mutating func byte() throws -> UInt8 {
            guard offset < bytes.count else { throw Invalid.archive }
            defer { offset += 1 }
            return bytes[offset]
        }
    }
}
