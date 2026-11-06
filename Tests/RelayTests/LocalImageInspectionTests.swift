import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Testing
@preconcurrency import LiteRTLM
@testable import Relay

@MainActor
struct LocalImageInspectionTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_VISION_TEST_MODEL"] != nil), .timeLimit(.minutes(4)))
    func recognizesTwoOppositeColorsFromNativeImageInput() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["RELAY_VISION_TEST_MODEL"])
        let backend = ProcessInfo.processInfo.environment["RELAY_VISION_TEST_BACKEND"] ?? "cpu"
        for (red, blue, expected) in [(1.0, 0.0, "red"), (0.0, 1.0, "blue")] {
            let image = try imageFixture(red: red, blue: blue)
            let reply = try await LocalImageInference.inspect(InspectionImage(jpeg: image, label: "Synthetic color card"),
                question: "Which color fills most of this image? Answer with one color word.",
                configuration: ModelConfiguration(modelPath: path, computeBackend: backend))
            #expect(reply.lowercased().contains(expected), Comment(rawValue: reply))
        }
    }

    @Test func normalizesASelectedImageAndRejectsNonImageBytes() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "card.jpg")
        try imageFixture(red: 1, blue: 0).write(to: file)
        let prepared = try await InspectionImage.loadFile(file)
        #expect(prepared.label == "card.jpg")
        #expect(CGImageSourceCreateWithData(prepared.jpeg as CFData, nil) != nil)
        try Data("not an image".utf8).write(to: file)
        await #expect(throws: (any Error).self) { try await InspectionImage.loadFile(file) }
    }

    private func imageFixture(red: Double, blue: Double) throws -> Data {
        let context = try #require(CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: red, green: 0.05, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
