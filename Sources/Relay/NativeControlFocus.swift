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
    }
    static func protectedValue(_ flags: [Bool?]) -> Bool? {
        if flags.contains(where: { $0 == true }) { return true }
        return flags.contains(where: { $0 == false }) ? false : nil
    }

    static func capture(_ access: Access) throws -> NativeControlSession.FocusFence {
        try access.validateIdentity()
        let metadata = try access.metadata()
        try admit(metadata)
        try access.validateIdentity()
        let labels = try access.qualifiedLabels()
        try access.validateIdentity()
        let contents = try access.contents()
        try access.validateIdentity()
        let digest = try sourceDigest(contents)
        let descriptor = try NativeControlTargetDescriptor(role: metadata.role, label: labels.label,
            identifier: labels.identifier, selection: .init(location: contents.selection.location,
                length: contents.selection.length, originalUTF16Count: contents.value.utf16.count))
        let validateSource: @MainActor () throws -> Void = {
            try access.validateIdentity()
            let current = try access.metadata()
            try admit(current)
            try access.validateIdentity()
            let currentLabels = try access.qualifiedLabels()
            try access.validateIdentity()
            let currentContents = try access.contents()
            try access.validateIdentity()
            let currentDescriptor = try NativeControlTargetDescriptor(role: current.role, label: currentLabels.label,
                identifier: currentLabels.identifier, selection: .init(location: currentContents.selection.location,
                    length: currentContents.selection.length, originalUTF16Count: currentContents.value.utf16.count))
            guard metadata == current, descriptor == currentDescriptor,
                  try sourceDigest(currentContents) == digest else { throw NativeControlSession.Failure.changedFocus }
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

    private static func admit(_ metadata: Metadata) throws {
        guard ["AXTextField", "AXTextArea", "AXComboBox"].contains(metadata.role),
              !metadata.role.localizedCaseInsensitiveContains("secure"),
              !metadata.subrole.localizedCaseInsensitiveContains("secure"),
              !metadata.role.localizedCaseInsensitiveContains("password"),
              !metadata.subrole.localizedCaseInsensitiveContains("password"),
              metadata.protected == false, metadata.hidden == false, metadata.enabled == true,
              metadata.valueWritable, metadata.selectionWritable else { throw NativeControlSession.Failure.unavailableFocus }
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
