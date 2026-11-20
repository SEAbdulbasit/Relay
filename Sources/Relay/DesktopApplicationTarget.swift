import AppKit
import PolicyMetadataProcess
import Foundation

/// Stable process identity. A PID alone can be reused after an app exits.
nonisolated struct DesktopApplicationIdentity: Equatable, Sendable {
    let processID: pid_t
    let launchedAt: Date
    let bundleID: String
    let bundleURL: URL
}

@MainActor
enum DesktopApplicationTarget {
    static func identity(of application: NSRunningApplication) -> DesktopApplicationIdentity? {
        guard !application.isTerminated, application.processIdentifier > 0,
              let launchedAt = application.launchDate, launchedAt.timeIntervalSince1970.isFinite,
              let bundleID = application.bundleIdentifier, !bundleID.isEmpty,
              let bundleURL = application.bundleURL, bundleURL.isFileURL else { return nil }
        return DesktopApplicationIdentity(processID: application.processIdentifier, launchedAt: launchedAt,
            bundleID: bundleID, bundleURL: bundleURL.resolvingSymlinksInPath().standardizedFileURL)
    }

    static func select(_ applications: [NSRunningApplication], foreground: pid_t?) -> NSRunningApplication? {
        guard !applications.isEmpty, Set(applications.map(\.processIdentifier)).count == applications.count else { return nil }
        if applications.count == 1 {
            guard let application = applications.first, identity(of: application) != nil else { return nil }
            return application
        }
        guard let foreground, let application = applications.first(where: { $0.processIdentifier == foreground }),
              let selected = identity(of: application),
              applications.allSatisfy({ other in
                  guard other.bundleIdentifier == selected.bundleID else { return false }
                  // macOS can omit the launch date or bundle URL for an unrelated
                  // process. It is never selected or controlled. Known conflicting
                  // application copies still refuse; the foreground identity must
                  // always be complete before any observation or mutation.
                  return other.bundleURL.map { $0.resolvingSymlinksInPath().standardizedFileURL == selected.bundleURL } ?? true
              }) else { return nil }
        guard select(applications.compactMap { identity(of: $0) }, foreground: foreground) == selected else { return nil }
        return application
    }

    nonisolated static func select(_ candidates: [DesktopApplicationIdentity], foreground: pid_t?) -> DesktopApplicationIdentity? {
        guard let first = candidates.first,
              Set(candidates.map(\.processID)).count == candidates.count else { return nil }
        if candidates.count == 1 { return first }
        // A display-name collision between different applications is not a profile.
        guard candidates.allSatisfy({ $0.bundleID == first.bundleID && $0.bundleURL == first.bundleURL }),
              let foreground else { return nil }
        return candidates.first { $0.processID == foreground }
    }

    static func matches(_ identity: DesktopApplicationIdentity, application: NSRunningApplication) -> Bool {
        Self.identity(of: application) == identity
    }
}


// A metadata phase can compare actual live process properties without resolving
// the same bundle URL on every technical AX query. This is not a source,
// privacy, capture, action or input capability; full matches remain mandatory.
extension DesktopApplicationTarget {
    nonisolated enum MetadataProcessFailure: Error, Equatable { case changed, expired }

    /// Exact raw facts used by the actual producer. Constructing comparison
    /// data cannot create a MetadataProcessBinding or its private-init lease.
    nonisolated struct MetadataProcessFacts: Equatable {
        let processID: pid_t
        let launchedAt: Date
        let bundleIDUTF8: Data
        let rawBundleURLUTF8: Data
        let isFileURL: Bool
        let terminated: Bool
        var isUsable: Bool {
            processID > 0 && launchedAt.timeIntervalSince1970.isFinite
                && !bundleIDUTF8.isEmpty && !rawBundleURLUTF8.isEmpty
                && isFileURL && !terminated
        }
    }
    /// Pure comparison/lifetime state shared by the actual lease and tests.
    /// It has no process object, validator, permission or successful verdict.
    nonisolated struct MetadataProcessState {
        private var active = true
        mutating func retire() { active = false }
        func requireActive() throws { guard active else { throw MetadataProcessFailure.expired } }
        func validateKernel(expected: UInt64, observed: UInt64?) throws {
            try requireActive()
            guard expected > 0, observed == expected else { throw MetadataProcessFailure.changed }
        }
        func validate(expected: MetadataProcessFacts, retained: MetadataProcessFacts?,
                      secondRead: MetadataProcessFacts?) throws {
            try requireActive()
            guard expected.isUsable, retained?.isUsable == true, secondRead?.isUsable == true,
                  retained == expected, secondRead == expected else { throw MetadataProcessFailure.changed }
        }
    }
    /// Comparison data only. It cannot construct a process binding or witness.
    nonisolated struct MetadataQueryKey {
        let object: ObjectIdentifier
        let identity: DesktopApplicationIdentity
        let facts: MetadataProcessFacts
        let kernelStart: UInt64
        func requireSame(as other: Self) throws {
            guard object == other.object, identity == other.identity,
                  facts.isUsable, other.facts.isUsable, facts == other.facts,
                  kernelStart > 0, kernelStart == other.kernelStart else {
                throw MetadataProcessFailure.changed
            }
        }
    }
    /// Shared orchestration has no process, source or permission constructor.
    /// A nested attempt poisons the actual outer query even if its caller catches.
    final class MetadataQueryScope {
        enum Failure: Error, Equatable { case expired, reentrant }
        final class Lifetime {
            private var active = true
            fileprivate var refusal: (any Error)?
            fileprivate init() {}
            func check() throws {
                guard active else { throw Failure.expired }
                if let refusal { throw refusal }
            }
            func validate(_ validation: () throws -> Void) throws {
                do { try check(); try validation(); try check() }
                catch { refuse(error); throw error }
            }
            fileprivate func refuse(_ error: any Error) { if refusal == nil { refusal = error } }
            fileprivate func retire() { active = false }
        }
        private var current: Lifetime?
        private var refusal: (any Error)?
        func run<Value>(before: () throws -> Void, after: () throws -> Void,
                        body: (Lifetime) throws -> Value) throws -> Value {
            if let refusal { throw refusal }
            if let current {
                let error = Failure.reentrant
                current.refuse(error)
                refusal = error
                throw error
            }
            let lifetime = Lifetime()
            current = lifetime
            defer {
                if let error = lifetime.refusal { refusal = error }
                lifetime.retire(); current = nil
            }
            try before()
            try lifetime.check()
            let result = Result { try body(lifetime) }
            // A fresh process refusal retains the existing strong-exit priority.
            // It runs even on a throwing body, before inspecting a poisoned lease.
            try after()
            try lifetime.check()
            return try result.get()
        }
    }
    private static func kernelStart(of pid: pid_t) -> UInt64? {
        var value: UInt64 = 0
        guard relay_policy_process_start(pid, &value) == 0, value > 0 else { return nil }
        return value
    }
    private static func metadataFacts(of application: NSRunningApplication) -> MetadataProcessFacts? {
        guard let launchedAt = application.launchDate, let bundleID = application.bundleIdentifier,
              let bundleURL = application.bundleURL else { return nil }
        return MetadataProcessFacts(processID: application.processIdentifier, launchedAt: launchedAt,
            bundleIDUTF8: Data(bundleID.utf8), rawBundleURLUTF8: Data(bundleURL.absoluteString.utf8),
            isFileURL: bundleURL.isFileURL, terminated: application.isTerminated)
    }
    /// Only this actual process factory constructs a binding. No arbitrary
    /// caller validator or raw comparison facts can supply its authority.
    final class MetadataProcessBinding {
        private let identity: DesktopApplicationIdentity
        private let application: NSRunningApplication
        private let original: MetadataProcessFacts
        private let kernelStart: UInt64
        private init(identity: DesktopApplicationIdentity, application: NSRunningApplication,
                     original: MetadataProcessFacts, kernelStart: UInt64) {
            self.identity = identity; self.application = application; self.original = original; self.kernelStart = kernelStart
        }
        static func bind(identity: DesktopApplicationIdentity,
                         application: NSRunningApplication) throws -> MetadataProcessBinding {
            try Task.checkCancellation()
            guard let kernelBefore = DesktopApplicationTarget.kernelStart(of: identity.processID),
                  DesktopApplicationTarget.matches(identity, application: application),
                  let original = DesktopApplicationTarget.metadataFacts(of: application), original.isUsable,
                  original.processID == identity.processID, original.launchedAt == identity.launchedAt,
                  original.bundleIDUTF8 == Data(identity.bundleID.utf8),
                  DesktopApplicationTarget.kernelStart(of: identity.processID) == kernelBefore else { throw MetadataProcessFailure.changed }
            return MetadataProcessBinding(identity: identity, application: application, original: original, kernelStart: kernelBefore)
        }
        /// No async body. A live kernel-start check of the exact PID brackets fresh
        /// retained-object raw facts on every query. Canonical bundle
        /// matching still runs on both exits, including a throwing body.
        func withLease<Value>(_ body: @MainActor (MetadataProcessLease) throws -> Value) throws -> Value {
            try MetadataProcessLease.run(identity: identity, application: application, original: original, kernelStart: kernelStart, body: body)
        }
    }
    final class MetadataProcessLease {
        private let identity: DesktopApplicationIdentity
        private let application: NSRunningApplication
        private let original: MetadataProcessFacts
        private let kernelStart: UInt64
        private var state = MetadataProcessState()
        private let queryScope = MetadataQueryScope()
        private init(identity: DesktopApplicationIdentity, application: NSRunningApplication,
                     original: MetadataProcessFacts, kernelStart: UInt64) {
            self.identity = identity; self.application = application; self.original = original; self.kernelStart = kernelStart
        }
        fileprivate static func run<Value>(identity: DesktopApplicationIdentity, application: NSRunningApplication,
            original: MetadataProcessFacts, kernelStart: UInt64, body: @MainActor (MetadataProcessLease) throws -> Value) throws -> Value {
            let lease = MetadataProcessLease(identity: identity, application: application, original: original, kernelStart: kernelStart)
            defer { lease.state.retire() }
            try lease.validateStrong()
            let result = Result { try body(lease) }
            // Current process identity overrides a stale body's error, just as
            // the original metadata phase's strong exit already does.
            try lease.validateStrong()
            return try result.get()
        }
        func check() throws {
            try state.requireActive(); try Task.checkCancellation()
            // Kernel lifetime brackets two newly read property samples from
            // the actual retained object. No replacement NSRunningApplication
            // lookup or caller-supplied successful process verdict is reused.
            try state.validateKernel(expected: kernelStart, observed: DesktopApplicationTarget.kernelStart(of: identity.processID))
            let first = DesktopApplicationTarget.metadataFacts(of: application)
            let second = DesktopApplicationTarget.metadataFacts(of: application)
            try state.validate(expected: original, retained: first, secondRead: second)
            try state.validateKernel(expected: kernelStart, observed: DesktopApplicationTarget.kernelStart(of: identity.processID))
            try Task.checkCancellation(); try state.requireActive()
        }
        /// Minted only inside one actual producer aggregate callback. It is not
        /// usable during a later AX operation, phase, private read or await.
        final class QueryWitness {
            private weak var issuer: MetadataProcessLease?
            private let lifetime: MetadataQueryScope.Lifetime
            private weak var savedOwner: AssistantStore.ExactUnsentSavedInvocation?
            private var savedOwnerBound = false
            fileprivate init(issuer: MetadataProcessLease, lifetime: MetadataQueryScope.Lifetime) {
                self.issuer = issuer; self.lifetime = lifetime
            }
            fileprivate func validate(_ receiver: MetadataProcessLease) throws {
                try lifetime.validate {
                    try Task.checkCancellation()
                    guard let issuer else { throw MetadataProcessFailure.expired }
                    try issuer.state.requireActive(); try receiver.state.requireActive()
                    try receiver.queryKey.requireSame(as: issuer.queryKey)
                }
            }
            /// Denial-only association with the actual returned-record owner.
            /// The witness factory and the owner's initializer remain sealed.
            /// A second binding (including after weak-owner loss) poisons this
            /// aggregate rather than opening another saved-owner bracket.
            func bindSavedOwner(_ owner: AssistantStore.ExactUnsentSavedInvocation) throws {
                try lifetime.validate {
                    try Task.checkCancellation()
                    guard let issuer else { throw MetadataProcessFailure.expired }
                    try issuer.state.requireActive()
                    guard !savedOwnerBound else { throw MetadataQueryScope.Failure.reentrant }
                    savedOwnerBound = true; savedOwner = owner
                }
            }
            func validateSavedOwner(_ owner: AssistantStore.ExactUnsentSavedInvocation) throws {
                try lifetime.validate {
                    try Task.checkCancellation()
                    guard let issuer else { throw MetadataProcessFailure.expired }
                    try issuer.state.requireActive()
                    guard savedOwnerBound, savedOwner === owner else { throw MetadataProcessFailure.changed }
                }
            }
        }
        private var queryKey: MetadataQueryKey {
            .init(object: ObjectIdentifier(application), identity: identity, facts: original, kernelStart: kernelStart)
        }
        func check(currentQuery: QueryWitness?) throws {
            if let currentQuery { try currentQuery.validate(self) }
            else { try check() }
        }
        func withCurrentQuery<Value>(readAudit: NativeReadAudit?,
                                     _ body: (QueryWitness) throws -> Value) throws -> Value {
            try queryScope.run(before: {
                try NativeReadAudit.measure(readAudit, .policyMetadataQueryProcessProof) { try self.check() }
            }, after: {
                try NativeReadAudit.measure(readAudit, .policyMetadataQueryProcessProof) { try self.check() }
            }, body: { lifetime in
                try body(QueryWitness(issuer: self, lifetime: lifetime))
            })
        }
        private func validateStrong() throws {
            try check()
            guard DesktopApplicationTarget.matches(identity, application: application) else {
                throw MetadataProcessFailure.changed
            }
            try check()
        }
    }
}
