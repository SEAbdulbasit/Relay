import AppKit
import CryptoKit
import Foundation
import PDFKit

/// A captured, bounded source value. It is deliberately not Codable or written
/// to the conversation, knowledge index, exported history, or a remote provider.
nonisolated struct DocumentSummarySource: Sendable {
    enum Kind: String, Sendable { case selection, browser, pdf }
    static let maximumTextBytes = 8_000
    let kind: Kind
    let title: String
    let application: String
    let location: String?
    let text: String
    let coverage: String
    let truncated: Bool
    let capturedAt: Date

    init(kind: Kind, title: String, application: String, location: String? = nil, text: String,
         coverage: String, truncated: Bool = false, capturedAt: Date = Date()) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= Self.maximumTextBytes,
              BoundTextSelection.usableText(text, maximumBytes: Self.maximumTextBytes),
              capturedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw RelayError.message("This source did not expose bounded readable text for a local summary.")
        }
        self.kind = kind
        self.title = Self.prefix(title, bytes: 512)
        self.application = Self.prefix(application, bytes: 128)
        self.location = location.map { Self.prefix($0, bytes: 2_048) }
        self.text = text
        self.coverage = Self.prefix(coverage, bytes: 768)
        self.truncated = truncated
        self.capturedAt = capturedAt
    }

    static func browser(_ snapshot: BrowserPageReader.Snapshot, application: String) throws -> Self {
        let url = URL(string: snapshot.url)
        let videoHost = url?.host?.lowercased().split(separator: ".").suffix(2).joined(separator: ".")
        let videoLimit = ["youtube.com", "youtu.be"].contains(videoHost ?? "")
            ? " Video and audio were not decoded, and no dedicated caption or transcript retrieval was performed. Any loaded transcript text is page text only." : ""
        return try Self(kind: .browser, title: snapshot.title, application: application, location: snapshot.url,
            text: snapshot.text,
            coverage: "Static text from the chosen browser's selected loaded document, including accessible offscreen nodes. Editable fields, unloaded content and hidden history were excluded."
                + (snapshot.truncated ? " The capture was bounded; some loaded content was omitted." : "") + videoLimit,
            truncated: snapshot.truncated)
    }

    /// Keeps opening, middle and ending rather than silently losing a long
    /// document's final decisions. Gaps are visible to the model and the reader.
    static func excerpt(_ text: String, maximumBytes: Int = maximumTextBytes) -> String {
        guard text.utf8.count > maximumBytes else { return text }
        let gap = "\n[Source excerpt gap]\n"
        guard maximumBytes > gap.utf8.count * 2 else { return prefix(text, bytes: max(0, maximumBytes)) }
        let budget = max(0, maximumBytes - gap.utf8.count * 2)
        let scalars = Array(text.unicodeScalars)
        let opening = prefix(text, bytes: budget / 3)
        let midpoint = scalars.count / 2
        let middleOpening = suffix(String(String.UnicodeScalarView(scalars.prefix(midpoint))), bytes: budget / 6)
        let middleEnding = prefix(String(String.UnicodeScalarView(scalars.dropFirst(midpoint))), bytes: budget / 3 - middleOpening.utf8.count)
        let middle = middleOpening + middleEnding
        let end = suffix(text, bytes: budget - opening.utf8.count - middle.utf8.count)
        return opening + gap + middle + gap + end
    }

    static func prefix(_ text: String, bytes: Int) -> String {
        var result = "", count = 0
        for scalar in text.unicodeScalars {
            guard count + scalar.utf8.count <= bytes else { break }
            result.unicodeScalars.append(scalar); count += scalar.utf8.count
        }
        return result
    }

    private static func suffix(_ text: String, bytes: Int) -> String {
        var kept: [Unicode.Scalar] = [], count = 0
        for scalar in text.unicodeScalars.reversed() {
            guard count + scalar.utf8.count <= bytes else { break }
            kept.append(scalar); count += scalar.utf8.count
        }
        return String(String.UnicodeScalarView(kept.reversed()))
    }
}

@MainActor
enum DocumentSummaryCapture {
    typealias PDFExtract = @MainActor (Data, String, String) async throws -> DocumentSummarySource
    static func browser(application: NSRunningApplication?) async throws -> DocumentSummarySource {
        try await browser(target: BrowserPageReader.captureCurrentTarget(application: application))
    }

    static func browser(target: BrowserPageReader.CurrentDocumentTarget) async throws -> DocumentSummarySource {
        let snapshot = try await BrowserPageReader.readCurrent(target: target)
        return try DocumentSummarySource.browser(snapshot, application: target.applicationName)
    }

    static func pdf(path: String, currentGrants: @MainActor () -> [ScopeGrant], pinnedURL: URL? = nil,
                    extract: PDFExtract = { try await extractPDF(data: $0, title: $1, path: $2) }) async throws -> DocumentSummarySource {
        let url = try ToolPolicy.scopedURL(path, grants: currentGrants())
        guard pinnedURL == nil || url == pinnedURL else {
            throw RelayError.message("The chosen PDF path changed before capture. Select the intended file again; no source was read.")
        }
        guard url.pathExtension.lowercased() == "pdf" else { throw RelayError.message("Choose a granted PDF file for this summary.") }
        let data = try LocalStateFile.read(url, maximumBytes: 10_485_760)
        let digest = SHA256.hash(data: data)
        let source = try await extract(data, url.lastPathComponent, url.path)
        try Task.checkCancellation()
        guard try ToolPolicy.scopedURL(path, grants: currentGrants()) == url,
              SHA256.hash(data: try LocalStateFile.read(url, maximumBytes: 10_485_760)) == digest else {
            throw RelayError.message("The PDF or its selected-file scope changed during capture. No summary source was retained.")
        }
        return source
    }

    @concurrent static func extractPDF(data: Data, title: String, path: String) async throws -> DocumentSummarySource {
        try Task.checkCancellation()
        guard data.count <= 10_485_760, let document = PDFDocument(data: data), !document.isLocked, document.pageCount > 0 else {
            throw RelayError.message("This PDF is locked, malformed or exceeds the 10 MB limit. No document text was captured.")
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        var pages: [String] = [], pagesRead = 0, partialPage = false
        for index in 0..<min(20, document.pageCount) {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { break }
            let text = document.page(at: index)?.string ?? ""
            let bounded = DocumentSummarySource.excerpt(text, maximumBytes: 4_000)
            partialPage = partialPage || bounded.utf8.count < text.utf8.count
            pages.append("[Page \(index + 1)]\n" + bounded)
            pagesRead += 1
        }
        let extracted = pages.joined(separator: "\n\n")
        let text = DocumentSummarySource.excerpt(extracted)
        let truncated = partialPage || pagesRead < document.pageCount || text.utf8.count < extracted.utf8.count
        guard pages.contains(where: { $0.components(separatedBy: "\n").dropFirst().joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }) else {
            throw RelayError.message("This PDF exposed no readable text layer. Scanned pages, images and locked content need another explicit inspection path.")
        }
        return try DocumentSummarySource(kind: .pdf, title: title, application: "PDF", location: path, text: text,
            coverage: "Read text layers from \(pagesRead) of \(document.pageCount) PDF pages on this Mac. Images, layout and OCR were not inspected."
                + (truncated ? " Source excerpts or pages were omitted by the bounded capture." : ""), truncated: truncated)
    }
}
