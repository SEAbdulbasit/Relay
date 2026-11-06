import Foundation
import Observation

@Observable @MainActor
final class DraftModelPreferences {
    private struct Saved: Codable {
        let version: Int
        let model: ModelConfiguration?
    }

    private(set) var model: ModelConfiguration?
    private(set) var status = "Double Tap uses the active local chat model."
    @ObservationIgnored private let location: URL?

    init(location: URL?) {
        self.location = location
        guard let location, FileManager.default.fileExists(atPath: location.path) else { return }
        do {
            let saved = try JSONDecoder().decode(Saved.self, from: LocalStateFile.read(location, maximumBytes: 8_192))
            guard saved.version == 1 else { throw RelayError.message("Unknown draft model preferences.") }
            if let config = saved.model { _ = try LocalModelClient.validatedModelURL(config) }
            model = saved.model
            if model != nil { status = "Separate local draft model selected. Relay checks it on the first draft." }
        } catch { status = "The saved draft model could not be opened. Double Tap uses the active chat model." }
    }

    func select(_ url: URL) {
        let config = ModelConfiguration(modelPath: url.path, computeBackend: model?.computeBackend ?? "cpu",
                                       model: url.deletingPathExtension().lastPathComponent)
        apply(config)
    }

    func selectBackend(_ backend: String) {
        guard var model else { return }
        model.computeBackend = backend
        apply(model)
    }

    func useChatModel() { apply(nil) }

    private func apply(_ config: ModelConfiguration?) {
        do {
            if let config { _ = try LocalModelClient.validatedModelURL(config) }
            if let location {
                try FileManager.default.createDirectory(at: location.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                let data = try JSONEncoder().encode(Saved(version: 1, model: config))
                try LocalPrivateFileWriter.write(data: data, to: location, maximumBytes: 8_192)
            }
            model = config
            status = config == nil ? "Double Tap uses the active local chat model."
                : "Separate local draft model selected. Relay checks it on the first draft."
        } catch {
            status = "Draft model selection was not saved. " + error.localizedDescription
        }
    }
}
