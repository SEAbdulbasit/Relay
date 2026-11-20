import Compression
import Foundation

/// Supported Apple Notes body container: one complete gzip member, then the
/// protobuf length-delimited fields 2 -> 3 -> 2. Never searches arbitrary bytes
/// for a plausible string. Attachments, tables and formatting are not decoded.
nonisolated enum NotesBodyDecoder {
    static let maximumCompressedBytes = 1_048_576
    static let maximumInflatedBytes = 1_048_576
    static let maximumTextBytes = 8_192
    static let version = 1

    enum Failure: Error, Equatable { case size, gzip, checksum, protobuf, text }
    struct Text: Sendable, Equatable { let value: String; let limited: Bool }

    static func decode(_ blob: Data) throws -> Text {
        let raw = try gunzip(blob)
        let document = try field(2, in: raw)
        let note = try field(3, in: document)
        let bytes = try field(2, in: note)
        guard let text = String(data: bytes, encoding: .utf8), !text.contains("\0") else { throw Failure.text }
        let bounded = NativePersonalSources.bounded(text, maximumBytes: maximumTextBytes)
        return Text(value: bounded, limited: bounded.utf8.count != text.utf8.count)
    }

    private static func gunzip(_ data: Data) throws -> Data {
        guard (18...maximumCompressedBytes).contains(data.count) else { throw Failure.size }
        let bytes = [UInt8](data)
        guard bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8, bytes[3] & 0xe0 == 0 else { throw Failure.gzip }
        let trailer = bytes.count - 8
        var offset = 10
        if bytes[3] & 4 != 0 {
            guard offset + 2 <= trailer else { throw Failure.gzip }
            let count = Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
            offset += 2
            guard count <= trailer - offset else { throw Failure.gzip }
            offset += count
        }
        for flag in [UInt8(8), UInt8(16)] where bytes[3] & flag != 0 {
            let start = offset
            while offset < trailer, bytes[offset] != 0 {
                guard offset - start < 4_096 else { throw Failure.gzip }
                offset += 1
            }
            guard offset < trailer else { throw Failure.gzip }
            offset += 1
        }
        if bytes[3] & 2 != 0 {
            guard offset + 2 <= trailer else { throw Failure.gzip }
            let expected = UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
            guard UInt16(truncatingIfNeeded: try crc32(Data(bytes[..<offset]))) == expected else { throw Failure.checksum }
            offset += 2
        }
        guard offset < trailer else { throw Failure.gzip }
        let raw = try inflate(Data(bytes[offset..<trailer]))
        func uint32(_ index: Int) -> UInt32 {
            (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[index + $1]) << (8 * $1) }
        }
        guard uint32(trailer) == (try crc32(raw)), uint32(trailer + 4) == UInt32(raw.count) else { throw Failure.checksum }
        return raw
    }

    private static func inflate(_ data: Data) throws -> Data {
        let count = 32_768
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        defer { destination.deallocate() }
        return try data.withUnsafeBytes { buffer in
            guard let source = buffer.bindMemory(to: UInt8.self).baseAddress else { throw Failure.gzip }
            var stream = compression_stream(dst_ptr: destination, dst_size: count,
                src_ptr: source, src_size: data.count, state: nil)
            guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { throw Failure.gzip }
            defer { compression_stream_destroy(&stream) }
            stream.src_ptr = source; stream.src_size = data.count
            var result = Data()
            while true {
                try Task.checkCancellation()
                let before = stream.src_size
                stream.dst_ptr = destination; stream.dst_size = count
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = count - stream.dst_size
                guard produced <= maximumInflatedBytes - result.count else { throw Failure.size }
                result.append(destination, count: produced)
                switch status {
                case COMPRESSION_STATUS_END:
                    // Concatenated members/trailing deflate bytes are unsupported.
                    guard stream.src_size == 0 else { throw Failure.gzip }
                    return result
                case COMPRESSION_STATUS_OK:
                    guard produced > 0 || stream.src_size < before else { throw Failure.gzip }
                default: throw Failure.gzip
                }
            }
        }
    }

    static func crc32(_ data: Data) throws -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for (index, byte) in data.enumerated() {
            if index % 4_096 == 0 { try Task.checkCancellation() }
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xedb8_8320 : 0) }
        }
        return ~crc
    }

    /// Walk the WHOLE bounded message. Duplicate required fields, malformed
    /// suffixes, groups, invalid lengths/keys and varint overflow all refuse.
    private static func field(_ wanted: UInt64, in data: Data) throws -> Data {
        let bytes = [UInt8](data)
        var offset = 0, fields = 0
        var found: Data?
        func varint() throws -> UInt64 {
            var result: UInt64 = 0
            for index in 0..<10 {
                guard offset < bytes.count else { throw Failure.protobuf }
                let byte = bytes[offset]; offset += 1
                if index == 9, byte > 1 { throw Failure.protobuf }
                result |= UInt64(byte & 0x7f) << (index * 7)
                if byte & 0x80 == 0 { return result }
            }
            throw Failure.protobuf
        }
        while offset < bytes.count {
            fields += 1
            guard fields <= 65_536 else { throw Failure.size }
            if fields % 256 == 0 { try Task.checkCancellation() }
            let key = try varint(), number = key >> 3
            guard (1...0x1fff_ffff).contains(number) else { throw Failure.protobuf }
            switch key & 7 {
            case 0: _ = try varint(); if number == wanted { throw Failure.protobuf }
            case 1, 5:
                let width = (key & 7) == 1 ? 8 : 4
                guard number != wanted, width <= bytes.count - offset else { throw Failure.protobuf }
                offset += width
            case 2:
                let count = try varint()
                guard count <= UInt64(bytes.count - offset) else { throw Failure.protobuf }
                let end = offset + Int(count)
                if number == wanted {
                    guard found == nil else { throw Failure.protobuf }
                    found = Data(bytes[offset..<end])
                }
                offset = end
            default: throw Failure.protobuf
            }
        }
        guard let found else { throw Failure.protobuf }
        return found
    }
}
