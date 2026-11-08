import CryptoKit
import Foundation
import RelayJournal

/// Bounded freshness IO for already selected files. One physical worker remains
/// owned until its synchronous kernel work finishes, even after its waiter has
/// been cancelled or timed out. This object grants no source/action authority.
@MainActor final class SelectedFileProofWorker {
    static let shared = SelectedFileProofWorker()

    nonisolated struct Proof: Sendable {
        let input: String
        let canonicalPath: String
        let reference: JournalArtifactReference
        let contentDigest: Data
        let id: Data
    }
    nonisolated enum Failure: LocalizedError, Equatable {
        case busy, timedOut, unsafeSource
        var errorDescription: String? {
            switch self {
            case .busy: "A selected-file freshness read is still settling. No additional read was queued."
            case .timedOut: "The selected-file freshness check timed out. Its late result will not be used."
            case .unsafeSource: "The selected file or its authorized scope changed. Its freshness proof is unavailable."
            }
        }
    }
    private nonisolated enum Resolution: Sendable {
        case value(Proof), failed(Failure), cancelled
    }
    /// Only synchronized ownership and continuation state live here. Filesystem
    /// work, callbacks, cancellation and continuation resumption run unlocked.
    private nonisolated final class Delivery: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Resolution?
        private var continuation: CheckedContinuation<Proof, any Error>?
        var isPending: Bool { lock.withLock { result == nil } }
        func install(_ continuation: CheckedContinuation<Proof, any Error>) {
            let completed: Resolution? = lock.withLock {
                if let result { return result }
                self.continuation = continuation
                return nil
            }
            if let completed { Self.resume(continuation, with: completed) }
        }
        @discardableResult func complete(_ result: Resolution) -> Bool {
            let delivery: (Bool, CheckedContinuation<Proof, any Error>?) = lock.withLock {
                guard self.result == nil else { return (false, nil) }
                self.result = result
                let continuation = self.continuation
                self.continuation = nil
                return (true, continuation)
            }
            if let continuation = delivery.1 { Self.resume(continuation, with: result) }
            return delivery.0
        }
        private static func resume(_ continuation: CheckedContinuation<Proof, any Error>, with result: Resolution) {
            switch result {
            case .value(let proof): continuation.resume(returning: proof)
            case .failed(let error): continuation.resume(throwing: error)
            case .cancelled: continuation.resume(throwing: CancellationError())
            }
        }
    }
    #if DEBUG
    /// The hook can delay only real IO that already returned. It cannot replace
    /// file bytes, metadata, a digest or a proof. It is never present in Release.
    private nonisolated final class ReadHook: @unchecked Sendable {
        private let lock = NSLock()
        private var callback: (@Sendable () -> Void)?
        func set(_ callback: @escaping @Sendable () -> Void) { lock.withLock { self.callback = callback } }
        func take() -> (@Sendable () -> Void)? {
            lock.withLock { let value = callback; callback = nil; return value }
        }
    }
    private let readHook = ReadHook()
    func pauseAfterNextRead(_ callback: @escaping @Sendable () -> Void) { readHook.set(callback) }
    #endif

    private struct Active {
        let id: UUID
        let task: Task<Void, Never>
        let expiry: Task<Void, Never>
    }
    private let timeout: Duration
    private var active: Active?
    var activeCount: Int { active == nil ? 0 : 1 }

    init(timeout: Duration = .seconds(2)) {
        self.timeout = min(.seconds(5), max(.milliseconds(1), timeout))
    }

    func capture(input: String, grants: [ScopeGrant]) async throws -> Proof {
        try await perform(input: input, expected: nil, grants: grants)
    }
    func validate(_ proof: Proof, grants: [ScopeGrant]) async throws {
        _ = try await perform(input: proof.input, expected: proof, grants: grants)
    }
    func drain() async {
        // No second queue/task is created. Cancellation of this waiter cannot
        // release the physical worker's slot or close its in-flight descriptor.
        if let task = active?.task { await task.value }
    }

    private func perform(input: String, expected: Proof?, grants: [ScopeGrant]) async throws -> Proof {
        try Task.checkCancellation()
        guard active == nil else { throw Failure.busy }
        let id = UUID(), delivery = Delivery()
        let deadline = ContinuousClock.now.advanced(by: timeout)
        #if DEBUG
        let afterRead: @Sendable () -> Void = { [readHook] in readHook.take()?() }
        #else
        let afterRead: @Sendable () -> Void = {}
        #endif
        let physical = Task { [weak self] in
            let result = await Self.kernel(input: input, expected: expected, grants: grants,
                deadline: deadline, delivery: delivery, afterRead: afterRead)
            delivery.complete(result)
            // This is reached only after LocalStateFile's own defer closed its
            // descriptor and the entire physical kernel/hook returned.
            self?.physicalFinished(id)
        }
        let expiry = Task {
            do { try await Task.sleep(until: deadline, clock: .continuous) }
            catch { return }
            if delivery.complete(.failed(.timedOut)) { physical.cancel() }
        }
        active = Active(id: id, task: physical, expiry: expiry)
        return try await withTaskCancellationHandler {
            let proof = try await withCheckedThrowingContinuation { continuation in delivery.install(continuation) }
            try Task.checkCancellation()
            // A positive kernel result may wait for this actor while the
            // expiry task is also queued. Admission keeps the original deadline.
            guard ContinuousClock.now < deadline else { throw Failure.timedOut }
            return proof
        } onCancel: {
            delivery.complete(.cancelled)
            physical.cancel()
            expiry.cancel()
        }
    }
    private func physicalFinished(_ id: UUID) {
        guard let active, active.id == id else { return }
        active.expiry.cancel()
        self.active = nil
    }

    /// All canonicalization, metadata, selected-grant filesystem checks, reads
    /// and hashing run on the concurrent executor. No private bytes return to UI.
    @concurrent private static func kernel(input: String, expected: Proof?, grants: [ScopeGrant],
                                          deadline: ContinuousClock.Instant, delivery: Delivery,
                                          afterRead: @escaping @Sendable () -> Void) async -> Resolution {
        func check() throws {
            try Task.checkCancellation()
            guard delivery.isPending else { throw CancellationError() }
            guard ContinuousClock.now < deadline else { throw Failure.timedOut }
        }
        do {
            try check()
            let canonical = try ToolPolicy.scopedURL(input, grants: grants)
            try check()
            let canonicalPath = canonical.path
            let authorized: (String) throws -> Bool = { path in
                try check()
                let allowed = try ToolPolicy.scopedURL(path, grants: grants)
                try check()
                return allowed.path.utf8.elementsEqual(canonicalPath.utf8)
            }
            if let expected {
                guard canonicalPath.utf8.elementsEqual(expected.canonicalPath.utf8) else { throw Failure.unsafeSource }
                try JournalArtifactAccess.validate(expected.reference, isAuthorized: authorized)
                try check()
            }
            let reference = try JournalArtifactAccess.capture(visiblePath: canonicalPath, isAuthorized: authorized)
            try check()
            let data = try LocalStateFile.read(canonical, maximumBytes: 1_048_576)
            // LocalStateFile owns its descriptor until its synchronous return.
            // Cancellation/timeout never calls close from another task.
            afterRead()
            try check()
            let digest = Data(SHA256.hash(data: data))
            try check()
            try JournalArtifactAccess.validate(reference, isAuthorized: authorized)
            try check()
            guard try ToolPolicy.scopedURL(input, grants: grants).path.utf8.elementsEqual(canonicalPath.utf8),
                  let identity = reference.identityDigest else { throw Failure.unsafeSource }
            try check()
            var identityInput = Data("relay.selected-file-proof.v1".utf8)
            for field in [Data(canonicalPath.utf8), identity, digest] {
                var length = UInt64(field.count).bigEndian
                withUnsafeBytes(of: &length) { identityInput.append(contentsOf: $0) }
                identityInput.append(field)
            }
            let proof = Proof(input: input, canonicalPath: canonicalPath, reference: reference,
                contentDigest: digest, id: Data(SHA256.hash(data: identityInput)))
            if let expected {
                guard proof.id == expected.id, proof.contentDigest == expected.contentDigest,
                      proof.reference.identityDigest == expected.reference.identityDigest,
                      proof.reference.visiblePath.utf8.elementsEqual(expected.reference.visiblePath.utf8),
                      proof.reference.canonicalPath.map({ Data($0.utf8) }) == expected.reference.canonicalPath.map({ Data($0.utf8) }) else {
                    throw Failure.unsafeSource
                }
            }
            try check()
            return .value(proof)
        } catch is CancellationError { return .cancelled }
        catch let failure as Failure { return .failed(failure) }
        catch { return .failed(.unsafeSource) }
    }
}
