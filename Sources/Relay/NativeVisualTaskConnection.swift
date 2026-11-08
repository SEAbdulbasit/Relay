import Foundation

/// Original-target/source facts are separate from foreground input admission.
/// The frozen controller cannot yet supply every field for background reads;
/// production availability remains false until that adapter is qualified.
@MainActor struct NativeVisualTaskSource {
    let observation: NativeControlSession.Observation
    let sourceID: UUID
    let validateOriginalSource: @MainActor () throws -> Void
    /// Actual current image/composite planning source. The native app-selected
    /// capture fence stays private inside the controller's capture operation.
    let validatePlanningObservation: @MainActor () throws -> Void
    let validateForInput: @MainActor () throws -> Void
}

@MainActor final class NativeVisualTaskConnection {
    let id = UUID()
    let controller: NativeControlSession
    let observeRead: @MainActor (NativeWindowTaskAdapter.ApplicationAdmission) async throws -> NativeVisualTaskSource
    let refreshOriginal: @MainActor (NativeVisualTaskSource) async throws -> NativeVisualTaskSource
    /// Control-only explicit authorized composite observation. This may keep a
    /// read-only source when task/window metadata does not admit editor capture.
    let refreshForInputPlanning: @MainActor (NativeVisualTaskSource) async throws -> NativeVisualTaskSource
    let prepareForReview: @MainActor (NativeControlSession.Action, NativeVisualProposalIdentity, NativeVisualTaskSource, NativeVisionFrame?) async throws -> NativeControlSession.ReviewedProposal
    /// Runs only in inserted journal.effect admission. The positive adapter
    /// restores focus inside its reserved FIFO/shared gate and returns typed
    /// partial/uncertain facts rather than throwing them away on revocation.
    let executeAdmitted: @MainActor (NativeControlSession.ReviewedProposal) async -> NativeVisualStepOutcome
    private let closeOwnedClient: @MainActor () async -> Void
    private var closing: Task<Void, Never>?

    init(controller: NativeControlSession,
         observeRead: @escaping @MainActor (NativeWindowTaskAdapter.ApplicationAdmission) async throws -> NativeVisualTaskSource,
         refreshOriginal: @escaping @MainActor (NativeVisualTaskSource) async throws -> NativeVisualTaskSource,
         refreshForInputPlanning: @escaping @MainActor (NativeVisualTaskSource) async throws -> NativeVisualTaskSource,
         prepareForReview: @escaping @MainActor (NativeControlSession.Action, NativeVisualProposalIdentity, NativeVisualTaskSource, NativeVisionFrame?) async throws -> NativeControlSession.ReviewedProposal,
         executeAdmitted: @escaping @MainActor (NativeControlSession.ReviewedProposal) async -> NativeVisualStepOutcome,
         closeOwnedClient: @escaping @MainActor () async -> Void) {
        self.controller = controller; self.observeRead = observeRead; self.refreshOriginal = refreshOriginal
        self.refreshForInputPlanning = refreshForInputPlanning
        self.closeOwnedClient = closeOwnedClient
        self.prepareForReview = prepareForReview; self.executeAdmitted = executeAdmitted
    }
    func stop() {
        guard closing == nil else { return }
        controller.stop()
        closing = Task { [controller, closeOwnedClient] in await controller.drain(); await closeOwnedClient() }
    }
    func drain() async { if let closing { await closing.value } else { await controller.drain() } }
}

@MainActor struct NativeVisualTaskConnectionFactory {
    enum Dependency: String, CaseIterable, Hashable {
        case backgroundOriginalRead = "source-only background read adapter"
        case reviewedOriginalFocus = "reviewed original-window focus capability"
        case durableControllerIdentity = "uncapped journal-bound controller identity"
        case ordinarySemanticInspection = "generic ordinary semantic inspection"
        case focusedTargetReview = "exact original-window keyboard/text review"
        case providerProvenance = "native observation event provenance"
    }
    let missingDependencies: Set<Dependency>
    let open: @MainActor (NativeVisualTaskScope, NativeOrdinaryVisualPolicy) async throws -> NativeVisualTaskConnection

    /// No unavailable capability is advertised or opened by the active app.
    static var unavailable: Self {
        .init(missingDependencies: Set(Dependency.allCases), open: { _, _ in
            throw NativeVisualTaskFailure.unavailableDependency("the task-owned controller adapter")
        })
    }
}

/// Shared ordinary-task owner. The read facade and Executor control facade use
/// this same serialized owner and connection; there is no per-agent executor.
@MainActor final class NativeComputerTaskSession {
    let scope: NativeVisualTaskScope
    let policy: NativeOrdinaryVisualPolicy
    private let factory: NativeVisualTaskConnectionFactory
    private var connection: NativeVisualTaskConnection?
    private var opening: Task<NativeVisualTaskConnection, Error>?
    private var retiring: Task<Void, Never>?
    private var stopped = false
    private var busy = false
    private struct Waiter { let id: UUID; let continuation: CheckedContinuation<Void, Error> }
    private var waiters: [Waiter] = []

    init(scope: NativeVisualTaskScope, factory: NativeVisualTaskConnectionFactory,
         policy: NativeOrdinaryVisualPolicy) {
        self.scope = scope; self.factory = factory; self.policy = policy
    }
    var isBusy: Bool { busy || opening != nil }
    var controlIsAvailable: Bool { !stopped && factory.missingDependencies.isEmpty }
    private static let readDependencies: Set<NativeVisualTaskConnectionFactory.Dependency> = [.backgroundOriginalRead, .providerProvenance]
    var readIsAvailable: Bool { !stopped && factory.missingDependencies.isDisjoint(with: Self.readDependencies) }

    func withOperation<Value>(validateSource: @escaping @MainActor () throws -> Void = {},
                              _ operation: @MainActor (NativeVisualTaskConnection) async throws -> Value) async throws -> Value {
        try await withAccess(required: Set(NativeVisualTaskConnectionFactory.Dependency.allCases), validateSource: validateSource, operation)
    }
    private func withReadOperation<Value>(validateSource: @escaping @MainActor () throws -> Void = {},
                                          _ operation: @MainActor (NativeVisualTaskConnection) async throws -> Value) async throws -> Value {
        try await withAccess(required: Self.readDependencies, validateSource: validateSource, operation)
    }
    private func withAccess<Value>(required: Set<NativeVisualTaskConnectionFactory.Dependency>,
                                   validateSource: @escaping @MainActor () throws -> Void,
                                   _ operation: @MainActor (NativeVisualTaskConnection) async throws -> Value) async throws -> Value {
        try await acquire(); defer { release() }
        try validate()
        do {
            let current = try await ownedConnection(required: required)
            // Effect operations settle their typed original-run checkpoint
            // inside this closure before this task/source fence is evaluated.
            let result = try await operation(current)
            try validate(); try validateSource()
            return result
        } catch {
            // A stale task must not publish either a late answer or a late raw
            // provider error into its replacement. This does not change the
            // factual outcome already retained by the original checkpoint.
            do { try validate(); try validateSource() } catch { throw CancellationError() }
            throw error
        }
    }

    /// MakeBackend bridge for the existing read-only service. Retiring a broken
    /// connection does not mint another task or automatically retry the read.
    func makeReadBackend() async throws -> NativeWindowTaskAdapter.Backend {
        let current = try await withReadOperation { $0 }
        let connectionID = current.id
        return .init(initial: { [weak self] admission in
            guard let self else { throw NativeVisualTaskFailure.stopped }
            var sourceFence: @MainActor () throws -> Void = {}
            return try await self.withReadOperation(validateSource: { try sourceFence() }) { connection in
                guard connection.id == connectionID else { throw NativeVisualTaskFailure.staleProposal }
                try admission.validate()
                let source = try await connection.observeRead(admission)
                sourceFence = source.validateOriginalSource
                try source.validateOriginalSource()
                return NativeWindowTaskAdapter.Capture(snapshot: source.observation.snapshot,
                    isCurrent: { [weak self, weak connection] in
                        guard let self, let connection else { return false }
                        do { try self.validate(); try source.validateOriginalSource(); return connection.controller.isCurrent(source.observation) }
                        catch { return false }
                    }, refreshOriginal: { [weak self] in
                        guard let self else { throw NativeVisualTaskFailure.stopped }
                        return try await self.withReadOperation(validateSource: source.validateOriginalSource) { original in
                            guard original.id == connectionID else { throw NativeVisualTaskFailure.staleProposal }
                            let refreshed = try await original.refreshOriginal(source)
                            try refreshed.validateOriginalSource()
                            return NativeWindowTaskAdapter.Capture(snapshot: refreshed.observation.snapshot,
                                isCurrent: { [weak self] in
                                    guard let self else { return false }
                                    do { try self.validate(); try refreshed.validateOriginalSource(); return original.controller.isCurrent(refreshed.observation) }
                                    catch { return false }
                                }, refreshOriginal: nil,
                                sourceValidation: Self.readbackSource(refreshed, validateOwner: { [weak self] in
                                    guard let self else { throw NativeVisualTaskFailure.stopped }
                                    try self.validate()
                                }))
                        }
                    }, sourceValidation: Self.readbackSource(source, validateOwner: { [weak self] in
                        guard let self else { throw NativeVisualTaskFailure.stopped }
                        try self.validate()
                    }))
            }
        }, stop: { [weak self] in self?.retire(connectionID) }, drain: { [weak self] in await self?.retiring?.value })
    }

    private static func readbackSource(_ source: NativeVisualTaskSource,
                                       validateOwner: @escaping @MainActor () throws -> Void) -> NativeCurrentReadbackSource {
        let validateOriginal = source.validateOriginalSource
        return NativeCurrentReadbackSource(sourceID: source.sourceID,
            application: source.observation.snapshot.application, validateOriginalSource: {
                try validateOwner(); try validateOriginal(); try validateOwner()
            })
    }

    func stop() {
        guard !stopped else { return }
        stopped = true; scope.stop(); policy.stop(); opening?.cancel(); connection?.stop()
        for waiter in waiters { waiter.continuation.resume(throwing: NativeVisualTaskFailure.stopped) }
        waiters.removeAll()
    }
    func drain() async {
        if let opening, let late = try? await opening.value { late.stop(); await late.drain() }
        await retiring?.value
        await connection?.drain()
    }
    private func validate() throws {
        try scope.validate()
        guard !stopped else { throw NativeVisualTaskFailure.stopped }
    }
    private func ownedConnection(required: Set<NativeVisualTaskConnectionFactory.Dependency>) async throws -> NativeVisualTaskConnection {
        try validate()
        if let dependency = factory.missingDependencies.intersection(required).sorted(by: { $0.rawValue < $1.rawValue }).first {
            throw NativeVisualTaskFailure.unavailableDependency(dependency.rawValue)
        }
        if let connection { return connection }
        if let retiring { await retiring.value; self.retiring = nil; try validate() }
        let factory = factory, scope = scope, policy = policy
        let pending = Task { try await factory.open(scope, policy) }; opening = pending
        defer { opening = nil }
        let candidate = try await withTaskCancellationHandler { try await pending.value } onCancel: { pending.cancel() }
        do { try validate() } catch { candidate.stop(); await candidate.drain(); throw error }
        connection = candidate; return candidate
    }
    private func retire(_ id: UUID) {
        guard let current = connection, current.id == id else { return }
        current.stop(); connection = nil
        retiring = Task { await current.drain() }
    }
    private func acquire() async throws {
        try validate()
        if !busy { busy = true; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in waiters.append(.init(id: id, continuation: continuation)) }
        } onCancel: { Task { @MainActor [weak self] in self?.cancelWaiter(id) } }
        do { try validate() } catch { release(); throw error }
    }
    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
    private func release() {
        if !waiters.isEmpty, !stopped { waiters.removeFirst().continuation.resume() }
        else { busy = false }
    }
}
