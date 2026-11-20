import AppKit
import CoreGraphics
import CryptoKit
import Dispatch
import Foundation
import ImageIO
import Testing
@testable import Relay

nonisolated private final class ReadinessGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var didEnter = false
    private var released = false

    var entered: Bool { lock.withLock { didEnter } }

    func pause() {
        let shouldWait = lock.withLock { () -> Bool in
            guard !didEnter, !released else { return false }
            didEnter = true
            return true
        }
        if shouldWait { semaphore.wait() }
    }

    func release() {
        let shouldSignal = lock.withLock {
            let first = !released
            released = true
            return first
        }
        if shouldSignal {
            semaphore.signal()
        }
    }
}

nonisolated private final class ReadinessHarness: @unchecked Sendable {
    struct Entry: Sendable, Equatable {
        let sequence: Int
        let reusedPreviousImage: Bool
        let width: Int
        let height: Int
        let pixelBytes: Int
        let profile: LocalOCRExecution.Profile
        let preferCPU: Bool
        let pixelDigest: Data
    }

    struct Snapshot: Sendable, Equatable {
        let factories: [Entry]
        let performs: [Int]
        let cancellations: [Int]
        let releases: [Int]
        let mainThreadObserved: Bool
        let firstPerformFinished: Bool
        let firstCancelFinished: Bool
    }

    enum ResponseMode: Sendable {
        case validPrimerAndEcho
        case firstDocumentEmpty
        case firstDocumentWrongNonce
        case reusedDocumentEmpty
        case reusedDocumentWrongNonce
        case secondDocumentEmpty
        case secondDocumentLeaksFirstNonce
        case performThrows
    }

    private let lock = NSLock()
    private let firstPrimerDigest: Data
    private let secondPrimerDigest: Data
    private var nextSequence = 0
    private var factories: [Entry] = []
    // Only actual live operations witness image identity. Historical addresses
    // cannot classify a fresh generation after the previous operation retires.
    private var liveOperationImages: [Int: CGImage] = [:]
    private var performs: [Int] = []
    private var cancellations: [Int] = []
    private var releases: [Int] = []
    private var mainThreadObserved = false
    private var firstPerformFinished = false
    private var firstCancelFinished = false
    private var mode: ResponseMode
    let firstDocumentPerformGate: ReadinessGate?
    let reusedDocumentPerformGate: ReadinessGate?
    let secondDocumentPerformGate: ReadinessGate?
    let firstCancelGate: ReadinessGate?
    let ordinaryPerformGate: ReadinessGate?

    init(mode: ResponseMode = .validPrimerAndEcho,
         firstDocumentPerformGate: ReadinessGate? = nil,
         reusedDocumentPerformGate: ReadinessGate? = nil,
         secondDocumentPerformGate: ReadinessGate? = nil,
         firstCancelGate: ReadinessGate? = nil,
         ordinaryPerformGate: ReadinessGate? = nil) {
        self.firstPrimerDigest = (try? DocumentOCRPreparation.makeBitmap(text: DocumentOCRPreparation.firstBannerText))
            .map(Self.pixelDigest(for:)) ?? Data()
        self.secondPrimerDigest = (try? DocumentOCRPreparation.makeBitmap(text: DocumentOCRPreparation.secondBannerText))
            .map(Self.pixelDigest(for:)) ?? Data()
        self.mode = mode
        self.firstDocumentPerformGate = firstDocumentPerformGate
        self.reusedDocumentPerformGate = reusedDocumentPerformGate
        self.secondDocumentPerformGate = secondDocumentPerformGate
        self.firstCancelGate = firstCancelGate
        self.ordinaryPerformGate = ordinaryPerformGate
    }

    var snapshot: Snapshot {
        lock.withLock {
            Snapshot(
                factories: factories,
                performs: performs,
                cancellations: cancellations,
                releases: releases,
                mainThreadObserved: mainThreadObserved,
                firstPerformFinished: firstPerformFinished,
                firstCancelFinished: firstCancelFinished
            )
        }
    }

    var liveOperationImageCount: Int { lock.withLock { liveOperationImages.count } }

    func shareLiveImage(_ first: Int, _ second: Int) -> Bool {
        lock.withLock {
            guard let firstImage = liveOperationImages[first],
                  let secondImage = liveOperationImages[second] else { return false }
            return ObjectIdentifier(firstImage) == ObjectIdentifier(secondImage)
        }
    }

    func setMode(_ newMode: ResponseMode) {
        lock.withLock { mode = newMode }
    }

    func releaseAll() {
        firstDocumentPerformGate?.release()
        reusedDocumentPerformGate?.release()
        secondDocumentPerformGate?.release()
        firstCancelGate?.release()
        ordinaryPerformGate?.release()
    }

    func make(_ input: LocalOCRExecution.Input) -> any LocalOCRExecution.Operation {
        let digest = Self.pixelDigest(for: input.image)
        let entry = lock.withLock { () -> Entry in
            nextSequence += 1
            mainThreadObserved = mainThreadObserved || Thread.isMainThread
            let previousImage = factories.last.flatMap { liveOperationImages[$0.sequence] }
            let reusedPreviousImage = previousImage.map {
                ObjectIdentifier($0) == ObjectIdentifier(input.image)
            } ?? false
            let created = Entry(
                sequence: nextSequence,
                reusedPreviousImage: reusedPreviousImage,
                width: input.image.width,
                height: input.image.height,
                pixelBytes: input.image.bytesPerRow * input.image.height,
                profile: input.profile,
                preferCPU: input.preferCPU,
                pixelDigest: digest
            )
            factories.append(created)
            liveOperationImages[created.sequence] = input.image
            return created
        }
        return ReadinessOperation(entry: entry, harness: self)
    }

    func perform(_ entry: Entry) throws -> String {
        let currentMode = lock.withLock { () -> ResponseMode in
            performs.append(entry.sequence)
            mainThreadObserved = mainThreadObserved || Thread.isMainThread
            return mode
        }
        let isBannerGeometry = entry.width == DocumentOCRPreparation.bannerWidth
            && entry.height == DocumentOCRPreparation.bannerHeight
        let isFirstBanner = isBannerGeometry && entry.pixelDigest == firstPrimerDigest
        let isSecondBanner = isBannerGeometry && entry.pixelDigest == secondPrimerDigest

        if isBannerGeometry && entry.profile == .document {
            if isFirstBanner && !entry.reusedPreviousImage {
                if entry.sequence == 1 {
                    firstDocumentPerformGate?.pause()
                    lock.withLock { firstPerformFinished = true }
                } else {
                    firstDocumentPerformGate?.pause()
                }
                switch currentMode {
                case .firstDocumentEmpty:
                    return ""
                case .firstDocumentWrongNonce:
                    return "RELAY SCREEN CHECK 99999"
                case .performThrows:
                    throw RelayError.message("SYNTHETIC_PRIMER_BACKEND_FAILURE")
                case .validPrimerAndEcho, .reusedDocumentEmpty, .reusedDocumentWrongNonce, .secondDocumentEmpty, .secondDocumentLeaksFirstNonce:
                    return DocumentOCRPreparation.firstBannerText
                }
            } else if isFirstBanner && entry.reusedPreviousImage {
                reusedDocumentPerformGate?.pause()
                switch currentMode {
                case .reusedDocumentEmpty:
                    return ""
                case .reusedDocumentWrongNonce:
                    return "RELAY SCREEN CHECK 99999"
                case .performThrows:
                    throw RelayError.message("SYNTHETIC_PRIMER_BACKEND_FAILURE")
                case .validPrimerAndEcho, .firstDocumentEmpty, .firstDocumentWrongNonce, .secondDocumentEmpty, .secondDocumentLeaksFirstNonce:
                    return DocumentOCRPreparation.firstBannerText
                }
            } else if isSecondBanner {
                secondDocumentPerformGate?.pause()
                switch currentMode {
                case .validPrimerAndEcho:
                    return DocumentOCRPreparation.secondBannerText
                case .firstDocumentEmpty, .firstDocumentWrongNonce, .reusedDocumentEmpty, .reusedDocumentWrongNonce, .secondDocumentEmpty:
                    return ""
                case .secondDocumentLeaksFirstNonce:
                    return DocumentOCRPreparation.firstBannerText + "\n" + DocumentOCRPreparation.secondBannerText
                case .performThrows:
                    throw RelayError.message("SYNTHETIC_PRIMER_BACKEND_FAILURE")
                }
            }
        }

        if entry.width == 1 {
            ordinaryPerformGate?.pause()
        }
        if entry.profile == .ownedEnglishMarker {
            return DocumentOCRPreparation.firstBannerText
        }
        return "document-\(entry.width)"
    }

    func cancel(_ entry: Entry) {
        lock.withLock {
            cancellations.append(entry.sequence)
            mainThreadObserved = mainThreadObserved || Thread.isMainThread
        }
        if entry.sequence == 1 {
            firstCancelGate?.pause()
            lock.withLock { firstCancelFinished = true }
        }
    }

    func released(_ entry: Entry) {
        lock.withLock {
            liveOperationImages.removeValue(forKey: entry.sequence)
            releases.append(entry.sequence)
            mainThreadObserved = mainThreadObserved || Thread.isMainThread
        }
    }
    private static func pixelDigest(for image: CGImage) -> Data {
        guard let provider = image.dataProvider,
              let cfData = provider.data else {
            return Data()
        }
        return Data(SHA256.hash(data: cfData as Data))
    }
}

nonisolated private final class ReadinessOperation: LocalOCRExecution.Operation, @unchecked Sendable {
    let entry: ReadinessHarness.Entry
    let harness: ReadinessHarness

    init(entry: ReadinessHarness.Entry, harness: ReadinessHarness) {
        self.entry = entry
        self.harness = harness
    }

    func perform() throws -> String {
        try harness.perform(entry)
    }

    func cancel() {
        harness.cancel(entry)
    }
    deinit { harness.released(entry) }
}

@MainActor @Suite(.serialized)
struct DocumentOCRPreparationTests {
    private enum TestFailure: Error {
        case waitExpired
        case imageCreationFailed
    }

    private final class Flag {
        var value = false
    }

    enum InvalidPrimerCase: Sendable, CaseIterable {
        case firstDocumentEmpty
        case firstDocumentWrongNonce
        case reusedDocumentEmpty
        case reusedDocumentWrongNonce
        case secondDocumentEmpty
        case secondDocumentLeaksFirstNonce
        case performThrows

        fileprivate var mode: ReadinessHarness.ResponseMode {
            switch self {
            case .firstDocumentEmpty: .firstDocumentEmpty
            case .firstDocumentWrongNonce: .firstDocumentWrongNonce
            case .reusedDocumentEmpty: .reusedDocumentEmpty
            case .reusedDocumentWrongNonce: .reusedDocumentWrongNonce
            case .secondDocumentEmpty: .secondDocumentEmpty
            case .secondDocumentLeaksFirstNonce: .secondDocumentLeaksFirstNonce
            case .performThrows: .performThrows
            }
        }

        var expectedProfiles: [LocalOCRExecution.Profile] {
            switch self {
            case .firstDocumentEmpty, .firstDocumentWrongNonce, .performThrows:
                [.document]
            case .reusedDocumentEmpty, .reusedDocumentWrongNonce:
                [.document, .document]
            case .secondDocumentEmpty, .secondDocumentLeaksFirstNonce:
                [.document, .document, .document]
            }
        }
    }

    private func smallImage(width: Int = 1, height: Int = 1) throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage() else {
            throw TestFailure.imageCreationFailed
        }
        return image
    }

    private func until(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw TestFailure.waitExpired }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private func expectGeneratedPins(_ worker: LocalOCRExecution, count: Int, generation: UInt64) {
        let resources = worker.generatedResourceInfo
        #expect(resources.count == count && count <= 3)
        #expect(resources.allSatisfy { $0.generation == generation && $0.width == 1_120 && $0.height == 160 && $0.pixelBytes == 716_800 })
        #expect(resources.reduce(0) { $0 + $1.pixelBytes } == count * 716_800)
        #expect(worker.retiringGeneratedPixelBytes == 0)
    }
    private func retireReadyPins(_ worker: LocalOCRExecution) async {
        worker.cancelDocumentReadiness()
        await worker.drain()
        #expect(worker.generatedResourceInfo.isEmpty && worker.retiringGeneratedPixelBytes == 0)
        #expect(worker.activeCount == 0 && worker.ownedCount == 0 && worker.accountedPixelBytes == 0)
    }

    @Test func requiredReuseRejectsMissingOrInvalidImageInsteadOfAllocatingAnother() throws {
        #expect(throws: LocalOCRExecution.Failure.invalidImage) {
            try DocumentOCRPreparation.makePrimerCheck(for: .reusedDocumentCheck)
        }
        let invalidImage = try smallImage()
        #expect(throws: LocalOCRExecution.Failure.invalidImage) {
            try DocumentOCRPreparation.makePrimerCheck(for: .reusedDocumentCheck, reusing: invalidImage)
        }
        let first = try DocumentOCRPreparation.makePrimerCheck(for: .firstDocumentCheck)
        let reused = try DocumentOCRPreparation.makePrimerCheck(for: .reusedDocumentCheck, reusing: first.image)
        #expect(ObjectIdentifier(first.image) == ObjectIdentifier(reused.image))
        #expect(reused.pixelBytes == DocumentOCRPreparation.bannerPixelBytes)
    }

    @Test(arguments: [false, true])
    func retiredOperationCannotTurnTheNextFirstStageIntoAReuseCheck(wrongNonce: Bool) throws {
        let harness = ReadinessHarness(mode: wrongNonce ? .firstDocumentWrongNonce : .firstDocumentEmpty)
        let image = try DocumentOCRPreparation.makeBitmap(text: DocumentOCRPreparation.firstBannerText)
        let input = LocalOCRExecution.Input(image: image, orientation: .up, preferCPU: true, profile: .document)
        var first: (any LocalOCRExecution.Operation)? = harness.make(input)
        let firstText = try first?.perform()
        let expected = wrongNonce ? "RELAY SCREEN CHECK 99999" : ""
        #expect(firstText == expected)
        #expect(harness.liveOperationImageCount == 1)
        first = nil
        #expect(harness.snapshot.releases == [1])
        #expect(harness.liveOperationImageCount == 0)

        // Deliberately use the SAME still-live caller image: only an actual
        // preceding live operation can establish the required reuse stage.
        let second = harness.make(input)
        let secondText = try second.perform()
        #expect(secondText == expected)
        #expect(harness.snapshot.factories.map(\.reusedPreviousImage) == [false, false])
        #expect(harness.liveOperationImageCount == 1)
        #expect(!harness.shareLiveImage(1, 2))
    }

    @Test func coldFirstUseFailsFastForDocumentReadsAndMapsClosedErrorsWhileAllowingOwnedMarkerWithoutCachingReadiness() async throws {
        let harness = ReadinessHarness()
        let worker = LocalOCRExecution(requiresDocumentReadiness: true) { harness.make($0) }
        let docImage = try smallImage(width: 4, height: 1)
        let markerImage = try DocumentOCRPreparation.makeBitmap(text: DocumentOCRPreparation.firstBannerText)

        #expect(worker.documentReadinessState == .unstarted)
        #expect(worker.currentReadinessGeneration == 0)
        #expect(throws: LocalOCRExecution.Failure.documentRecognitionPreparing) {
            try worker.checkAvailability(for: .document)
        }
        try worker.checkAvailability(for: .ownedEnglishMarker)

        await #expect(throws: LocalOCRExecution.Failure.documentRecognitionPreparing) {
            try await worker.recognize(image: docImage, orientation: .up, profile: .document)
        }
        let mappedPreparing = FileExtractionWorker.mapOCRFailure(LocalOCRExecution.Failure.documentRecognitionPreparing)
        #expect(mappedPreparing as? FileExtractionWorker.Failure == .recognitionPreparing)
        #expect((mappedPreparing as? FileExtractionWorker.Failure)?.errorDescription?.contains("initial preparation") == true)

        do {
            _ = try await SidekickWindowText.recognizeImage(docImage, profile: .document, execution: worker)
            Issue.record("Cold SidekickWindowText document read unexpectedly succeeded.")
        } catch let error as RelayError {
            #expect(error.localizedDescription == LocalOCRExecution.Failure.documentRecognitionPreparing.localizedDescription)
        }

        #expect(harness.snapshot.factories.isEmpty && harness.snapshot.performs.isEmpty)
        #expect(worker.ownedCount == 0 && worker.accountedPixelBytes == 0)

        // Owned English marker remains immediately usable while document readiness is unstarted,
        // and never caches or fakes document readiness.
        #expect(try await ScreenCaptureCheck.markerIsVisible(
            in: markerImage,
            nonce: DocumentOCRPreparation.firstNonce,
            execution: worker
        ))
        #expect(try await !ScreenCaptureCheck.markerIsVisible(
            in: markerImage,
            nonce: DocumentOCRPreparation.secondNonce,
            execution: worker
        ))
        await worker.drain()
        #expect(worker.documentReadinessState == .unstarted)
        #expect(harness.snapshot.factories.count == 2)
        #expect(harness.snapshot.factories.allSatisfy { $0.profile == .ownedEnglishMarker && $0.preferCPU })
        #expect(worker.ownedCount == 0 && worker.accountedPixelBytes == 0)
    }

    @Test func primerRunsThreeAccurateDocumentChecksReusingFirstImageThenFreshSecondImageOnSameSlotAndFailsFastContendingReads() async throws {
        let firstDocGate = ReadinessGate()
        let reusedDocGate = ReadinessGate()
        let secondDocGate = ReadinessGate()
        let harness = ReadinessHarness(
            firstDocumentPerformGate: firstDocGate,
            reusedDocumentPerformGate: reusedDocGate,
            secondDocumentPerformGate: secondDocGate
        )
        let worker = LocalOCRExecution(requiresDocumentReadiness: true) { harness.make($0) }
        let docImage = try smallImage(width: 3, height: 1)
        let markerImage = try DocumentOCRPreparation.makeBitmap(text: DocumentOCRPreparation.firstBannerText)
        let firstDocStepCheck = try DocumentOCRPreparation.makePrimerCheck(for: .firstDocumentCheck)
        let reusedDocStepCheck = try DocumentOCRPreparation.makePrimerCheck(
            for: .reusedDocumentCheck,
            reusing: firstDocStepCheck.image
        )
        let secondDocStepCheck = try DocumentOCRPreparation.makePrimerCheck(
            for: .secondDocumentCheck,
            reusing: reusedDocStepCheck.image
        )
        #expect(firstDocStepCheck.step.profile == .document && firstDocStepCheck.pixelBytes == 716_800)
        #expect(reusedDocStepCheck.step.profile == .document && reusedDocStepCheck.pixelBytes == 716_800)
        #expect(ObjectIdentifier(reusedDocStepCheck.image) == ObjectIdentifier(firstDocStepCheck.image))
        #expect(secondDocStepCheck.step.profile == .document && secondDocStepCheck.pixelBytes == 716_800)
        #expect(ObjectIdentifier(secondDocStepCheck.image) != ObjectIdentifier(firstDocStepCheck.image))

        let prepareTask = Task {
            try await worker.prepareDocumentReadiness(timeout: .seconds(90))
        }

        do {
            // Stage 1: first .document (.accurate) check on fresh 1120x160 firstBannerText bitmap.
            try await until { firstDocGate.entered }
            #expect(worker.documentReadinessState == .priming(generation: 1))
            #expect(worker.activeCount == 1 && worker.ownedCount == 1)
            #expect(worker.accountedPixelBytes == 716_800)
            #expect(harness.snapshot.factories.map(\.profile) == [.document])
            #expect(harness.snapshot.performs == [1])
            let firstEntry = try #require(harness.snapshot.factories.first)
            #expect(firstEntry.width == 1_120 && firstEntry.height == 160 && firstEntry.preferCPU && !firstEntry.reusedPreviousImage)

            // Contending .document and .ownedEnglishMarker calls both fail fast while priming holds the slot.
            await #expect(throws: LocalOCRExecution.Failure.documentRecognitionPreparing) {
                try await worker.recognize(image: docImage, orientation: .up, profile: .document)
            }
            await #expect(throws: LocalOCRExecution.Failure.documentRecognitionPreparing) {
                try await worker.recognize(image: markerImage, orientation: .up, preferCPU: true, profile: .ownedEnglishMarker)
            }
            do {
                _ = try await ScreenCaptureCheck.markerIsVisible(
                    in: markerImage,
                    nonce: DocumentOCRPreparation.firstNonce,
                    execution: worker
                )
                Issue.record("Contending marker check unexpectedly queued or succeeded during active primer.")
            } catch let error as RelayError {
                #expect(error.localizedDescription == LocalOCRExecution.Failure.documentRecognitionPreparing.localizedDescription)
            }
            #expect(worker.ownedCount == 1 && worker.accountedPixelBytes == 716_800)
            #expect(harness.snapshot.factories.count == 1)

            // Stage 2: first check resources stay pinned and billed while the second .document check reuses the exact same CGImage instance.
            firstDocGate.release()
            try await until { reusedDocGate.entered }
            #expect(worker.documentReadinessState == .priming(generation: 1))
            #expect(worker.activeCount == 1 && worker.ownedCount == 1)
            #expect(worker.accountedPixelBytes == 2 * 716_800)
            expectGeneratedPins(worker, count: 1, generation: 1)
            #expect(harness.snapshot.factories.map(\.profile) == [.document, .document])
            #expect(harness.snapshot.performs == [1, 2])
            let secondEntry = harness.snapshot.factories[1]
            #expect(secondEntry.width == 1_120 && secondEntry.height == 160 && secondEntry.preferCPU && secondEntry.reusedPreviousImage)
            #expect(harness.shareLiveImage(firstEntry.sequence, secondEntry.sequence))
            #expect(secondEntry.pixelDigest == firstEntry.pixelDigest)

            // Stage 3: two prior generated resources stay pinned; the fresh secondBannerText bitmap is independently recognized.
            reusedDocGate.release()
            try await until { secondDocGate.entered }
            #expect(worker.documentReadinessState == .priming(generation: 1))
            #expect(worker.activeCount == 1 && worker.ownedCount == 1)
            #expect(worker.accountedPixelBytes == 3 * 716_800)
            expectGeneratedPins(worker, count: 2, generation: 1)
            #expect(harness.snapshot.factories.map(\.profile) == [.document, .document, .document])
            #expect(harness.snapshot.performs == [1, 2, 3])
            let thirdEntry = harness.snapshot.factories[2]
            #expect(thirdEntry.width == 1_120 && thirdEntry.height == 160 && thirdEntry.preferCPU && !thirdEntry.reusedPreviousImage)
            #expect(harness.liveOperationImageCount == 3)
            #expect(!harness.shareLiveImage(secondEntry.sequence, thirdEntry.sequence))
            #expect(thirdEntry.pixelDigest != secondEntry.pixelDigest)

            secondDocGate.release()
            try await prepareTask.value
            await worker.drain()
            #expect(worker.documentReadinessState == .ready(generation: 1))
            #expect(worker.activeCount == 0 && worker.ownedCount == 0 && worker.accountedPixelBytes == 3 * 716_800)
            expectGeneratedPins(worker, count: 3, generation: 1)
            #expect(!harness.snapshot.mainThreadObserved)

            let recognizedDoc = try await worker.recognize(image: docImage, orientation: .up, profile: .document)
            #expect(recognizedDoc == "document-3")
            #expect(try await ScreenCaptureCheck.markerIsVisible(
                in: markerImage,
                nonce: DocumentOCRPreparation.firstNonce,
                execution: worker
            ))
            await worker.drain()
            #expect(worker.activeCount == 0 && worker.ownedCount == 0 && worker.accountedPixelBytes == 3 * 716_800)
            expectGeneratedPins(worker, count: 3, generation: 1)
            await retireReadyPins(worker)
        } catch {
            prepareTask.cancel()
            harness.releaseAll()
            _ = await prepareTask.result
            await worker.drain()
            throw error
        }
    }

    @Test func primerPinsExactlyThreeGeneratedResourcesWithinItsTotalDecodedByteCeiling() async throws {
        let harness = ReadinessHarness()
        let exactCeilingWorker = LocalOCRExecution(
            maximumPixelBytes: 3 * DocumentOCRPreparation.bannerPixelBytes,
            requiresDocumentReadiness: true
        ) { harness.make($0) }
        try await exactCeilingWorker.prepareDocumentReadiness(timeout: .seconds(90))
        await exactCeilingWorker.drain()
        #expect(exactCeilingWorker.documentReadinessState == .ready(generation: 1))
        #expect(exactCeilingWorker.activeCount == 0 && exactCeilingWorker.ownedCount == 0)
        #expect(exactCeilingWorker.accountedPixelBytes == 3 * 716_800)
        expectGeneratedPins(exactCeilingWorker, count: 3, generation: 1)
        #expect(harness.snapshot.factories.map(\.profile) == [.document, .document, .document])
        #expect(harness.snapshot.factories.map(\.reusedPreviousImage) == [false, true, false])
        await retireReadyPins(exactCeilingWorker)
        // The previous one-bitmap ceiling and one byte below the new exact
        // resource requirement both refuse before any generated SDK operation.
        for limit in [DocumentOCRPreparation.bannerPixelBytes, 3 * DocumentOCRPreparation.bannerPixelBytes - 1] {
            let underCeilingWorker = LocalOCRExecution(maximumPixelBytes: limit, requiresDocumentReadiness: true) { harness.make($0) }
            await #expect(throws: LocalOCRExecution.Failure.capacityUnavailable) {
                try await underCeilingWorker.prepareDocumentReadiness(timeout: .seconds(90))
            }
            #expect(underCeilingWorker.ownedCount == 0 && underCeilingWorker.accountedPixelBytes == 0)
            #expect(underCeilingWorker.generatedResourceInfo.isEmpty && harness.snapshot.factories.count == 3)
        }
    }

    @Test(arguments: InvalidPrimerCase.allCases)
    func invalidPrimerOutputOrFailureAcrossAllThreeStagesTransitionsToFailedWithoutAutoRetryAndSupportsExplicitRetry(
        _ invalidCase: InvalidPrimerCase
    ) async throws {
        let harness = ReadinessHarness(mode: invalidCase.mode)
        let worker = LocalOCRExecution(requiresDocumentReadiness: true) { harness.make($0) }
        let docImage = try smallImage(width: 5, height: 1)

        await #expect(throws: LocalOCRExecution.Failure.documentRecognitionUnavailable) {
            try await worker.prepareDocumentReadiness(timeout: .seconds(90))
        }
        await worker.drain()
        #expect(worker.documentReadinessState == .failed(generation: 2))
        #expect(harness.snapshot.factories.map(\.profile) == invalidCase.expectedProfiles)
        #expect(harness.snapshot.performs.count == invalidCase.expectedProfiles.count)
        #expect(worker.ownedCount == 0 && worker.accountedPixelBytes == 0)

        // Ordinary document reads fail fast with .documentRecognitionUnavailable and never auto-retry priming.
        await #expect(throws: LocalOCRExecution.Failure.documentRecognitionUnavailable) {
            try await worker.recognize(image: docImage, orientation: .up, profile: .document)
        }
        let mappedUnavailable = FileExtractionWorker.mapOCRFailure(LocalOCRExecution.Failure.documentRecognitionUnavailable)
        #expect(mappedUnavailable as? FileExtractionWorker.Failure == .recognitionUnavailable)
        #expect(harness.snapshot.performs.count == invalidCase.expectedProfiles.count)

        // Explicit retry after physical settlement runs a fresh 3-stage generation and reaches .ready.
        harness.setMode(.validPrimerAndEcho)
        try await worker.prepareDocumentReadiness(timeout: .seconds(90))
        await worker.drain()
        #expect(worker.documentReadinessState == .ready(generation: 3))
        #expect(harness.snapshot.performs.count == invalidCase.expectedProfiles.count + 3)
        #expect(harness.snapshot.factories.suffix(3).map(\.profile) == [.document, .document, .document])
        #expect(harness.snapshot.factories.suffix(3).map(\.reusedPreviousImage) == [false, true, false])
        #expect(try await worker.recognize(image: docImage, orientation: .up, profile: .document) == "document-5")
        await worker.drain()
        #expect(worker.activeCount == 0 && worker.ownedCount == 0 && worker.accountedPixelBytes == 3 * 716_800)
        expectGeneratedPins(worker, count: 3, generation: 3)
        await retireReadyPins(worker)
    }

    @Test func concurrentPrepareCallersBoundWaitersToEightAndLeaveZeroTombstonesAfterCancellationOrReady() async throws {
        let firstDocGate = ReadinessGate()
        let harness = ReadinessHarness(firstDocumentPerformGate: firstDocGate)
        let worker = LocalOCRExecution(requiresDocumentReadiness: true) { harness.make($0) }
        let center = NotificationCenter()
        let preparation = DocumentOCRPreparation(execution: worker, center: center, startImmediately: false)

        let cancelledWaiterDone = Flag()
        var tasks: [Task<Void, any Error>] = []
        tasks.append(Task { try await preparation.prepareNow() })
        tasks.append(Task {
            defer { cancelledWaiterDone.value = true }
            try await worker.prepareDocumentReadiness(timeout: .seconds(90))
        })
        for _ in 0..<(LocalOCRExecution.maximumReadinessWaiters - 2) {
            tasks.append(Task { try await worker.prepareDocumentReadiness(timeout: .seconds(90)) })
        }

        do {
            try await until { firstDocGate.entered && worker.readinessWaiterCount == LocalOCRExecution.maximumReadinessWaiters }
            #expect(worker.documentReadinessState == .priming(generation: 1))
            #expect(worker.ownedCount == 1 && harness.snapshot.factories.count == 1)

            // 9th concurrent waiter is rejected with .capacityUnavailable without disturbing active owners.
            await #expect(throws: LocalOCRExecution.Failure.capacityUnavailable) {
                try await worker.prepareDocumentReadiness(timeout: .seconds(90))
            }
            #expect(worker.readinessWaiterCount == LocalOCRExecution.maximumReadinessWaiters)

            // Cancelling one waiter removes only its ticket and leaves the remaining 7 owners active.
            tasks[1].cancel()
            try await until { cancelledWaiterDone.value }
            await #expect(throws: CancellationError.self) { try await tasks[1].value }
            #expect(worker.readinessWaiterCount == LocalOCRExecution.maximumReadinessWaiters - 1)
            #expect(worker.documentReadinessState == .priming(generation: 1))
            #expect(harness.snapshot.cancellations.isEmpty)

            firstDocGate.release()
            for (index, task) in tasks.enumerated() where index != 1 {
                try await task.value
            }
            // Late cancellation on already-settled tasks leaves zero waiter state or tombstones.
            tasks.forEach { $0.cancel() }
            await worker.drain()
            #expect(worker.readinessWaiterCount == 0)
            #expect(worker.documentReadinessState == .ready(generation: 1))
            #expect(harness.snapshot.factories.map(\.profile) == [.document, .document, .document])
            #expect(harness.snapshot.factories.map(\.reusedPreviousImage) == [false, true, false])
            #expect(harness.snapshot.performs == [1, 2, 3])
            #expect(worker.activeCount == 0 && worker.ownedCount == 0 && worker.accountedPixelBytes == 3 * 716_800)
            expectGeneratedPins(worker, count: 3, generation: 1)
            await retireReadyPins(worker)
        } catch {
            tasks.forEach { $0.cancel() }
            harness.releaseAll()
            for task in tasks { _ = await task.result }
            await worker.drain()
            throw error
        }
    }

    @Test(arguments: [false, true], [false, true])
    func lastOwnerOrPrimaryTerminationCancellationRejectsContendingMarkerUntilBothPerformAndCancelSettle(
        _ cancelFirst: Bool,
        _ usePrimaryTermination: Bool
    ) async throws {
        let performGate = ReadinessGate()
        let cancelGate = ReadinessGate()
        let harness = ReadinessHarness(firstDocumentPerformGate: performGate, firstCancelGate: cancelGate)
        let worker = LocalOCRExecution(requiresDocumentReadiness: true) { harness.make($0) }
        let center = NotificationCenter()
        let preparation = DocumentOCRPreparation(execution: worker, center: center, startImmediately: false)
        let markerImage = try DocumentOCRPreparation.makeBitmap(text: DocumentOCRPreparation.firstBannerText)
        let waiterDone = Flag()
        let waiter = Task {
            defer { waiterDone.value = true }
            try await preparation.prepareNow()
        }

        do {
            try await until { performGate.entered }
            #expect(worker.documentReadinessState == .priming(generation: 1))
            #expect(worker.activeCount == 1 && worker.accountedPixelBytes == 716_800)

            if usePrimaryTermination {
                center.post(name: NSApplication.willTerminateNotification, object: nil)
                #expect(preparation.isTerminated)
            } else {
                waiter.cancel()
            }
            try await until { waiterDone.value }
            await #expect(throws: CancellationError.self) { try await waiter.value }
            try await until { cancelGate.entered }
            #expect(worker.documentReadinessState == .failed(generation: 2))
            #expect(worker.activeCount == 1 && worker.accountedPixelBytes == 716_800)
            #expect(worker.readinessWaiterCount == 0)

            // While the cancelled primer's perform() and cancel() are still in flight in .failed state,
            // contending .ownedEnglishMarker is rejected as .documentRecognitionPreparing.
            #expect(throws: LocalOCRExecution.Failure.documentRecognitionPreparing) {
                try worker.checkAvailability(for: .ownedEnglishMarker)
            }
            await #expect(throws: LocalOCRExecution.Failure.documentRecognitionPreparing) {
                try await worker.recognize(image: markerImage, orientation: .up, preferCPU: true, profile: .ownedEnglishMarker)
            }
            do {
                _ = try await ScreenCaptureCheck.markerIsVisible(
                    in: markerImage,
                    nonce: DocumentOCRPreparation.firstNonce,
                    execution: worker
                )
                Issue.record("Contending marker check unexpectedly succeeded before physical primer settlement.")
            } catch let error as RelayError {
                #expect(error.localizedDescription == LocalOCRExecution.Failure.documentRecognitionPreparing.localizedDescription)
            }

            // Explicit retry is also refused while the cancelled physical primer operation is still settling.
            await #expect(throws: LocalOCRExecution.Failure.capacityUnavailable) {
                try await worker.prepareDocumentReadiness(timeout: .seconds(90))
            }
            #expect(worker.documentReadinessState == .failed(generation: 2))

            if cancelFirst {
                cancelGate.release()
                try await until { harness.snapshot.firstCancelFinished }
                #expect(worker.activeCount == 1 && worker.accountedPixelBytes == 716_800)
                // Still physically active in perform(): marker must remain rejected as preparing.
                #expect(throws: LocalOCRExecution.Failure.documentRecognitionPreparing) {
                    try worker.checkAvailability(for: .ownedEnglishMarker)
                }
                performGate.release()
            } else {
                performGate.release()
                try await until { harness.snapshot.firstPerformFinished }
                #expect(worker.activeCount == 1 && worker.accountedPixelBytes == 716_800)
                // Still physically active in cancel(): marker must remain rejected as preparing.
                #expect(throws: LocalOCRExecution.Failure.documentRecognitionPreparing) {
                    try worker.checkAvailability(for: .ownedEnglishMarker)
                }
                cancelGate.release()
            }

            await worker.drain()
            // Late completion of generation 1 never flips state to .ready and never starts Stage 2.
            #expect(worker.documentReadinessState == .failed(generation: 2))
            #expect(harness.snapshot.factories.count == 1 && harness.snapshot.performs == [1] && harness.snapshot.cancellations == [1])
            #expect(worker.ownedCount == 0 && worker.accountedPixelBytes == 0)

            // Once physically settled in .failed, .ownedEnglishMarker is permitted again.
            try worker.checkAvailability(for: .ownedEnglishMarker)
            #expect(try await ScreenCaptureCheck.markerIsVisible(
                in: markerImage,
                nonce: DocumentOCRPreparation.firstNonce,
                execution: worker
            ))
            await worker.drain()

            if usePrimaryTermination {
                await #expect(throws: CancellationError.self) { try await preparation.prepareNow() }
            }
            // Explicit retry on the worker succeeds in generation 3 across all 3 stages.
            try await worker.prepareDocumentReadiness(timeout: .seconds(90))
            await worker.drain()
            #expect(worker.documentReadinessState == .ready(generation: 3))
            #expect(harness.snapshot.factories.suffix(3).map(\.profile) == [.document, .document, .document])
            #expect(harness.snapshot.factories.suffix(3).map(\.reusedPreviousImage) == [false, true, false])
            expectGeneratedPins(worker, count: 3, generation: 3)
            await retireReadyPins(worker)
        } catch {
            waiter.cancel()
            harness.releaseAll()
            _ = await waiter.result
            await worker.drain()
            throw error
        }
    }

    @Test func primerTimeoutRejectsContendingMarkerUntilPhysicalSettlementAndAllowsExplicitRetryAfterDrain() async throws {
        let performGate = ReadinessGate()
        let cancelGate = ReadinessGate()
        let harness = ReadinessHarness(firstDocumentPerformGate: performGate, firstCancelGate: cancelGate)
        let worker = LocalOCRExecution(requiresDocumentReadiness: true) { harness.make($0) }
        let markerImage = try DocumentOCRPreparation.makeBitmap(text: DocumentOCRPreparation.firstBannerText)

        do {
            await #expect(throws: LocalOCRExecution.Failure.documentRecognitionUnavailable) {
                try await worker.prepareDocumentReadiness(timeout: .milliseconds(25))
            }
            try await until { cancelGate.entered }
            #expect(worker.documentReadinessState == .failed(generation: 2))
            #expect(worker.activeCount == 1 && worker.accountedPixelBytes == 716_800)

            // Contending marker and retry before physical settlement are both rejected.
            #expect(throws: LocalOCRExecution.Failure.documentRecognitionPreparing) {
                try worker.checkAvailability(for: .ownedEnglishMarker)
            }
            await #expect(throws: LocalOCRExecution.Failure.documentRecognitionPreparing) {
                try await worker.recognize(image: markerImage, orientation: .up, preferCPU: true, profile: .ownedEnglishMarker)
            }
            await #expect(throws: LocalOCRExecution.Failure.capacityUnavailable) {
                try await worker.prepareDocumentReadiness(timeout: .seconds(5))
            }

            performGate.release()
            cancelGate.release()
            await worker.drain()
            #expect(worker.documentReadinessState == .failed(generation: 2))
            #expect(worker.ownedCount == 0 && worker.accountedPixelBytes == 0)

            try await worker.prepareDocumentReadiness(timeout: .seconds(5))
            await worker.drain()
            #expect(worker.documentReadinessState == .ready(generation: 3))
            expectGeneratedPins(worker, count: 3, generation: 3)
            await retireReadyPins(worker)
        } catch {
            harness.releaseAll()
            await worker.drain()
            throw error
        }
    }

    @Test func postReadyBoundedQueueAndPixelAccountingRemainEnforced() async throws {
        let ordinaryGate = ReadinessGate()
        let harness = ReadinessHarness(ordinaryPerformGate: ordinaryGate)
        let worker = LocalOCRExecution(requiresDocumentReadiness: true) { harness.make($0) }

        try await worker.prepareDocumentReadiness(timeout: .seconds(90))
        await worker.drain()
        #expect(worker.documentReadinessState == .ready(generation: 1))

        let images = try (1...9).map { try smallImage(width: $0, height: 1) }
        var tasks: [Task<String, any Error>] = []
        do {
            for (index, img) in images.prefix(8).enumerated() {
                tasks.append(Task {
                    try await worker.recognize(image: img, orientation: .up, profile: .document)
                })
                try await until { worker.ownedCount == index + 1 }
            }
            try await until { ordinaryGate.entered }
            let expectedBytes = 3 * 716_800 + images.prefix(8).reduce(0) { $0 + $1.bytesPerRow * $1.height }
            #expect(worker.accountedPixelBytes == expectedBytes)

            await #expect(throws: LocalOCRExecution.Failure.capacityUnavailable) {
                try await worker.recognize(image: images[8], orientation: .up, profile: .document)
            }

            ordinaryGate.release()
            for (index, task) in tasks.enumerated() {
                #expect(try await task.value == "document-\(index + 1)")
            }
            await worker.drain()
            #expect(worker.activeCount == 0 && worker.ownedCount == 0 && worker.accountedPixelBytes == 3 * 716_800)
            expectGeneratedPins(worker, count: 3, generation: 1)
            await retireReadyPins(worker)
        } catch {
            tasks.forEach { $0.cancel() }
            harness.releaseAll()
            for task in tasks { _ = await task.result }
            await worker.drain()
            throw error
        }
    }
    @Test func pinnedGeneratedPixelsRemainInsidePrivateAdmissionBudgetAndTerminationWaitsForPhysicalJob() async throws {
        let gate = ReadinessGate(), harness = ReadinessHarness(ordinaryPerformGate: gate)
        let image = try smallImage(), bytes = image.bytesPerRow * image.height
        let worker = LocalOCRExecution(maximumPixelBytes: 3 * 716_800 + bytes,
            requiresDocumentReadiness: true) { harness.make($0) }
        let center = NotificationCenter()
        let preparation = DocumentOCRPreparation(execution: worker, center: center)
        try await preparation.prepareNow()
        expectGeneratedPins(worker, count: 3, generation: 1)
        let job = Task { try await worker.recognize(image: image, orientation: .up, profile: .document) }
        do {
            try await until { gate.entered }
            #expect(worker.activeCount == 1 && worker.ownedCount == 1)
            #expect(worker.accountedPixelBytes == 3 * 716_800 + bytes)
            await #expect(throws: LocalOCRExecution.Failure.capacityUnavailable) {
                _ = try await worker.recognize(image: image, orientation: .up, profile: .document)
            }
            #expect(harness.snapshot.factories.count == 4 && harness.snapshot.performs.count == 4)
            center.post(name: NSApplication.willTerminateNotification, object: nil)
            #expect(preparation.isTerminated && worker.documentReadinessState == .failed(generation: 2))
            #expect(worker.generatedResourceInfo.count == 3 && worker.accountedPixelBytes == 3 * 716_800 + bytes)
            // The ordinary job is not a primer. Requested pin retirement must
            // still block marker admission before a disposal job can exist.
            var markerRefusal: LocalOCRExecution.Failure?
            do { try worker.checkAvailability(for: .ownedEnglishMarker) }
            catch { markerRefusal = error as? LocalOCRExecution.Failure }
            #expect(markerRefusal == .documentRecognitionPreparing)
            try #require(markerRefusal == .documentRecognitionPreparing)
            await #expect(throws: LocalOCRExecution.Failure.documentRecognitionPreparing) {
                _ = try await worker.recognize(image: image, orientation: .up, profile: .ownedEnglishMarker)
            }
            #expect(worker.ownedCount == 1 && harness.snapshot.factories.count == 4)
            job.cancel()
            await #expect(throws: CancellationError.self) { _ = try await job.value }
            // Neither waiter cancellation nor termination releases SDK input/pins.
            #expect(worker.activeCount == 1 && worker.accountedPixelBytes == 3 * 716_800 + bytes)
            gate.release(); await worker.drain()
            #expect(worker.activeCount == 0 && worker.ownedCount == 0 && worker.accountedPixelBytes == 0)
            #expect(worker.generatedResourceInfo.isEmpty && worker.retiringGeneratedPixelBytes == 0)
            #expect(worker.documentReadinessState == .failed(generation: 2))
            #expect(throws: LocalOCRExecution.Failure.documentRecognitionUnavailable) { try worker.checkAvailability(for: .document) }
        } catch {
            job.cancel(); gate.release(); _ = await job.result
            worker.cancelDocumentReadiness(); await worker.drain(); throw error
        }
    }

    @Test func generatedResourceRetirementStaysBilledAndBlocksNewGenerationUntilItsSDKQueueDisposalEnds() async throws {
        let queue = DispatchQueue(label: "Relay.OwnedPrimerRetirement"), gate = ReadinessGate()
        let harness = ReadinessHarness()
        let worker = LocalOCRExecution(testQueue: queue, requiresDocumentReadiness: true) { harness.make($0) }
        try await worker.prepareDocumentReadiness()
        await worker.drain(); expectGeneratedPins(worker, count: 3, generation: 1)
        #expect(harness.snapshot.releases.isEmpty)
        queue.async { gate.pause() }
        do {
            try await until { gate.entered }
            worker.cancelDocumentReadiness()
            #expect(worker.documentReadinessState == .failed(generation: 2))
            #expect(worker.activeCount == 0 && worker.ownedCount == 0)
            #expect(worker.generatedResourceInfo.isEmpty && worker.retiringGeneratedPixelBytes == 3 * 716_800)
            let retiring = worker.retiringGeneratedResourceInfo
            #expect(retiring.count == 3 && retiring.allSatisfy { $0.generation == 1 && $0.width == 1_120 && $0.height == 160 && $0.pixelBytes == 716_800 })
            #expect(worker.accountedPixelBytes == 3 * 716_800)
            #expect(throws: LocalOCRExecution.Failure.documentRecognitionPreparing) { try worker.checkAvailability(for: .ownedEnglishMarker) }
            await #expect(throws: LocalOCRExecution.Failure.capacityUnavailable) { try await worker.prepareDocumentReadiness() }
            #expect(harness.snapshot.factories.count == 3 && harness.snapshot.releases.isEmpty)
            gate.release(); await worker.drain()
            #expect(worker.accountedPixelBytes == 0 && worker.retiringGeneratedPixelBytes == 0)
            #expect(harness.snapshot.releases.sorted() == [1, 2, 3] && !harness.snapshot.mainThreadObserved)
            #expect(worker.documentReadinessState == .failed(generation: 2))
            // Explicit new owner runs three actual protocol operations; old
            // generation completion cannot manufacture readiness.
            try await worker.prepareDocumentReadiness()
            #expect(worker.documentReadinessState == .ready(generation: 3))
            #expect(harness.snapshot.performs.count == 6)
            expectGeneratedPins(worker, count: 3, generation: 3)
            await retireReadyPins(worker)
        } catch {
            gate.release(); worker.cancelDocumentReadiness(); await worker.drain(); throw error
        }
    }

}
