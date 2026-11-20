import Foundation

/// Parent navigation stays deferred until the mounted note reader resolves edits.
/// Ownership prevents a retiring reader from clearing a newer reader's handler.
@MainActor
final class KnowledgeNavigationGuard {
    typealias Action = @MainActor () -> Void
    private var owner: UUID?
    private var handler: ((@escaping Action) -> Void)?

    func install(owner: UUID, handler: @escaping (@escaping Action) -> Void) {
        self.owner = owner
        self.handler = handler
    }

    func remove(owner: UUID) {
        guard self.owner == owner else { return }
        self.owner = nil
        handler = nil
    }

    func request(_ action: @escaping Action) {
        if let handler { handler(action) } else { action() }
    }
}

/// Shared by actual reader actions and parent departures. A failed save or a
/// cancellation never releases the deferred action or silently discards edits.
@MainActor
struct KnowledgeUnsavedChangesGuard<Action> {
    enum Decision { case save, discard, cancel }
    private(set) var pendingAction: Action?

    mutating func request(_ action: Action, hasUnsavedChanges: Bool) -> Action? {
        pendingAction = hasUnsavedChanges ? action : nil
        return hasUnsavedChanges ? nil : action
    }

    mutating func resolve(_ decision: Decision, save: () -> Bool = { true }) -> Action? {
        guard let action = pendingAction else { return nil }
        pendingAction = nil
        switch decision {
        case .save: return save() ? action : nil
        case .discard: return action
        case .cancel: return nil
        }
    }
}
