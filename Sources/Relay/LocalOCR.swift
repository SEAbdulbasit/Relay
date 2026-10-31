import Foundation
import CoreGraphics
import ImageIO
import PDFKit
import Vision

/// On-device OCR for explicitly supplied files. This type never captures a screen or chooses scope.
nonisolated enum LocalOCR {
    static let maximumImageBytes = 20_971_520
    static let maximumPDFBytes = 10_485_760
    static let maximumPixels = 16_000_000
    static let maximumOutputBytes = 12_000

    static func validateImageDimensions(width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= 12_000, height <= 12_000,
              width <= maximumPixels / height else {
            throw RelayError.message("OCR image dimensions exceed the 16-megapixel limit or are invalid.")
        }
    }

    static func validatePDFPageLimit(_ maxPages: Int) throws {
        guard (1...5).contains(maxPages) else { throw RelayError.message("PDF OCR accepts a page limit from 1 to 5.") }
    }

    /// The caller must resolve and authorize file scope before calling this entry point.
    @concurrent static func recognizeImage(at url: URL) async throws -> String {
        try Task.checkCancellation()
        let data = try boundedData(at: url, maximumBytes: maximumImageBytes)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw RelayError.message("This file is not a decodable image with known dimensions.")
        }
        try validateImageDimensions(width: width.intValue, height: height.intValue)
        try Task.checkCancellation()
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw RelayError.message("The selected image could not be decoded for local OCR.")
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        let text = try await recognize(image: image, orientation: CGImagePropertyOrientation(rawValue: orientation) ?? .up)
        try Task.checkCancellation()
        return boundedOutput(text, note: "OCR output was truncated at 12 KB.")
    }

    /// Extract text where available; render only bounded pages that lack a text layer.
    /// Returned text is recognition output, never independent proof of a model answer.
    @concurrent static func recognizePDF(at url: URL, maxPages: Int = 3) async throws -> String {
        try validatePDFPageLimit(maxPages)
        try Task.checkCancellation()
        let data = try boundedData(at: url, maximumBytes: maximumPDFBytes)
        guard let document = PDFDocument(data: data), !document.isLocked else {
            throw RelayError.message("PDF OCR needs an unlocked, readable PDF up to 10 MB.")
        }
        let count = min(document.pageCount, maxPages)
        guard count > 0 else { throw RelayError.message("The selected PDF contains no pages.") }
        var pages: [String] = []
        for index in 0..<count {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { throw RelayError.message("PDF page \(index + 1) could not be read.") }
            let embedded = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let text: String
            if !embedded.isEmpty { text = embedded }
            else { text = try await recognize(image: renderedImage(page), orientation: .up) }
            pages.append("[Page \(index + 1)]\n" + (text.isEmpty ? "[No text recognized]" : text))
            if pages.joined(separator: "\n\n").utf8.count >= maximumOutputBytes { break }
        }
        let pageNote = document.pageCount > count ? "\n\n[Only the first \(count) of \(document.pageCount) pages were processed.]" : ""
        try Task.checkCancellation()
        return boundedOutput(pages.joined(separator: "\n\n") + pageNote, note: "PDF OCR output was truncated at 12 KB; later pages may be omitted.")
    }

    static func boundedOutput(_ text: String, note: String) -> String {
        guard text.utf8.count > maximumOutputBytes else { return text }
        let marker = "\n[\(note)]"
        let budget = max(0, maximumOutputBytes - marker.utf8.count)
        var output = ""
        var used = 0
        for scalar in text.unicodeScalars {
            let size = scalar.utf8.count
            guard used + size <= budget else { break }
            output.unicodeScalars.append(scalar)
            used += size
        }
        return output + marker
    }

    private static func boundedData(at url: URL, maximumBytes: Int) throws -> Data {
        let data = try LocalStateFile.read(url, maximumBytes: maximumBytes)
        guard !data.isEmpty else { throw RelayError.message("The selected OCR file is empty.") }
        return data
    }

    // Vision explicitly supports cancel() while a request is performing. No other mutation is shared.
    private final class RequestBox: @unchecked Sendable {
        let request = VNRecognizeTextRequest()
    }

    private static func recognize(image: CGImage, orientation: CGImagePropertyOrientation) async throws -> String {
        try Task.checkCancellation()
        let box = RequestBox()
        let request = box.request
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = true
        // Vision performs recognition locally. No model provider or network request is involved.
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation)
        try await withTaskCancellationHandler(operation: {
            try handler.perform([request])
        }, onCancel: { box.request.cancel() })
        try Task.checkCancellation()
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    private static func renderedImage(_ page: PDFPage) throws -> CGImage {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0,
              bounds.width <= 6_000, bounds.height <= 6_000 else { throw RelayError.message("PDF page geometry is invalid or too large for OCR.") }
        let width = Int(ceil(bounds.width * 2))
        let height = Int(ceil(bounds.height * 2))
        try validateImageDimensions(width: width, height: height)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw RelayError.message("Could not allocate the bounded PDF OCR image.")
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: 2, y: 2)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .mediaBox, to: context)
        guard let image = context.makeImage() else { throw RelayError.message("PDF page rendering failed.") }
        return image
    }
}
