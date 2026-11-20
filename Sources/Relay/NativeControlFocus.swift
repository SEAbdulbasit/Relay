import Foundation
import CryptoKit

/// Privacy-first focused editor admission. Metadata is checked before contents are requested;
/// missing value/selection/enabled evidence is a refusal, never an unavailable-value digest.
@MainActor enum NativeControlFocus {
    struct Metadata: Equatable {
        let role: String
        let subrole: String
        let protected: Bool?
        let hidden: Bool?
        let enabled: Bool?
        let valueWritable: Bool
        let selectionWritable: Bool
        var standardEditor: NativeStandardControlSurvey.Editor? = nil
    }
    struct Contents {
        let value: String
        let selection: NSRange
    }
    struct Labels {
        let label: String?
        let identifier: String?
    }
    struct Access {
        /// Retained original app/window/editor only; background source review is allowed.
        let validateIdentity: @MainActor () throws -> Void
        /// Actual foreground + retained original focus, required only for input.
        let validateInputIdentity: @MainActor () throws -> Void
        let metadata: @MainActor () throws -> Metadata
        /// Never called until privacy metadata and the source hierarchy admit the field.
        let qualifiedLabels: @MainActor () throws -> Labels
        let contents: @MainActor () throws -> Contents
        /// Brackets the complete synchronous editor snapshot.
        var validatePrivacy: @MainActor () throws -> Void = {}
    }
    static func protectedValue(_ flags: [Bool?]) -> Bool? {
        if flags.contains(where: { $0 == true }) { return true }
        return flags.contains(where: { $0 == false }) ? false : nil
    }

    static func capture(_ access: Access) throws -> NativeControlSession.FocusFence {
        let (metadata, descriptor, digest) = try snapshot(access)
        let validateSource: @MainActor () throws -> Void = {
            let (current, currentDescriptor, currentDigest) = try snapshot(access)
            guard metadata == current, descriptor == currentDescriptor, currentDigest == digest else {
                throw NativeControlSession.Failure.changedFocus
            }
        }
        return .init(descriptor: descriptor, validateSourceBeforeInput: validateSource, validateBeforeInput: {
            try access.validateInputIdentity()
            try validateSource()
            try access.validateInputIdentity()
        }, validateAfterInput: {
            try access.validateInputIdentity()
            try access.validateIdentity()
            try admit(access.metadata())
        })
    }

    private static func snapshot(_ access: Access) throws -> (Metadata, NativeControlTargetDescriptor, Data) {
        try access.validateIdentity()
        try access.validatePrivacy()
        let metadata = try access.metadata()
        try admit(metadata)
        try access.validateIdentity()
        let labels = try access.qualifiedLabels()
        try access.validateIdentity()
        let contents = try access.contents()
        try access.validateIdentity()
        try access.validatePrivacy()
        let descriptor = try NativeControlTargetDescriptor(role: metadata.role, label: labels.label,
            identifier: labels.identifier, selection: .init(location: contents.selection.location,
                length: contents.selection.length, originalUTF16Count: contents.value.utf16.count))
        return (metadata, descriptor, try sourceDigest(contents))
    }

    private static func admit(_ metadata: Metadata) throws {
        guard ["AXTextField", "AXTextArea", "AXComboBox"].contains(metadata.role),
              !metadata.role.localizedCaseInsensitiveContains("secure"),
              !metadata.subrole.localizedCaseInsensitiveContains("secure"),
              !metadata.role.localizedCaseInsensitiveContains("password"),
              !metadata.subrole.localizedCaseInsensitiveContains("password"),
              metadata.protected != true, metadata.hidden != true,
              metadata.valueWritable, metadata.selectionWritable else { throw NativeControlSession.Failure.unavailableFocus }
        if let standard = metadata.standardEditor {
            try standard.validate(role: metadata.role, subrole: metadata.subrole, protected: metadata.protected,
                hidden: metadata.hidden, enabled: metadata.enabled)
        } else {
            guard metadata.protected == false, metadata.hidden == false, metadata.enabled == true else {
                throw NativeControlSession.Failure.unavailableFocus
            }
        }
    }
    private static func sourceDigest(_ contents: Contents) throws -> Data {
        let count = contents.value.utf16.count
        guard contents.value.utf8.count <= 65_536, contents.selection.location != NSNotFound,
              contents.selection.location >= 0, contents.selection.length >= 0,
              contents.selection.location <= count, contents.selection.length <= count - contents.selection.location else {
            throw NativeControlSession.Failure.unavailableFocus
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return Data(SHA256.hash(data: try encoder.encode(["value": contents.value,
            "selection": "\(contents.selection.location):\(contents.selection.length)"])))
    }
}
