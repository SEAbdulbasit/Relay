import Foundation
import Testing
@testable import Relay

struct NotesBodyDecoderTests {
    @Test func exactGzipProtobufTextPreservesUnicodeWhitespaceAndRealCRC() throws {
        #expect(try NotesBodyDecoder.crc32(Data("123456789".utf8)) == 0xcbf4_3926)
        let text = "  Cafe\u{301} 🌍\n\tOwned note\n"
        let actual = try NotesBodyDecoder.decode(NotesImportTestData.note(text))
        #expect(Data(actual.value.utf8) == Data(text.utf8) && !actual.limited)
    }
    @Test func unknownLegalFieldsAndOptionalGzipNameDoNotBecomeBodyText() throws {
        var raw = Data([8, 1, 0x1d, 1, 2, 3, 4])
        raw.append(NotesImportTestData.message(2, NotesImportTestData.message(3, NotesImportTestData.message(2, Data("Only actual body".utf8)))))
        let blob = try NotesImportTestData.gzip(raw, name: "Not part of body")
        #expect(try NotesBodyDecoder.decode(blob).value == "Only actual body")
    }
    @Test(arguments: ["crc", "size", "reserved", "truncated", "trailing-member"])
    func matchedTextDoesNotPermitMalformedGzip(_ damage: String) throws {
        var blob = try NotesImportTestData.note("Do not accept plausible body alone")
        switch damage {
        case "crc": blob[blob.count - 8] ^= 1
        case "size": blob[blob.count - 4] ^= 1
        case "reserved": blob[3] |= 0x80
        case "truncated": blob.removeLast()
        default: blob.append(try NotesImportTestData.note("Second member is unsupported"))
        }
        #expect(throws: NotesBodyDecoder.Failure.self) { try NotesBodyDecoder.decode(blob) }
    }
    @Test(arguments: ["suffix", "duplicate", "zero-key", "overflow", "group", "length"])
    func wholeMessageMustBeValidEvenAfterTheWantedTextWasFound(_ damage: String) throws {
        let body = NotesImportTestData.message(2, NotesImportTestData.message(3, NotesImportTestData.message(2, Data("Plausible text".utf8))))
        var raw = body
        switch damage {
        case "suffix": raw.append(0x80)
        case "duplicate": raw.append(body)
        case "zero-key": raw.append(0)
        case "overflow": raw.append(contentsOf: Array(repeating: 0xff, count: 11))
        case "group": raw.append(0x1b)
        default: raw.append(contentsOf: [0x22, 0x7f, 1])
        }
        let blob = try NotesImportTestData.gzip(raw)
        #expect(throws: NotesBodyDecoder.Failure.protobuf) { try NotesBodyDecoder.decode(blob) }
    }
    @Test func wrongWireAndInvalidUTF8RefuseRatherThanSearchingOtherFields() throws {
        let wrong = try NotesImportTestData.gzip(Data([0x10, 0]))
        #expect(throws: NotesBodyDecoder.Failure.protobuf) { try NotesBodyDecoder.decode(wrong) }
        let invalid = try NotesImportTestData.gzip(NotesImportTestData.message(2, NotesImportTestData.message(3, NotesImportTestData.message(2, Data([0xff])))))
        #expect(throws: NotesBodyDecoder.Failure.text) { try NotesBodyDecoder.decode(invalid) }
    }
    @Test func outputBoundUsesWholeUTF8ScalarsAndReportsOmission() throws {
        let text = String(repeating: "🌍", count: 3_000)
        let decoded = try NotesBodyDecoder.decode(NotesImportTestData.note(text))
        #expect(decoded.limited && decoded.value.utf8.count == NotesBodyDecoder.maximumTextBytes)
        #expect(decoded.value == String(repeating: "🌍", count: 2_048))
    }
    @Test func compressedAndInflatedInputsHaveIndependentHardBounds() throws {
        let oversized = Data(repeating: 0, count: NotesBodyDecoder.maximumCompressedBytes + 1)
        #expect(throws: NotesBodyDecoder.Failure.size) { try NotesBodyDecoder.decode(oversized) }
        // Fixed standard gzip of 1,048,577 ASCII A bytes, generated with Python
        // gzip (mtime=0). Tiny compressed input must not bypass the inflate cap.
        let compressed = try #require(Data(base64Encoded: """
            H4sIAAAAAAAC/+3BMQEAAADCoGzrX8oQvkABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
            AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
            AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
            AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
            AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
            AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
            AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
            AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
            AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
            AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
            AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
            AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
            AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
            AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAJwGIRLgMQEA
            EAA=
            """, options: .ignoreUnknownCharacters))
        #expect(compressed.count < 2_048)
        #expect(throws: NotesBodyDecoder.Failure.size) { try NotesBodyDecoder.decode(compressed) }
    }

    @MainActor @Test func cancellationRefusesBeforeReturningDecodedText() async throws {
        let bytes = try NotesImportTestData.note("Owned cancellation fixture")
        let task = Task { try NotesBodyDecoder.decode(bytes) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
