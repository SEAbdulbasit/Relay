import ApplicationServices
import Foundation

/// Pure decision logic used by the AX adapter. A refreshed list never replaces
/// the retained original identity or grants input/source/review authority.
@MainActor
enum NativeWindowEnumeration {
    nonisolated enum Attribute: Sendable, Equatable { case windows, title }
    nonisolated struct ReadFailure: Error {
        let attribute: Attribute
        let status: AXError
    }
    nonisolated enum Failure: Error, Equatable { case unavailableWindow, wrongWindow, changedEnumeration }
    nonisolated enum Resolution: Sendable, Equatable { case firstScan, refreshedSameIdentities, retiredInvalidSibling }
    struct Backend<Handle> {
        let enumerate: () throws -> [Handle]
        let title: (Handle) throws -> String
        let same: (Handle, Handle) -> Bool
        /// Positive process, original AX object, full metadata and browser proof.
        let validateOriginal: () throws -> Void
        /// Owning task/source/Stop/deadline/cancellation fence, never a new budget.
        let requireCurrent: () throws -> Void
    }
    private enum Scan<Handle> {
        case complete
        case invalidSibling(members: [Handle], index: Int)
    }

    @discardableResult
    static func validate<Handle>(original: Handle, title: String, allowSiblingRecovery: Bool,
                                 backend: Backend<Handle>) throws -> Resolution {
        try backend.requireCurrent()
        try backend.validateOriginal()
        let members = try enumerate(original: original, backend: backend)
        switch try scan(members, original: original, expectedTitle: title,
                        allowInvalidSibling: allowSiblingRecovery, backend: backend) {
        case .complete:
            try backend.requireCurrent(); try backend.validateOriginal(); try backend.requireCurrent()
            return .firstScan
        case .invalidSibling(let previous, let failedIndex):
            // Exactly one bounded complete re-enumeration. Never retry an invalid
            // original, drop an unreadable final sibling, or accept new identities.
            try backend.requireCurrent(); try backend.validateOriginal(); try backend.requireCurrent()
            let fresh = try enumerate(original: original, backend: backend)
            let disappeared = try validateRefresh(previous: previous, failedIndex: failedIndex,
                                                   fresh: fresh, same: backend.same)
            _ = try scan(fresh, original: original, expectedTitle: title,
                         allowInvalidSibling: false, backend: backend)
            try backend.requireCurrent(); try backend.validateOriginal(); try backend.requireCurrent()
            return disappeared ? .retiredInvalidSibling : .refreshedSameIdentities
        }
    }

    private static func enumerate<Handle>(original: Handle, backend: Backend<Handle>) throws -> [Handle] {
        try backend.requireCurrent()
        let members = try backend.enumerate()
        try backend.requireCurrent()
        guard !members.isEmpty, members.count <= 64 else { throw Failure.unavailableWindow }
        for index in members.indices {
            if members[..<index].contains(where: { backend.same($0, members[index]) }) { throw Failure.wrongWindow }
        }
        guard members.filter({ backend.same($0, original) }).count == 1 else { throw Failure.wrongWindow }
        return members
    }

    private static func scan<Handle>(_ members: [Handle], original: Handle, expectedTitle: String,
                                      allowInvalidSibling: Bool, backend: Backend<Handle>) throws -> Scan<Handle> {
        var matching: [Handle] = []
        for (index, member) in members.enumerated() {
            try backend.requireCurrent()
            let isOriginal = backend.same(member, original)
            let title: String
            do { title = try backend.title(member) }
            catch {
                try backend.requireCurrent()
                if allowInvalidSibling, !isOriginal, let failure = error as? ReadFailure,
                   failure.attribute == .title, failure.status == .invalidUIElement {
                    return .invalidSibling(members: members, index: index)
                }
                throw error
            }
            try backend.requireCurrent()
            if expectedTitle.utf16.elementsEqual(title.utf16) {
                matching.append(member)
                guard matching.count <= 1 else { throw Failure.wrongWindow }
            }
        }
        guard matching.count == 1, let member = matching.first, backend.same(member, original) else { throw Failure.wrongWindow }
        return .complete
    }

    private static func validateRefresh<Handle>(previous: [Handle], failedIndex: Int,
                                                fresh: [Handle], same: (Handle, Handle) -> Bool) throws -> Bool {
        guard fresh.allSatisfy({ member in previous.contains { same($0, member) } }) else { throw Failure.changedEnumeration }
        for index in previous.indices where index != failedIndex {
            guard fresh.contains(where: { same($0, previous[index]) }) else { throw Failure.changedEnumeration }
        }
        let disappeared = !fresh.contains { same($0, previous[failedIndex]) }
        guard fresh.count == previous.count - (disappeared ? 1 : 0) else { throw Failure.changedEnumeration }
        return disappeared
    }
}
