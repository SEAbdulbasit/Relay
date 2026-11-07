import AppKit
import Foundation

/// The answer is local comparison data, never a prompt hint or persisted state.
/// This is an image-input check, not evidence of tool or action reliability.
nonisolated struct LMStudioVisionProbe: Sendable {
    static let width = 640
    static let height = 240
    let jpeg: Data
    let expectedMarker: String

    @MainActor static func make() throws -> Self {
        let alphabet = Array("BCDFGHJKLMNPQRSTVWXYZ23456789")
        var generator = SystemRandomNumberGenerator()
        let marker = String((0..<8).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &generator)] })
        guard let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32),
              let context = NSGraphicsContext(bitmapImageRep: image) else { throw LMStudioFailure.visionProbeFailed }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 72, weight: .bold),
                                                       .foregroundColor: NSColor.black]
        let size = (marker as NSString).size(withAttributes: attributes)
        (marker as NSString).draw(at: NSPoint(x: (CGFloat(width) - size.width) / 2,
                                             y: (CGFloat(height) - size.height) / 2), withAttributes: attributes)
        guard let jpeg = image.representation(using: .jpeg, properties: [.compressionFactor: 0.9]),
              !jpeg.isEmpty, jpeg.count <= LMStudioVisionAttachment.maximumJPEGBytes else { throw LMStudioFailure.visionProbeFailed }
        return Self(jpeg: jpeg, expectedMarker: marker)
    }
}
