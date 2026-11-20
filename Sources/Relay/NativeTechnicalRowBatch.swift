import ApplicationServices
import Foundation

/// Short-lived decoding of technical role/privacy metadata only. Never reads
/// user labels or editor content and never caches a privacy admission.
@MainActor enum NativeTechnicalRowBatch {
    static let attributeNames = [kAXRoleAttribute, kAXSubroleAttribute,
        "AXProtectedContent", "AXContainsProtectedContent", "AXHidden"]
    struct Metadata {
        let role: String, subrole: String
        let protectionFlags: [NativeStandardControlSurvey.OptionalFlag]
        let hidden: NativeStandardControlSurvey.OptionalFlag
    }
    typealias Incomplete = (NativeReadAudit.MetadataOrigin, String?, AXError?, CFTypeRef?, String?, Bool?) -> NativeOrdinaryWindowPolicySource.Failure

    static func decode(status: AXError, values: CFTypeRef?, names: Set<String>,
                       incomplete: Incomplete = { _, _, _, _, _, _ in .incomplete }) throws -> Metadata {
        guard status == .success, let values, CFGetTypeID(values) == CFArrayGetTypeID() else {
            throw incomplete(.requiredText, kAXRoleAttribute, status, values, nil, nil)
        }
        let array = unsafeDowncast(values, to: CFArray.self)
        guard CFArrayGetCount(array) == attributeNames.count else {
            throw incomplete(.requiredText, kAXRoleAttribute, .success, values, nil, nil)
        }
        func slot(_ index: Int) throws -> (AXError, CFTypeRef?) {
            guard let pointer = CFArrayGetValueAtIndex(array, index) else { throw NativeOrdinaryWindowPolicySource.Failure.incomplete }
            let value = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as CFTypeRef
            if CFGetTypeID(value) == AXValueGetTypeID() {
                let boxed = unsafeDowncast(value, to: AXValue.self)
                var error = AXError.failure
                guard AXValueGetType(boxed) == .axError,
                      AXValueGetValue(boxed, .axError, &error), error != .success else {
                    throw NativeOrdinaryWindowPolicySource.Failure.incomplete
                }
                return (error, nil)
            }
            // CFNull is ambiguous according to the SDK. It is never converted
            // into unsupported/noValue, an absent subrole, or a false flag.
            guard CFGetTypeID(value) != CFNullGetTypeID() else { throw NativeOrdinaryWindowPolicySource.Failure.incomplete }
            return (.success, value)
        }
        let (roleStatus, roleValue) = try slot(0)
        guard roleStatus == .success, let role = roleValue as? String, role.utf8.count <= 1_024 else {
            throw incomplete(.requiredText, kAXRoleAttribute, roleStatus, roleValue, nil, nil)
        }
        let (subroleStatus, subroleValue) = try slot(1)
        let subrole: String
        if subroleStatus == .attributeUnsupported, !names.contains(kAXSubroleAttribute), subroleValue == nil {
            subrole = ""
        } else {
            guard subroleStatus == .success, let value = subroleValue as? String, value.utf8.count <= 1_024 else {
                throw incomplete(.optionalText, kAXSubroleAttribute, subroleStatus, subroleValue, role, names.contains(kAXSubroleAttribute))
            }
            subrole = value
        }
        func flag(_ index: Int) throws -> NativeStandardControlSurvey.OptionalFlag {
            let name = attributeNames[index], (status, value) = try slot(index)
            do {
                return try NativeStandardControlSurvey.optionalFlag(status: status, advertised: names.contains(name), value: value)
            } catch {
                _ = incomplete(.optionalFlag, name, status, value, role, names.contains(name))
                throw error
            }
        }
        return try Metadata(role: role, subrole: subrole, protectionFlags: [flag(2), flag(3)], hidden: flag(4))
    }
}
