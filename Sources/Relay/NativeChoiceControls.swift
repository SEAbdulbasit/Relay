import ApplicationServices
import CryptoKit
import Foundation

/// Qualified native choice changes. A table mutation writes AXSelectedRows only;
/// it never presses a row or dispatches an activation/open action.
/// https://developer.apple.com/documentation/appkit/nsaccessibilitytable/setaccessibilityselectedrows(_:)
@MainActor
enum NativeChoiceControls {
    enum Kind: String { case radio, row }
    struct Choice {
        let element: AXUIElement
        let label: String
        let enabled: Bool
        let selected: Bool
        let contentIdentity: String
    }
    struct Snapshot {
        let kind: Kind
        let pid: pid_t
        let target: AXUIElement
        let container: AXUIElement
        let containerLabel: String
        let choices: [Choice]
        let targetIndex: Int
        let identityFingerprint: String

        var label: String { choices[targetIndex].label }
        var alreadySelected: Bool { selectedIndices == [targetIndex] }
        var selectedIndices: [Int] { choices.indices.filter { choices[$0].selected } }
        var fingerprint: String { digest([identityFingerprint] + choices.map { $0.selected ? "1" : "0" }) }
        var reviewText: String {
            choices.map { "\($0.label) [selected=\($0.selected), enabled=\($0.enabled)]" }.joined(separator: "\n")
        }

        func sameIdentity(as other: Self) -> Bool {
            kind == other.kind && pid == other.pid && identityFingerprint == other.identityFingerprint
                && CFEqual(target, other.target) && CFEqual(container, other.container)
                && choices.count == other.choices.count
                && zip(choices, other.choices).allSatisfy { CFEqual($0.element, $1.element) }
        }
    }

    static func snapshot(_ target: AXUIElement, pid: pid_t) throws -> Snapshot {
        guard !NativeAttachmentStaging.isChooserControl(target) else { throw failure("File chooser selections remain manual.") }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(450))
        try requireOwner(target, pid: pid)
        try requireOrdinaryWindow(target, pid: pid)
        let kind: Kind
        let container: AXUIElement
        let choices: [Choice]
        switch string(target, kAXRoleAttribute) {
        case "AXRadioButton":
            kind = .radio
            guard let parent = element(target, kAXParentAttribute), ["AXRadioGroup", "AXGroup"].contains(string(parent, kAXRoleAttribute)),
                  let peers = attribute(parent, kAXChildrenAttribute) as? [AXUIElement], (2...32).contains(peers.count) else {
                throw failure("The radio choice has no complete bounded native peer group.")
            }
            container = parent
            choices = try peers.map { peer in
                try requireBudget(deadline)
                try requireOwner(peer, pid: pid)
                guard string(peer, kAXRoleAttribute) == "AXRadioButton", let parent = element(peer, kAXParentAttribute),
                      CFEqual(parent, container), let enabled = bool(peer, kAXEnabledAttribute),
                      let selected = bool(peer, kAXValueAttribute) else { throw failure("The radio peer state is incomplete.") }
                let label = try validatedLabel(label(peer))
                return Choice(element: peer, label: label, enabled: enabled, selected: selected,
                              contentIdentity: semanticIdentity(peer))
            }
        case "AXRow":
            kind = .row
            guard let parent = ancestor(target, roles: ["AXTable", "AXOutline"], pid: pid),
                  bool(parent, kAXEnabledAttribute) == true,
                  let rows = attribute(parent, kAXRowsAttribute) as? [AXUIElement], (1...32).contains(rows.count),
                  let selected = attribute(parent, kAXSelectedRowsAttribute) as? [AXUIElement], selected.count <= 1 else {
                throw failure("The row has no enabled bounded native table with one readable selection.")
            }
            container = parent
            var settable = DarwinBoolean(false)
            guard AXUIElementIsAttributeSettable(container, kAXSelectedRowsAttribute as CFString, &settable) == .success,
                  settable.boolValue else { throw failure("The native table does not support direct row selection.") }
            choices = try rows.map { row in
                try requireBudget(deadline)
                try requireOwner(row, pid: pid)
                guard string(row, kAXRoleAttribute) == "AXRow",
                      ancestor(row, roles: ["AXTable", "AXOutline"], pid: pid).map({ CFEqual($0, container) }) == true,
                      let isSelected = bool(row, kAXSelectedAttribute) else { throw failure("The row identity or selected state is incomplete.") }
                let info = try rowContent(row, pid: pid, deadline: deadline)
                guard isSelected == selected.contains(where: { CFEqual($0, row) }) else {
                    throw failure("The table and its rows disagree about the current selection.")
                }
                return Choice(element: row, label: info.label, enabled: info.enabled, selected: isSelected, contentIdentity: info.identity)
            }
            guard selected.allSatisfy({ selected in choices.contains(where: { CFEqual($0.element, selected) }) }) else {
                throw failure("The selected row is outside the complete native table snapshot.")
            }
        default: throw failure("Only a native radio choice or table row supports this selection path.")
        }
        try requireOwner(container, pid: pid)
        guard !NativeAttachmentStaging.isChooserControl(container),
              choices.filter(\.selected).count <= 1,
              Set(choices.map(\.label)).count == choices.count,
              choices.reduce(0, { $0 + $1.label.utf8.count }) <= 6_000,
              let targetIndex = choices.firstIndex(where: { CFEqual($0.element, target) }), choices[targetIndex].enabled else {
            throw failure("The target is disabled, duplicated, ambiguous or outside its native choice container.")
        }
        for (index, choice) in choices.enumerated() {
            guard !choices.prefix(index).contains(where: { CFEqual($0.element, choice.element) }) else {
                throw failure("The native choice container repeats the same accessible object.")
            }
        }
        let containerLabel = try validatedLabel(label(container))
        if kind == .radio {
            var actions: CFArray?
            guard AXUIElementCopyActionNames(target, &actions) == .success, (actions as? [String])?.contains(kAXPressAction) == true else {
                throw failure("The native radio choice has no press action.")
            }
        }
        try requireBudget(deadline)
        let identity = digest([kind.rawValue, String(pid), String(CFHash(container)), semanticIdentity(container)]
            + choices.flatMap { [String(CFHash($0.element)), $0.label, $0.enabled ? "1" : "0", $0.contentIdentity] })
        return Snapshot(kind: kind, pid: pid, target: target, container: container, containerLabel: containerLabel,
                        choices: choices, targetIndex: targetIndex, identityFingerprint: identity)
    }

    static func performOnce(_ before: Snapshot) throws -> AXError {
        try Task.checkCancellation()
        let current = try snapshot(before.target, pid: before.pid)
        guard current.sameIdentity(as: before), current.fingerprint == before.fingerprint, !current.alreadySelected else {
            throw failure("The native choices changed before dispatch. No selection was sent.")
        }
        switch before.kind {
        case .radio:
            AXUIElementSetMessagingTimeout(before.target, 0.5)
            return AXUIElementPerformAction(before.target, kAXPressAction as CFString)
        case .row:
            AXUIElementSetMessagingTimeout(before.container, 0.5)
            return AXUIElementSetAttributeValue(before.container, kAXSelectedRowsAttribute as CFString, [before.target] as CFArray)
        }
    }

    static func rowLabel(_ row: AXUIElement, pid: pid_t) throws -> String {
        try rowContent(row, pid: pid, deadline: ContinuousClock.now.advanced(by: .milliseconds(150))).label
    }

    static func reviewState(_ item: AXUIElement, pid: pid_t) throws -> (label: String, value: String, enabled: Bool) {
        switch string(item, kAXRoleAttribute) {
        case "AXRadioButton":
            guard let selected = bool(item, kAXValueAttribute), let enabled = bool(item, kAXEnabledAttribute) else {
                throw failure("A peer radio choice lacks a complete state for review.")
            }
            return (try validatedLabel(label(item)), "selected=\(selected)", enabled)
        case "AXRow":
            guard let selected = bool(item, kAXSelectedAttribute) else { throw failure("A row lacks a selected state for review.") }
            let content = try rowContent(item, pid: pid, deadline: ContinuousClock.now.advanced(by: .milliseconds(150)))
            return (content.label, "selected=\(selected)", content.enabled)
        default: throw failure("This element has no qualified native choice state.")
        }
    }

    private struct RowContent { let label: String; let enabled: Bool; let identity: String }
    private static func rowContent(_ row: AXUIElement, pid: pid_t, deadline: ContinuousClock.Instant) throws -> RowContent {
        var queue: [(AXUIElement, Int)] = [(row, 0)]
        var visited: [AXUIElement] = []
        var cursor = 0
        var labels: [String] = []
        var identities: [String] = []
        var enabled = true
        while cursor < queue.count {
            try requireBudget(deadline)
            guard cursor < 48 else { throw failure("The row content exceeds the complete inspection budget.") }
            let (current, depth) = queue[cursor]; cursor += 1
            guard !visited.contains(where: { CFEqual($0, current) }) else { throw failure("The row content contains repeated accessible objects.") }
            visited.append(current)
            try requireOwner(current, pid: pid)
            let role = string(current, kAXRoleAttribute)
            guard ["AXRow", "AXCell", "AXGroup", "AXStaticText", "AXImage"].contains(role),
                  bool(current, "AXHidden") != true else { throw failure("Only fully visible, read-only row content is supported.") }
            if ["AXCell", "AXStaticText"].contains(role) {
                guard let state = bool(current, kAXEnabledAttribute) else { throw failure("A row cell lacks a readable enabled state.") }
                enabled = enabled && state
                var settable = DarwinBoolean(false)
                let status = AXUIElementIsAttributeSettable(current, kAXValueAttribute as CFString, &settable)
                guard (status == .success && !settable.boolValue) || status == .attributeUnsupported || status == .noValue else {
                    throw failure("Editable or incompletely inspected table cells are not qualified for this selection path.")
                }
            } else if let state = bool(current, kAXEnabledAttribute) { enabled = enabled && state }
            identities.append(semanticIdentity(current))
            var childValue: CFTypeRef?
            let childStatus = AXUIElementCopyAttributeValue(current, kAXChildrenAttribute as CFString, &childValue)
            let children: [AXUIElement]
            if childStatus == .success, let items = childValue as? [AXUIElement] { children = items }
            else if childStatus == .attributeUnsupported || childStatus == .noValue { children = [] }
            else { throw failure("The complete read-only row subtree could not be inspected.") }
            guard children.count <= 16, depth < 6 || children.isEmpty else { throw failure("The row content exceeds its structural bounds.") }
            if role == "AXStaticText" || (role == "AXCell" && children.isEmpty) {
                let text = string(current, kAXValueAttribute).isEmpty ? label(current) : string(current, kAXValueAttribute)
                if !text.isEmpty { labels.append(try validatedLabel(text)) }
            } else {
                queue.append(contentsOf: children.map { ($0, depth + 1) })
            }
        }
        try requireBudget(deadline)
        let text = try validatedLabel(labels.joined(separator: " | "))
        return RowContent(label: text, enabled: enabled, identity: digest(identities + labels))
    }

    private static func requireOwner(_ item: AXUIElement, pid: pid_t) throws {
        AXUIElementSetMessagingTimeout(item, 0.015)
        var owner: pid_t = 0
        guard AXUIElementGetPid(item, &owner) == .success, owner == pid else { throw failure("The native choice belongs to another process.") }
    }
    private static func requireBudget(_ deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw failure("The complete native selection scan exceeded its inspection budget.") }
    }
    private static func requireOrdinaryWindow(_ target: AXUIElement, pid: pid_t) throws {
        var current: AXUIElement? = target
        var visited: [AXUIElement] = []
        for _ in 0..<24 {
            guard let item = current, !visited.contains(where: { CFEqual($0, item) }) else { break }
            visited.append(item)
            try requireOwner(item, pid: pid)
            let role = string(item, kAXRoleAttribute)
            let subrole = string(item, kAXSubroleAttribute)
            let identifier = string(item, kAXIdentifierAttribute)
            guard !["AXSheet", "AXDialog"].contains(role), !["AXDialog", "AXSystemDialog"].contains(subrole),
                  bool(item, "AXModal") != true, !["open-panel", "GoToWindow", "PathTextField"].contains(identifier) else {
                throw failure("Dialog, authentication and file chooser selections remain manual/unsupported.")
            }
            if role == "AXWindow" { return }
            current = element(item, kAXParentAttribute)
        }
        throw failure("The native choice has no identifiable ordinary containing window.")
    }
    private static func ancestor(_ item: AXUIElement, roles: Set<String>, pid: pid_t) -> AXUIElement? {
        var current = element(item, kAXParentAttribute)
        for _ in 0..<6 {
            guard let value = current, (try? requireOwner(value, pid: pid)) != nil else { return nil }
            if roles.contains(string(value, kAXRoleAttribute)) { return value }
            if string(value, kAXRoleAttribute) == "AXWindow" { return nil }
            current = element(value, kAXParentAttribute)
        }
        return nil
    }
    private static func semanticIdentity(_ item: AXUIElement) -> String {
        digest([kAXRoleAttribute, kAXSubroleAttribute, kAXIdentifierAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXEnabledAttribute]
            .map { string(item, $0) })
    }
    private static func validatedLabel(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 512, !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !value.contains(where: \.isNewline) else { throw failure("An exact single-line native choice label up to 512 UTF-8 bytes is required.") }
        return value
    }
    private static func label(_ item: AXUIElement) -> String {
        let title = string(item, kAXTitleAttribute)
        return title.isEmpty ? string(item, kAXDescriptionAttribute) : title
    }
    private static func bool(_ item: AXUIElement, _ key: String) -> Bool? {
        guard let value = attribute(item, key) else { return nil }
        if CFGetTypeID(value) == CFBooleanGetTypeID() { return value as? Bool }
        guard CFGetTypeID(value) == CFNumberGetTypeID(), let number = value as? NSNumber else { return nil }
        return number.doubleValue == 0 ? false : number.doubleValue == 1 ? true : nil
    }
    private static func string(_ item: AXUIElement, _ key: String) -> String {
        guard let value = attribute(item, key) else { return "" }
        if let value = value as? String { return value }
        return String(describing: value)
    }
    private static func element(_ item: AXUIElement, _ key: String) -> AXUIElement? {
        guard let value = attribute(item, key), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }
    private static func attribute(_ item: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(item, key as CFString, &value) == .success ? value : nil
    }
    private static func digest(_ values: [String]) -> String {
        let text = values.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func failure(_ message: String) -> RelayError { .message(message) }
}
