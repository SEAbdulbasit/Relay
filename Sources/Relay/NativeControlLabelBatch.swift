import ApplicationServices
import Foundation

/// Single-control optional label batching for retained ordinary-window policy
/// inspection. Never caches privacy verdicts across controls, widens deadlines,
/// retries failed queries, reorders attributes or retains raw label text.
nonisolated enum NativeControlLabelBatch {
    static let attributeNames: [String] = [
        kAXTitleAttribute,
        kAXDescriptionAttribute,
        kAXIdentifierAttribute,
    ]
    static let maximumLabelUTF8Bytes = 1_024
    static let maximumCombinedUTF8Bytes = 1_024

    struct RawResponse {
        let status: AXError
        let values: CFTypeRef?
        init(status: AXError, values: CFTypeRef?) {
            self.status = status
            self.values = values
        }
    }

    typealias IncompleteRecorder = (
        NativeReadAudit.MetadataOrigin,
        String?,
        AXError?,
        CFTypeRef?,
        Bool?
    ) -> NativeOrdinaryWindowPolicySource.Failure

    static func boxedError(_ status: AXError) -> AXValue? {
        var raw = status
        return AXValueCreate(.axError, &raw)
    }

    /// Brackets the single private batch query with strict pre- and post-query
    /// survey/ancestry fences before any slot is decoded or returned.
    @MainActor static func read(
        advertisedNames: Set<String>,
        validatePrivateScope: @MainActor () throws -> Void,
        transport: @MainActor () throws -> RawResponse,
        incomplete: IncompleteRecorder = { _, _, _, _, _ in .incomplete }
    ) throws -> String {
        try validatePrivateScope()
        let response = try transport()
        try validatePrivateScope()
        return try decode(
            status: response.status,
            rawValues: response.values,
            advertisedNames: advertisedNames,
            incomplete: incomplete
        )
    }

    /// Preserves the outer visibility gate and only classifies or publishes a
    /// control's labels after the pre-fence, single batch transport, post-fence
    /// and strict 3-slot decoder have all succeeded.
    @MainActor static func inspectControl<Node>(
        _ node: Node,
        access: NativeStandardControlSurvey.AncestryAccess<Node>,
        read: @MainActor () throws -> String,
        boundaries: inout Set<NativeOrdinaryWindowPolicySource.Dedicated>,
        labels: inout [String]
    ) throws {
        try inspectControl(visibility: {
            try NativeStandardControlSurvey.visibleOriginalForLabels(from: node, access: access)
        }, read: read, boundaries: &boundaries, labels: &labels)
    }

    /// A visibility callback may finish a metadata-only phase, but no phase
    /// remains active while this shared core invokes the private read callback.
    @MainActor static func inspectControl(
        visibility: @MainActor () throws -> Bool,
        read: @MainActor () throws -> String,
        boundaries: inout Set<NativeOrdinaryWindowPolicySource.Dedicated>,
        labels: inout [String]
    ) throws {
        guard try visibility() else { return }
        let value = try read()
        try recordVerifiedLabel(value, boundaries: &boundaries, labels: &labels)
    }

    @MainActor static func recordVerifiedLabel(
        _ value: String,
        boundaries: inout Set<NativeOrdinaryWindowPolicySource.Dedicated>,
        labels: inout [String]
    ) throws {
        if NativeOrdinaryWindowPolicySource.isSensitive(value) {
            throw NativeOrdinaryWindowPolicySource.Failure.protectedContext
        }
        if let boundary = NativeOrdinaryWindowPolicySource.dedicated(value) {
            boundaries.insert(boundary)
        }
        labels.append(value)
    }

    /// Decodes the exact 3-slot `[AXTitle, AXDescription, AXIdentifier]` batch.
    /// Boxed `.noValue` is absent; boxed `.attributeUnsupported` is absent only
    /// when unadvertised; all other errors, `CFNull`, non-strings, wrong array
    /// counts, top-level errors and UTF-8 byte overflows refuse the whole batch.
    static func decode(
        status: AXError,
        rawValues: CFTypeRef?,
        advertisedNames: Set<String>,
        incomplete: IncompleteRecorder = { _, _, _, _, _ in .incomplete }
    ) throws -> String {
        guard status == .success else {
            throw incomplete(.labelValue, nil, status, rawValues, nil)
        }
        guard let rawValues, CFGetTypeID(rawValues) == CFArrayGetTypeID() else {
            throw incomplete(.labelValue, nil, .success, rawValues, nil)
        }
        let array = unsafeDowncast(rawValues, to: CFArray.self)
        guard CFArrayGetCount(array) == attributeNames.count else {
            throw incomplete(.labelValue, nil, .success, rawValues, nil)
        }
        var values: [String] = []
        values.reserveCapacity(attributeNames.count)
        for (index, name) in attributeNames.enumerated() {
            let advertised = advertisedNames.contains(name)
            guard let rawPointer = CFArrayGetValueAtIndex(array, index) else {
                throw incomplete(.labelValue, name, .success, nil, advertised)
            }
            let slot = Unmanaged<AnyObject>.fromOpaque(rawPointer).takeUnretainedValue() as CFTypeRef
            if CFGetTypeID(slot) == AXValueGetTypeID() {
                let axValue = unsafeDowncast(slot, to: AXValue.self)
                guard AXValueGetType(axValue) == .axError else {
                    throw incomplete(.labelValue, name, .success, slot, advertised)
                }
                var slotStatus = AXError.failure
                guard AXValueGetValue(axValue, .axError, &slotStatus), slotStatus != .success else {
                    throw incomplete(.labelValue, name, .failure, slot, advertised)
                }
                if slotStatus == .noValue { continue }
                if slotStatus == .attributeUnsupported, !advertised { continue }
                throw incomplete(.labelValue, name, slotStatus, nil, advertised)
            }
            guard CFGetTypeID(slot) == CFStringGetTypeID(),
                  let value = slot as? String,
                  value.utf8.count <= maximumLabelUTF8Bytes else {
                throw incomplete(.labelValue, name, .success, slot, advertised)
            }
            values.append(value)
        }
        guard values.reduce(0, { $0 + $1.utf8.count }) <= maximumCombinedUTF8Bytes else {
            throw incomplete(.labelBound, nil, nil, nil, nil)
        }
        return values.joined(separator: " ")
    }
}
