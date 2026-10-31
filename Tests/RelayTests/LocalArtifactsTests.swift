import AppKit
import Foundation
import PDFKit
import Testing
@testable import Relay

@MainActor
struct LocalArtifactsTests {
    @Test func rejectsEmptyOversizedAndControlBearingContent() throws {
        for (title, body) in [("", "Body"), ("  ", "Body"), ("Title", " \n\t"), ("Title\nOther", "Body"), ("Title\u{2028}Other", "Body"), ("Title", "Body\u{0}"), (String(repeating: "é", count: 257), "Body"), ("Title", String(repeating: "a", count: 100_001))] {
            #expect(throws: (any Error).self) { try LocalArtifacts.validatedContent(title: title, body: body) }
        }
        let content = try LocalArtifacts.validatedContent(title: "  Notes  ", body: "A\nB\tC")
        #expect(content.title == "Notes")
        #expect(content.body == "A\nB\tC")
    }

    @Test func actualNativePDFReopensAndContainsTitleAndBody() async throws {
        let data = try await LocalArtifacts.makePDF(title: "Relay export", body: "A local document.\nSecond line: 123.")
        #expect(data.starts(with: Data("%PDF".utf8)))
        let document = try #require(PDFDocument(data: data))
        #expect(document.pageCount == 1)
        let extracted = try #require(document.string)
        #expect(extracted.contains("Relay export"))
        #expect(extracted.contains("A local document."))
        #expect(extracted.contains("Second line: 123."))
        #expect(document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "Relay export")
    }

    @Test func PDFPaginatesWithoutDroppingEndOfDocument() async throws {
        let body = (1...180).map { "Line \($0): A bounded native PDF document with readable content." }.joined(separator: "\n")
        let data = try await LocalArtifacts.makePDF(title: "Long export", body: body)
        let document = try #require(PDFDocument(data: data))
        #expect(document.pageCount > 1)
        #expect(document.pageCount <= LocalArtifacts.maximumPages)
        let extracted = try #require(document.string)
        #expect(extracted.contains("Line 1:"))
        #expect(extracted.contains("Line 180:"))
    }

    @Test func nativeRTFRoundTripsUnicodeTitleAndBody() throws {
        let title = "Relay résumé"
        let body = "مرحبا بالعالم 🌍\nTabs\there and café."
        let data = try LocalArtifacts.makeRTF(title: title, body: body)
        let restored = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        #expect(restored.string == title + "\n\n" + body)
        #expect(data.count <= LocalArtifacts.maximumArtifactBytes)
    }

    @Test func PDFPageBudgetFailsRatherThanSilentlyTruncates() async {
        let body = String(repeating: "line\n", count: 10_000)
        await #expect(throws: (any Error).self) { try await LocalArtifacts.makePDF(title: "Too many pages", body: body) }
    }
    @Test func nativeDOCXWritesRealZIPAndReopensUnicodeWithoutContentLoss() throws {
        let title = "Relay résumé"
        let body = "مرحبا بالعالم 🌍\nExact  double spaces\tand café — 123."
        let expected = title + "\n\n" + body
        let data = try LocalArtifacts.makeDOCX(title: title, body: body)
        #expect(data.starts(with: Data([0x50, 0x4b, 0x03, 0x04])))
        #expect(data.range(of: Data("[Content_Types].xml".utf8)) != nil)
        #expect(data.range(of: Data("word/document.xml".utf8)) != nil)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("relay-docx-\(UUID().uuidString).docx")
        defer { try? FileManager.default.removeItem(at: file) }
        try data.write(to: file, options: .withoutOverwriting)
        let readback = try Data(contentsOf: file)
        #expect(readback == data)
        let reopened = try NSAttributedString(data: readback,
            options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil)
        #expect(reopened.string == expected || reopened.string == expected + "\n")
        #expect(data.count <= LocalArtifacts.maximumArtifactBytes)
    }

    @Test func DOCXPlainTextDoesNotInterpretHTMLOrDropLiteralCharacters() throws {
        let body = "<img src=\"https://example.invalid/remote.png\"> & 1 < 2; \\literal {text}."
        let data = try LocalArtifacts.makeDOCX(title: "Literal export", body: body)
        let reopened = try NSAttributedString(data: data,
            options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil)
        let expected = "Literal export\n\n" + body
        #expect(reopened.string == expected || reopened.string == expected + "\n")
    }

    @Test func DOCXVerificationAllowsOnlyParagraphLineEndingNormalization() {
        #expect(LocalArtifacts.docxTextMatches("Title\n\nBody\n", expected: "Title\r\n\r\nBody"))
        #expect(!LocalArtifacts.docxTextMatches("Title\nBody", expected: "Title\n\nBody"))
        #expect(!LocalArtifacts.docxTextMatches("Title\n\nBody ", expected: "Title\n\nBody"))
        #expect(!LocalArtifacts.docxTextMatches("Title\n\nChanged", expected: "Title\n\nBody"))
        #expect(!LocalArtifacts.docxTextMatches("Title\n\nBody\n\n", expected: "Title\n\nBody"))
    }

    @Test func DOCXRejectsEmptyOversizedAndControlBearingTextBeforeWriting() {
        for (title, body) in [("", "Body"), ("Title\nOther", "Body"), ("Title", " "), ("Title", "bad\u{0}"), ("Title", String(repeating: "a", count: 100_001))] {
            #expect(throws: (any Error).self) { try LocalArtifacts.makeDOCX(title: title, body: body) }
        }
    }

}
