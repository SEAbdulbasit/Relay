import AppKit
import Foundation

/// The application owns tasks even when its last workspace view is removed.
/// Termination remains an explicit cancellation boundary independent of windows.
@MainActor final class AssistantApplicationLifetime {
    private let center: NotificationCenter
    private let token: NSObjectProtocol

    init(center: NotificationCenter = .default, onTermination: @escaping @MainActor () -> Void) {
        self.center = center
        token = center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { onTermination() }
        }
    }

    isolated deinit { center.removeObserver(token) }
}
