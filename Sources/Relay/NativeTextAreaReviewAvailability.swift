import ApplicationServices
import Foundation

/// NSTextView is not an NSControl and may omit AXEnabled. This adapter only
/// describes that field in a reviewed payload; it never grants a write or
/// substitutes an assumed enabled Boolean.
@MainActor
enum NativeTextAreaReviewAvailability {
    nonisolated enum EnabledResponse { case absent, advertised, failed }
    nonisolated struct Proof {
        var role: String
        var enabledResponse: EnabledResponse
        var valueIsText: Bool
        var valueWritable: Bool
        var focusWritable: Bool
        var selectionWritable: Bool
        var validSelection: Bool
        var secure: Bool
        var attachedToOriginalWindow: Bool
    }

    nonisolated static func accepts(_ proof: Proof) -> Bool {
        proof.role == "AXTextArea" && proof.enabledResponse == .absent && proof.valueIsText
            && proof.valueWritable && proof.focusWritable && proof.selectionWritable && proof.validSelection
            && !proof.secure && proof.attachedToOriginalWindow
    }

    static func inspect(_ element: AXUIElement, value: CFTypeRef, in window: AXUIElement,
                        processID: pid_t) throws -> AXReviewField.AvailabilityEvidence {
        try Task.checkCancellation()
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success, let attributes = names as? [String] else {
            throw RelayError.message("The text area's review attributes could not be inspected completely.")
        }
        var enabled: CFTypeRef?
        let enabledStatus = AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabled)
        let enabledResponse: EnabledResponse = attributes.contains(kAXEnabledAttribute) ? .advertised
            : [.attributeUnsupported, .noValue].contains(enabledStatus) ? .absent : .failed
        let role = string(element, kAXRoleAttribute)
        let subrole = string(element, kAXSubroleAttribute)
        let text = value as? String
        var selected: CFTypeRef?
        var range = CFRange()
        var validSelection = false
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selected) == .success,
           let selected, CFGetTypeID(selected) == AXValueGetTypeID() {
            let rangeValue = selected as! AXValue
            if AXValueGetType(rangeValue) == .cfRange, AXValueGetValue(rangeValue, .cfRange, &range), let text {
                validSelection = range.location >= 0 && range.length >= 0
                    && range.location <= text.utf16.count && range.length <= text.utf16.count - range.location
            }
        }
        let proof = Proof(role: role, enabledResponse: enabledResponse, valueIsText: text != nil,
            valueWritable: writable(element, kAXValueAttribute), focusWritable: writable(element, kAXFocusedAttribute),
            selectionWritable: writable(element, kAXSelectedTextRangeAttribute), validSelection: validSelection,
            secure: [role, subrole].contains { $0.localizedCaseInsensitiveContains("secure") || $0.localizedCaseInsensitiveContains("password") },
            attachedToOriginalWindow: attached(element, to: window, processID: processID))
        guard accepts(proof) else {
            throw RelayError.message("The text area has no explicit enabled state and its complete editable-text capability could not be verified.")
        }
        return .writableNativeTextArea
    }

    private static func writable(_ element: AXUIElement, _ name: String) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success && settable.boolValue
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value as? String ?? "" : ""
    }

    private static func attached(_ element: AXUIElement, to window: AXUIElement, processID: pid_t) -> Bool {
        let root = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(root, 0.05)
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement], windows.contains(where: { CFEqual($0, window) }) else { return false }
        var node = element
        for _ in 0..<32 {
            var pid: pid_t = 0
            guard AXUIElementGetPid(node, &pid) == .success, pid == processID else { return false }
            if CFEqual(node, window) { return true }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { return false }
            node = parent as! AXUIElement
            AXUIElementSetMessagingTimeout(node, 0.015)
        }
        return false
    }
}
