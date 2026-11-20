/// Synchronous diagnostic ordering only. No Process/runtime constructor,
/// environment, storage, cancellation policy, transport, task or input grant.
/// The production caller supplies its actual Process.run operation; pure tests
/// supply inert operations and synthetic metadata without launching anything.
/// Receipt failure may deny startup; the existing owner remains responsible
/// for real cleanup. A diagnostic observer supplies no executable authority.
nonisolated enum OwnedNativeProcessStartDelivery {
    static func perform<Payload: Sendable>(observer: (@Sendable (Payload) throws -> Void)?,
        launch: () throws -> Void, didLaunch: () -> Void, payload: () -> Payload) throws {
        try launch()
        didLaunch()
        guard let observer else { return }
        try observer(payload())
    }
}
