import AppKit
import Foundation

extension NativeWindowTaskAdapter.Backend {
    /// Lazy task-owned model-free native handshake. A stopped/steered opening
    /// connection is closed before it can publish a backend to the replacement.
    @MainActor static func openReadOnly(ownership: NativeWindowTaskAdapter.Ownership) async throws -> Self {
        try Task.checkCancellation()
        guard ownership.isCurrent() else { throw NativeWindowTaskAdapter.Failure.inactiveTask }
        let client: OwnedNativeComputerUseClient
        do { client = try await OwnedNativeComputerUseClient.open(runtime: .discover()) }
        catch let failure as OwnedNativeComputerUseClient.Failure { throw NativeReadTransportError(failure) }
        do {
            try Task.checkCancellation()
            guard ownership.isCurrent() else { throw NativeWindowTaskAdapter.Failure.inactiveTask }
            let observer = TargetBoundNativeObservation(client: client, sessionIsActive: ownership.isCurrent)
            return readOnly(observer: observer)
        } catch { await client.close(); throw error }
    }

    /// First-promotion backend uses only the already-qualified active observer.
    /// It can make the invocation's initial read. It cannot fabricate an
    /// original-window refresh capability that the active observer lacks.
    @MainActor static func readOnly(observer: TargetBoundNativeObservation) -> Self {
        Self(initial: { admission in
            try admission.validate()
            guard let app = NSRunningApplication(processIdentifier: admission.application.processID),
                  DesktopApplicationTarget.matches(admission.application, application: app) else {
                throw NativeWindowTaskAdapter.Failure.unadmittedApplication
            }
            let snapshot = try await observer.observe(observer.prepare(application: app))
            try admission.validate()
            return NativeWindowTaskAdapter.Capture(snapshot: snapshot,
                isCurrent: { observer.isCurrent(snapshot) }, refreshOriginal: nil)
        }, stop: { observer.stop() }, drain: { await observer.drain() })
    }
}
