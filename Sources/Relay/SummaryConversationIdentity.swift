import AppKit
import ApplicationServices
import Foundation

/// The identifier comes from the app's current document metadata. It is not a
/// title, contact name, message hash, generated token or navigation permission.
/// This value is transient and deliberately has no Codable conformance.
nonisolated struct SummaryConversationIdentity: Equatable, Sendable {
    let profile: SummaryConversationSnapshot.Profile
    private let documentIdentity: String

    private init(profile: SummaryConversationSnapshot.Profile, documentIdentity: String) {
        self.profile = profile; self.documentIdentity = documentIdentity
    }

    /// Identifier shape validation only. It does not establish that an app
    /// exposes the current thread here. Conditional per-invocation admission
    /// also needs the actual transcript and consistent current AX metadata;
    /// recorded live app/version qualification remains a separate G7 gate.
    static func qualifiedDocumentShape(profile: SummaryConversationSnapshot.Profile, raw: String) -> Self? {
        guard raw.utf8.count <= 2_048, !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let parts = URLComponents(string: raw), parts.user == nil, parts.password == nil,
              parts.port == nil, parts.query == nil, parts.fragment == nil else { return nil }
        switch profile {
        case .claude:
            // Anthropic documents /chat/{conversation-id} and identifies that
            // segment as the existing conversation UUID. /new, /project and
            // shared links do not identify this private current conversation.
            guard ["https", "claude"].contains(parts.scheme?.lowercased() ?? ""),
                  parts.host?.lowercased() == "claude.ai" else { return nil }
            let path = parts.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
            guard path.count == 3, path[0].isEmpty, path[1] == "chat",
                  let uuid = UUID(uuidString: String(path[2])) else { return nil }
            return Self(profile: profile, documentIdentity: "claude.ai/chat/" + uuid.uuidString.lowercased())
        case .whatsApp, .messages, .chatGPT, .codex, .slack:
            // No qualified current-thread AX metadata contract has been
            // established for these profiles. Names and constant AX IDs cannot
            // substitute for one, and no database or ambient source is read.
            return nil
        }
    }
}

/// A trusted metadata-only boundary. Production retains an AX transcript root;
/// inert tests use local NSObject identities without querying any application.
@MainActor enum SummaryConversationCaptureBoundary {
    enum Failure: Error, Equatable, LocalizedError {
        case missingIdentity, changedConversation, incomplete, inactive, limit
        var errorDescription: String? {
            switch self {
            case .missingIdentity:
                "This conversation did not expose a qualified stable thread identity. Select the intended text instead."
            case .changedConversation:
                "The original conversation changed during capture. No replacement conversation was retained. Select the intended text or invoke Summarize again."
            case .incomplete:
                "The complete conversation boundary could not be captured. Select the intended text instead."
            case .inactive: "The conversation capture stopped or its interactive session ended."
            case .limit: "Conversation identity could not be checked within this bounded capture. Select the intended text instead."
            }
        }
    }

    struct Boundary {
        let identity: SummaryConversationIdentity
        let transcriptRoot: CFTypeRef
        let headerAnchor: String

        func matches(_ other: Self) -> Bool {
            identity == other.identity && CFEqual(transcriptRoot, other.transcriptRoot)
                && headerAnchor.utf16.elementsEqual(other.headerAnchor.utf16)
        }
    }
    struct Frozen {
        let tree: SummaryNativeDocumentCapture.Tree
        /// Captures only the original metadata and inspector, never body text.
        let validate: @MainActor () throws -> Void
    }

    /// A short synchronous capture still needs this boundary: MainActor does
    /// not stop another application's process from changing its conversation.
    static func freeze(profile: SummaryConversationSnapshot.Profile,
                       isActive: @escaping @MainActor () -> Bool,
                       maximumSeconds: TimeInterval,
                       inspect: @escaping @MainActor () throws -> Boundary,
                       read: @MainActor () throws -> SummaryNativeDocumentCapture.Tree) throws -> Frozen {
        let began = ProcessInfo.processInfo.systemUptime
        let seconds = maximumSeconds.isFinite ? max(0, min(maximumSeconds, 0.25)) : 0
        func check() throws {
            try Task.checkCancellation()
            guard isActive() else { throw Failure.inactive }
            guard ProcessInfo.processInfo.systemUptime - began < seconds else { throw Failure.limit }
        }
        try check()
        let original = try inspect()
        guard original.identity.profile == profile else { throw Failure.missingIdentity }
        try check()
        let tree = try read()
        try check()
        guard !tree.limited else { throw Failure.incomplete }
        guard original.matches(try inspect()) else { throw Failure.changedConversation }
        try check()
        return Frozen(tree: tree, validate: {
            try Task.checkCancellation()
            guard isActive() else { throw Failure.inactive }
            guard original.matches(try inspect()) else { throw Failure.changedConversation }
        })
    }
}

/// A documented route validates identifier shape, not current AX availability.
/// Admission additionally requires the actual declared transcript and matching
/// current document metadata. Live app/version qualification remains separate.
@MainActor enum SummaryConversationAXIdentity {
    struct Candidate {
        let transcriptRoot: CFTypeRef?
        let documentMetadata: [String]
        let headerAnchor: String
    }

    static func admit(profile: SummaryConversationSnapshot.Profile,
                      candidates: [Candidate]) throws -> SummaryConversationCaptureBoundary.Boundary {
        guard profile == .claude, candidates.count == 1, let candidate = candidates.first,
              let root = candidate.transcriptRoot, candidate.documentMetadata.count <= 6,
              candidate.headerAnchor.utf8.count <= 512 else { throw SummaryConversationCaptureBoundary.Failure.missingIdentity }
        var identities: [SummaryConversationIdentity] = []
        for raw in candidate.documentMetadata where !raw.isEmpty {
            // These values already came from the transcript, enclosing web
            // area or original window's current-document attributes. A /new,
            // project, malformed or other route cannot be silently dropped
            // while an obsolete transcript still exposes a valid old chat URL.
            guard let identity = SummaryConversationIdentity.qualifiedDocumentShape(profile: profile, raw: raw) else {
                throw SummaryConversationCaptureBoundary.Failure.missingIdentity
            }
            identities.append(identity)
        }
        guard let identity = identities.first, identities.allSatisfy({ $0 == identity }) else {
            throw SummaryConversationCaptureBoundary.Failure.missingIdentity
        }
        return .init(identity: identity, transcriptRoot: root, headerAnchor: candidate.headerAnchor)
    }

    static func inspect(window: AXUIElement, profile: SummaryConversationSnapshot.Profile,
                        maximumSeconds: TimeInterval = 0.05) throws -> SummaryConversationCaptureBoundary.Boundary {
        guard profile == .claude else { throw SummaryConversationCaptureBoundary.Failure.missingIdentity }
        return try inspectCandidate(window: window, profile: profile, maximumSeconds: maximumSeconds)
    }

    /// Read-only capability qualification seam. It inspects metadata, never a
    /// conversation body, and cannot enable a production profile by itself.
    static func inspectCandidate(window: AXUIElement, profile: SummaryConversationSnapshot.Profile,
                                 maximumSeconds: TimeInterval = 0.05) throws -> SummaryConversationCaptureBoundary.Boundary {
        let began = ProcessInfo.processInfo.systemUptime
        let seconds = maximumSeconds.isFinite ? max(0, min(maximumSeconds, 0.1)) : 0
        var pending: [(AXUIElement, AXUIElement?, Int)] = [(window, nil, 0)]
        var roots: [(AXUIElement, AXUIElement?)] = []
        var seen: [UInt: [AXUIElement]] = [:]
        var headerAnchors: [String] = []
        var count = 0
        func check() throws {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime - began < seconds, count < 1_000 else {
                throw SummaryConversationCaptureBoundary.Failure.limit
            }
        }
        func attribute(_ element: AXUIElement, _ name: String) throws -> CFTypeRef? {
            try check()
            AXUIElementSetMessagingTimeout(element, 0.005)
            var value: CFTypeRef?
            switch AXUIElementCopyAttributeValue(element, name as CFString, &value) {
            case .success: return value
            case .attributeUnsupported, .noValue: return nil
            default: throw SummaryConversationCaptureBoundary.Failure.incomplete
            }
        }
        func string(_ element: AXUIElement, _ name: String) throws -> String {
            let value = try attribute(element, name)
            if let url = value as? URL { return url.absoluteString }
            let text = value as? String ?? ""
            guard text.utf8.count <= 2_048 else { throw SummaryConversationCaptureBoundary.Failure.limit }
            return text
        }
        while let (element, inheritedWebArea, depth) = pending.popLast() {
            try check(); count += 1
            guard depth <= 80 else { throw SummaryConversationCaptureBoundary.Failure.limit }
            let key = CFHash(element)
            if seen[key]?.contains(where: { CFEqual($0, element) }) == true { continue }
            seen[key, default: []].append(element)
            let role = try string(element, "AXRole"), subrole = try string(element, "AXSubrole")
            if ["AXToolbar", "AXMenuBar", "AXMenu"].contains(role) || subrole == "AXSecureTextField" { continue }
            if (try attribute(element, "AXHidden") as? Bool) == true { continue }
            if (try attribute(element, "AXProtectedContent") as? Bool) == true { continue }
            let identifier = try string(element, "AXIdentifier")
            let classes = try attribute(element, "AXDOMClassList") as? [String] ?? []
            guard classes.count <= 128 else { throw SummaryConversationCaptureBoundary.Failure.limit }
            if ["ChatBar_ComposerTextView", "MessageEntryView"].contains(identifier) || classes.contains("ProseMirror") { continue }
            let webArea = role == "AXWebArea" ? element : inheritedWebArea
            let transcript: Bool = switch profile {
            case .whatsApp: identifier == "ChatMessagesTableView"
            case .messages: identifier == "TranscriptCollectionView"
            case .claude: classes.contains("epitaxy-chat-panel-body")
            case .chatGPT, .codex:
                if classes.contains("thread-scroll-container") { try string(element, "AXDescription") == "Conversation" }
                else { false }
            case .slack: classes.contains("p-message_pane")
            }
            if transcript { roots.append((element, webArea)); continue }
            if ["NavigationBar_HeaderViewButton", "ConversationTitle"].contains(identifier) {
                let title = try string(element, "AXTitle")
                headerAnchors.append(title.isEmpty ? try string(element, "AXDescription") : title)
            }
            var childCount: CFIndex = 0
            let status = AXUIElementGetAttributeValueCount(element, "AXChildren" as CFString, &childCount)
            guard [AXError.success, .attributeUnsupported, .noValue].contains(status), childCount >= 0,
                  childCount <= 1_000 - count - pending.count else { throw SummaryConversationCaptureBoundary.Failure.incomplete }
            if childCount > 0 {
                var raw: CFArray?
                guard AXUIElementCopyAttributeValues(element, "AXChildren" as CFString, 0, childCount, &raw) == .success,
                      let children = raw as? [AXUIElement] else { throw SummaryConversationCaptureBoundary.Failure.incomplete }
                pending += children.reversed().map { ($0, webArea, depth + 1) }
            }
        }
        guard roots.count == 1, let (root, webArea) = roots.first, headerAnchors.count <= 1 else {
            throw SummaryConversationCaptureBoundary.Failure.missingIdentity
        }
        // Only current document metadata from this transcript, its enclosing
        // web area and the originating window is eligible. Link targets and
        // sidebar child URLs are never candidates for conversation identity.
        var documentMetadata: [String] = []
        for element in [root, webArea, window].compactMap({ $0 }) {
            for name in ["AXDocument", "AXURL"] {
                let raw = try string(element, name)
                documentMetadata.append(raw)
            }
        }
        try check()
        return try admit(profile: profile, candidates: [.init(transcriptRoot: root,
            documentMetadata: documentMetadata, headerAnchor: headerAnchors.first ?? "")])
    }
}
