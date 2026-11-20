#if DEBUG
import CoreGraphics
import Dispatch
import Foundation
import Testing
import Vision
@testable import Relay

@MainActor struct VisionFirstPrimerFactoryCrossoverTests {
    @Test(.enabled(if: VisionFirstPrimerFactoryCrossover.mode != nil))
    func oneOwnedGeneratedPrimerRequestUsesSelectedFactory() throws {
        try #require(Thread.isMainThread)
        let mode = try #require(VisionFirstPrimerFactoryCrossover.mode)
        #expect(VisionFirstPrimerFactoryCrossover.run(mode))
    }
}

private nonisolated enum VisionFirstPrimerFactoryCrossover {
    enum Mode: String, Sendable { case raw, production }

    static var mode: Mode? {
        ProcessInfo.processInfo.environment["RELAY_RUN_VISION_PRIMER_FACTORY_CROSSOVER"].flatMap(Mode.init(rawValue:))
    }

    private static let firstImageSHA256 = "392a60effb99097db911e63747c7aae0cc96f3a326379d6d6e5dd7fbd979ffba"

    static func run(_ mode: Mode) -> Bool {
        let done = DispatchSemaphore(value: 0)
        let result = VisionRawHostThreeCheckProbe.Recorder()
        let queue = DispatchQueue(label: "Relay.OwnedVisionThreeCheckProbe", qos: .userInitiated)
        let began = ProcessInfo.processInfo.systemUptime
        let context = Context(mode: mode, began: began)
        context.emit("started", attempts: 0)
        queue.async {
            let passed = autoreleasepool { runOnQueue(context) }
            result.setExitCode(passed ? 0 : 1)
            done.signal()
        }
        done.wait()
        return result.snapshot().code == 0
    }

    private static func runOnQueue(_ context: Context) -> Bool {
        guard !Thread.isMainThread else {
            context.emit("wrongQueue", attempts: 0)
            return false
        }
        let owned: LocalOCRExecution.GeneratedFirstPrimerDiagnostic
        do { owned = try LocalOCRExecution.makeGeneratedFirstPrimerDiagnostic() }
        catch {
            context.emit("imageFailed", attempts: 0,
                         ["error": VisionRawHostThreeCheckProbe.errorRecord(error)])
            return false
        }
        let input = owned.input
        let image = input.image
        let digest = VisionRawHostThreeCheckProbe.pixelSHA256(image)
        guard digest == firstImageSHA256, image.width == 1_120, image.height == 160,
              image.bytesPerRow == 4_480, image.bitsPerPixel == 32,
              image.bitmapInfo.rawValue == 1, input.profile == .document,
              input.orientation == .up, input.preferCPU else {
            context.emit("imageMismatch", attempts: 0)
            return false
        }
        context.emit("imageReady", attempts: 0, ["pixelSHA256": firstImageSHA256,
            "width": image.width, "height": image.height, "bytesPerRow": image.bytesPerRow,
            "bitsPerPixel": image.bitsPerPixel, "bitmapInfo": image.bitmapInfo.rawValue])
        return autoreleasepool { runOneRequest(owned, context: context) }
    }

    private static func runOneRequest(_ owned: LocalOCRExecution.GeneratedFirstPrimerDiagnostic,
                                      context: Context) -> Bool {
        let configureBegan = ProcessInfo.processInfo.systemUptime
        let perform: () throws -> String
        do {
            switch context.mode {
            case .raw:
                let request = VNRecognizeTextRequest()
                let input = owned.input
                let handler = VNImageRequestHandler(cgImage: input.image, orientation: input.orientation)
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = false
                request.automaticallyDetectsLanguage = true
                request.usesCPUOnly = true
                perform = {
                    try handler.perform([request])
                    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                        .joined(separator: "\n")
                }
            case .production:
                let operation = try owned.makeProductionOperation()
                perform = { try operation.perform() }
            }
        } catch {
            context.emit("configurationFailed", attempts: 0,
                         ["error": VisionRawHostThreeCheckProbe.errorRecord(error)])
            return false
        }
        context.emit("configured", attempts: 0,
                     ["durationMilliseconds": VisionRawHostThreeCheckProbe.elapsed(configureBegan)])
        context.emit("performStarted", attempts: 1)
        let performBegan = ProcessInfo.processInfo.systemUptime
        let text: String
        do { text = try perform() }
        catch {
            context.emit("performFailed", attempts: 1,
                         ["durationMilliseconds": VisionRawHostThreeCheckProbe.elapsed(performBegan),
                          "error": VisionRawHostThreeCheckProbe.errorRecord(error)])
            return false
        }
        let duration = VisionRawHostThreeCheckProbe.elapsed(performBegan)
        let matched = DocumentOCRPreparation.validatePrimerOutput(text,
            expectedText: DocumentOCRPreparation.firstBannerText,
            forbiddenNonce: DocumentOCRPreparation.secondNonce)
        context.emit("performFinished", attempts: 1,
                     ["durationMilliseconds": duration, "positiveSourceMatch": matched])
        return matched
    }

    private struct Context: Sendable {
        let mode: Mode
        let began: Double

        func emit(_ phase: String, attempts: Int, _ detail: [String: Any] = [:]) {
            var record: [String: Any] = [
                "schema": 1, "phase": phase, "mode": mode.rawValue, "performAttempts": attempts,
                "pid": ProcessInfo.processInfo.processIdentifier, "onMainThread": Thread.isMainThread,
                "timestampMilliseconds": VisionRawHostThreeCheckProbe.elapsed(began)
            ]
            record.merge(detail) { current, _ in current }
            VisionRawHostThreeCheckProbe.emit(record)
        }
    }
}
#endif
