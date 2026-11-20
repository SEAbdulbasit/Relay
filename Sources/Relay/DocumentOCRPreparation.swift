import AppKit
import CoreGraphics
import CoreText
import Foundation

/// App-lifetime coordinator for genuine three-stage OCR readiness on the shared
/// `LocalOCRExecution` slot: runs three `.document` (`.accurate`) checks on
/// `1120x160` CoreText bitmaps matching the verified three-check CPU probe
/// order (Step 1 on fresh `firstBannerText` bitmap, Step 2 reusing the same
/// `CGImage` instance with a fresh request/handler, Step 3 on a fresh
/// `secondBannerText` bitmap). At most three generated bitmap/request contexts
/// stay charged to the decoded budget while ready. No private image is retained.
/// Termination explicitly cancels any in-flight priming generation without
/// altering `AssistantStore.stop()`.
@MainActor final class DocumentOCRPreparation {
    nonisolated static let defaultTimeout: Duration = .seconds(90)
    nonisolated static let firstBannerText = "RELAY SCREEN CHECK 24681"
    nonisolated static let firstNonce = "24681"
    nonisolated static let secondBannerText = "RELAY SCREEN CHECK 13579"
    nonisolated static let secondNonce = "13579"
    nonisolated static let bannerWidth = 1_120
    nonisolated static let bannerHeight = 160
    nonisolated static let bannerPixelBytes = bannerWidth * 4 * bannerHeight

    nonisolated enum PrimerStep: Int, Sendable, Equatable, CaseIterable {
        case firstDocumentCheck = 1
        case reusedDocumentCheck = 2
        case secondDocumentCheck = 3

        var profile: LocalOCRExecution.Profile {
            .document
        }

        var reusesPreviousImage: Bool {
            self == .reusedDocumentCheck
        }

        var expectedText: String {
            switch self {
            case .firstDocumentCheck, .reusedDocumentCheck:
                DocumentOCRPreparation.firstBannerText
            case .secondDocumentCheck:
                DocumentOCRPreparation.secondBannerText
            }
        }

        var forbiddenNonce: String {
            switch self {
            case .firstDocumentCheck, .reusedDocumentCheck:
                DocumentOCRPreparation.secondNonce
            case .secondDocumentCheck:
                DocumentOCRPreparation.firstNonce
            }
        }

        var nextStep: PrimerStep? {
            switch self {
            case .firstDocumentCheck:
                .reusedDocumentCheck
            case .reusedDocumentCheck:
                .secondDocumentCheck
            case .secondDocumentCheck:
                nil
            }
        }
    }

    nonisolated struct PrimerCheck: @unchecked Sendable {
        let step: PrimerStep
        let expectedText: String
        let forbiddenNonce: String
        let image: CGImage
        let pixelBytes: Int
    }

    private let execution: LocalOCRExecution
    private let timeout: Duration
    private var lifetime: AssistantApplicationLifetime?
    private var task: Task<Void, Never>?
    private var activeTaskID: UUID?
    private(set) var isTerminated = false

    init(execution: LocalOCRExecution = .shared,
         center: NotificationCenter = .default,
         timeout: Duration = DocumentOCRPreparation.defaultTimeout,
         startImmediately: Bool = false) {
        self.execution = execution
        self.timeout = timeout
        self.lifetime = AssistantApplicationLifetime(center: center) { [weak self] in
            self?.stopForTermination()
        }
        if startImmediately {
            start()
        }
    }

    static func startAppOwned(execution: LocalOCRExecution = .shared,
                              center: NotificationCenter = .default,
                              timeout: Duration = DocumentOCRPreparation.defaultTimeout) -> DocumentOCRPreparation {
        DocumentOCRPreparation(execution: execution, center: center, timeout: timeout, startImmediately: true)
    }

    @discardableResult
    func start() -> Task<Void, Never>? {
        guard !isTerminated else { return nil }
        if let task { return task }
        let execution = self.execution
        let timeout = self.timeout
        let id = UUID()
        activeTaskID = id
        let created = Task { [weak self] in
            defer {
                if self?.activeTaskID == id {
                    self?.task = nil
                    self?.activeTaskID = nil
                }
            }
            _ = try? await execution.prepareDocumentReadiness(timeout: timeout)
        }
        task = created
        return created
    }

    func prepareNow() async throws {
        guard !isTerminated else { throw CancellationError() }
        try await execution.prepareDocumentReadiness(timeout: timeout)
    }

    func stopForTermination() {
        isTerminated = true
        task?.cancel()
        task = nil
        activeTaskID = nil
        execution.cancelDocumentReadiness()
    }

    isolated deinit {
        task?.cancel()
    }

    nonisolated static func makePrimerCheck(for step: PrimerStep,
                                            reusing previousImage: CGImage? = nil) throws -> PrimerCheck {
        let image: CGImage
        if step.reusesPreviousImage {
            guard let previousImage,
                  previousImage.width == bannerWidth,
                  previousImage.height == bannerHeight,
                  previousImage.bytesPerRow == bannerWidth * 4 else {
                throw LocalOCRExecution.Failure.invalidImage
            }
            image = previousImage
        } else {
            image = try makeBitmap(text: step.expectedText)
        }
        let bytes = try LocalOCRExecution.checkedPixelBytes(
            bytesPerRow: image.bytesPerRow,
            height: image.height
        )
        return PrimerCheck(
            step: step,
            expectedText: step.expectedText,
            forbiddenNonce: step.forbiddenNonce,
            image: image,
            pixelBytes: bytes
        )
    }

    nonisolated static func makeBitmap(text: String) throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: bannerWidth,
            height: bannerHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw LocalOCRExecution.Failure.invalidImage
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: bannerWidth, height: bannerHeight))
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Menlo-Bold" as CFString, 56, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ])
        context.textPosition = CGPoint(x: 35, y: 57)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        guard let image = context.makeImage(),
              image.width == bannerWidth,
              image.height == bannerHeight else {
            throw LocalOCRExecution.Failure.invalidImage
        }
        return image
    }

    nonisolated static func validatePrimerOutput(_ recognized: String,
                                                 expectedText: String,
                                                 forbiddenNonce: String) -> Bool {
        let expected = normalized(expectedText)
        guard !expected.isEmpty else { return false }
        let lines = recognized.split(whereSeparator: \.isNewline).map { normalized(String($0)) }
        guard lines.contains(expected) else { return false }
        let forbidden = normalized(forbiddenNonce)
        if !forbidden.isEmpty, lines.joined().contains(forbidden) {
            return false
        }
        return true
    }

    nonisolated static func normalized(_ text: String) -> String {
        text.uppercased().filter { $0.isLetter || $0.isNumber }
    }
}
