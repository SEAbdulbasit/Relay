import AppKit
import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import Relay

@MainActor
struct ArtifactToolIntegrationTests {
    @Test func plainTextCannotMasqueradeAsNativeArtifact() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let tools = MacTools()
        tools.grants = [ScopeGrant(path: root.path, writable: true)]
        for ext in ["pdf", "rtf", "docx", "xlsx"] {
            let output = root.appendingPathComponent("invalid." + ext)
            await #expect(throws: (any Error).self) {
                try await tools.execute(ToolCall(name: "write_file", arguments: ["path": .string(output.path), "content": .string("ordinary UTF-8")]))
            }
            #expect(!FileManager.default.fileExists(atPath: output.path))
        }
    }
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("relay-artifact-integration-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func documentCall(path: URL, format: String = "pdf", title: String = "Local integration", body: String = "Synthetic body 123.") -> ToolCall {
        ToolCall(name: "create_document", arguments: ["path": .string(path.path), "format": .string(format), "title": .string(title), "body": .string(body)])
    }

    private func imageData(text: String) throws -> Data {
        let image = NSImage(size: NSSize(width: 1000, height: 180))
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1000, height: 180)).fill()
        (text as NSString).draw(at: NSPoint(x: 35, y: 65), withAttributes: [.font: NSFont.systemFont(ofSize: 65, weight: .medium), .foregroundColor: NSColor.black])
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    @Test func createsPDFRTFAndDOCXThroughScopedToolWithIndependentReopen() async throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let tools = MacTools()
        tools.grants = [ScopeGrant(path: folder.path, writable: true)]
        for format in ["pdf", "rtf", "docx"] {
            let output = folder.appendingPathComponent("generated." + format)
            let title = "Integration export"
            let body = format != "pdf" ? "مرحبا 🌍\nExact synthetic content." : "Exact synthetic content.\nSecond line: 123."
            let result = try await tools.execute(documentCall(path: output, format: format, title: title, body: body))
            #expect(result.verified)
            #expect(result.artifactPath == (try ToolPolicy.canonicalURL(output.path).path))
            #expect(result.evidence.contains("reopened"))
            let data = try Data(contentsOf: output)
            if format == "pdf" {
                let document = try #require(PDFDocument(data: data))
                #expect(document.pageCount == 1)
                #expect(document.string?.contains(title) == true)
                #expect(document.string?.contains("Second line: 123.") == true)
                let read = try await tools.execute(ToolCall(name: "read_file", arguments: ["path": .string(output.path)]))
                #expect(read.verified)
                #expect(read.summary.contains("Exact synthetic content."))
                #expect(read.evidence.contains("PDFKit"))
            } else if format == "rtf" {
                let restored = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
                #expect(restored.string == title + "\n\n" + body)
            } else {
                let restored = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil)
                #expect(LocalArtifacts.docxTextMatches(restored.string, expected: title + "\n\n" + body))
            }
        }
    }

    @Test func documentCreationRejectsReadonlyOutsideScopeAndFormatMismatchWithoutWrites() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let allowed = root.appendingPathComponent("allowed", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let tools = MacTools()
        tools.grants = [ScopeGrant(path: allowed.path)]
        await #expect(throws: (any Error).self) { try await tools.execute(documentCall(path: allowed.appendingPathComponent("readonly.pdf"))) }
        tools.grants = [ScopeGrant(path: allowed.path, writable: true)]
        for call in [documentCall(path: outside.appendingPathComponent("outside.pdf")), documentCall(path: allowed.appendingPathComponent("mismatch.rtf")), documentCall(path: allowed.appendingPathComponent("unsupported.odt"), format: "odt"), documentCall(path: allowed.appendingPathComponent(".hidden.pdf"))] {
            await #expect(throws: (any Error).self) { try await tools.execute(call) }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: allowed.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test func documentOverwriteRequiresOneUseReviewAndRejectsChangedContents() async throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let tools = MacTools()
        tools.grants = [ScopeGrant(path: folder.path, writable: true)]
        let output = folder.appendingPathComponent("replace.pdf")
        let original = try await LocalArtifacts.makePDF(title: "Original", body: "Original content.")
        try original.write(to: output)
        let replacement = documentCall(path: output, title: "Replacement", body: "New reviewed content.")
        #expect(tools.reviewReason(for: replacement) != nil)
        await #expect(throws: (any Error).self) { try await tools.execute(replacement) }
        #expect(try Data(contentsOf: output) == original)
        try tools.prepareReview(replacement)
        try tools.authorize(replacement)
        let external = try await LocalArtifacts.makePDF(title: "External", body: "Changed during review.")
        try external.write(to: output)
        await #expect(throws: (any Error).self) { try await tools.execute(replacement) }
        #expect(try Data(contentsOf: output) == external)
        try tools.prepareReview(replacement)
        try tools.authorize(replacement)
        #expect(try await tools.execute(replacement).verified)
        let final = try #require(PDFDocument(url: output))
        #expect(final.string?.contains("New reviewed content.") == true)
        await #expect(throws: (any Error).self) { try await tools.execute(replacement) }
    }

    @Test func documentApprovalDoesNotCoverChangedBodyOrRevokedGrant() async throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("approved.rtf")
        let original = try LocalArtifacts.makeRTF(title: "Original", body: "Do not replace without review.")
        try original.write(to: output)
        let tools = MacTools()
        tools.grants = [ScopeGrant(path: folder.path, writable: true)]
        let call = documentCall(path: output, format: "rtf")
        try tools.prepareReview(call)
        try tools.authorize(call)
        var altered = call
        altered.arguments["body"] = .string("Unapproved content")
        await #expect(throws: (any Error).self) { try await tools.execute(altered) }
        #expect(try Data(contentsOf: output) == original)
        try tools.prepareReview(call)
        try tools.authorize(call)
        tools.grants = [ScopeGrant(path: folder.path, writable: false)]
        await #expect(throws: (any Error).self) { try await tools.execute(call) }
        #expect(try Data(contentsOf: output) == original)
    }

    @Test func selectedImageUsesRealLocalOCRAndOutsideSymlinkIsRejected() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let allowed = root.appendingPathComponent("allowed", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let image = allowed.appendingPathComponent("selected.png")
        try imageData(text: "SCOPE OCR 321").write(to: image)
        let tools = MacTools()
        tools.grants = [ScopeGrant(path: allowed.path)]
        let result = try await tools.execute(ToolCall(name: "read_file", arguments: ["path": .string(image.path)]))
        #expect(result.verified)
        #expect(result.summary.uppercased().contains("SCOPE"))
        #expect(result.summary.contains("321"))
        #expect(result.evidence.contains("Vision OCR locally"))
        #expect(result.evidence.contains("may contain errors"))
        let unselected = outside.appendingPathComponent("secret.png")
        try imageData(text: "UNSELECTED DATA").write(to: unselected)
        let link = allowed.appendingPathComponent("escape.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: unselected)
        for url in [unselected, link] {
            await #expect(throws: (any Error).self) { try await tools.execute(ToolCall(name: "read_file", arguments: ["path": .string(url.path)])) }
        }
    }

    @Test func scannedPDFOCRDoesNotSilentlyReadBeyondThreePages() async throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try #require(NSBitmapImageRep(data: imageData(text: "SCANNED PAGE 123"))?.cgImage)
        let last = try #require(NSBitmapImageRep(data: imageData(text: "FOURTH OMITTED"))?.cgImage)
        let data = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: data))
        var bounds = CGRect(x: 0, y: 0, width: 500, height: 90)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        for index in 0..<4 {
            context.beginPDFPage(nil)
            context.draw(index == 3 ? last : first, in: bounds)
            context.endPDFPage()
        }
        context.closePDF()
        let url = folder.appendingPathComponent("scanned.pdf")
        try (data as Data).write(to: url)
        #expect(PDFDocument(url: url)?.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false)
        let tools = MacTools()
        tools.grants = [ScopeGrant(path: folder.path)]
        let result = try await tools.execute(ToolCall(name: "read_file", arguments: ["path": .string(url.path)]))
        #expect(result.verified)
        #expect(result.evidence.contains("OCR"))
        #expect(result.summary.contains("123"))
        #expect(result.summary.contains("first 3 of 4 pages"))
        #expect(!result.summary.contains("FOURTH"))
    }

    @Test func invalidOrOversizedSelectedImageFailsWithoutFabricatingText() async throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let tools = MacTools()
        tools.grants = [ScopeGrant(path: folder.path)]
        for data in [Data("not an image".utf8), Data(repeating: 0, count: LocalOCR.maximumImageBytes + 1)] {
            let url = folder.appendingPathComponent("invalid.png")
            try data.write(to: url)
            await #expect(throws: (any Error).self) { try await tools.execute(ToolCall(name: "read_file", arguments: ["path": .string(url.path)])) }
        }
    }
}
