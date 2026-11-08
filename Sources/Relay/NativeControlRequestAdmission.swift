import Foundation

/// Trusted process-local adapter over one accepted journal proposal. Neither
/// model strings nor restored journal metadata construct an executable ticket.
@MainActor
struct NativeControlRequestAdmission {
    let requestID: String
    let originalProviderCallID: Data
    let exactCallDigest: Data
    let validateAcceptedProposal: @MainActor () throws -> Void
    let admitOneAttempt: @MainActor () throws -> Void

    func validate() throws {
        guard !requestID.isEmpty, requestID.utf8.count <= 512,
              !originalProviderCallID.isEmpty, originalProviderCallID.count <= 1_024,
              exactCallDigest.count == 32 else { throw NativeControlSession.Failure.invalidAction }
        try validateAcceptedProposal()
    }
}

/// Bounded actual AX facts, populated only after privacy/plain-editor admission.
/// A display DTO is not source authority or input permission.
nonisolated struct NativeControlTargetDescriptor: Sendable, Equatable {
    nonisolated struct Selection: Sendable, Equatable {
        let location: Int
        let length: Int
        let originalUTF16Count: Int
    }
    let role: String
    let label: String?
    let identifier: String?
    let selection: Selection?

    init(role: String, label: String?, identifier: String?, selection: Selection?) throws {
        guard ["AXTextField", "AXTextArea", "AXComboBox"].contains(role),
              label.map({ !$0.isEmpty && $0.utf8.count <= 512 && !Self.containsControls($0) }) ?? true,
              identifier.map({ !$0.isEmpty && $0.utf8.count <= 512 && !Self.containsControls($0) }) ?? true else {
            throw NativeControlSession.Failure.unavailableFocus
        }
        if let selection {
            guard selection.location >= 0, selection.length >= 0, selection.originalUTF16Count >= 0,
                  selection.location <= selection.originalUTF16Count,
                  selection.length <= selection.originalUTF16Count - selection.location else {
                throw NativeControlSession.Failure.unavailableFocus
            }
        }
        self.role = role; self.label = label; self.identifier = identifier; self.selection = selection
    }

    static func == (left: Self, right: Self) -> Bool {
        func same(_ a: String?, _ b: String?) -> Bool {
            switch (a, b) {
            case (nil, nil): true
            case (.some(let a), .some(let b)): a.utf16.elementsEqual(b.utf16)
            default: false
            }
        }
        return left.role.utf16.elementsEqual(right.role.utf16) && same(left.label, right.label)
            && same(left.identifier, right.identifier) && left.selection == right.selection
    }

    private static func containsControls(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}
