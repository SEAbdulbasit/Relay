import CoreGraphics
import CoreML
import CoreText
import CryptoKit
import Darwin
import Dispatch
import Foundation
import ImageIO
import Testing
import Vision
@testable import Relay

private final class OCRTestGate: @unchecked Sendable {
    static let shared = OCRTestGate()
    private let lock = NSLock()
    private var _done = false
    var isDone: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _done
    }
    func markDone() {
        lock.lock()
        defer { lock.unlock() }
        _done = true
    }
}

/// The full-suite fixtures share production readiness. On refusal preserve
/// only the generated primer's closed diagnostics, then rethrow the exact error.
func prepareOwnedOCRReadinessRecordingFailure() async throws {
    if ProcessInfo.processInfo.environment["RELAY_RUN_DOCUMENT_OCR_READINESS"] == "1" {
        while !OCRTestGate.shared.isDone {
            try await Task.sleep(for: .milliseconds(25))
        }
    }
    let execution = LocalOCRExecution.shared
    do {
        try await execution.prepareDocumentReadiness()
    } catch {
        let checks = execution.documentPreparationChecks
        if let encoded = try? JSONEncoder().encode(checks) {
            print("Owned full-suite OCR readiness refusal: " + String(decoding: encoded, as: UTF8.self))
        }
        throw error
    }
}

@Suite(.serialized) @MainActor struct DocumentOCRLiveReadinessTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_RUN_DOCUMENT_OCR_READINESS"] == "1"))
    func actualGeneratedPrimerAndFreshPostReadyImageRequirePositiveSourceText() async throws {
        defer { OCRTestGate.shared.markDone() }
        await awaitParitySuiteQuietWindow(milliseconds: 12500)
        let execution = LocalOCRExecution.shared
        let outcome: Result<Void, any Error>
        do { try await execution.prepareDocumentReadiness(); outcome = .success(()) }
        catch { outcome = .failure(error) }
        let checks = execution.documentPreparationChecks
        let encoded = try JSONEncoder().encode(checks)
        print("Owned generated OCR primer diagnostic: " + (String(data: encoded, encoding: .utf8) ?? "unavailable"))
        do {
            try outcome.get()
            try #require(checks.count == 3 && checks.allSatisfy(\.sourceMatched))
            let fresh = try DocumentOCRPreparation.makeBitmap(text: "RELAY SCREEN CHECK 97531")
            let recognized = try await execution.recognize(image: fresh, orientation: .up, preferCPU: true, profile: .document)
            #expect(DocumentOCRPreparation.validatePrimerOutput(recognized,
                expectedText: "RELAY SCREEN CHECK 97531", forbiddenNonce: "24681"))
            await execution.drain()
            #expect(execution.activeCount == 0 && execution.ownedCount == 0)
            let resources = execution.generatedResourceInfo
            #expect(resources.count == 3 && resources.allSatisfy { $0.width == 1_120 && $0.height == 160 && $0.pixelBytes == 716_800 })
            #expect(execution.accountedPixelBytes == 3 * 716_800)
            execution.cancelDocumentReadiness()
            await execution.drain()
            #expect(execution.generatedResourceInfo.isEmpty && execution.retiringGeneratedPixelBytes == 0)
            #expect(execution.activeCount == 0 && execution.accountedPixelBytes == 0)
        } catch {
            execution.cancelDocumentReadiness()
            await execution.drain()
            throw error
        }
    }
}

/// Exact e54d raw three-check Vision probe inside one opted-in SwiftTesting host
/// process. Uses the same serial .userInitiated GCD queue, outer sequence
/// autoreleasepool, inner per-check autoreleasepools, CoreText bitmap recipe,
/// public VNRecognizeTextRequest configuration, and positive/negative source
/// oracles, without touching LocalOCRExecution or any production worker/API.
nonisolated struct VisionRawHostThreeCheckProbeTests {
    @Test func rawThreeCheckOracleRequiresPositiveSourceTextOnAllThreeChecks() {
        #expect(VisionRawHostThreeCheckProbe.evaluateCheck(
            recognizedText: "RELAY SCREEN CHECK 24681",
            imageID: "A",
            expectedNonce: "24681",
            expectedMatch: true
        ) == .init(passed: true, textMatch: true, actualOwnedSourceTextMatch: true))

        #expect(VisionRawHostThreeCheckProbe.evaluateCheck(
            recognizedText: "RELAY SCREEN CHECK 24681",
            imageID: "A",
            expectedNonce: "24682",
            expectedMatch: false
        ) == .init(passed: true, textMatch: false, actualOwnedSourceTextMatch: true))

        #expect(VisionRawHostThreeCheckProbe.evaluateCheck(
            recognizedText: "Relay Capture Fixture 24681",
            imageID: "B",
            expectedNonce: "24681",
            expectedMatch: false
        ) == .init(passed: true, textMatch: false, actualOwnedSourceTextMatch: true))

        // Empty OCR output or leaked Image A text on Image B must fail closed.
        #expect(!VisionRawHostThreeCheckProbe.evaluateCheck(
            recognizedText: "",
            imageID: "A",
            expectedNonce: "24682",
            expectedMatch: false
        ).passed)
        #expect(!VisionRawHostThreeCheckProbe.evaluateCheck(
            recognizedText: "",
            imageID: "B",
            expectedNonce: "24681",
            expectedMatch: false
        ).passed)
        #expect(!VisionRawHostThreeCheckProbe.evaluateCheck(
            recognizedText: "RELAY SCREEN CHECK 24681",
            imageID: "B",
            expectedNonce: "24681",
            expectedMatch: false
        ).passed)
    }

    @MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["RELAY_RUN_VISION_RAW_THREE_CHECK_PROBE"] == "1"))
    func actualRawThreeCheckProbeMatchesStandalonePoolAndSourceOracles() throws {
        try #require(Thread.isMainThread, "The exact standalone comparison waits on the main thread.")
        let summary = VisionRawHostThreeCheckProbe.executeCPUProbe()
        #expect(summary.exitCode == 0)
        #expect(summary.performAttempts == 3)
        #expect(summary.checksPassed == 3)
        #expect(!summary.wrongExecutionQueue)
        #expect(summary.checkIndices == [1, 2, 3])
        #expect(summary.textMatches == [true, false, false])
        #expect(summary.sourceTextMatches == [true, true, true])
        #expect(summary.observationCounts.count == 3 && summary.observationCounts.allSatisfy { $0 > 0 })
        #expect(summary.checkSuccesses == [true, true, true])
        #expect(summary.queueEventsOffMainThread)
    }
}

nonisolated enum VisionRawHostThreeCheckProbe {
    enum Mode: String, Sendable { case cpu }
    enum Failure: Error { case bitmapUnavailable }

    struct OracleEvaluation: Sendable, Equatable {
        let passed: Bool
        let textMatch: Bool
        let actualOwnedSourceTextMatch: Bool
    }

    struct Summary: Sendable, Equatable {
        let exitCode: Int32
        let performAttempts: Int
        let checksPassed: Int
        let wrongExecutionQueue: Bool
        let checkIndices: [Int]
        let textMatches: [Bool]
        let sourceTextMatches: [Bool]
        let observationCounts: [Int]
        let checkSuccesses: [Bool]
        let queueEventsOffMainThread: Bool
    }

    struct Outcome: Sendable {
        let code: Int32
        let performed: Int
    }

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var records: [[String: Any]] = []
        private var code: Int32 = 70

        func append(_ record: [String: Any]) {
            lock.withLock { records.append(record) }
        }

        func setExitCode(_ value: Int32) {
            lock.withLock { code = value }
        }

        func snapshot() -> (code: Int32, records: [[String: Any]]) {
            lock.withLock { (code, records) }
        }
    }

    struct Context: Sendable {
        let mode: Mode
        let began: Double
        let pid: Int32
        let recorder: Recorder

        func log(_ phase: String, check: Int = 0, image: String = "none", performs: Int,
                 _ detail: [String: Any] = [:]) {
            var record: [String: Any] = [
                "schema": 1,
                "phase": phase,
                "mode": mode.rawValue,
                "pid": pid,
                "checkIndex": check,
                "image": image,
                "performAttempts": performs,
                "timestampMilliseconds": VisionRawHostThreeCheckProbe.elapsed(began),
                "onMainThread": Thread.isMainThread
            ]
            record.merge(detail) { _, current in current }
            recorder.append(record)
            VisionRawHostThreeCheckProbe.emit(record)
        }
    }

    static func executeCPUProbe() -> Summary {
        let recorder = Recorder()
        let context = Context(
            mode: .cpu,
            began: ProcessInfo.processInfo.systemUptime,
            pid: ProcessInfo.processInfo.processIdentifier,
            recorder: recorder
        )
        let completed = DispatchSemaphore(value: 0)
        context.log("started", performs: 0, ["maximumPerforms": 3, "fixedNonce": "24681", "host": "SwiftTesting"])
        let queue = DispatchQueue(label: "Relay.OwnedVisionThreeCheckProbe", qos: .userInitiated)
        queue.async {
            let code = autoreleasepool { run(context) }
            recorder.setExitCode(code)
            completed.signal()
        }
        completed.wait()
        let (code, records) = recorder.snapshot()
        let finishedChecks = records.filter { ($0["phase"] as? String) == "checkFinished" }
        let sequenceFinished = records.last { ($0["phase"] as? String) == "sequenceFinished" }
        let queueRecords = records.filter { ($0["phase"] as? String) != "started" }
        return Summary(
            exitCode: code,
            performAttempts: (sequenceFinished?["performAttempts"] as? Int) ?? -1,
            checksPassed: (sequenceFinished?["checksPassed"] as? Int) ?? -1,
            wrongExecutionQueue: records.contains { ($0["phase"] as? String) == "wrongExecutionQueue" },
            checkIndices: finishedChecks.compactMap { $0["checkIndex"] as? Int },
            textMatches: finishedChecks.compactMap { $0["textMatch"] as? Bool },
            sourceTextMatches: finishedChecks.compactMap { $0["actualOwnedSourceTextMatch"] as? Bool },
            observationCounts: finishedChecks.compactMap { $0["observationCount"] as? Int },
            checkSuccesses: finishedChecks.compactMap { $0["success"] as? Bool },
            queueEventsOffMainThread: !queueRecords.isEmpty && queueRecords.allSatisfy { ($0["onMainThread"] as? Bool) == false }
        )
    }

    static func run(_ context: Context) -> Int32 {
        guard !Thread.isMainThread else {
            context.log("wrongExecutionQueue", performs: 0)
            return 70
        }
        context.log("sequenceStarted", performs: 0)
        var performs = 0, passed = 0
        func finished(_ code: Int32, at check: Int) -> Int32 {
            context.log("sequenceFinished", check: check, performs: performs,
                ["success": code == 0, "checksPassed": passed, "exitCode": code])
            return code
        }
        let imageA: CGImage
        do { imageA = try timedBitmap(context, image: "A", text: "RELAY SCREEN CHECK 24681", performs: performs) }
        catch { return finished(70, at: 1) }
        let first = autoreleasepool {
            check(context, image: imageA, imageID: "A", index: 1, expectedNonce: "24681",
                  expectedMatch: true, reused: false, performedBefore: performs)
        }
        performs += first.performed
        guard first.code == 0 else { return finished(first.code, at: 1) }
        passed += 1
        // This second independent negative check MUST rerun recognition on the
        // SAME CGImage. It cannot reuse the first request, result or text.
        let second = autoreleasepool {
            check(context, image: imageA, imageID: "A", index: 2, expectedNonce: "24682",
                  expectedMatch: false, reused: true, performedBefore: performs)
        }
        performs += second.performed
        guard second.code == 0 else { return finished(second.code, at: 2) }
        passed += 1
        let imageB: CGImage
        do { imageB = try timedBitmap(context, image: "B", text: "Relay Capture Fixture 24681", performs: performs) }
        catch { return finished(70, at: 3) }
        let third = autoreleasepool {
            check(context, image: imageB, imageID: "B", index: 3, expectedNonce: "24681",
                  expectedMatch: false, reused: false, performedBefore: performs)
        }
        performs += third.performed
        guard third.code == 0 else { return finished(third.code, at: 3) }
        passed += 1
        return finished(0, at: 3)
    }

    static func timedBitmap(_ context: Context, image: String, text: String, performs: Int) throws -> CGImage {
        context.log("bitmapStarted", image: image, performs: performs)
        let began = ProcessInfo.processInfo.systemUptime
        do {
            let result = try bitmap(text: text)
            guard let pixels = pixelSHA256(result) else { throw Failure.bitmapUnavailable }
            context.log("bitmapFinished", image: image, performs: performs,
                ["durationMilliseconds": elapsed(began), "width": result.width,
                 "height": result.height, "bytesPerRow": result.bytesPerRow,
                 "pixelSHA256": pixels, "bitsPerPixel": result.bitsPerPixel,
                 "bitmapInfo": result.bitmapInfo.rawValue])
            return result
        } catch {
            context.log("bitmapFailed", image: image, performs: performs,
                ["durationMilliseconds": elapsed(began), "error": errorRecord(error)])
            throw error
        }
    }

    static func check(_ context: Context, image: CGImage, imageID: String, index: Int,
                      expectedNonce: String, expectedMatch: Bool, reused: Bool,
                      performedBefore: Int) -> Outcome {
        context.log("configurationStarted", check: index, image: imageID, performs: performedBefore,
            ["expectedNonce": expectedNonce, "expectedMatch": expectedMatch, "sameImageAsPrevious": reused])
        let configurationBegan = ProcessInfo.processInfo.systemUptime
        let request = VNRecognizeTextRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = true
        // Public deprecated compatibility discriminator only, after all other config.
        // No per-stage query/assignment, fallback, language narrowing or product change.
        request.usesCPUOnly = true
        let deviceMilliseconds: Double = 0
        let configuration: [String: Any] = [
            "recognitionLevel": "accurate",
            "usesLanguageCorrection": false,
            "automaticallyDetectsLanguage": request.automaticallyDetectsLanguage,
            "orientation": "up",
            "revision": request.revision,
            "stageQuery": "notRequestedDeprecatedCPUOnlyDiscriminator",
            "usesCPUOnly": request.usesCPUOnly,
            "recognitionLanguages": "defaultPreserved"
        ]
        let configurationMilliseconds = elapsed(configurationBegan)
        context.log("configurationFinished", check: index, image: imageID, performs: performedBefore,
            ["durationMilliseconds": configurationMilliseconds, "configuration": configuration])
        let attempted = performedBefore + 1
        context.log("performStarted", check: index, image: imageID, performs: attempted)
        let performBegan = ProcessInfo.processInfo.systemUptime
        do { try handler.perform([request]) }
        catch {
            context.log("performFailed", check: index, image: imageID, performs: attempted,
                ["durationMilliseconds": elapsed(performBegan), "error": errorRecord(error)])
            return Outcome(code: 1, performed: 1)
        }
        let performMilliseconds = elapsed(performBegan)
        context.log("performFinished", check: index, image: imageID, performs: attempted,
            ["durationMilliseconds": performMilliseconds])
        context.log("extractionStarted", check: index, image: imageID, performs: attempted)
        let extractionBegan = ProcessInfo.processInfo.systemUptime
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        let oracle = evaluateCheck(
            recognizedText: text,
            imageID: imageID,
            expectedNonce: expectedNonce,
            expectedMatch: expectedMatch
        )
        let extractionMilliseconds = elapsed(extractionBegan)
        context.log("extractionFinished", check: index, image: imageID, performs: attempted,
            ["durationMilliseconds": extractionMilliseconds, "observationCount": request.results?.count ?? 0])
        context.log("checkFinished", check: index, image: imageID, performs: attempted,
            ["success": oracle.passed, "expectedMatch": expectedMatch, "textMatch": oracle.textMatch,
             "actualOwnedSourceTextMatch": oracle.actualOwnedSourceTextMatch,
             "observationCount": request.results?.count ?? 0,
             "configurationDurationMilliseconds": configurationMilliseconds,
             "deviceQueryDurationMilliseconds": deviceMilliseconds,
             "performDurationMilliseconds": performMilliseconds,
             "extractionDurationMilliseconds": extractionMilliseconds])
        return Outcome(code: oracle.passed ? 0 : 2, performed: 1)
    }

    static func evaluateCheck(recognizedText: String, imageID: String,
                              expectedNonce: String, expectedMatch: Bool) -> OracleEvaluation {
        let expected = normalized("RELAY SCREEN CHECK " + expectedNonce)
        let matched = recognizedText.split(whereSeparator: \.isNewline).contains { normalized(String($0)) == expected }
        let actualOwnedText = imageID == "A" ? "RELAY SCREEN CHECK 24681" : "Relay Capture Fixture 24681"
        let sourceTextMatch = recognizedText.split(whereSeparator: \.isNewline).contains {
            normalized(String($0)) == normalized(actualOwnedText)
        }
        // Strengthens both negative oracles: empty responses cannot pass them.
        let passed = matched == expectedMatch && sourceTextMatch
        return OracleEvaluation(
            passed: passed,
            textMatch: matched,
            actualOwnedSourceTextMatch: sourceTextMatch
        )
    }

    /// Same offscreen CoreText fixture bytes/geometry/options as the compiled
    /// ScreenCaptureCheckTests helper and e54d standalone probe.
    static func bitmap(text: String) throws -> CGImage {
        guard let context = CGContext(data: nil, width: 1_120, height: 160, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure.bitmapUnavailable }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1_120, height: 160))
        let text = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Menlo-Bold" as CFString, 56, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ])
        context.textPosition = CGPoint(x: 35, y: 57)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        guard let image = context.makeImage() else { throw Failure.bitmapUnavailable }
        return image
    }

    static func pixelSHA256(_ image: CGImage) -> String? {
        guard let provider = image.dataProvider,
              let data = provider.data as Data?,
              !data.isEmpty else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func normalized(_ text: String) -> String {
        text.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    static func errorRecord(_ error: any Error) -> [String: Any] {
        let records = LocalOCRExecution.primerSDKErrorRecords(error)
        let root = records.first ?? .init(domain: "unavailable", code: (error as NSError).code)
        let underlying = records.dropFirst().map { ["domain": $0.domain, "code": $0.code] }
        return [
            "type": "NSError",
            "domain": root.domain,
            "code": root.code,
            "underlying": underlying
        ]
    }

    static func elapsed(_ began: Double) -> Double {
        let value = (ProcessInfo.processInfo.systemUptime - began) * 1_000
        return value.isFinite ? max(0, value) : -1
    }

    static func emit(_ record: [String: Any]) {
        guard var bytes = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
              bytes.count <= 16_384 else { return }
        bytes.append(10)
        FileHandle.standardOutput.write(bytes)
    }
}
