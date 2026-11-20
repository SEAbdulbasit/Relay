import CoreGraphics
import Dispatch
import Foundation
import ImageIO
import Testing
@testable import Relay

nonisolated private final class OCRProtocolGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var didEnter = false, released = false
    var entered: Bool { lock.withLock { didEnter } }
    func pause() { lock.withLock { didEnter = true }; semaphore.wait() }
    func release() {
        let signal = lock.withLock { let first = !released; released = true; return first }
        if signal { semaphore.signal() }
    }
}

nonisolated private final class OCRProtocolState: @unchecked Sendable {
    struct Snapshot {
        let factories: [Int], performs: [Int], cancellations: [Int]
        let mainThread: Bool, performFinished: Bool, cancelFinished: Bool
        let secondSawBothSettled: Bool
    }
    private let lock = NSLock()
    private var factories: [Int] = [], performs: [Int] = [], cancellations: [Int] = []
    private var mainThread = false, performFinished = false, cancelFinished = false
    private var secondSawBothSettled = false
    let factoryGate: OCRProtocolGate?
    let performGate: OCRProtocolGate?
    let cancelGate: OCRProtocolGate?
    let fails: Bool
    init(factoryGate: OCRProtocolGate? = nil, performGate: OCRProtocolGate? = nil,
         cancelGate: OCRProtocolGate? = nil, fails: Bool = false) {
        self.factoryGate = factoryGate; self.performGate = performGate
        self.cancelGate = cancelGate; self.fails = fails
    }
    var snapshot: Snapshot {
        lock.withLock {
            .init(factories: factories, performs: performs, cancellations: cancellations,
                  mainThread: mainThread, performFinished: performFinished, cancelFinished: cancelFinished,
                  secondSawBothSettled: secondSawBothSettled)
        }
    }
    func make(_ input: LocalOCRExecution.Input) -> any LocalOCRExecution.Operation {
        let id = input.image.width
        lock.withLock {
            factories.append(id); mainThread = mainThread || Thread.isMainThread
            if id == 2 { secondSawBothSettled = performFinished && cancelFinished }
        }
        if id == 1 { factoryGate?.pause() }
        return OCRProtocolOperation(id: id, state: self)
    }
    func perform(_ id: Int) throws -> String {
        lock.withLock { performs.append(id); mainThread = mainThread || Thread.isMainThread }
        if id == 1 { performGate?.pause() }
        lock.withLock { if id == 1 { performFinished = true } }
        if fails { throw RelayError.message("OWNED_PRIVATE_SDK_ERROR_MUST_NOT_ESCAPE") }
        return "owned-\(id)"
    }
    func cancel(_ id: Int) {
        lock.withLock { cancellations.append(id); mainThread = mainThread || Thread.isMainThread }
        if id == 1 { cancelGate?.pause() }
        lock.withLock { if id == 1 { cancelFinished = true } }
    }
    func releaseAll() { factoryGate?.release(); performGate?.release(); cancelGate?.release() }
}

nonisolated private final class OCRProtocolOperation: LocalOCRExecution.Operation, @unchecked Sendable {
    let id: Int
    let state: OCRProtocolState
    init(id: Int, state: OCRProtocolState) { self.id = id; self.state = state }
    func perform() throws -> String { try state.perform(id) }
    func cancel() { state.cancel(id) }
}

nonisolated private final class OCRProfileRecorder: @unchecked Sendable {
    struct Entry: Sendable, Equatable {
        let width: Int
        let profile: LocalOCRExecution.Profile
        let preferCPU: Bool
    }
    private let lock = NSLock()
    private var entries: [Entry] = []
    var snapshot: [Entry] { lock.withLock { entries } }
    func record(_ input: LocalOCRExecution.Input) {
        lock.withLock {
            entries.append(Entry(width: input.image.width, profile: input.profile, preferCPU: input.preferCPU))
        }
    }
}

/// Only queue/lifetime protocol is injected. Original real OCR tests continue
/// to use LocalOCR's actual shared Vision backend without replacement.
@MainActor @Suite(.serialized) struct LocalOCRExecutionTests {
    private enum Failure: Error { case waitExpired, imageUnavailable }
    private final class Completion { var value = false }
    private func image(_ id: Int = 1) throws -> CGImage {
        guard let context = CGContext(data: nil, width: id, height: 1, bitsPerComponent: 8,
            bytesPerRow: id * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let image = context.makeImage() else {
            throw Failure.imageUnavailable
        }
        return image
    }
    private func until(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw Failure.waitExpired }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    @Test func actualUsedProfilesKeepDocumentRecognitionMultilingualAndOwnedMarkerExplicit() {
        let document = LocalOCRExecution.Profile.document.configuration
        #expect(document.level == .accurate)
        #expect(document.automaticallyDetectsLanguage)
        #expect(document.recognitionLanguages == nil)
        #expect(!document.usesLanguageCorrection)

        let marker = LocalOCRExecution.Profile.ownedEnglishMarker.configuration
        #expect(marker.level == .fast)
        #expect(!marker.automaticallyDetectsLanguage)
        #expect(marker.recognitionLanguages == ["en-US"])
        #expect(!marker.usesLanguageCorrection)
        // Configuration is derived from each immutable job purpose. Asking
        // for marker settings cannot change later document defaults.
        #expect(LocalOCRExecution.Profile.document.configuration == document)
    }

    @Test func alternatingQueuedProfilesStayWithTheirOwnJobsAndPreserveDefaultDevicePreference() async throws {
        let gate = OCRProtocolGate(), state = OCRProtocolState(performGate: gate)
        let recorder = OCRProfileRecorder()
        let worker = LocalOCRExecution(factory: { input in
            recorder.record(input)
            return state.make(input)
        })
        let pixels = try (1...3).map { try image($0) }
        var tasks: [Task<String, any Error>] = []
        do {
            tasks.append(Task {
                try await worker.recognize(image: pixels[0], orientation: .up,
                                           preferCPU: true, profile: .ownedEnglishMarker)
            })
            try await until { gate.entered }
            tasks.append(Task {
                // Both omitted arguments must retain the actual document
                // defaults despite a marker operation owning the SDK slot.
                try await worker.recognize(image: pixels[1], orientation: .up)
            })
            try await until { worker.ownedCount == 2 }
            tasks.append(Task {
                try await worker.recognize(image: pixels[2], orientation: .up,
                                           preferCPU: true, profile: .ownedEnglishMarker)
            })
            try await until { worker.ownedCount == 3 }
            let firstOnly = [OCRProfileRecorder.Entry(width: 1, profile: .ownedEnglishMarker, preferCPU: true)]
            #expect(recorder.snapshot == firstOnly)
            #expect(state.snapshot.factories == [1] && state.snapshot.performs == [1])
            let expectedBytes = pixels.reduce(0) { $0 + $1.bytesPerRow * $1.height }
            #expect(worker.accountedPixelBytes == expectedBytes)
            gate.release()
            for (index, task) in tasks.enumerated() {
                #expect(try await task.value == "owned-\(index + 1)")
            }
            await worker.drain()
            let expected = [
                OCRProfileRecorder.Entry(width: 1, profile: .ownedEnglishMarker, preferCPU: true),
                OCRProfileRecorder.Entry(width: 2, profile: .document, preferCPU: false),
                OCRProfileRecorder.Entry(width: 3, profile: .ownedEnglishMarker, preferCPU: true)
            ]
            #expect(recorder.snapshot == expected)
            #expect(state.snapshot.factories == [1,2,3] && state.snapshot.performs == [1,2,3])
            #expect(worker.ownedCount == 0 && worker.accountedPixelBytes == 0)
        } catch {
            tasks.forEach { $0.cancel() }; state.releaseAll()
            for task in tasks { _ = await task.result }
            await worker.drain(); throw error
        }
    }

    @Test func checkedPixelAccountingRefusesZeroOverflowAndAggregateExhaustion() throws {
        for (row, height) in [(0,1), (1,0), (-1,1), (Int.max,2), (LocalOCRExecution.maximumPixelBytes + 1,1)] {
            #expect(throws: LocalOCRExecution.Failure.invalidImage) {
                try LocalOCRExecution.checkedPixelBytes(bytesPerRow: row, height: height)
            }
        }
        #expect(try LocalOCRExecution.checkedPixelBytes(bytesPerRow: 8, height: 9) == 72)
        let maximum = LocalOCRExecution.maximumPixelBytes
        #expect(LocalOCRExecution.canAdmit(ownedJobs: 7, accountedBytes: maximum - 4, inputBytes: 4))
        #expect(!LocalOCRExecution.canAdmit(ownedJobs: 7, accountedBytes: maximum - 4, inputBytes: 5))
        #expect(!LocalOCRExecution.canAdmit(ownedJobs: 8, accountedBytes: 4, inputBytes: 4))
        #expect(!LocalOCRExecution.canAdmit(ownedJobs: 0, accountedBytes: maximum, inputBytes: 1))
    }

    @Test func aBlockedPhysicalOperationLeavesMainActorAndAsyncProgressAvailable() async throws {
        let gate = OCRProtocolGate(), state = OCRProtocolState(performGate: gate)
        let worker = LocalOCRExecution(factory: { state.make($0) }), pixels = try image()
        let task = Task { try await worker.recognize(image: pixels, orientation: .up) }
        do {
            try await until { gate.entered }
            // Both run while the synchronous performer is still blocked. No
            // semaphore wait occurs on the main/cooperative test task.
            let heartbeat = Task { @MainActor in true }
            let independent = Task.detached { 42 }
            #expect(await heartbeat.value)
            #expect(await independent.value == 42)
            #expect(!state.snapshot.mainThread && worker.activeCount == 1)
            gate.release()
            #expect(try await task.value == "owned-1")
            await worker.drain()
            #expect(worker.ownedCount == 0 && worker.accountedPixelBytes == 0)
        } catch {
            task.cancel(); gate.release(); _ = await task.result; await worker.drain(); throw error
        }
    }

    @Test(arguments: 2...8)
    func pendingCancellationPreservesFIFOAndReleasesOnlyThatImagesAccount(_ removed: Int) async throws {
        let gate = OCRProtocolGate(), state = OCRProtocolState(performGate: gate)
        let worker = LocalOCRExecution(factory: { state.make($0) })
        let images = try (1...9).map { try image($0) }
        var tasks: [Task<String, any Error>] = []
        var completions: [Completion] = []
        var overflow: Task<String, any Error>?
        do {
            for (index, pixels) in images.prefix(8).enumerated() {
                let completed = Completion()
                completions.append(completed)
                tasks.append(Task {
                    defer { completed.value = true }
                    return try await worker.recognize(image: pixels, orientation: .up)
                })
                try await until { worker.ownedCount == index + 1 }
            }
            try await until { gate.entered }
            #expect(state.snapshot.factories == [1] && state.snapshot.performs == [1])
            let total = images.prefix(8).reduce(0) { $0 + $1.bytesPerRow * $1.height }
            #expect(worker.accountedPixelBytes == total)
            let overflowCompleted = Completion(), overflowImage = images[8]
            let ninth = Task {
                defer { overflowCompleted.value = true }
                return try await worker.recognize(image: overflowImage, orientation: .up)
            }
            overflow = ninth
            try await until { overflowCompleted.value }
            await #expect(throws: LocalOCRExecution.Failure.capacityUnavailable) { try await ninth.value }
            #expect(worker.ownedCount == 8 && state.snapshot.factories == [1])
            tasks[removed - 1].cancel()
            try await until { completions[removed - 1].value }
            await #expect(throws: CancellationError.self) { try await tasks[removed - 1].value }
            #expect(worker.ownedCount == 7)
            #expect(worker.accountedPixelBytes == total - images[removed - 1].bytesPerRow * images[removed - 1].height)
            #expect(state.snapshot.cancellations.isEmpty && state.snapshot.factories == [1])
            gate.release()
            for (index, task) in tasks.enumerated() where index + 1 != removed {
                #expect(try await task.value == "owned-\(index + 1)")
            }
            await worker.drain()
            let survivors = (1...8).filter { $0 != removed }
            #expect(state.snapshot.factories == survivors && state.snapshot.performs == survivors)
            #expect(worker.ownedCount == 0 && worker.accountedPixelBytes == 0)
        } catch {
            tasks.forEach { $0.cancel() }; overflow?.cancel(); state.releaseAll()
            for task in tasks { _ = await task.result }
            if let overflow { _ = await overflow.result }
            await worker.drain(); throw error
        }
    }

    @Test func cancellationBeforeDispatchClaimPerformsNothingAndStillDrainsSubmission() async throws {
        let queue = DispatchQueue(label: "Relay.OCR.pure-suspended"), state = OCRProtocolState()
        queue.suspend()
        var resumed = false
        defer { if !resumed { queue.resume() } }
        let worker = LocalOCRExecution(testQueue: queue, factory: { state.make($0) }), pixels = try image()
        let completed = Completion()
        let task = Task {
            defer { completed.value = true }
            return try await worker.recognize(image: pixels, orientation: .up)
        }
        do {
            try await until { worker.ownedCount == 1 }
            task.cancel()
            try await until { completed.value }
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(state.snapshot.factories.isEmpty && state.snapshot.performs.isEmpty)
            #expect(worker.activeCount == 1 && worker.accountedPixelBytes == pixels.bytesPerRow)
            resumed = true; queue.resume(); await worker.drain()
            #expect(worker.ownedCount == 0 && worker.accountedPixelBytes == 0)
            #expect(state.snapshot.factories.isEmpty && state.snapshot.performs.isEmpty)
        } catch {
            task.cancel(); resumed = true; queue.resume(); _ = await task.result; await worker.drain(); throw error
        }
    }

    @Test func cancellationDuringFactoryCannotStartTheSDKPerform() async throws {
        let gate = OCRProtocolGate(), state = OCRProtocolState(factoryGate: gate)
        let worker = LocalOCRExecution(factory: { state.make($0) }), pixels = try image()
        let completed = Completion()
        let task = Task {
            defer { completed.value = true }
            return try await worker.recognize(image: pixels, orientation: .up)
        }
        do {
            try await until { gate.entered }
            task.cancel()
            try await until { completed.value }
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(worker.activeCount == 1 && state.snapshot.performs.isEmpty)
            gate.release(); await worker.drain()
            #expect(state.snapshot.performs.isEmpty && state.snapshot.cancellations.isEmpty)
            #expect(worker.ownedCount == 0 && worker.accountedPixelBytes == 0)
        } catch {
            task.cancel(); gate.release(); _ = await task.result; await worker.drain(); throw error
        }
    }

    @Test(arguments: [false, true], [false, true])
    func activeCancellationKeepsTheSlotUntilPerformAndCancelBothSettle(_ lateError: Bool, _ cancelFirst: Bool) async throws {
        let perform = OCRProtocolGate(), cancel = OCRProtocolGate()
        let state = OCRProtocolState(performGate: perform, cancelGate: cancel, fails: lateError)
        let worker = LocalOCRExecution(factory: { state.make($0) }), firstImage = try image(), secondImage = try image(2)
        let completed = Completion()
        let first = Task {
            defer { completed.value = true }
            return try await worker.recognize(image: firstImage, orientation: .up)
        }
        var second: Task<String, any Error>?
        do {
            try await until { perform.entered }
            second = Task { try await worker.recognize(image: secondImage, orientation: .up) }
            try await until { worker.ownedCount == 2 }
            first.cancel(); first.cancel()
            try await until { completed.value }
            await #expect(throws: CancellationError.self) { try await first.value }
            try await until { cancel.entered }
            #expect(worker.activeCount == 1 && worker.ownedCount == 2)
            if cancelFirst {
                cancel.release()
                try await until { state.snapshot.cancelFinished }
            } else {
                perform.release()
                try await until { state.snapshot.performFinished }
            }
            #expect(state.snapshot.factories == [1] && state.snapshot.cancellations == [1])
            #expect(worker.accountedPixelBytes == firstImage.bytesPerRow + secondImage.bytesPerRow)
            cancel.release(); perform.release()
            if let second {
                if lateError {
                    await #expect(throws: LocalOCRExecution.Failure.recognitionUnavailable) { try await second.value }
                } else { #expect(try await second.value == "owned-2") }
            }
            await worker.drain()
            #expect(state.snapshot.secondSawBothSettled && state.snapshot.factories == [1,2])
            #expect(worker.ownedCount == 0 && worker.accountedPixelBytes == 0)
        } catch {
            first.cancel(); second?.cancel(); state.releaseAll(); _ = await first.result
            if let second { _ = await second.result }
            await worker.drain(); throw error
        }
    }

    @Test func rawPerformerErrorsHaveOnlyTheClosedFailureSurface() async throws {
        let state = OCRProtocolState(fails: true), worker = LocalOCRExecution(factory: { state.make($0) })
        let pixels = try image()
        do {
            _ = try await worker.recognize(image: pixels, orientation: .up)
            Issue.record("An owned failed performer returned a value.")
        } catch let failure as LocalOCRExecution.Failure {
            #expect(failure == .recognitionUnavailable)
            #expect(!failure.localizedDescription.contains("OWNED_PRIVATE_SDK_ERROR"))
        } catch {
            await worker.drain()
            throw error
        }
        await worker.drain()
        #expect(worker.ownedCount == 0 && worker.accountedPixelBytes == 0)
    }
}
