import CoreGraphics
import Dispatch
import Foundation
import ImageIO
import Vision

/// A single app-lifetime SDK slot with a bounded FIFO. Queue ownership and
/// waiter cancellation are separate: cancellation never frees a running slot.
nonisolated final class LocalOCRExecution: @unchecked Sendable {
    static let shared = LocalOCRExecution()
    static let maximumJobs = 8
    static let maximumReadinessWaiters = 8
    static let maximumPixelBytes = 512 * 1_024 * 1_024

    /// Internal recognition purpose, never capture or source authority.
    /// Document input keeps its existing multilingual accurate settings.
    enum Profile: Sendable, Equatable {
        case document
        case ownedEnglishMarker

        var configuration: Configuration {
            switch self {
            case .document:
                Configuration(level: .accurate, automaticallyDetectsLanguage: true,
                              recognitionLanguages: nil, usesLanguageCorrection: false)
            case .ownedEnglishMarker:
                Configuration(level: .fast, automaticallyDetectsLanguage: false,
                              recognitionLanguages: ["en-US"], usesLanguageCorrection: false)
            }
        }
    }
    /// The actual settings consumed below by VisionOperation. It contains no
    /// image, text, nonce, request, source or permission state.
    struct Configuration: Sendable, Equatable {
        enum Level: Sendable, Equatable { case accurate, fast }
        let level: Level
        let automaticallyDetectsLanguage: Bool
        let recognitionLanguages: [String]?
        let usesLanguageCorrection: Bool
    }

    enum DocumentReadinessState: Sendable, Equatable {
        case unstarted
        case priming(generation: UInt64)
        case ready(generation: UInt64)
        case failed(generation: UInt64)
    }

    /// Only generated primer checks enter this bounded diagnostic. No source
    /// text, image, path, nonce or SDK error description is retained.
    struct SDKErrorRecord: Sendable, Codable, Equatable {
        let domain: String
        let code: Int
    }
    /// Generated input only. At most root + three underlying NSError records;
    /// no descriptions, source strings, paths or other userInfo are copied.
    static func primerSDKErrorRecords(_ error: any Error) -> [SDKErrorRecord] {
        var result: [SDKErrorRecord] = [], current: NSError? = error as NSError
        var seen = Set<ObjectIdentifier>()
        while let actual = current, result.count < 4, seen.insert(ObjectIdentifier(actual)).inserted {
            let bytes = Array(actual.domain.utf8)
            let letter: (UInt8) -> Bool = { (65...90).contains($0) || (97...122).contains($0) || $0 == 95 }
            let valid = !bytes.isEmpty && bytes.count <= 128 && letter(bytes[0])
                && bytes.allSatisfy { letter($0) || (48...57).contains($0) || $0 == 46 || $0 == 45 }
            result.append(.init(domain: valid ? actual.domain : "unavailable", code: actual.code))
            current = actual.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return result
    }
    struct PreparationCheck: Sendable, Codable {
        let generation: UInt64
        let step: Int
        let elapsedMilliseconds: Double
        let resultKind: String
        let returnedByteCount: Int
        let sourceMatched: Bool
        let sdkErrorDomain: String?
        let sdkErrorCode: Int?
        let sdkUnderlyingErrors: [SDKErrorRecord]?
    }
    private var preparationChecks: [PreparationCheck] = []
    var documentPreparationChecks: [PreparationCheck] { lock.withLock { preparationChecks } }

    enum Failure: LocalizedError, Equatable {
        case capacityUnavailable
        case invalidImage
        case recognitionUnavailable
        case documentRecognitionPreparing
        case documentRecognitionUnavailable

        var errorDescription: String? {
            switch self {
            case .capacityUnavailable:
                "Local text recognition is busy. Wait for existing recognition to settle."
            case .invalidImage:
                "The decoded image exceeds the bounded local recognition capacity."
            case .recognitionUnavailable:
                "Local text recognition could not complete."
            case .documentRecognitionPreparing:
                "Local text recognition is still finishing initial preparation on this Mac. Wait for preparation to settle, then try again."
            case .documentRecognitionUnavailable:
                "Local document text recognition is unavailable because initial preparation did not complete."
            }
        }
    }

    /// CGImage is retained as immutable input. No file, decode or source query
    /// is permitted here; all other fields are copied values.
    struct Input: @unchecked Sendable {
        let image: CGImage
        let orientation: CGImagePropertyOrientation
        let preferCPU: Bool
        let profile: Profile
    }

    protocol Operation: AnyObject, Sendable {
        func perform() throws -> String
        func cancel()
    }
    typealias Factory = @Sendable (Input) throws -> any Operation

    /// Pure value-type primer stage descriptor; retains no CGImage or pixel buffer.
    private struct PrimerStage: Sendable, Equatable {
        let generation: UInt64
        let step: DocumentOCRPreparation.PrimerStep
    }
    private enum ClaimedInput {
        case ready(Input)
        case firstPrimer(PrimerStage)
    }

    private enum Phase: Equatable { case created, pending, submitted, running, settled }
    private enum Resolution {
        case text(String), failed(Failure), cancelled
        func resume(_ continuation: CheckedContinuation<String, any Error>) {
            switch self {
            case .text(let text): continuation.resume(returning: text)
            case .failed(let failure): continuation.resume(throwing: failure)
            case .cancelled: continuation.resume(throwing: CancellationError())
            }
        }
    }
    private enum ReadinessResolution {
        case ready, failed(Failure), cancelled
        func resume(_ continuation: CheckedContinuation<Void, any Error>) {
            switch self {
            case .ready: continuation.resume(returning: ())
            case .failed(let failure): continuation.resume(throwing: failure)
            case .cancelled: continuation.resume(throwing: CancellationError())
            }
        }
    }
    /// Finite per-call registration cell for `prepareDocumentReadiness`.
    /// Eliminates global cancellation-tombstone sets and duplicate resumptions.
    private final class ReadinessTicket: @unchecked Sendable {
        enum State: Equatable {
            case created
            case waiting(generation: UInt64)
            case settled
        }
        var state = State.created
        var resolution: ReadinessResolution?
        var continuation: CheckedContinuation<Void, any Error>?
    }
    /// Every mutable field is accessed under the owning execution's lock.
    private final class Job: @unchecked Sendable {
        var input: Input?
        let pixelBytes: Int
        let primerStage: PrimerStage?
        let primerBegan: ContinuousClock.Instant?
        var phase = Phase.created
        var resolution: Resolution?
        var continuation: CheckedContinuation<String, any Error>?
        var operation: (any Operation)?
        var sdkStarted = false
        var primerSDKErrors: [SDKErrorRecord] = []
        var performSettled = false
        var primerBytesTransferred = false
        var cancelInFlight = false
        var cancelIssued = false
        init(input: Input?, pixelBytes: Int, primerStage: PrimerStage? = nil) {
            self.input = input
            self.pixelBytes = pixelBytes
            self.primerStage = primerStage
            primerBegan = primerStage == nil ? nil : .now
        }
    }

    /// Generated primers only; no ordinary input can enter this set. Each
    /// transferred bitmap remains charged until its SDK-queue disposal ends.
    private struct PrimerResource {
        let generation: UInt64
        let input: Input
        let operation: any Operation
        let pixelBytes: Int
    }
    struct GeneratedResourceInfo: Sendable, Equatable {
        let generation: UInt64, width: Int, height: Int, pixelBytes: Int
    }
    private final class ResourceRetirement: @unchecked Sendable {
        let pixelBytes: Int
        let info: [GeneratedResourceInfo]
        private var resources: [PrimerResource]
        init(_ resources: [PrimerResource]) {
            self.resources = resources
            info = resources.map { .init(generation: $0.generation, width: $0.input.image.width,
                height: $0.input.image.height, pixelBytes: $0.pixelBytes) }
            pixelBytes = resources.reduce(0) { $0 + $1.pixelBytes }
        }
        /// Sole resource owner after transfer; only the serial SDK queue calls.
        func dispose() { resources.removeAll() }
    }
    private struct Effects {
        var delivery: (CheckedContinuation<String, any Error>, Resolution)?
        var readinessDeliveries: [(CheckedContinuation<Void, any Error>, ReadinessResolution)] = []
        var start: Job?
        var cancellation: (Job, any Operation)?
        var drains: [CheckedContinuation<Void, Never>] = []
        var retirement: ResourceRetirement?
    }
    private let lock = NSLock()
    private let queue: DispatchQueue
    private let cancellationQueue: DispatchQueue
    private let pixelBytesLimit: Int
    private let factory: Factory
    private var active: Job?
    private var pending: [Job] = []
    private var pixelBytes = 0
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    private var documentReadiness: DocumentReadinessState
    private var readinessGeneration: UInt64 = 0
    private var readinessTickets: [ReadinessTicket] = []
    private var readinessTimeoutItem: DispatchWorkItem?
    private var primerResources: [PrimerResource] = []
    private var retirePrimerResources = false
    private var resourceRetirement: ResourceRetirement?

    private init() {
        queue = DispatchQueue(label: "Relay.LocalOCR.perform", qos: .userInitiated)
        cancellationQueue = DispatchQueue(label: "Relay.LocalOCR.cancel", qos: .userInitiated)
        pixelBytesLimit = Self.maximumPixelBytes
        documentReadiness = ProcessInfo.processInfo.environment["RELAY_RUN_DOCUMENT_OCR_READINESS"] == "1"
            ? .unstarted
            : .ready(generation: 0)
        factory = { VisionOperation(input: $0) }
    }
    #if DEBUG
    /// An owned, fixed primer image for an isolated Swift Testing diagnostic.
    /// The probe compares the actual factory with a raw request on the same
    /// queue and image. This bypasses the worker only in the diagnostic.
    struct GeneratedFirstPrimerDiagnostic {
        let input: Input
        private let factory: Factory

        fileprivate init(input: Input, factory: @escaping Factory) {
            self.input = input
            self.factory = factory
        }

        func makeProductionOperation() throws -> any Operation {
            try factory(input)
        }
    }

    static func makeGeneratedFirstPrimerDiagnostic() throws -> GeneratedFirstPrimerDiagnostic {
        let first = try DocumentOCRPreparation.makePrimerCheck(for: .firstDocumentCheck)
        let input = Input(image: first.image, orientation: .up, preferCPU: true, profile: first.step.profile)
        return GeneratedFirstPrimerDiagnostic(input: input, factory: shared.factory)
    }

    /// Pure protocol tests default to pre-ready queue admission so existing
    /// protocol suites stay unchanged; readiness protocol tests pass
    /// `requiresDocumentReadiness: true` to exercise cold `.unstarted` gating.
    init(testQueue: DispatchQueue = DispatchQueue(label: "Relay.LocalOCR.protocol-test"),
         maximumPixelBytes: Int = LocalOCRExecution.maximumPixelBytes,
         requiresDocumentReadiness: Bool = false,
         factory: @escaping Factory) {
        queue = testQueue
        cancellationQueue = DispatchQueue(label: "Relay.LocalOCR.protocol-test.cancel")
        pixelBytesLimit = max(1, min(Self.maximumPixelBytes, maximumPixelBytes))
        documentReadiness = requiresDocumentReadiness ? .unstarted : .ready(generation: 0)
        self.factory = factory
    }
    #endif

    var activeCount: Int { lock.withLock { active == nil ? 0 : 1 } }
    var ownedCount: Int { lock.withLock { pending.count + (active == nil ? 0 : 1) } }
    var accountedPixelBytes: Int { lock.withLock { pixelBytes } }
    var documentReadinessState: DocumentReadinessState { lock.withLock { documentReadiness } }
    var currentReadinessGeneration: UInt64 { lock.withLock { readinessGeneration } }
    var readinessWaiterCount: Int { lock.withLock { readinessTickets.count } }
    var generatedResourceInfo: [GeneratedResourceInfo] {
        lock.withLock { primerResources.map { .init(generation: $0.generation,
            width: $0.input.image.width, height: $0.input.image.height, pixelBytes: $0.pixelBytes) } }
    }
    var retiringGeneratedPixelBytes: Int { lock.withLock { resourceRetirement?.pixelBytes ?? 0 } }
    var retiringGeneratedResourceInfo: [GeneratedResourceInfo] { lock.withLock { resourceRetirement?.info ?? [] } }

    static func checkedPixelBytes(bytesPerRow: Int, height: Int) throws -> Int {
        guard bytesPerRow > 0, height > 0 else { throw Failure.invalidImage }
        let (bytes, overflow) = bytesPerRow.multipliedReportingOverflow(by: height)
        guard !overflow, bytes > 0, bytes <= maximumPixelBytes else { throw Failure.invalidImage }
        return bytes
    }

    static func canAdmit(ownedJobs: Int,
                         accountedBytes: Int,
                         inputBytes: Int,
                         maximumBytes: Int = LocalOCRExecution.maximumPixelBytes) -> Bool {
        ownedJobs >= 0 && ownedJobs < maximumJobs
            && accountedBytes >= 0 && accountedBytes <= maximumBytes
            && inputBytes > 0 && inputBytes <= maximumBytes - accountedBytes
    }

    func checkAvailability(for profile: Profile) throws {
        if let failure = lock.withLock({ availabilityFailureLocked(for: profile) }) {
            throw failure
        }
    }

    func recognize(image: CGImage, orientation: CGImagePropertyOrientation,
                   preferCPU: Bool = false, profile: Profile = .document) async throws -> String {
        try Task.checkCancellation()
        let bytes = try Self.checkedPixelBytes(bytesPerRow: image.bytesPerRow, height: image.height)
        let job = Job(input: Input(image: image, orientation: orientation, preferCPU: preferCPU, profile: profile), pixelBytes: bytes)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let text = try await withCheckedThrowingContinuation { continuation in
                apply(lock.withLock { submit(job, continuation: continuation) })
            }
            try Task.checkCancellation()
            return text
        } onCancel: {
            self.apply(self.lock.withLock { self.cancel(job) })
        }
    }

    func prepareDocumentReadiness(timeout: Duration = DocumentOCRPreparation.defaultTimeout) async throws {
        try Task.checkCancellation()
        let clamped = Self.clampedReadinessTimeout(timeout)
        let ticket = ReadinessTicket()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                apply(lock.withLock {
                    registerReadinessTicketLocked(ticket, timeout: clamped, continuation: continuation)
                })
            }
            try Task.checkCancellation()
        } onCancel: {
            self.apply(self.lock.withLock {
                self.cancelReadinessTicketLocked(ticket)
            })
        }
    }

    /// Explicit primary app-lifetime cancellation. Aborts any in-flight priming
    /// generation and fences its generation so late completion never sets ready.
    func cancelDocumentReadiness() {
        apply(lock.withLock {
            var effects = Effects()
            switch documentReadiness {
            case .priming(let generation):
                abortPrimingLocked(expectedGeneration: generation, reason: .cancelled, effects: &effects)
            case .ready:
                readinessGeneration &+= 1
                documentReadiness = .failed(generation: readinessGeneration)
                retirePrimerResources = true
                scheduleResourceRetirementLocked(effects: &effects)
            case .unstarted, .failed: break
            }
            return effects
        })
    }

    /// Waits for physical quiescence even if this drain waiter was cancelled.
    /// Waiters retain no image, request, body or source authority.
    func drain() async {
        await withCheckedContinuation { continuation in
            let immediate = lock.withLock {
                guard active != nil || !pending.isEmpty || resourceRetirement != nil else { return true }
                drainWaiters.append(continuation)
                return false
            }
            if immediate { continuation.resume() }
        }
    }

    private var hasUnsettledPrimerLocked: Bool {
        if retirePrimerResources { return true }
        if resourceRetirement != nil { return true }
        if case .priming = documentReadiness { return true }
        if active?.primerStage != nil { return true }
        return pending.contains { $0.primerStage != nil }
    }

    private func availabilityFailureLocked(for profile: Profile) -> Failure? {
        if hasUnsettledPrimerLocked {
            return .documentRecognitionPreparing
        }
        switch (profile, documentReadiness) {
        case (.document, .ready):
            return nil
        case (.document, .unstarted), (.document, .priming):
            return .documentRecognitionPreparing
        case (.document, .failed):
            return .documentRecognitionUnavailable
        case (.ownedEnglishMarker, .priming):
            return .documentRecognitionPreparing
        case (.ownedEnglishMarker, .unstarted), (.ownedEnglishMarker, .ready), (.ownedEnglishMarker, .failed):
            return nil
        }
    }

    // These state transitions run only while lock is held. SDK calls, queue
    // submission and continuation resumption always happen after unlocking.
    private func deliver(_ resolution: Resolution, to job: Job, effects: inout Effects) {
        guard job.resolution == nil else { return }
        job.resolution = resolution
        if let continuation = job.continuation {
            job.continuation = nil
            effects.delivery = (continuation, resolution)
        }
    }
    private func deliverReadiness(_ resolution: ReadinessResolution,
                                  to ticket: ReadinessTicket,
                                  effects: inout Effects) {
        guard ticket.resolution == nil else { return }
        ticket.resolution = resolution
        if let continuation = ticket.continuation {
            ticket.continuation = nil
            effects.readinessDeliveries.append((continuation, resolution))
        }
    }
    private func submit(_ job: Job, continuation: CheckedContinuation<String, any Error>) -> Effects {
        var effects = Effects()
        if let resolution = job.resolution {
            effects.delivery = (continuation, resolution)
            job.phase = .settled
            job.input = nil
            return effects
        }
        job.continuation = continuation
        if job.primerStage == nil, let profile = job.input?.profile,
           let failure = availabilityFailureLocked(for: profile) {
            deliver(.failed(failure), to: job, effects: &effects)
            job.phase = .settled
            job.input = nil
            return effects
        }
        guard Self.canAdmit(ownedJobs: pending.count + (active == nil ? 0 : 1),
                            accountedBytes: pixelBytes, inputBytes: job.pixelBytes,
                            maximumBytes: pixelBytesLimit) else {
            deliver(.failed(.capacityUnavailable), to: job, effects: &effects)
            job.phase = .settled
            job.input = nil
            return effects
        }
        pixelBytes += job.pixelBytes
        if active == nil {
            active = job
            job.phase = .submitted
            effects.start = job
        } else {
            job.phase = .pending
            pending.append(job)
        }
        return effects
    }
    private func cancel(_ job: Job) -> Effects {
        var effects = Effects()
        cancelLocked(job, into: &effects)
        return effects
    }
    private func cancelLocked(_ job: Job, into effects: inout Effects) {
        guard job.phase != .settled else { return }
        deliver(.cancelled, to: job, effects: &effects)
        if job.phase == .pending, let index = pending.firstIndex(where: { $0 === job }) {
            pending.remove(at: index)
            pixelBytes -= job.pixelBytes
            job.phase = .settled
            job.input = nil
        } else if job.phase == .running, job.sdkStarted, !job.performSettled, !job.cancelIssued, let operation = job.operation {
            job.cancelIssued = true
            job.cancelInFlight = true
            effects.cancellation = (job, operation)
        }
    }
    private func registerReadinessTicketLocked(_ ticket: ReadinessTicket,
                                               timeout: Duration,
                                               continuation: CheckedContinuation<Void, any Error>) -> Effects {
        var effects = Effects()
        if let resolution = ticket.resolution {
            effects.readinessDeliveries.append((continuation, resolution))
            ticket.state = .settled
            return effects
        }
        if Task.isCancelled {
            ticket.resolution = .cancelled
            ticket.state = .settled
            effects.readinessDeliveries.append((continuation, .cancelled))
            return effects
        }
        ticket.continuation = continuation
        switch documentReadiness {
        case .ready:
            deliverReadiness(.ready, to: ticket, effects: &effects)
            ticket.state = .settled
            return effects
        case .priming(let generation):
            guard readinessTickets.count < Self.maximumReadinessWaiters else {
                deliverReadiness(.failed(.capacityUnavailable), to: ticket, effects: &effects)
                ticket.state = .settled
                return effects
            }
            ticket.state = .waiting(generation: generation)
            readinessTickets.append(ticket)
            return effects
        case .unstarted, .failed:
            guard active == nil, pending.isEmpty, resourceRetirement == nil,
                  readinessTickets.count < Self.maximumReadinessWaiters,
                  Self.canAdmit(ownedJobs: 0, accountedBytes: pixelBytes,
                    inputBytes: 3 * DocumentOCRPreparation.bannerPixelBytes, maximumBytes: pixelBytesLimit) else {
                deliverReadiness(.failed(.capacityUnavailable), to: ticket, effects: &effects)
                ticket.state = .settled
                return effects
            }
            readinessGeneration &+= 1
            let generation = readinessGeneration
            documentReadiness = .priming(generation: generation)
            preparationChecks.removeAll(keepingCapacity: true)
            ticket.state = .waiting(generation: generation)
            readinessTickets.append(ticket)
            let firstStage = PrimerStage(generation: generation, step: .firstDocumentCheck)
            // Reserve the exact bitmap charge before the physical queue
            // allocates it. This job owns the slot even while input is absent.
            let firstJob = Job(input: nil, pixelBytes: DocumentOCRPreparation.bannerPixelBytes,
                               primerStage: firstStage)
            pixelBytes += firstJob.pixelBytes
            active = firstJob
            firstJob.phase = .submitted
            effects.start = firstJob
            scheduleReadinessTimeoutLocked(generation: generation, timeout: timeout)
            return effects
        }
    }
    private func cancelReadinessTicketLocked(_ ticket: ReadinessTicket) -> Effects {
        var effects = Effects()
        guard ticket.state != .settled else { return effects }
        let waitingGeneration: UInt64? = {
            if case .waiting(let generation) = ticket.state { return generation }
            return nil
        }()
        deliverReadiness(.cancelled, to: ticket, effects: &effects)
        ticket.state = .settled
        if let index = readinessTickets.firstIndex(where: { $0 === ticket }) {
            readinessTickets.remove(at: index)
        }
        if let generation = waitingGeneration {
            let hasRemainingOwners = readinessTickets.contains {
                if case .waiting(let current) = $0.state { return current == generation }
                return false
            }
            if !hasRemainingOwners {
                abortPrimingLocked(expectedGeneration: generation, reason: .cancelled, effects: &effects)
            }
        }
        return effects
    }
    private func scheduleReadinessTimeoutLocked(generation: UInt64, timeout: Duration) {
        readinessTimeoutItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let effects = self.lock.withLock {
                var effects = Effects()
                guard case .priming(let current) = self.documentReadiness, current == generation else {
                    return effects
                }
                self.abortPrimingLocked(
                    expectedGeneration: generation,
                    reason: .failed(.documentRecognitionUnavailable),
                    effects: &effects
                )
                return effects
            }
            self.apply(effects)
        }
        readinessTimeoutItem = item
        cancellationQueue.asyncAfter(
            deadline: .now() + .nanoseconds(Self.nanoseconds(for: timeout)),
            execute: item
        )
    }
    private func abortPrimingLocked(expectedGeneration: UInt64,
                                    reason: ReadinessResolution,
                                    effects: inout Effects) {
        guard case .priming(let current) = documentReadiness, current == expectedGeneration else { return }
        readinessTimeoutItem?.cancel()
        readinessTimeoutItem = nil
        readinessGeneration &+= 1
        documentReadiness = .failed(generation: readinessGeneration)
        retirePrimerResources = true
        var remaining: [ReadinessTicket] = []
        for ticket in readinessTickets {
            if case .waiting(let ticketGeneration) = ticket.state, ticketGeneration == expectedGeneration {
                deliverReadiness(reason, to: ticket, effects: &effects)
                ticket.state = .settled
            } else {
                remaining.append(ticket)
            }
        }
        readinessTickets = remaining
        if let activeJob = active, activeJob.primerStage?.generation == expectedGeneration {
            cancelLocked(activeJob, into: &effects)
        }
        scheduleResourceRetirementLocked(effects: &effects)
    }
    private func finishPrimerLocked(_ job: Job,
                                    stage: PrimerStage,
                                    resolution: Resolution,
                                    effects: inout Effects) {
        let generationStillActive: Bool = {
            if case .priming(let current) = documentReadiness {
                return current == stage.generation && job.resolution == nil && !job.cancelIssued && !job.cancelInFlight
            }
            return false
        }()
        guard generationStillActive else {
            finalize(job, effects: &effects)
            return
        }
        let passed: Bool = {
            guard case .text(let recognized) = resolution else { return false }
            return DocumentOCRPreparation.validatePrimerOutput(
                recognized,
                expectedText: stage.step.expectedText,
                forbiddenNonce: stage.step.forbiddenNonce
            )
        }()
        if preparationChecks.count < 3 {
            let kind: String
            let count: Int
            switch resolution {
            case .text(let text): kind = "text"; count = text.utf8.count
            case .cancelled: kind = "cancelled"; count = 0
            case .failed: kind = "sdkFailure"; count = 0
            }
            let elapsed = (job.primerBegan ?? .now).duration(to: .now).components
            preparationChecks.append(.init(generation: stage.generation, step: stage.step.rawValue,
                elapsedMilliseconds: Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15,
                resultKind: kind, returnedByteCount: count, sourceMatched: passed,
                sdkErrorDomain: job.primerSDKErrors.first?.domain, sdkErrorCode: job.primerSDKErrors.first?.code,
                sdkUnderlyingErrors: job.primerSDKErrors.count > 1 ? Array(job.primerSDKErrors.dropFirst()) : nil))
        }
        guard passed else {
            abortPrimingLocked(
                expectedGeneration: stage.generation,
                reason: .failed(.documentRecognitionUnavailable),
                effects: &effects
            )
            finalize(job, effects: &effects)
            return
        }
        guard pinGeneratedResourceLocked(job, stage: stage) else {
            abortPrimingLocked(expectedGeneration: stage.generation,
                reason: .failed(.documentRecognitionUnavailable), effects: &effects)
            finalize(job, effects: &effects)
            return
        }
        if let nextStep = stage.step.nextStep {
            guard active === job, job.performSettled, !job.cancelInFlight else {
                finalize(job, effects: &effects)
                return
            }
            let previousImage = job.input?.image
            // Transfer only this generated input/request to the bounded
            // generation set. Its bytes stay charged while the next runs.
            active = nil
            if !job.primerBytesTransferred { pixelBytes -= job.pixelBytes }
            job.input = nil
            job.operation = nil
            job.phase = .settled
            guard Self.canAdmit(ownedJobs: pending.count, accountedBytes: pixelBytes,
                inputBytes: DocumentOCRPreparation.bannerPixelBytes, maximumBytes: pixelBytesLimit) else {
                abortPrimingLocked(expectedGeneration: stage.generation,
                    reason: .failed(.documentRecognitionUnavailable), effects: &effects)
                return
            }
            let nextCheck: DocumentOCRPreparation.PrimerCheck
            do {
                nextCheck = try DocumentOCRPreparation.makePrimerCheck(for: nextStep, reusing: previousImage)
            } catch {
                abortPrimingLocked(
                    expectedGeneration: stage.generation,
                    reason: .failed(.documentRecognitionUnavailable),
                    effects: &effects
                )
                advanceAfterSettlementLocked(effects: &effects)
                return
            }
            guard Self.canAdmit(ownedJobs: pending.count, accountedBytes: pixelBytes,
                                inputBytes: nextCheck.pixelBytes,
                                maximumBytes: pixelBytesLimit) else {
                abortPrimingLocked(
                    expectedGeneration: stage.generation,
                    reason: .failed(.documentRecognitionUnavailable),
                    effects: &effects
                )
                advanceAfterSettlementLocked(effects: &effects)
                return
            }
            let nextStage = PrimerStage(generation: stage.generation, step: nextStep)
            let nextInput = Input(
                image: nextCheck.image,
                orientation: .up,
                preferCPU: true,
                profile: nextStep.profile
            )
            let nextJob = Job(input: nextInput, pixelBytes: nextCheck.pixelBytes, primerStage: nextStage)
            pixelBytes += nextJob.pixelBytes
            active = nextJob
            nextJob.phase = .submitted
            effects.start = nextJob
        } else {
            finalize(job, effects: &effects)
            guard active == nil, pending.isEmpty,
                  case .priming(let current) = documentReadiness,
                  current == stage.generation else {
                return
            }
            readinessTimeoutItem?.cancel()
            readinessTimeoutItem = nil
            documentReadiness = .ready(generation: stage.generation)
            var remaining: [ReadinessTicket] = []
            for ticket in readinessTickets {
                if case .waiting(let ticketGeneration) = ticket.state, ticketGeneration == stage.generation {
                    deliverReadiness(.ready, to: ticket, effects: &effects)
                    ticket.state = .settled
                } else {
                    remaining.append(ticket)
                }
            }
            readinessTickets = remaining
        }
    }
    private func pinGeneratedResourceLocked(_ job: Job, stage: PrimerStage) -> Bool {
        guard active === job, job.performSettled, !job.cancelInFlight,
              !job.primerBytesTransferred, primerResources.count < 3,
              primerResources.allSatisfy({ $0.generation == stage.generation }),
              let input = job.input, let operation = job.operation,
              input.profile == stage.step.profile,
              input.image.width == DocumentOCRPreparation.bannerWidth,
              input.image.height == DocumentOCRPreparation.bannerHeight,
              job.pixelBytes == DocumentOCRPreparation.bannerPixelBytes else { return false }
        primerResources.append(.init(generation: stage.generation, input: input,
            operation: operation, pixelBytes: job.pixelBytes))
        job.primerBytesTransferred = true
        return true
    }
    private func scheduleResourceRetirementLocked(effects: inout Effects) {
        guard retirePrimerResources, active == nil, resourceRetirement == nil else { return }
        retirePrimerResources = false
        guard !primerResources.isEmpty else { return }
        let retirement = ResourceRetirement(primerResources)
        primerResources.removeAll()
        resourceRetirement = retirement
        effects.retirement = retirement
    }
    private func advanceAfterSettlementLocked(effects: inout Effects) {
        scheduleResourceRetirementLocked(effects: &effects)
        guard active == nil, resourceRetirement == nil else { return }
        if !pending.isEmpty {
            let next = pending.removeFirst()
            active = next; next.phase = .submitted; effects.start = next
        } else {
            effects.drains = drainWaiters; drainWaiters = []
        }
    }
    private func finalize(_ job: Job, effects: inout Effects) {
        guard active === job, job.performSettled, !job.cancelInFlight else { return }
        active = nil
        if !job.primerBytesTransferred { pixelBytes -= job.pixelBytes }
        job.input = nil
        job.operation = nil
        job.phase = .settled
        advanceAfterSettlementLocked(effects: &effects)
    }
    private func apply(_ effects: Effects) {
        if let (continuation, resolution) = effects.delivery { resolution.resume(continuation) }
        for (continuation, resolution) in effects.readinessDeliveries { resolution.resume(continuation) }
        for waiter in effects.drains { waiter.resume() }
        if let (job, operation) = effects.cancellation {
            cancellationQueue.async { [self] in
                autoreleasepool { operation.cancel() }
                let finished = lock.withLock {
                    job.cancelInFlight = false
                    var effects = Effects()
                    finalize(job, effects: &effects)
                    return effects
                }
                apply(finished)
            }
        }
        if let retirement = effects.retirement {
            queue.async { [self] in
                autoreleasepool { retirement.dispose() }
                let finished = lock.withLock {
                    var effects = Effects()
                    guard resourceRetirement === retirement else { return effects }
                    pixelBytes -= retirement.pixelBytes
                    resourceRetirement = nil
                    advanceAfterSettlementLocked(effects: &effects)
                    return effects
                }
                apply(finished)
            }
        }
        if let job = effects.start {
            queue.async { [self] in
                // Dispose of perform's local input/operation and autoreleased
                // SDK objects BEFORE settlement can release accounted pixels
                // or construct the next primer bitmap on the same slot.
                let resolution = autoreleasepool { perform(job) }
                finish(job, with: resolution)
            }
        }
    }
    private func perform(_ job: Job) -> Resolution {
        let claim: ClaimedInput? = lock.withLock {
            guard active === job, job.phase == .submitted, job.resolution == nil else { return nil }
            job.phase = .running
            if let input = job.input { return .ready(input) }
            guard let stage = job.primerStage, stage.step == .firstDocumentCheck,
                  case .priming(let generation) = documentReadiness, generation == stage.generation else { return nil }
            return .firstPrimer(stage)
        }
        guard let claim else { return .cancelled }
        let input: Input
        switch claim {
        case .ready(let ready): input = ready
        case .firstPrimer(let stage):
            do {
                let first = try DocumentOCRPreparation.makePrimerCheck(for: stage.step)
                guard first.pixelBytes == job.pixelBytes else { throw Failure.invalidImage }
                input = Input(image: first.image, orientation: .up, preferCPU: true, profile: first.step.profile)
            } catch let failure as Failure { return .failed(failure) }
            catch { return .failed(.recognitionUnavailable) }
            let installed = lock.withLock {
                guard active === job, job.phase == .running, job.resolution == nil, job.input == nil,
                      case .priming(let generation) = documentReadiness, generation == stage.generation else { return false }
                job.input = input
                return true
            }
            guard installed else { return .cancelled }
        }
        do {
            // Factory/configuration and perform/results all stay on this GCD
            // queue. A pending job has never constructed a Vision object.
            let operation = try factory(input)
            let mayPerform = lock.withLock {
                guard active === job, job.phase == .running, job.resolution == nil else { return false }
                job.operation = operation
                job.sdkStarted = true
                return true
            }
            guard mayPerform else { return .cancelled }
            let text = try operation.perform()
            return .text(text)
        } catch is CancellationError { return .cancelled }
        catch {
            // Primer input is app-generated. Closed domain+numeric code only;
            // ordinary private OCR errors/strings are never retained here.
            if job.primerStage != nil {
                let records = Self.primerSDKErrorRecords(error)
                lock.withLock { job.primerSDKErrors = records }
            }
            return .failed(.recognitionUnavailable)
        }
    }
    private func finish(_ job: Job, with resolution: Resolution) {
        apply(lock.withLock {
            var effects = Effects()
            guard active === job, job.phase != .settled else { return effects }
            job.performSettled = true
            if let stage = job.primerStage {
                if job.input == nil, case .failed(let failure) = resolution {
                    // Bitmap setup failed before a Vision request existed.
                    // Keep its closed error without recording an SDK check.
                    abortPrimingLocked(expectedGeneration: stage.generation, reason: .failed(failure), effects: &effects)
                    finalize(job, effects: &effects)
                } else {
                    finishPrimerLocked(job, stage: stage, resolution: resolution, effects: &effects)
                }
            } else {
                deliver(resolution, to: job, effects: &effects)
                finalize(job, effects: &effects)
            }
            return effects
        })
    }

    private static func clampedReadinessTimeout(_ timeout: Duration) -> Duration {
        min(.seconds(90), max(.milliseconds(1), timeout))
    }

    private static func nanoseconds(for duration: Duration) -> Int {
        let components = duration.components
        let seconds = max(0, components.seconds)
        let attoseconds = max(0, components.attoseconds)
        let fromSeconds = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        if fromSeconds.overflow { return Int.max }
        let fromAttoseconds = Int64(attoseconds / 1_000_000_000)
        let total = fromSeconds.partialValue.addingReportingOverflow(fromAttoseconds)
        return total.overflow ? Int.max : max(1, Int(total.partialValue))
    }

    /// Only cancel() crosses queues. This lock serializes that documented
    /// operation against extraction of results after perform has returned.
    private final class VisionOperation: Operation, @unchecked Sendable {
        private let request = VNRecognizeTextRequest()
        private let handler: VNImageRequestHandler
        private let lock = NSLock()
        private var cancelled = false
        init(input: Input) {
            handler = VNImageRequestHandler(cgImage: input.image, orientation: input.orientation)
            let configuration = input.profile.configuration
            request.recognitionLevel = configuration.level == .accurate ? .accurate : .fast
            request.usesLanguageCorrection = configuration.usesLanguageCorrection
            request.automaticallyDetectsLanguage = configuration.automaticallyDetectsLanguage
            if let languages = configuration.recognitionLanguages {
                request.recognitionLanguages = languages
            }
            if input.profile == .document || input.preferCPU {
                Self.applyCPUOnlyCompatibility(to: request)
            }
        }
        /// Public compatibility property (`VNRequest.h:64`, deprecated in macOS 14.0)
        /// applied after all recognition configuration.
        private static func applyCPUOnlyCompatibility(to request: VNRecognizeTextRequest) {
            request.usesCPUOnly = true
        }
        func perform() throws -> String {
            try handler.perform([request])
            return try lock.withLock {
                guard !cancelled else { throw CancellationError() }
                return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            }
        }
        func cancel() {
            lock.withLock {
                cancelled = true
                request.cancel()
            }
        }
    }
}
