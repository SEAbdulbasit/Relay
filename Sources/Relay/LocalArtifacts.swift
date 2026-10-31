import AppKit
import CoreText
import Foundation

/// Native text exports only. Scope, overwrite review and durable writes belong to the caller.
nonisolated enum LocalArtifacts {
    static let maximumTitleBytes = 512
    static let maximumBodyBytes = 100_000
    static let maximumPages = 60
    static let maximumArtifactBytes = 10_485_760

    struct Content: Sendable {
        let title: String
        let body: String
    }

    static func validatedContent(title: String, body: String) throws -> Content {
        guard !title.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }),
              title.utf8.count <= maximumTitleBytes else {
            throw RelayError.message("A document title must be a single line up to 512 UTF-8 bytes without control characters.")
        }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              body.utf8.count <= maximumBodyBytes,
              !body.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0) && !["\n", "\r", "\t"].contains(String($0))
              }) else {
            throw RelayError.message("A document needs a nonempty title and body up to 100 KB; only ordinary text, line breaks and tabs are supported.")
        }
        return Content(title: title, body: body)
    }

    /// CoreText pagination runs off the UI actor, with a hard page and byte budget.
    @concurrent static func makePDF(title: String, body: String) async throws -> Data {
        let content = try validatedContent(title: title, body: body)
        try Task.checkCancellation()
        let text = NSMutableAttributedString(string: content.title + "\n\n" + content.body)
        let fullRange = NSRange(location: 0, length: text.length)
        text.addAttributes([
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 12, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.08, alpha: 1)
        ], range: fullRange)
        text.addAttribute(NSAttributedString.Key(kCTFontAttributeName as String),
                          value: CTFontCreateWithName("Helvetica-Bold" as CFString, 26, nil),
                          range: NSRange(location: 0, length: content.title.utf16.count))
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        guard let output = CFDataCreateMutable(nil, 0), let consumer = CGDataConsumer(data: output) else {
            throw RelayError.message("Could not allocate the native PDF output.")
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let metadata = [kCGPDFContextTitle as String: content.title, kCGPDFContextCreator as String: "Relay"] as CFDictionary
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, metadata) else {
            throw RelayError.message("Could not create the native PDF context.")
        }
        let path = CGPath(rect: mediaBox.insetBy(dx: 54, dy: 54), transform: nil)
        var offset = 0
        var pages = 0
        while offset < text.length {
            do { try Task.checkCancellation() }
            catch { context.closePDF(); throw error }
            guard pages < maximumPages else {
                context.closePDF()
                throw RelayError.message("The document exceeds the 60-page export limit. Shorten its content.")
            }
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: offset, length: 0), path, nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else {
                context.closePDF()
                throw RelayError.message("The document contains text that could not be paginated safely.")
            }
            context.beginPDFPage(nil)
            CTFrameDraw(frame, context)
            context.endPDFPage()
            offset += visible.length
            pages += 1
            if CFDataGetLength(output) > maximumArtifactBytes {
                context.closePDF()
                throw RelayError.message("The generated PDF exceeded the 10 MB export limit.")
            }
        }
        context.closePDF()
        try Task.checkCancellation()
        let data = output as Data
        guard !data.isEmpty, data.count <= maximumArtifactBytes else { throw RelayError.message("The generated PDF is empty or exceeds the 10 MB limit.") }
        return data
    }

    /// AppKit's attributed text/font conversion remains on the UI actor; input is capped at 100 KB.
    @MainActor static func makeRTF(title: String, body: String) throws -> Data {
        let content = try validatedContent(title: title, body: body)
        try Task.checkCancellation()
        let text = NSMutableAttributedString(string: content.title + "\n\n" + content.body,
                                            attributes: [.font: NSFont.systemFont(ofSize: 12)])
        text.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 24), range: NSRange(location: 0, length: content.title.utf16.count))
        let data = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        try Task.checkCancellation()
        guard !data.isEmpty, data.count <= maximumArtifactBytes else { throw RelayError.message("The generated RTF is empty or exceeds the 10 MB limit.") }
        return data
    }
    /// Native Office Open XML export from plain attributed text only. No HTML import,
    /// attachments, remote assets or provider request is involved in constructing the source.
    @MainActor static func makeDOCX(title: String, body: String) throws -> Data {
        let content = try validatedContent(title: title, body: body)
        try Task.checkCancellation()
        let expected = content.title + "\n\n" + content.body
        let text = NSMutableAttributedString(string: expected, attributes: [.font: NSFont.systemFont(ofSize: 12)])
        text.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 24),
                          range: NSRange(location: 0, length: content.title.utf16.count))
        let data: Data
        do {
            data = try text.data(from: NSRange(location: 0, length: text.length),
                                 documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        } catch {
            throw RelayError.message("Native DOCX export is unavailable on this macOS build: \(error.localizedDescription). Choose PDF or RTF explicitly instead; no disguised file was created.")
        }
        try Task.checkCancellation()
        guard !data.isEmpty, data.count <= maximumArtifactBytes,
              data.starts(with: Data([0x50, 0x4b, 0x03, 0x04])) else {
            throw RelayError.message("Native DOCX output was not a bounded Office Open XML ZIP document.")
        }
        let reopened = try NSAttributedString(data: data,
            options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil)
        try Task.checkCancellation()
        guard docxTextMatches(reopened.string, expected: expected) else {
            throw RelayError.message("Native DOCX reopen did not preserve the requested title and body. No document was returned for writing.")
        }
        return data
    }

    /// Office paragraphs normalize line endings and may add one terminal paragraph break.
    /// Other whitespace, punctuation and Unicode text must remain exact.
    static func docxTextMatches(_ actual: String, expected: String) -> Bool {
        let normalizeLines: (String) -> String = {
            $0.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        }
        let actual = normalizeLines(actual), expected = normalizeLines(expected)
        return actual == expected || actual == expected + "\n"
    }

}
