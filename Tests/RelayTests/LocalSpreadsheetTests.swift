import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import Testing
@testable import Relay

struct LocalSpreadsheetTests {
    @Test func fixedOpenXMLPackageAndStoredZIPStructureHaveIndependentChecksums() throws {
        let data = try LocalSpreadsheet.data(rows: [[.text("Heading"), .number(12.5), .boolean(true), .blank]])
        let parts = try unpackGeneratedZIP(data)
        #expect(Set(parts.keys) == ["[Content_Types].xml", "_rels/.rels", "xl/workbook.xml", "xl/_rels/workbook.xml.rels", "xl/worksheets/sheet1.xml", "xl/styles.xml"])
        for part in parts.values { _ = try XMLDocument(data: part, options: []) }
        let sheet = try text("xl/worksheets/sheet1.xml", in: parts)
        #expect(sheet.contains("<dimension ref=\"A1:D1\"/>"))
        #expect(sheet.contains("<c r=\"B1\" t=\"n\"><v>12.5</v></c>"))
        #expect(sheet.contains("<c r=\"C1\" t=\"b\"><v>1</v></c>"))
        #expect(sheet.contains("<c r=\"D1\"/>"))
        #expect(try text("xl/_rels/workbook.xml.rels", in: parts).contains("Target=\"worksheets/sheet1.xml\""))
        #expect(try text("[Content_Types].xml", in: parts).contains("spreadsheetml.sheet.main+xml"))
        #expect(LocalSpreadsheet.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(LocalSpreadsheet.crc32(Data()) == 0)
    }

    @Test func formulaLikeTextAndMarkupStayLiteralWithoutExecutableSpreadsheetParts() throws {
        let strings = ["=SUM(A1:A2)", "+1+1", "-2+3", "@command", "=HYPERLINK(\"https://example.com\")", "<tag>&\"'", "مقهى 🌍", "\tline1\nline2\rline3"]
        let parts = try unpackGeneratedZIP(LocalSpreadsheet.data(rows: [strings.map(SpreadsheetCell.text)], sheetName: "O'Neil & café"))
        let sheet = try text("xl/worksheets/sheet1.xml", in: parts)
        #expect(sheet.components(separatedBy: "t=\"inlineStr\"").count - 1 == strings.count)
        #expect(!sheet.contains("<f>"))
        #expect(!sheet.contains("<hyperlink"))
        #expect(sheet.contains("&lt;tag&gt;&amp;&quot;&apos;"))
        #expect(sheet.contains("&#13;"))
        #expect(sheet.contains("xml:space=\"preserve\""))
        #expect(!parts.keys.contains { $0.contains("vba") || $0.contains("externalLinks") })
        #expect(try text("xl/workbook.xml", in: parts).contains("O&apos;Neil &amp; café"))
    }

    @Test func literalSpreadsheetEscapeSequencesRoundTripThroughOnePassSTXstringDecoding() throws {
        let strings = ["_x0041_", "_x000D_", "_x005F_x0041_", "_x000A__x000D_", "literal _X00aF_ token"]
        let parts = try unpackGeneratedZIP(LocalSpreadsheet.data(rows: [strings.map(SpreadsheetCell.text)], sheetName: "_x0041_"))
        let sheet = try #require(parts["xl/worksheets/sheet1.xml"])
        let xml = try XMLDocument(data: sheet, options: [])
        let nodes = try xml.nodes(forXPath: "//*[local-name()='t']")
        let decoded = try nodes.map { try referenceSTXstringDecode(#require($0.stringValue)) }
        #expect(decoded == strings)
        #expect(try text("xl/workbook.xml", in: parts).contains("name=\"_x005F_x0041_\""))
    }

    @Test func jsonCellTypesRemainExplicitAndFormulaObjectsAreRejected() throws {
        let input = JSONValue.array([.array([.string("=1+1"), .number(1.25), .bool(false), .null])])
        let parts = try unpackGeneratedZIP(LocalSpreadsheet.data(rowsJSON: input))
        let sheet = try text("xl/worksheets/sheet1.xml", in: parts)
        #expect(sheet.contains("t=\"inlineStr\""))
        #expect(sheet.contains("<v>1.25</v>"))
        #expect(sheet.contains("t=\"b\"><v>0</v>"))
        #expect(throws: LocalSpreadsheetError.invalidRows) { try LocalSpreadsheet.data(rowsJSON: .object([:])) }
        #expect(throws: LocalSpreadsheetError.invalidRows) {
            try LocalSpreadsheet.data(rowsJSON: .array([.array([.object(["formula": .string("SUM(A1:A2)")])])]))
        }
        #expect(throws: LocalSpreadsheetError.invalidNumber) { try LocalSpreadsheet.data(rows: [[.number(.nan)]]) }
        #expect(throws: LocalSpreadsheetError.invalidNumber) { try LocalSpreadsheet.data(rows: [[.number(.infinity)]]) }
    }

    @Test func xmlControlsAndInvalidSheetNamesFailBeforeArchiveGeneration() throws {
        for invalid in ["\0", "\u{B}", "\u{FFFE}"] {
            #expect(throws: LocalSpreadsheetError.invalidXMLCharacter) { try LocalSpreadsheet.data(rows: [[.text(invalid)]]) }
        }
        for name in ["", "   ", "Bad/Name", "Bad[Name]", "'Name", "Name'", "New\nLine", String(repeating: "a", count: 32), String(repeating: "🌍", count: 16)] {
            #expect(throws: LocalSpreadsheetError.invalidSheetName) { try LocalSpreadsheet.data(rows: [], sheetName: name) }
        }
        #expect(throws: LocalSpreadsheetError.cellTextTooLong) {
            try LocalSpreadsheet.data(rows: [[.text(String(repeating: "a", count: 32_768))]])
        }
    }

    @Test func rowColumnContentAndExpandedArchiveLimitsAreEnforced() throws {
        #expect(throws: LocalSpreadsheetError.tooLarge) { try LocalSpreadsheet.data(rows: Array(repeating: [], count: 1_001)) }
        #expect(throws: LocalSpreadsheetError.tooLarge) { try LocalSpreadsheet.data(rows: [Array(repeating: .blank, count: 31)]) }
        let row: [SpreadsheetCell] = [.text(String(repeating: "a", count: 30_000))]
        #expect(throws: LocalSpreadsheetError.tooLarge) { try LocalSpreadsheet.data(rows: Array(repeating: row, count: 35)) }
        let expandedRow = Array(repeating: SpreadsheetCell.text(String(repeating: "&", count: 340)), count: 30)
        #expect(throws: LocalSpreadsheetError.tooLarge) { try LocalSpreadsheet.data(rows: Array(repeating: expandedRow, count: 100)) }
    }

    @Test func emptyWorkbookAndThirtyColumnEdgeAreValidAndFilesystemBytesRoundTrip() throws {
        let empty = try unpackGeneratedZIP(LocalSpreadsheet.data(rows: []))
        #expect(try text("xl/worksheets/sheet1.xml", in: empty).contains("<sheetData></sheetData>"))
        var row = Array(repeating: SpreadsheetCell.blank, count: 30)
        row[29] = .text("AD edge")
        let data = try LocalSpreadsheet.data(rows: [row])
        let parts = try unpackGeneratedZIP(data)
        #expect(try text("xl/worksheets/sheet1.xml", in: parts).contains("r=\"AD1\""))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("relay-xlsx-test-" + UUID().uuidString + ".xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        #expect(try LocalStateFile.read(url, maximumBytes: LocalSpreadsheet.maximumArchiveBytes) == data)
    }

    @Test func rawNumericTokensRejectLossBeforeDoubleDecoding() throws {
        for token in ["0.10000000000000001", "9007199254740993", "-9007199254740993", "1.234567890123456e-20", "1e309", "1e-324", "2e-308", "1e16", String(repeating: "0", count: 129)] {
            #expect(throws: LocalSpreadsheetError.invalidNumber) {
                try LocalSpreadsheet.data(rowsJSONString: "[[\(token)]]")
            }
        }
        for value in [Double.nan, .infinity, 9_007_199_254_740_992, Double.leastNonzeroMagnitude, 0.12345678901234567] {
            #expect(throws: LocalSpreadsheetError.invalidNumber) { try LocalSpreadsheet.data(rows: [[.number(value)]]) }
            #expect(throws: LocalSpreadsheetError.invalidNumber) {
                try LocalSpreadsheet.data(rowsJSON: .array([.array([.number(value)])]))
            }
        }
    }

    @Test func rawNormalNumbersAndQuotedPrecisionRemainLiteral() throws {
        let raw = #"[[42,0.1,-12.5,1.230000e2,0e-999,"9007199254740993","0.10000000000000001","\"12345678901234567890\"","=1+1","-2+3","1e999"]]"#
        let parts = try unpackGeneratedZIP(LocalSpreadsheet.data(rowsJSONString: raw))
        let xml = try XMLDocument(data: #require(parts["xl/worksheets/sheet1.xml"]), options: [])
        let numbers = try xml.nodes(forXPath: "//*[local-name()='c'][@t='n']/*[local-name()='v']").compactMap(\.stringValue)
        #expect(numbers == ["42.0", "0.1", "-12.5", "123.0", "0.0"])
        let strings = try xml.nodes(forXPath: "//*[local-name()='t']").compactMap(\.stringValue)
        #expect(strings == ["9007199254740993", "0.10000000000000001", "\"12345678901234567890\"", "=1+1", "-2+3", "1e999"])
        #expect(try xml.nodes(forXPath: "//*[local-name()='f']").isEmpty)
    }

    @Test func rawMalformedJSONAndInputBoundsFail() throws {
        for raw in ["[[01]]", "[[+1]]", "[[1+2]]", "[[.1]]", "[[1.]]", "[[--1]]", #"[["unterminated]]"#, "[[true,]]", "[[true, \n\t]]", "[[,true]]", "[[true,,false]]", "[[true],]"] {
            #expect(throws: (any Error).self) { try LocalSpreadsheet.data(rowsJSONString: raw) }
        }
        #expect(throws: LocalSpreadsheetError.tooLarge) {
            try LocalSpreadsheet.data(rowsJSONString: String(repeating: " ", count: LocalSpreadsheet.maximumContentBytes + 1))
        }
    }

    /// Independent one-pass ST_Xstring reference decoder. Generated escapes may encode
    /// underscores only; source-looking escape text must remain literal after this pass.
    private func referenceSTXstringDecode(_ encoded: String) throws -> String {
        let expression = try NSRegularExpression(pattern: #"_[xX]([0-9A-Fa-f]{4})_"#)
        let matches = expression.matches(in: encoded, range: NSRange(encoded.startIndex..., in: encoded))
        var result = ""
        var position = encoded.startIndex
        for match in matches {
            let range = try #require(Range(match.range, in: encoded))
            let hexRange = try #require(Range(match.range(at: 1), in: encoded))
            let value = try #require(UInt32(encoded[hexRange], radix: 16))
            #expect(value == 0x005F)
            result += encoded[position..<range.lowerBound]
            result += "_"
            position = range.upperBound
        }
        result += encoded[position...]
        return result
    }

    private func text(_ name: String, in parts: [String: Data]) throws -> String {
        let data = try #require(parts[name])
        return try #require(String(data: data, encoding: .utf8))
    }

    /// Independent generated-fixture ZIP oracle: parses local/central/EOCD structures and
    /// checks every payload with a separate bitwise CRC implementation, not the writer table.
    private func unpackGeneratedZIP(_ data: Data) throws -> [String: Data] {
        var offset = 0
        var parts: [String: Data] = [:]
        var localOffsets: [String: Int] = [:]
        while offset + 30 <= data.count, try little(data, offset, 4) == 0x0403_4B50 {
            #expect(try little(data, offset + 6, 2) == 0x0800)
            #expect(try little(data, offset + 8, 2) == 0) // Stored, never arbitrary decompression.
            let size = Int(try little(data, offset + 18, 4))
            #expect(try little(data, offset + 22, 4) == UInt32(size))
            let nameLength = Int(try little(data, offset + 26, 2))
            let extraLength = Int(try little(data, offset + 28, 2))
            let payloadOffset = offset + 30 + nameLength + extraLength
            try #require(payloadOffset + size <= data.count)
            let name = try #require(String(data: data.subdata(in: (offset + 30)..<(offset + 30 + nameLength)), encoding: .utf8))
            let payload = data.subdata(in: payloadOffset..<(payloadOffset + size))
            #expect(try little(data, offset + 14, 4) == independentCRC(payload))
            #expect(parts[name] == nil)
            parts[name] = payload
            localOffsets[name] = offset
            offset = payloadOffset + size
        }
        let centralStart = offset
        var centralCount = 0
        while offset + 46 <= data.count, try little(data, offset, 4) == 0x0201_4B50 {
            let nameLength = Int(try little(data, offset + 28, 2))
            let extraLength = Int(try little(data, offset + 30, 2))
            let commentLength = Int(try little(data, offset + 32, 2))
            try #require(offset + 46 + nameLength + extraLength + commentLength <= data.count)
            let name = try #require(String(data: data.subdata(in: (offset + 46)..<(offset + 46 + nameLength)), encoding: .utf8))
            let payload = try #require(parts[name])
            #expect(try little(data, offset + 16, 4) == independentCRC(payload))
            #expect(try little(data, offset + 20, 4) == UInt32(payload.count))
            #expect(try little(data, offset + 42, 4) == UInt32(#require(localOffsets[name])))
            centralCount += 1
            offset += 46 + nameLength + extraLength + commentLength
        }
        #expect(centralCount == parts.count)
        #expect(try little(data, offset, 4) == 0x0605_4B50)
        #expect(try little(data, offset + 8, 2) == UInt32(parts.count))
        #expect(try little(data, offset + 10, 2) == UInt32(parts.count))
        #expect(try little(data, offset + 12, 4) == UInt32(offset - centralStart))
        #expect(try little(data, offset + 16, 4) == UInt32(centralStart))
        #expect(offset + 22 == data.count)
        return parts
    }
    private func little(_ data: Data, _ offset: Int, _ bytes: Int) throws -> UInt32 {
        try #require(offset >= 0 && bytes > 0 && bytes <= 4 && offset + bytes <= data.count)
        return (0..<bytes).reduce(0) { $0 | (UInt32(data[offset + $1]) << UInt32($1 * 8)) }
    }
    private func independentCRC(_ data: Data) -> UInt32 {
        var value: UInt32 = 0xFFFF_FFFF
        for byte in data {
            value ^= UInt32(byte)
            for _ in 0..<8 { value = (value & 1) == 1 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1 }
        }
        return value ^ 0xFFFF_FFFF
    }
}
