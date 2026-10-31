import Foundation

// Compatibility names keep the export-specific surface narrow; app state uses the shared
// private writer with its own declared cap. This facade always enforces the export cap.
typealias ConversationExportWriteError = LocalPrivateFileWriteError
typealias ConversationExportWriteHooks = LocalPrivateFileWriteHooks
nonisolated enum ConversationExportWriter {
    static let maximumBytes = 12 * 1_024 * 1_024
    static func write(data: Data, to url: URL, hooks: ConversationExportWriteHooks = .init()) throws {
        try LocalPrivateFileWriter.write(data: data, to: url, maximumBytes: maximumBytes, hooks: hooks)
    }
    static func validateLocalVolume(flags: UInt32) throws {
        try LocalPrivateFileWriter.validateLocalVolume(flags: flags)
    }
}
