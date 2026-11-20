import ApplicationServices
import Foundation

/// Relational metadata only. No Codable capability, source grant, private read,
/// input permission or path survives this synchronous check. Production passes
/// actual retained references through Reader; pure graphs do not mint AX proof.
nonisolated enum NativeWindowParentMembership {
    enum Use: Sendable { case surveyRow, terminalChildren }
    enum Basis: Sendable, Equatable { case windowShortcut, currentParentChain }
    enum Failure: Error, Sendable, Equatable {
        case invalidShortcut, differentWindow, cycle, nodeBound, childBound
        case missingChild, duplicateChild, changedParent, changedRole, invalidWindowRole, unexpectedRoot
    }
    enum Shortcut<Node> { case reported(Node), missingValue, rejected }
    struct Access<Node> {
        let originalWindow: Node
        let identical: @MainActor (Node, Node) -> Bool
        let validate: @MainActor () throws -> Void
        /// Each actual Reader query also checks the exact original PID.
        let liveRole: @MainActor (Node) throws -> String
        let parent: @MainActor (Node) throws -> Node
        let directChildren: @MainActor (Node) throws -> [Node]
    }
    private struct Edge<Node> {
        let child: Node, parent: Node
        let childRole: String, parentRole: String
    }
    static let maximumNodes = 20
    static let maximumChildren = 512

    /// The actual Reader supplies the CF type-checked element, if present.
    /// Only noValue WITH nil permits the alternate proof. Even a contradictory
    /// success or unsupported value cannot be repaired by a matching graph.
    static func shortcut<Node>(status: AXError, valuePresent: Bool, element: Node?) -> Shortcut<Node> {
        if status == .success, valuePresent, let element { return .reported(element) }
        if status == .noValue, !valuePresent, case .none = element { return .missingValue }
        return .rejected
    }

    @MainActor static func require<Node>(_ node: Node, shortcut: Shortcut<Node>, expectedRole: String,
                                        access: Access<Node>) throws -> Basis {
        try access.validate()
        switch shortcut {
        case .reported(let window):
            guard access.identical(window, access.originalWindow) else { throw Failure.differentWindow }
            try access.validate()
            return .windowShortcut
        case .rejected: throw Failure.invalidShortcut
        case .missingValue: break
        }

        var current = node, expected = expectedRole
        var visited: [Node] = [], edges: [Edge<Node>] = []
        for _ in 0..<maximumNodes {
            try access.validate()
            guard !visited.contains(where: { access.identical($0, current) }) else { throw Failure.cycle }
            let role = try access.liveRole(current)
            guard role.utf8.elementsEqual(expected.utf8) else { throw Failure.changedRole }
            visited.append(current)
            if access.identical(current, access.originalWindow) {
                guard role == "AXWindow" else { throw Failure.invalidWindowRole }
                // No cached relationship from capture or an earlier phase is
                // reused. Every locally observed edge is checked again now.
                for edge in edges.reversed() { try verify(edge, access: access) }
                try requireRole(current, expected: role, access: access)
                try access.validate()
                return .currentParentChain
            }
            guard role != "AXApplication", role != "AXWindow" else { throw Failure.unexpectedRoot }
            guard visited.count < maximumNodes else { throw Failure.nodeBound }

            let parent = try access.parent(current)
            guard !visited.contains(where: { access.identical($0, parent) }) else { throw Failure.cycle }
            let parentRole = try access.liveRole(parent)
            try requireChild(current, of: parent, access: access)
            let edge = Edge(child: current, parent: parent, childRole: role, parentRole: parentRole)
            // Bracket each observed edge with a second live parent/children
            // read before recording it; final verification repeats every edge.
            try verify(edge, access: access)
            edges.append(edge)
            current = parent
            expected = parentRole
        }
        throw Failure.nodeBound
    }

    @MainActor private static func requireChild<Node>(_ child: Node, of parent: Node, access: Access<Node>) throws {
        try access.validate()
        let children = try access.directChildren(parent)
        guard children.count <= maximumChildren else { throw Failure.childBound }
        let occurrences = children.filter { access.identical($0, child) }.count
        guard occurrences != 0 else { throw Failure.missingChild }
        guard occurrences == 1 else { throw Failure.duplicateChild }
        try access.validate()
    }
    @MainActor private static func requireRole<Node>(_ node: Node, expected: String, access: Access<Node>) throws {
        try access.validate()
        guard try access.liveRole(node).utf8.elementsEqual(expected.utf8) else { throw Failure.changedRole }
        try access.validate()
    }
    @MainActor private static func verify<Node>(_ edge: Edge<Node>, access: Access<Node>) throws {
        try access.validate()
        guard access.identical(try access.parent(edge.child), edge.parent) else { throw Failure.changedParent }
        try requireChild(edge.child, of: edge.parent, access: access)
        try requireRole(edge.child, expected: edge.childRole, access: access)
        try requireRole(edge.parent, expected: edge.parentRole, access: access)
        try access.validate()
    }
}
