import AppKit
import CoreGraphics
import CryptoKit
import Dispatch
import Foundation
import ImageIO
import Testing
@testable import Relay

nonisolated private final class ArmedGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var armed: Bool
    private var didEnter = false
    private var released = false

    init(armed: Bool = false) {
        self.armed = armed
    }

    var entered: Bool {
        lock.withLock { didEnter }
    }

    func arm() {
        lock.withLock {
            guard !released else { return }
            armed = true
        }
    }

    func pauseIfArmed() -> Bool {
        let shouldWait = lock.withLock { () -> Bool in
            guard armed, !released else { return false }
            // A and reused A share pixels; this gate holds one actual operation.
            armed = false
            didEnter = true
            return true
        }
        if shouldWait {
            semaphore.wait()
        }
        return shouldWait
    }

    func release() {
        let shouldSignal = lock.withLock { () -> Bool in
            let first = !released
            released = true
            armed = false
            return first
        }
        if shouldSignal {
            semaphore.signal()
        }
    }
}

nonisolated private final class SettingsOCRHarness: @unchecked Sendable {
    struct Entry: Sendable, Equatable {
        let sequence: Int
        let width: Int
        let height: Int
        let profile: LocalOCRExecution.Profile
        let preferCPU: Bool
        let pixelDigest: Data
    }

    struct Snapshot: Sendable, Equatable {
        let factories: [Entry]
        let performs: [Int]
        let cancellations: [Int]
        let pausedPerformFinished: Bool
        let pausedCancelFinished: Bool
    }

    enum Mode: Sendable {
        case validPrimer
        case markerEmpty
        case firstDocumentWrongNonce
    }

    private let lock = NSLock()
    private let firstPrimerDigest: Data
    private let secondPrimerDigest: Data
    private var nextSequence = 0
    private var factories: [Entry] = []
    private var performs: [Int] = []
    private var cancellations: [Int] = []
    private var pausedPerformFinished = false
    private var pausedCancelFinished = false
    private var mode: Mode
    private var markerPerformGate: ArmedGate
    private var cancelGate: ArmedGate

    init(
        mode: Mode = .validPrimer,
        markerPerformGate: ArmedGate = ArmedGate(),
        cancelGate: ArmedGate = ArmedGate()
    ) {
        self.firstPrimerDigest = (try? DocumentOCRPreparation.makeBitmap(text: DocumentOCRPreparation.firstBannerText))
            .map(Self.pixelDigest(for:)) ?? Data()
        self.secondPrimerDigest = (try? DocumentOCRPreparation.makeBitmap(text: DocumentOCRPreparation.secondBannerText))
            .map(Self.pixelDigest(for:)) ?? Data()
        self.mode = mode
        self.markerPerformGate = markerPerformGate
        self.cancelGate = cancelGate
    }

    var snapshot: Snapshot {
        lock.withLock {
            Snapshot(
                factories: factories,
                performs: performs,
                cancellations: cancellations,
                pausedPerformFinished: pausedPerformFinished,
                pausedCancelFinished: pausedCancelFinished
            )
        }
    }

    func setMode(_ newMode: Mode) {
        lock.withLock {
            mode = newMode
        }
    }

    func setGates(
        markerPerformGate: ArmedGate = ArmedGate(),
        cancelGate: ArmedGate = ArmedGate()
    ) {
        lock.withLock {
            self.markerPerformGate = markerPerformGate
            self.cancelGate = cancelGate
            self.pausedPerformFinished = false
            self.pausedCancelFinished = false
        }
    }

    func releaseAll() {
        let (mGate, cGate) = lock.withLock { (markerPerformGate, cancelGate) }
        mGate.release()
        cGate.release()
    }

    func make(_ input: LocalOCRExecution.Input) -> any LocalOCRExecution.Operation {
        let digest = Self.pixelDigest(for: input.image)
        let entry = lock.withLock { () -> Entry in
            nextSequence += 1
            let created = Entry(
                sequence: nextSequence,
                width: input.image.width,
                height: input.image.height,
                profile: input.profile,
                preferCPU: input.preferCPU,
                pixelDigest: digest
            )
            factories.append(created)
            return created
        }
        return SettingsOCROperation(entry: entry, harness: self)
    }

    func perform(_ entry: Entry) throws -> String {
        let (currentMode, mGate) = lock.withLock { () -> (Mode, ArmedGate) in
            performs.append(entry.sequence)
            return (mode, markerPerformGate)
        }
        let isBanner = entry.width == DocumentOCRPreparation.bannerWidth
            && entry.height == DocumentOCRPreparation.bannerHeight
        let isFirstBanner = isBanner && entry.pixelDigest == firstPrimerDigest
        let isSecondBanner = isBanner && entry.pixelDigest == secondPrimerDigest

        // Preparation now begins with accurate document A, not the marker profile.
        if entry.profile == .document, isFirstBanner, mGate.pauseIfArmed() {
            lock.withLock { pausedPerformFinished = true }
        }
        if entry.profile == .ownedEnglishMarker {
            switch currentMode {
            case .markerEmpty:
                return ""
            case .validPrimer, .firstDocumentWrongNonce:
                return isFirstBanner ? DocumentOCRPreparation.firstBannerText : ""
            }
        }

        switch currentMode {
        case .validPrimer:
            if isFirstBanner { return DocumentOCRPreparation.firstBannerText }
            if isSecondBanner { return DocumentOCRPreparation.secondBannerText }
            return ""
        case .markerEmpty:
            return ""
        case .firstDocumentWrongNonce:
            return "RELAY SCREEN CHECK 99999"
        }
    }

    func cancel(_ entry: Entry) {
        let cGate = lock.withLock { () -> ArmedGate in
            cancellations.append(entry.sequence)
            return cancelGate
        }
        if cGate.pauseIfArmed() {
            lock.withLock { pausedCancelFinished = true }
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

nonisolated private final class SettingsOCROperation: LocalOCRExecution.Operation, @unchecked Sendable {
    let entry: SettingsOCRHarness.Entry
    let harness: SettingsOCRHarness

    init(entry: SettingsOCRHarness.Entry, harness: SettingsOCRHarness) {
        self.entry = entry
        self.harness = harness
    }

    func perform() throws -> String {
        try harness.perform(entry)
    }

    func cancel() {
        harness.cancel(entry)
    }
}

@MainActor @Suite(.serialized)
struct OCRReadinessSettingsTests {
    private enum TestFailure: Error {
        case waitExpired
    }

    private func until(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw TestFailure.waitExpired }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private func spinUntil(_ predicate: () -> Bool) throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw TestFailure.waitExpired }
            Thread.sleep(forTimeInterval: 0.0005)
        }
    }

    @Test func coldUnstartedAndActivePrimingReportPreparingWithoutPollingSDKOrFabricatingReady() async throws {
        let markerGate = ArmedGate(armed: true)
        let harness = SettingsOCRHarness(mode: .validPrimer, markerPerformGate: markerGate)
        let worker = LocalOCRExecution(requiresDocumentReadiness: true) { harness.make($0) }
        let settings = OCRReadinessSettings(execution: worker)

        #expect(worker.documentReadinessState == .unstarted)
        #expect(settings.status == .preparing)
        #expect(settings.statusDescription == "Preparing on this Mac…")
        #expect(!settings.canRetry && !settings.isRetrying)
        #expect(settings.errorMessage == nil)

        // Repeated refreshes (e.g. onAppear / re-render) never start priming, poll the SDK, or fabricate Ready.
        settings.refresh()
        settings.refresh()
        #expect(settings.status == .preparing)
        #expect(!settings.canRetry && !settings.isRetrying)
        #expect(worker.documentReadinessState == .unstarted)
        #expect(worker.ownedCount == 0)
        #expect(harness.snapshot.factories.isEmpty && harness.snapshot.performs.isEmpty)
        #expect(settings.retry() == nil)
        #expect(harness.snapshot.factories.isEmpty)

        let preparation = DocumentOCRPreparation(execution: worker, timeout: .seconds(90))
        let startup = try #require(preparation.start())
        do {
            try await until { markerGate.entered }
            #expect(worker.documentReadinessState == .priming(generation: 1))
            settings.refresh()
            #expect(settings.status == .preparing)
            #expect(!settings.canRetry && !settings.isRetrying)
            #expect(settings.retry() == nil)

            // Dismissing Settings while launch preparation is in flight never cancels the shared worker's primer.
            settings.cancelWaiter()
            #expect(worker.documentReadinessState == .priming(generation: 1))
            #expect(harness.snapshot.cancellations.isEmpty)
        } catch {
            harness.releaseAll()
            preparation.stopForTermination()
            await startup.value
            await worker.drain()
            throw error
        }

        markerGate.release()
        await startup.value
        await worker.drain()

        settings.refresh()
        #expect(worker.documentReadinessState == .ready(generation: 1))
        #expect(settings.status == .ready)
        #expect(settings.statusDescription == "Ready")
        #expect(!settings.canRetry && !settings.isRetrying)
        #expect(settings.errorMessage == nil)
        #expect(harness.snapshot.factories.map(\.profile) == [.document, .document, .document])
        #expect(settings.retry() == nil)
        #expect(harness.snapshot.factories.count == 3)
    }

    @Test func whileVisibleObservationUpdatesForegroundStatusAcrossStartupAndSettlementWithoutPollingSDKOrAutoRetrying() async throws {
        // Part 1: Settings opened during startup and remaining in foreground transitions .preparing -> .ready automatically.
        let readyGate = ArmedGate(armed: true)
        let readyHarness = SettingsOCRHarness(mode: .validPrimer, markerPerformGate: readyGate)
        let readyWorker = LocalOCRExecution(requiresDocumentReadiness: true) { readyHarness.make($0) }
        let readySettings = OCRReadinessSettings(execution: readyWorker)

        let readyVisibilityTask = Task {
            await readySettings.observeWhileVisible(pollInterval: .milliseconds(10))
        }
        let preparation = DocumentOCRPreparation(execution: readyWorker, timeout: .seconds(90))
        var readyStartup: Task<Void, Never>?
        do {
            // Multiple while-visible poll ticks while unstarted never invoke the SDK or start priming.
            try await Task.sleep(for: .milliseconds(30))
            #expect(readySettings.status == .preparing)
            #expect(readyWorker.documentReadinessState == .unstarted)
            #expect(readyHarness.snapshot.factories.isEmpty && readyHarness.snapshot.performs.isEmpty)

            readyStartup = try #require(preparation.start())
            try await until { readyGate.entered }
            #expect(readySettings.status == .preparing)

            readyGate.release()
            try await until { readySettings.status == .ready }
            #expect(readySettings.statusDescription == "Ready")
            #expect(!readySettings.canRetry && !readySettings.isRetrying)
        } catch {
            readyVisibilityTask.cancel()
            readyHarness.releaseAll()
            preparation.stopForTermination()
            await readyStartup?.value
            await readyWorker.drain()
            throw error
        }
        readyVisibilityTask.cancel()
        await readyVisibilityTask.value
        let readyOwnedTask = try #require(readyStartup)
        await readyOwnedTask.value
        await readyWorker.drain()

        // Part 2: Settings remaining in foreground when startup preparation fails transitions .preparing -> .failed
        // after physical settlement and never auto-retries on subsequent poll ticks.
        let failGate = ArmedGate(armed: true)
        let failHarness = SettingsOCRHarness(mode: .markerEmpty, markerPerformGate: failGate)
        let failWorker = LocalOCRExecution(requiresDocumentReadiness: true) { failHarness.make($0) }
        let failSettings = OCRReadinessSettings(execution: failWorker)

        let failVisibilityTask = Task {
            await failSettings.observeWhileVisible(pollInterval: .milliseconds(10))
        }
        let failPreparation = DocumentOCRPreparation(execution: failWorker, timeout: .seconds(90))
        var failedStartup: Task<Void, Never>?
        do {
            failedStartup = try #require(failPreparation.start())
            try await until { failGate.entered }
            #expect(failSettings.status == .preparing)
            #expect(!failSettings.canRetry)

            failGate.release()
            try await until { failSettings.status == .failed }
            #expect(failSettings.canRetry && !failSettings.isRetrying)

            // Keep observing for several more intervals; verify zero automatic retries.
            try await Task.sleep(for: .milliseconds(30))
            #expect(failWorker.documentReadinessState == .failed(generation: 2))
            #expect(failWorker.currentReadinessGeneration == 2)
            #expect(failHarness.snapshot.factories.count == 1)
        } catch {
            failVisibilityTask.cancel()
            failHarness.releaseAll()
            failPreparation.stopForTermination()
            await failedStartup?.value
            await failWorker.drain()
            throw error
        }
        failVisibilityTask.cancel()
        await failVisibilityTask.value
        let failedOwnedTask = try #require(failedStartup)
        await failedOwnedTask.value
        await failWorker.drain()
    }

    @Test func failedStateWithUnsettledPhysicalPrimerRemainsPreparingAndBlocksRetryUntilPerformAndCancelSettle() async throws {
        let markerGate = ArmedGate(armed: true)
        let cancelGate = ArmedGate(armed: true)
        let harness = SettingsOCRHarness(mode: .validPrimer, markerPerformGate: markerGate, cancelGate: cancelGate)
        let worker = LocalOCRExecution(requiresDocumentReadiness: true) { harness.make($0) }
        let settings = OCRReadinessSettings(execution: worker)

        let launchPrimer = Task {
            try await worker.prepareDocumentReadiness(timeout: .seconds(90))
        }
        do {
            try await until { markerGate.entered }
            #expect(worker.documentReadinessState == .priming(generation: 1))

            launchPrimer.cancel()
            await #expect(throws: CancellationError.self) {
                try await launchPrimer.value
            }
            try await until { cancelGate.entered }

            // Readiness state is already .failed(generation: 2), but both perform() and cancel() are still in flight.
            #expect(worker.documentReadinessState == .failed(generation: 2))
            #expect(worker.activeCount == 1)
            settings.refresh()
            #expect(settings.status == .preparing)
            #expect(!settings.canRetry && !settings.isRetrying)
            #expect(settings.retry() == nil)

            // Release perform() first while cancel() remains in flight: status must stay .preparing.
            markerGate.release()
            try await until { harness.snapshot.pausedPerformFinished }
            #expect(worker.documentReadinessState == .failed(generation: 2))
            #expect(worker.activeCount == 1)
            settings.refresh()
            #expect(settings.status == .preparing)
            #expect(!settings.canRetry)
            #expect(settings.retry() == nil)

            // Release cancel() and wait for physical quiescence.
            cancelGate.release()
            try await until { harness.snapshot.pausedCancelFinished }
            await worker.drain()
        } catch {
            harness.releaseAll()
            launchPrimer.cancel()
            await worker.drain()
            throw error
        }

        #expect(worker.activeCount == 0 && worker.ownedCount == 0)
        settings.refresh()
        #expect(settings.status == .failed)
        #expect(settings.statusDescription == "Unavailable. Initial preparation did not complete.")
        #expect(settings.canRetry && !settings.isRetrying)

        // Subsequent refreshes never auto-retry on failure.
        settings.refresh()
        #expect(worker.documentReadinessState == .failed(generation: 2))
        #expect(harness.snapshot.factories.count == 1)
    }

    @Test func explicitRetryCoalescesRepeatedClicksAndSharedPrepareCallersIntoSingleGeneration() async throws {
        let markerGate = ArmedGate(armed: false)
        let harness = SettingsOCRHarness(mode: .markerEmpty, markerPerformGate: markerGate)
        let worker = LocalOCRExecution(requiresDocumentReadiness: true) { harness.make($0) }
        let settings = OCRReadinessSettings(execution: worker)

        await #expect(throws: LocalOCRExecution.Failure.documentRecognitionUnavailable) {
            try await worker.prepareDocumentReadiness(timeout: .seconds(90))
        }
        await worker.drain()
        #expect(worker.documentReadinessState == .failed(generation: 2))

        settings.refresh()
        #expect(settings.status == .failed)
        #expect(settings.canRetry)

        harness.setMode(.validPrimer)
        markerGate.arm()

        let firstRetry = try #require(settings.retry())
        let duplicateRetry = try #require(settings.retry())
        #expect(firstRetry == duplicateRetry)
        #expect(settings.status == .preparing)
        #expect(settings.isRetrying && !settings.canRetry)
        #expect(settings.errorMessage == nil)

        var externalWaiter: Task<Void, any Error>?
        do {
            try await until { markerGate.entered }
            #expect(worker.documentReadinessState == .priming(generation: 3))
            #expect(worker.readinessWaiterCount == 1)

            externalWaiter = Task {
                try await worker.prepareDocumentReadiness(timeout: .seconds(90))
            }
            try await until { worker.readinessWaiterCount == 2 }
            #expect(worker.currentReadinessGeneration == 3)
        } catch {
            harness.releaseAll()
            firstRetry.cancel()
            externalWaiter?.cancel()
            await worker.drain()
            throw error
        }

        markerGate.release()
        await firstRetry.value
        try await externalWaiter?.value
        await worker.drain()

        #expect(worker.documentReadinessState == .ready(generation: 3))
        #expect(settings.status == .ready)
        #expect(!settings.isRetrying && !settings.canRetry)
        #expect(settings.errorMessage == nil)
        #expect(harness.snapshot.factories.map(\.profile) == [
            .document,
            .document,
            .document,
            .document
        ])
    }

    @Test func failedExplicitRetrySurfacesErrorWithoutAutoRetryAndClearsErrorWhenLaterReady() async throws {
        let harness = SettingsOCRHarness(mode: .firstDocumentWrongNonce)
        let worker = LocalOCRExecution(requiresDocumentReadiness: true) { harness.make($0) }
        let settings = OCRReadinessSettings(execution: worker)

        await #expect(throws: LocalOCRExecution.Failure.documentRecognitionUnavailable) {
            try await worker.prepareDocumentReadiness(timeout: .seconds(90))
        }
        await worker.drain()
        #expect(harness.snapshot.factories.map(\.profile) == [.document])
        settings.refresh()
        #expect(settings.status == .failed)
        #expect(settings.canRetry)

        let failedRetry = try #require(settings.retry())
        await failedRetry.value
        await worker.drain()

        #expect(worker.documentReadinessState == .failed(generation: 4))
        #expect(harness.snapshot.factories.map(\.profile) == [.document, .document])
        #expect(settings.status == .failed)
        #expect(!settings.isRetrying && settings.canRetry)
        #expect(settings.errorMessage == LocalOCRExecution.Failure.documentRecognitionUnavailable.localizedDescription)

        // Refreshing never triggers an automatic retry.
        settings.refresh()
        #expect(worker.currentReadinessGeneration == 4)

        harness.setMode(.validPrimer)
        let recoveryRetry = try #require(settings.retry())
        await recoveryRetry.value
        await worker.drain()

        #expect(worker.documentReadinessState == .ready(generation: 5))
        #expect(harness.snapshot.factories.map(\.profile) == [.document, .document, .document, .document, .document])
        #expect(settings.status == .ready)
        #expect(!settings.isRetrying && !settings.canRetry)
        #expect(settings.errorMessage == nil)
    }

    @Test func viewDismissalCancelsOnlySettingsWaiterLeavingSharedPrimerAliveOrSettlingSoleRetryCleanly() async throws {
        // Part 1: When another caller shares the active generation, cancelWaiter() removes only Settings's waiter.
        let sharedMarkerGate = ArmedGate(armed: false)
        let sharedHarness = SettingsOCRHarness(mode: .markerEmpty, markerPerformGate: sharedMarkerGate)
        let sharedWorker = LocalOCRExecution(requiresDocumentReadiness: true) { sharedHarness.make($0) }
        let sharedSettings = OCRReadinessSettings(execution: sharedWorker)

        await #expect(throws: LocalOCRExecution.Failure.documentRecognitionUnavailable) {
            try await sharedWorker.prepareDocumentReadiness(timeout: .seconds(90))
        }
        await sharedWorker.drain()
        sharedSettings.refresh()
        #expect(sharedSettings.status == .failed)

        sharedHarness.setMode(.validPrimer)
        sharedMarkerGate.arm()

        let sharedRetry = try #require(sharedSettings.retry())
        var secondOwner: Task<Void, any Error>?
        do {
            try await until { sharedMarkerGate.entered }
            secondOwner = Task {
                try await sharedWorker.prepareDocumentReadiness(timeout: .seconds(90))
            }
            try await until { sharedWorker.readinessWaiterCount == 2 }

            sharedSettings.cancelWaiter()
            #expect(!sharedSettings.isRetrying)
            try await until { sharedWorker.readinessWaiterCount == 1 }
            #expect(sharedWorker.documentReadinessState == .priming(generation: 3))
            #expect(sharedHarness.snapshot.cancellations.isEmpty)
            #expect(sharedSettings.status == .preparing)
            #expect(!sharedSettings.canRetry)
        } catch {
            sharedHarness.releaseAll()
            sharedRetry.cancel()
            secondOwner?.cancel()
            await sharedWorker.drain()
            throw error
        }

        sharedMarkerGate.release()
        await sharedRetry.value
        try await secondOwner?.value
        await sharedWorker.drain()
        sharedSettings.refresh()
        #expect(sharedWorker.documentReadinessState == .ready(generation: 3))
        #expect(sharedSettings.status == .ready)

        // Part 2: When Settings is the sole owner of the retry, cancelWaiter() aborts its ticket cleanly
        // and keeps status .preparing until physical perform() + cancel() settlement completes.
        let soleMarkerGate = ArmedGate(armed: false)
        let soleCancelGate = ArmedGate(armed: false)
        let soleHarness = SettingsOCRHarness(
            mode: .markerEmpty,
            markerPerformGate: soleMarkerGate,
            cancelGate: soleCancelGate
        )
        let soleWorker = LocalOCRExecution(requiresDocumentReadiness: true) { soleHarness.make($0) }
        let soleSettings = OCRReadinessSettings(execution: soleWorker)

        await #expect(throws: LocalOCRExecution.Failure.documentRecognitionUnavailable) {
            try await soleWorker.prepareDocumentReadiness(timeout: .seconds(90))
        }
        await soleWorker.drain()
        soleSettings.refresh()
        #expect(soleSettings.status == .failed)

        soleHarness.setMode(.validPrimer)
        soleMarkerGate.arm()
        soleCancelGate.arm()

        let soleRetry = try #require(soleSettings.retry())
        do {
            try await until { soleMarkerGate.entered }
            #expect(soleWorker.documentReadinessState == .priming(generation: 3))
            #expect(soleWorker.readinessWaiterCount == 1)

            soleSettings.cancelWaiter()
            #expect(!soleSettings.isRetrying)
            try await until { soleCancelGate.entered }

            // Even though state is .failed(generation: 4), the unsettled primer keeps status .preparing.
            #expect(soleWorker.documentReadinessState == .failed(generation: 4))
            #expect(soleWorker.activeCount == 1)
            soleSettings.refresh()
            #expect(soleSettings.status == .preparing)
            #expect(!soleSettings.canRetry)
            #expect(soleSettings.retry() == nil)

            soleMarkerGate.release()
            soleCancelGate.release()
            await soleRetry.value
            await soleWorker.drain()
        } catch {
            soleHarness.releaseAll()
            soleRetry.cancel()
            await soleWorker.drain()
            throw error
        }

        soleSettings.refresh()
        #expect(soleWorker.activeCount == 0 && soleWorker.ownedCount == 0)
        #expect(soleSettings.status == .failed)
        #expect(soleSettings.canRetry)
    }

    @Test func oldRetryTaskLateCompletionAfterCancelWaiterAndNewRetryCannotMutateStatusOrErrorMessage() async throws {
        let firstRetryGate = ArmedGate(armed: false)
        let harness = SettingsOCRHarness(mode: .markerEmpty, markerPerformGate: firstRetryGate)
        let worker = LocalOCRExecution(requiresDocumentReadiness: true) { harness.make($0) }
        let settings = OCRReadinessSettings(execution: worker)

        // Reach initial settled .failed(generation: 2).
        await #expect(throws: LocalOCRExecution.Failure.documentRecognitionUnavailable) {
            try await worker.prepareDocumentReadiness(timeout: .seconds(90))
        }
        await worker.drain()
        settings.refresh()
        #expect(settings.status == .failed)
        #expect(settings.canRetry)

        // Start old retry (generation 2) with mode == .markerEmpty, paused inside marker perform().
        firstRetryGate.arm()
        let oldRetry = try #require(settings.retry())
        let secondRetryGate = ArmedGate(armed: true)
        var newRetry: Task<Void, Never>?
        do {
            try await until { firstRetryGate.entered }
            #expect(worker.documentReadinessState == .priming(generation: 3))

            // Release oldRetry's background perform() so it fails with LocalOCRExecution.Failure.documentRecognitionUnavailable
            // and resumes oldRetry's continuation onto the MainActor queue before we yield on MainActor.
            firstRetryGate.release()
            try spinUntil {
                worker.documentReadinessState == .failed(generation: 4) && worker.activeCount == 0
            }

            // Still in the same MainActor turn before oldRetry's catch block executes:
            // dismiss/cancel the old waiter and start a new retry (generation 3).
            settings.cancelWaiter()
            #expect(settings.status == .failed)
            #expect(settings.canRetry && !settings.isRetrying)
            #expect(settings.errorMessage == nil)

            harness.setMode(.validPrimer)
            harness.setGates(markerPerformGate: secondRetryGate)
            let launchedNewRetry = try #require(settings.retry())
            newRetry = launchedNewRetry
            #expect(launchedNewRetry != oldRetry)
            #expect(settings.status == .preparing)
            #expect(settings.isRetrying && !settings.canRetry)
            #expect(settings.errorMessage == nil)

            // Yield to let oldRetry finish its catch block; because finishRetryTaskIfCurrent(oldID) returns false,
            // oldRetry must not clobber isRetrying, status, or errorMessage for the active newRetry.
            await oldRetry.value
            try await until { secondRetryGate.entered }
            #expect(worker.documentReadinessState == .priming(generation: 5))
            #expect(settings.status == .preparing)
            #expect(settings.isRetrying && !settings.canRetry)
            #expect(settings.errorMessage == nil)
        } catch {
            firstRetryGate.release()
            secondRetryGate.release()
            harness.releaseAll()
            oldRetry.cancel()
            newRetry?.cancel()
            await worker.drain()
            throw error
        }

        secondRetryGate.release()
        await newRetry?.value
        await worker.drain()

        #expect(worker.documentReadinessState == .ready(generation: 5))
        #expect(settings.status == .ready)
        #expect(!settings.isRetrying && !settings.canRetry)
        #expect(settings.errorMessage == nil)
    }
}
