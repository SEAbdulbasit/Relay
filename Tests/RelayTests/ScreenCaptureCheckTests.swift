import AppKit
import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import Relay

@MainActor
struct ScreenCaptureCheckTests {
    @Test func visibleMarkerMustMatchTheFixtureLaunch() async throws {
        let image = try bitmap(text: "RELAY SCREEN CHECK 24681")
        #expect(try await ScreenCaptureCheck.markerIsVisible(in: image, nonce: "24681"))
        #expect(try await !ScreenCaptureCheck.markerIsVisible(in: image, nonce: "24682"))
        let titleOnly = try bitmap(text: "Relay Capture Fixture 24681")
        #expect(try await !ScreenCaptureCheck.markerIsVisible(in: titleOnly, nonce: "24681"))
    }

    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["RELAY_RUN_SCREEN_CAPTURE_TEST"] == "1"),
        .timeLimit(.minutes(1))
    )
    func realBundledWindowCaptureReadsItsLaunchMarker() async throws {
        _ = NSApplication.shared
        try #require(CGPreflightScreenCaptureAccess(),
                     "The test runner needs existing macOS screen capture permission. This test never requests it.")
        let path = try #require(ProcessInfo.processInfo.environment["RELAY_AX_FIXTURE_APP"],
                                "Set RELAY_AX_FIXTURE_APP to the bundled RelayAccessibilityFixture.app.")
        try #require(path.hasPrefix("/"), "RELAY_AX_FIXTURE_APP must be an absolute path.")
        let report = try await ScreenCaptureCheck.run(fixtureURL: URL(fileURLWithPath: path))
        #expect(report.allPassed, Comment(rawValue: report.summary))
    }

    private func bitmap(text: String) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 1_120, height: 160, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1_120, height: 160))
        let text = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Menlo-Bold" as CFString, 56, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ])
        context.textPosition = CGPoint(x: 35, y: 57)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        return try #require(context.makeImage())
    }
}
