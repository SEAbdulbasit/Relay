import Foundation

nonisolated enum SpreadsheetCell: Sendable, Equatable {
    case text(String)
    case number(Double)
    case boolean(Bool)
    case blank

    init(json: JSONValue) throws {
        switch json {
        case .string(let value): self = .text(value)
        case .number(let value):
            try LocalSpreadsheet.validateNumber(value)
            self = .number(value)
        case .bool(let value): self = .boolean(value)
        case .null: self = .blank
        default: throw LocalSpreadsheetError.invalidRows
        }
    }
}

nonisolated enum LocalSpreadsheetError: LocalizedError, Equatable {
    case invalidRows, invalidSheetName, invalidNumber, invalidXMLCharacter, tooLarge, cellTextTooLong
    var errorDescription: String? {
        switch self {
        case .invalidRows: "Provide spreadsheet rows containing only text, finite numbers, booleans or null values."
        case .invalidSheetName: "Choose a nonempty sheet name of at most 31 UTF-16 units, without Excel's reserved name characters or leading/trailing apostrophes."
        case .invalidNumber: "Spreadsheet numbers require at most 15 significant decimal digits, magnitude at most 9,007,199,254,740,991 and no nonzero subnormal values. Use text for long IDs or exact decimals; no workbook was generated."
        case .invalidXMLCharacter: "A spreadsheet value contains unsupported XML control characters. No workbook was generated."
        case .tooLarge: "This values-only workbook is limited to 1,000 rows, 30 columns, 1 MiB of cell content and a 5 MiB archive."
        case .cellTextTooLong: "An Excel text cell cannot exceed 32,767 UTF-16 units. No workbook was generated."
        }
    }
}

/// A bounded, values-only XLSX writer. Every String is inlineStr, even if it starts with
/// '=','+','-' or '@'. There are no formulas, macros, hyperlinks, imports, shell commands,
/// runtime dependencies, network requests or implicit filesystem writes.
nonisolated enum LocalSpreadsheet {
    static let maximumRows = 1_000
    static let maximumColumns = 30
    static let maximumContentBytes = 1_024 * 1_024
    static let maximumArchiveBytes = 5 * 1_024 * 1_024

    /// Production entry point: inspect original numeric spelling before Double decoding
    /// can erase precision. The typed overloads cannot detect already-rounded input.
    static func data(rowsJSONString: String, sheetName: String = "Sheet1") throws -> Data {
        guard rowsJSONString.utf8.count <= maximumContentBytes else { throw LocalSpreadsheetError.tooLarge }
        let bytes = Array(rowsJSONString.utf8)
        var index = 0
        var quoted = false
        while index < bytes.count {
            let byte = bytes[index]
            if quoted {
                if byte == 92 { index += 2; continue }
                if byte == 34 { quoted = false }
                index += 1
                continue
            }
            if byte == 34 { quoted = true; index += 1; continue }
            if byte == 44 {
                // Darwin JSONDecoder accepts trailing commas. Require both adjacent
                // non-whitespace tokens to be values, independently of that decoder.
                var before = index - 1
                var after = index + 1
                while before >= 0 && [9, 10, 13, 32].contains(bytes[before]) { before -= 1 }
                while after < bytes.count && [9, 10, 13, 32].contains(bytes[after]) { after += 1 }
                guard before >= 0, after < bytes.count,
                      ![44, 58, 91, 123].contains(bytes[before]),
                      ![44, 58, 93, 125].contains(bytes[after]) else { throw LocalSpreadsheetError.invalidRows }
            }
            if byte == 45 || (48...57).contains(byte) {
                let start = index
                while index < bytes.count && (bytes[index] == 45 || bytes[index] == 43 || bytes[index] == 46 || bytes[index] == 69 || bytes[index] == 101 || (48...57).contains(bytes[index])) {
                    index += 1
                    guard index - start <= 128 else { throw LocalSpreadsheetError.invalidNumber }
                }
                let token = String(decoding: bytes[start..<index], as: UTF8.self)
                guard token.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil else {
                    throw LocalSpreadsheetError.invalidRows
                }
                try validateNumericToken(token)
            } else { index += 1 }
        }
        let decoded: JSONValue
        do { decoded = try JSONDecoder().decode(JSONValue.self, from: Data(bytes)) }
        catch { throw LocalSpreadsheetError.invalidRows }
        return try data(rowsJSON: decoded, sheetName: sheetName)
    }

    static func validateNumber(_ number: Double) throws {
        guard number.isFinite, abs(number) <= 9_007_199_254_740_991,
              number == 0 || abs(number) >= Double.leastNormalMagnitude else { throw LocalSpreadsheetError.invalidNumber }
        try validateNumericToken(String(number))
    }

    private static func validateNumericToken(_ token: String) throws {
        guard token.utf8.count <= 128, let number = Double(token), number.isFinite,
              abs(number) <= 9_007_199_254_740_991 else { throw LocalSpreadsheetError.invalidNumber }
        let mantissa = token.split(whereSeparator: { $0 == "e" || $0 == "E" })[0]
        let digits = mantissa.filter { $0 >= "0" && $0 <= "9" }
        let significant = digits.drop(while: { $0 == "0" }).reversed().drop(while: { $0 == "0" })
        guard significant.count <= 15,
              significant.isEmpty || (number != 0 && abs(number) >= Double.leastNormalMagnitude) else { throw LocalSpreadsheetError.invalidNumber }
    }

    static func data(rowsJSON: JSONValue, sheetName: String = "Sheet1") throws -> Data {
        guard case .array(let rows) = rowsJSON, rows.count <= maximumRows else { throw LocalSpreadsheetError.invalidRows }
        let converted = try rows.map { row -> [SpreadsheetCell] in
            guard case .array(let cells) = row, cells.count <= maximumColumns else { throw LocalSpreadsheetError.invalidRows }
            return try cells.map { try SpreadsheetCell(json: $0) }
        }
        return try data(rows: converted, sheetName: sheetName)
    }

    static func data(rows: [[SpreadsheetCell]], sheetName: String = "Sheet1") throws -> Data {
        guard rows.count <= maximumRows, rows.allSatisfy({ $0.count <= maximumColumns }) else { throw LocalSpreadsheetError.tooLarge }
        let safeName = try validSheetName(sheetName)
        var contentBytes = 0
        for row in rows {
            for cell in row {
                let count: Int
                switch cell {
                case .text(let text):
                    guard text.utf8.count <= maximumContentBytes - contentBytes else { throw LocalSpreadsheetError.tooLarge }
                    guard text.utf16.count <= 32_767 else { throw LocalSpreadsheetError.cellTextTooLong }
                    try validateXML(text)
                    count = text.utf8.count
                case .number(let number):
                    try validateNumber(number)
                    count = String(number).utf8.count
                case .boolean: count = 1
                case .blank: count = 0
                }
                guard count <= maximumContentBytes - contentBytes else { throw LocalSpreadsheetError.tooLarge }
                contentBytes += count
            }
        }
        let columns = rows.map(\.count).max() ?? 0
        let dimension = rows.isEmpty || columns == 0 ? "A1" : "A1:\(columnName(columns))\(rows.count)"
        var worksheet = declaration + "<worksheet xmlns=\"\(mainNamespace)\"><dimension ref=\"\(dimension)\"/><sheetData>"
        for (rowIndex, row) in rows.enumerated() {
            worksheet += "<row r=\"\(rowIndex + 1)\">"
            for (columnIndex, cell) in row.enumerated() {
                let reference = columnName(columnIndex + 1) + String(rowIndex + 1)
                switch cell {
                case .text(let text):
                    worksheet += "<c r=\"\(reference)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(escapeXML(text))</t></is></c>"
                case .number(let number): worksheet += "<c r=\"\(reference)\" t=\"n\"><v>\(String(number))</v></c>"
                case .boolean(let value): worksheet += "<c r=\"\(reference)\" t=\"b\"><v>\(value ? "1" : "0")</v></c>"
                case .blank: worksheet += "<c r=\"\(reference)\"/>"
                }
                guard worksheet.utf8.count <= maximumArchiveBytes else { throw LocalSpreadsheetError.tooLarge }
            }
            worksheet += "</row>"
        }
        worksheet += "</sheetData></worksheet>"
        let workbook = declaration + "<workbook xmlns=\"\(mainNamespace)\" xmlns:r=\"\(relationshipNamespace)\"><sheets><sheet name=\"\(escapeXML(safeName))\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>"
        let types = declaration + """
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>
        """
        let rootRelationships = declaration + "<Relationships xmlns=\"\(packageRelationshipNamespace)\"><Relationship Id=\"rId1\" Type=\"\(relationshipNamespace)/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>"
        let workbookRelationships = declaration + "<Relationships xmlns=\"\(packageRelationshipNamespace)\"><Relationship Id=\"rId1\" Type=\"\(relationshipNamespace)/worksheet\" Target=\"worksheets/sheet1.xml\"/><Relationship Id=\"rId2\" Type=\"\(relationshipNamespace)/styles\" Target=\"styles.xml\"/></Relationships>"
        let styles = declaration + """
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts><fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>
        """
        return try storedZIP([
            ("[Content_Types].xml", Data(types.utf8)),
            ("_rels/.rels", Data(rootRelationships.utf8)),
            ("xl/workbook.xml", Data(workbook.utf8)),
            ("xl/_rels/workbook.xml.rels", Data(workbookRelationships.utf8)),
            ("xl/worksheets/sheet1.xml", Data(worksheet.utf8)),
            ("xl/styles.xml", Data(styles.utf8))
        ])
    }

    private static let declaration = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
    private static let mainNamespace = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    private static let relationshipNamespace = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    private static let packageRelationshipNamespace = "http://schemas.openxmlformats.org/package/2006/relationships"

    private static func validSheetName(_ name: String) throws -> String {
        guard name.utf8.count <= 124, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf16.count <= 31,
              !name.contains(where: { "[]:*?/\\".contains($0) }), !name.hasPrefix("'"), !name.hasSuffix("'"),
              !name.unicodeScalars.contains(where: { $0.value < 32 }) else { throw LocalSpreadsheetError.invalidSheetName }
        try validateXML(name)
        return name
    }
    private static func validateXML(_ value: String) throws {
        guard value.unicodeScalars.allSatisfy({ scalar in
            let code = scalar.value
            return code == 9 || code == 10 || code == 13 || (32...0xD7FF).contains(code) || (0xE000...0xFFFD).contains(code) || (0x10000...0x10FFFF).contains(code)
        }) else { throw LocalSpreadsheetError.invalidXMLCharacter }
    }
    private static func escapeXML(_ value: String) -> String {
        var escaped = ""
        let scalars = Array(value.unicodeScalars)
        for index in scalars.indices {
            let scalar = scalars[index]
            // SpreadsheetML ST_Xstring treats _xHHHH_ as an escape. Protect each
            // original leading underscore, including overlapping patterns, without
            // revisiting the _x005F_ escapes that this pass itself generates.
            if scalar.value == 95, index + 6 < scalars.count,
               scalars[index + 1].value == 120 || scalars[index + 1].value == 88,
               scalars[index + 6].value == 95,
               (2...5).allSatisfy({ delta in
                   let code = scalars[index + delta].value
                   return (48...57).contains(code) || (65...70).contains(code) || (97...102).contains(code)
               }) {
                escaped += "_x005F_"
                continue
            }
            switch scalar.value {
            case 38: escaped += "&amp;"
            case 60: escaped += "&lt;"
            case 62: escaped += "&gt;"
            case 34: escaped += "&quot;"
            case 39: escaped += "&apos;"
            case 13: escaped += "&#13;"
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
    }
    private static func columnName(_ oneBased: Int) -> String {
        var column = oneBased
        var name = ""
        while column > 0 {
            column -= 1
            name = String(UnicodeScalar(65 + column % 26)!) + name
            column /= 26
        }
        return name
    }

    private struct ZIPEntry { let name: Data; let payload: Data; let crc: UInt32; let offset: UInt32 }
    private static func storedZIP(_ inputs: [(String, Data)]) throws -> Data {
        var archive = Data()
        var entries: [ZIPEntry] = []
        for (name, payload) in inputs {
            let name = Data(name.utf8)
            guard archive.count + payload.count + name.count + 30 <= maximumArchiveBytes else { throw LocalSpreadsheetError.tooLarge }
            let entry = ZIPEntry(name: name, payload: payload, crc: crc32(payload), offset: UInt32(archive.count))
            archive.appendLE(UInt32(0x04034B50)); archive.appendLE(UInt16(20)); archive.appendLE(UInt16(0x0800))
            archive.appendLE(UInt16(0)); archive.appendLE(UInt16(0)); archive.appendLE(UInt16(0x0021))
            archive.appendLE(entry.crc); archive.appendLE(UInt32(payload.count)); archive.appendLE(UInt32(payload.count))
            archive.appendLE(UInt16(name.count)); archive.appendLE(UInt16(0)); archive.append(name); archive.append(payload)
            entries.append(entry)
        }
        let centralStart = archive.count
        for entry in entries {
            archive.appendLE(UInt32(0x02014B50)); archive.appendLE(UInt16(0x0314)); archive.appendLE(UInt16(20))
            archive.appendLE(UInt16(0x0800)); archive.appendLE(UInt16(0)); archive.appendLE(UInt16(0)); archive.appendLE(UInt16(0x0021))
            archive.appendLE(entry.crc); archive.appendLE(UInt32(entry.payload.count)); archive.appendLE(UInt32(entry.payload.count))
            archive.appendLE(UInt16(entry.name.count)); archive.appendLE(UInt16(0)); archive.appendLE(UInt16(0)); archive.appendLE(UInt16(0)); archive.appendLE(UInt16(0))
            archive.appendLE(UInt32(0o100600) << 16); archive.appendLE(entry.offset); archive.append(entry.name)
        }
        let centralSize = archive.count - centralStart
        archive.appendLE(UInt32(0x06054B50)); archive.appendLE(UInt16(0)); archive.appendLE(UInt16(0))
        archive.appendLE(UInt16(entries.count)); archive.appendLE(UInt16(entries.count))
        archive.appendLE(UInt32(centralSize)); archive.appendLE(UInt32(centralStart)); archive.appendLE(UInt16(0))
        guard archive.count <= maximumArchiveBytes else { throw LocalSpreadsheetError.tooLarge }
        return archive
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] }
        return crc ^ 0xFFFF_FFFF
    }
    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        return crc
    }
}

private extension Data {
    nonisolated mutating func appendLE(_ value: UInt16) { append(UInt8(value & 0xFF)); append(UInt8((value >> 8) & 0xFF)) }
    nonisolated mutating func appendLE(_ value: UInt32) {
        append(UInt8(value & 0xFF)); append(UInt8((value >> 8) & 0xFF)); append(UInt8((value >> 16) & 0xFF)); append(UInt8((value >> 24) & 0xFF))
    }
}
