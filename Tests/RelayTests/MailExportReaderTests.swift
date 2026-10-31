import Foundation
import Testing
@testable import Relay

struct MailExportReaderTests {
    private func mail(_ headers: [String], _ body: String) -> Data {
        Data((headers.joined(separator: "\r\n") + "\r\n\r\n" + body).utf8)
    }

    @Test func decodesActualBase64UnicodeAndUnverifiedHeaders() throws {
        let expected = "مرحبا بالعالم 🌍\nLiteral body 123."
        let encoded = Data(expected.utf8).base64EncodedString(options: [.lineLength64Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        let parsed = try MailExportReader.parse(mail([
            "Subject: =?UTF-8?B?UmVsw6kg8J+MjQ==?=", "From: Claimed Sender <sender@example.invalid>",
            "Date: Fri, 30 Oct 2026 09:00:00 +0300", "Content-Type: text/plain; charset=utf-8", "Content-Transfer-Encoding: base64"
        ], encoded))
        #expect(parsed.subject == "Relé 🌍")
        #expect(parsed.claimedFrom == "Claimed Sender <sender@example.invalid>")
        #expect(parsed.date == "Fri, 30 Oct 2026 09:00:00 +0300")
        #expect(parsed.plainText == expected)
        #expect(parsed.coverageNote?.contains("unverified claims") == true)
    }

    @Test func quotedPrintableBodyAndEncodedWordUnderscoresHaveDifferentRules() throws {
        let parsed = try MailExportReader.parse(mail([
            "Subject: =?UTF-8?Q?Hello_?=", "\t=?UTF-8?Q?world_=F0=9F=8C=8D?=",
            "Content-Type: text/plain; charset=utf-8", "Content-Transfer-Encoding: quoted-printable"
        ], "caf=C3=A9 literal_underscore =\r\njoined=0Aline two"))
        #expect(parsed.subject == "Hello world 🌍")
        #expect(parsed.plainText == "café literal_underscore joined\nline two")
    }

    @Test func multipartPrefersOnePlainAlternativeAndNeverReturnsHTMLOrAttachmentMarkers() throws {
        let body = """
        Preamble ignored\r
        --outer\r
        Content-Type: multipart/alternative; boundary="inner"\r
        \r
        --inner\r
        Content-Type: text/plain; charset=utf-8\r
        Content-Transfer-Encoding: 8bit\r
        \r
        Selected plain body 🌍\r
        --inner\r
        Content-Type: text/html\r
        \r
        <img src="https://example.invalid/track">HTML_ONLY_MARKER\r
        --inner--\r
        --outer\r
        Content-Type: text/plain; charset=utf-8\r
        Content-Disposition: attachment; filename="../../ignored.txt"\r
        \r
        ATTACHMENT_ONLY_MARKER\r
        --outer--\r
        Epilogue ignored
        """
        let parsed = try MailExportReader.parse(mail(["Subject: Local export", "Content-Type: multipart/mixed; boundary=outer"], body))
        #expect(parsed.plainText == "Selected plain body 🌍")
        #expect(!parsed.plainText.contains("HTML_ONLY_MARKER"))
        #expect(!parsed.plainText.contains("ATTACHMENT_ONLY_MARKER"))
        #expect(!parsed.plainText.contains("https://"))
        #expect(parsed.coverageNote?.contains("remote content was not fetched") == true)
        #expect(parsed.coverageNote?.contains("Attachment") == true)
    }

    @Test func bodyBoundaryLookalikesAreNotMIMESeparators() throws {
        let body = "--x\r\nContent-Type: text/plain\r\n\r\nA --x inside a line\r\n--x-not-the-boundary\r\n--x--\r\n"
        let parsed = try MailExportReader.parse(mail(["Content-Type: multipart/mixed; boundary=x"], body))
        #expect(parsed.plainText == "A --x inside a line\n--x-not-the-boundary")
    }

    @Test func rejectsMalformedEncodingCharsetHeadersAndHTMLOnlyMail() {
        let cases = [
            mail(["Content-Type: text/plain; charset=utf-8", "Content-Transfer-Encoding: base64"], "YWJj!"),
            mail(["Content-Type: text/plain; charset=utf-8", "Content-Transfer-Encoding: base64"], "YR=="),
            mail(["Content-Type: text/plain; charset=utf-8", "Content-Transfer-Encoding: quoted-printable"], "bad=ZZ"),
            mail(["Content-Type: text/plain; charset=unsupported"], "body"),
            mail(["Subject: one", "Subject: two"], "body"),
            mail(["Content-Type: text/plain; charset=utf-8; charset=ascii"], "body"),
            mail(["Content-Type: text/html"], "<p>HTML only</p>"),
            mail(["Content-Type: multipart/mixed; boundary=x"], "--x\r\n\r\nUnclosed"),
            mail(["Subject: =?UTF-8?Q?bad=0Aheader?="], "body"),
            Data("Subject: missing separator".utf8)
        ]
        for input in cases { #expect(throws: (any Error).self) { try MailExportReader.parse(input) } }
    }

    @Test func nestingPartInputHeaderAndDecodedBudgetsAreEnforced() throws {
        func nested(_ depth: Int) -> String {
            if depth == 0 { return "Content-Type: text/plain\r\n\r\nbody" }
            return "Content-Type: multipart/mixed; boundary=b\(depth)\r\n\r\n--b\(depth)\r\n" + nested(depth - 1) + "\r\n--b\(depth)--\r\n"
        }
        #expect(throws: (any Error).self) { try MailExportReader.parse(Data(nested(5).utf8)) }
        let parts = (0..<41).map { _ in "--x\r\nContent-Type: text/plain\r\n\r\nbody\r\n" }.joined() + "--x--\r\n"
        #expect(throws: (any Error).self) { try MailExportReader.parse(mail(["Content-Type: multipart/mixed; boundary=x"], parts)) }
        #expect(throws: (any Error).self) { try MailExportReader.parse(Data(repeating: 65, count: 1_048_577)) }
        #expect(throws: (any Error).self) { try MailExportReader.parse(mail(["Subject: " + String(repeating: "a", count: 8193)], "body")) }
        #expect(throws: (any Error).self) { try MailExportReader.parse(mail(["Content-Type: text/plain"], "too large"), limits: .init(maximumDecodedBytes: 3)) }
    }

    @Test func textTruncationIsExplicitAndPreservesUTF8() throws {
        let body = String(repeating: "🌍", count: 20)
        let parsed = try MailExportReader.parse(mail(["Content-Type: text/plain; charset=utf-8", "Content-Transfer-Encoding: 8bit"], body), limits: .init(maximumTextBytes: 17))
        #expect(parsed.plainText == String(repeating: "🌍", count: 4))
        #expect(!parsed.plainText.contains("�"))
        #expect(parsed.coverageNote?.contains("truncated") == true)
    }

    @Test func legacyDeclaredCharsetsDecodeLocallyWithoutGuessing() throws {
        var input = mail(["Content-Type: text/plain; charset=iso-8859-1", "Content-Transfer-Encoding: 8bit"], "")
        input.append(contentsOf: [0x63, 0x61, 0x66, 0xe9])
        #expect(try MailExportReader.parse(input).plainText == "café")
        var windows = mail(["Content-Type: text/plain; charset=windows-1252", "Content-Transfer-Encoding: 8bit"], "")
        windows.append(contentsOf: [0x80, 0x20, 0x31])
        #expect(try MailExportReader.parse(windows).plainText == "€ 1")
    }
    @Test func quotedPrintableWhitespaceRunsAreDecodedOnceWithoutChangingInteriorSpaces() throws {
        let body = String(repeating: " ", count: 10_000) + "X\r\ntrailing spaces   \r\n"
        let parsed = try MailExportReader.parse(mail(["Content-Type: text/plain", "Content-Transfer-Encoding: quoted-printable"], body))
        #expect(parsed.plainText == String(repeating: " ", count: 10_000) + "X\ntrailing spaces\n")
    }

    @Test func binaryAttachmentsAreNotDecodedAndDuplicatePlainAlternativesAreNotConcatenated() throws {
        var body = Data("--outer\r\nContent-Type: multipart/alternative; boundary=inner\r\n\r\n--inner\r\nContent-Type: text/plain\r\n\r\nChosen body\r\n--inner\r\nContent-Type: text/plain\r\n\r\nUNSELECTED_ALTERNATIVE\r\n--inner--\r\n--outer\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=ignored.bin\r\n\r\n".utf8)
        body.append(contentsOf: [0xff, 0x00, 0x81, 0x01])
        body.append(Data("\r\n--outer--\r\n".utf8))
        var source = mail(["Content-Type: multipart/mixed; boundary=outer"], "")
        source.append(body)
        let parsed = try MailExportReader.parse(source)
        #expect(parsed.plainText == "Chosen body")
        #expect(!parsed.plainText.contains("UNSELECTED_ALTERNATIVE"))
        #expect(parsed.coverageNote?.contains("Only one plain-text alternative") == true)
    }

    @Test func headerFieldCountAndAmbiguousFilenameContinuationStayBounded() {
        let headers = (0..<201).map { "X-Fixture-\($0): value" }
        #expect(throws: (any Error).self) { try MailExportReader.parse(mail(headers, "body")) }
        let attachment = mail(["Content-Type: text/plain", "Content-Disposition: inline; filename*0*=utf-8''private; filename*1*=.txt"], "ATTACHMENT_NOT_BODY")
        #expect(throws: (any Error).self) { try MailExportReader.parse(attachment) }
    }

}
