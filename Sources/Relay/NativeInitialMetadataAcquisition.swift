import Foundation

/// Data-only comparison used by the actual survey. Digest equality never
/// substitutes for the ordered retained-object and direct-child comparisons.
nonisolated enum NativeOrderedMetadataComparison {
    @MainActor static func matches<Row, Node>(firstDigest: Data, secondDigest: Data,
        firstRows: [Row], secondRows: [Row], node: @MainActor (Row) -> Node,
        children: @MainActor (Row) -> [Node], identical: @MainActor (Node, Node) -> Bool) -> Bool {
        guard firstDigest == secondDigest, firstRows.count == secondRows.count else { return false }
        return zip(firstRows, secondRows).allSatisfy { first, second in
            guard identical(node(first), node(second)) else { return false }
            let left = children(first), right = children(second)
            return left.count == right.count
                && zip(left, right).allSatisfy { identical($0, $1) }
        }
    }
}

/// One automatic metadata acquisition, before that source's first control
/// disclosure. Exceptions are never comparison outcomes and are not retried.
@MainActor final class NativeInitialMetadataAcquisition {
    enum CompletedComparison { case equal, mismatch }
    enum Failure: Error, Equatable { case alreadyUsed, unstable }
    private enum State: Equatable { case unused, acquiring, spent }
    private var state = State.unused
    private(set) var captureCount = 0
    var hasStarted: Bool { state != .unused }
    fileprivate func seal() { state = .spent }

    func acquire<Snapshot>(validate: @MainActor () throws -> Void, capture: @MainActor () throws -> Snapshot,
                           compare: @MainActor (Snapshot, Snapshot) throws -> CompletedComparison) throws -> Snapshot {
        guard state == .unused else { throw Failure.alreadyUsed }
        state = .acquiring
        defer { state = .spent }
        try validate()
        captureCount += 1
        var previous = try capture()
        try validate()
        for _ in 2...3 {
            try validate()
            captureCount += 1
            let current = try capture()
            try validate()
            let comparison = try compare(previous, current)
            try validate()
            if case .equal = comparison { return current }
            previous = current
        }
        throw Failure.unstable
    }
}

/// One task-owned registry keyed by actual original-window comparison. A new
/// source wrapper/UUID for that same retained window cannot remint a loop.
/// It retains no survey, labels, image, field preview or input permission.
@MainActor final class NativeInitialMetadataOwners<Source> {
    private final class Entry {
        let source: Source
        let sourceID: UUID
        let acquisition = NativeInitialMetadataAcquisition()
        init(source: Source, sourceID: UUID) { self.source = source; self.sourceID = sourceID }
    }
    private let owner: AnyObject
    private var entries: [Entry] = []
    private var aliases: [UUID: Entry] = [:]
    private var revoked = false, inspecting = false
    init(owner: AnyObject) { self.owner = owner }
    func revoke() { revoked = true; aliases.removeAll(); entries.removeAll() }

    func withSource<Value>(_ source: Source, sourceID: UUID, owner: AnyObject,
        sameOriginalWindow: @MainActor (Source, Source) -> Bool, validate: @escaping @MainActor () throws -> Void,
        initial: @MainActor (NativeInitialMetadataAcquisition, @escaping @MainActor () throws -> Void) throws -> Value,
        strict: @MainActor () throws -> Value) throws -> Value {
        try requireOwner(owner)
        guard !inspecting else { throw NativeInitialMetadataAcquisition.Failure.alreadyUsed }
        inspecting = true
        defer { inspecting = false }
        let entry: Entry
        if let bound = aliases[sourceID] {
            guard sameOriginalWindow(bound.source, source) else { throw NativeVisualTaskFailure.staleProposal }
            entry = bound
        }
        else if let existing = entries.first(where: { sameOriginalWindow($0.source, source) }) { entry = existing }
        else {
            entry = Entry(source: source, sourceID: sourceID)
            entries.append(entry)
        }
        // Bind every observed wrapper ID before caller validation. Failure
        // cannot free an alias for a different process/window or remint a loop.
        aliases[sourceID] = entry
        let check: @MainActor () throws -> Void = { [self] in
            try requireOwner(owner); try validate(); try requireOwner(owner)
        }
        if entry.acquisition.hasStarted || entry.sourceID != sourceID {
            try check()
            let value = try strict()
            try check()
            return value
        }
        // Even a validation/caller failure ends this automatic opportunity.
        // A retained post-capture or error callback is strict from then on.
        defer { entry.acquisition.seal() }
        try check()
        let value = try initial(entry.acquisition, check)
        try check()
        return value
    }

    private func requireOwner(_ candidate: AnyObject) throws {
        guard !revoked else { throw NativeVisualTaskFailure.stopped }
        guard owner === candidate else { throw NativeVisualTaskFailure.staleTask }
    }
}
