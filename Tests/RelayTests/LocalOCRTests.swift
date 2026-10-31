import AppKit
import Foundation
import Testing
@testable import Relay

@MainActor
struct LocalOCRTests {
    @Test func rejectsUnboundedImageAndPDFPageGeometry() throws {
        try LocalOCR.validateImageDimensions(width: 4000, height: 4000)
        for (width, height) in [(0, 1), (1, -1), (4001, 4000), (12001, 1), (Int.max, Int.max)] {
            #expect(throws: (any Error).self) { try LocalOCR.validateImageDimensions(width: width, height: height) }
        }
        try LocalOCR.validatePDFPageLimit(1)
        try LocalOCR.validatePDFPageLimit(5)
        for count in [-1, 0, 6, Int.max] {
            #expect(throws: (any Error).self) { try LocalOCR.validatePDFPageLimit(count) }
        }
    }

    @Test func outputBudgetPreservesUTF8AndDisclosesTruncation() {
        let text = String(repeating: "مرحبًا 🌍 ", count: 2000)
        let output = LocalOCR.boundedOutput(text, note: "Truncated")
        #expect(output.utf8.count <= LocalOCR.maximumOutputBytes)
        #expect(output.hasSuffix("[Truncated]"))
        #expect(!output.contains("�"))
        #expect(LocalOCR.boundedOutput("Hello", note: "Truncated") == "Hello")
    }

    @Test func rejectsNetworkEmptyAndUndecodableInput() async throws {
        await #expect(throws: (any Error).self) {
            try await LocalOCR.recognizeImage(at: URL(string: "https://example.com/image.png")!)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for data in [Data(), Data("not an image".utf8)] {
            let url = directory.appendingPathComponent("fixture.png")
            try data.write(to: url)
            await #expect(throws: (any Error).self) { try await LocalOCR.recognizeImage(at: url) }
        }
    }

    @Test func cancelledRecognitionDoesNotReturnText() async throws {
        let task = Task {
            try Task.checkCancellation()
            return try await LocalOCR.recognizeImage(at: URL(fileURLWithPath: "/nonexistent/fixture.png"))
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled OCR returned text")
        } catch is CancellationError {
            // Cancellation is checked before reading or recognizing a file.
        }
    }

    @Test func actualVisionReadsLocallyGeneratedTextImage() async throws {
        let image = NSImage(size: NSSize(width: 1100, height: 180))
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1100, height: 180)).fill()
        ("HELLO RELAY 123" as NSString).draw(at: NSPoint(x: 50, y: 65), withAttributes: [
            .font: NSFont.systemFont(ofSize: 72, weight: .medium), .foregroundColor: NSColor.black
        ])
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("relay-ocr-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        let recognized = try await LocalOCR.recognizeImage(at: url).uppercased()
        #expect(recognized.contains("HELLO"))
        #expect(recognized.contains("RELAY"))
        #expect(recognized.contains("123"))
    }
}
