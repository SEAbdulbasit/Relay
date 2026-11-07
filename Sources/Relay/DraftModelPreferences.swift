import Foundation
import Observation

@Observable @MainActor
final class DraftModelPreferences {
    private struct Saved: Codable {
        let version: Int
        let model: ModelConfiguration?
    }

    private(set) var model: ModelConfiguration?
    private(set) var hasInvalidSelection = false
    private(set) var status = "Double Tap uses the active local chat model."
    @ObservationIgnored private let location: URL?

    init(location: URL?) {
        self.location = location
        guard let location, FileManager.default.fileExists(atPath: location.path) else { return }
        do {
            let saved = try JSONDecoder().decode(Saved.self, from: LocalStateFile.read(location, maximumBytes: 8_192))
            guard saved.version == 1 else { throw RelayError.message("Unknown draft model preferences.") }
            if let config = saved.model { try Self.validate(config) }
            model = saved.model
            if let model { status = "Separate \(model.localProviderName) drafting model selected. Relay checks it on the first draft." }
        } catch {
            hasInvalidSelection = true
            status = "The saved drafting choice is unavailable. Choose it again or explicitly use the chat model; no other provider will be substituted."
        }
    }

    func select(_ url: URL) {
        let config = ModelConfiguration(modelPath: url.path, computeBackend: model?.computeBackend ?? "cpu",
                                       model: url.deletingPathExtension().lastPathComponent)
        apply(config)
    }

    func selectBackend(_ backend: String) {
        guard var model, model.backend == .liteRTLM else { return }
        model.computeBackend = backend
        apply(model)
    }

    func selectLMStudio(_ configuration: ModelConfiguration) {
        guard configuration.backend == .lmStudio else { return }
        apply(configuration)
    }
    func useChatModel() { apply(nil) }

    private static func validate(_ configuration: ModelConfiguration) throws {
        switch configuration.backend {
        case .liteRTLM: _ = try LocalModelClient.validatedModelURL(configuration)
        case .lmStudio:
            guard configuration.lmStudio?.selection != nil else { throw LocalInferenceFailure.unconfigured }
        }
    }

    private func apply(_ config: ModelConfiguration?) {
        do {
            if let config { try Self.validate(config) }
            if let location {
                try FileManager.default.createDirectory(at: location.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                let data = try JSONEncoder().encode(Saved(version: 1, model: config))
                try LocalPrivateFileWriter.write(data: data, to: location, maximumBytes: 8_192)
            }
            model = config
            hasInvalidSelection = false
            status = config == nil ? "Double Tap uses the active local chat model."
                : "Separate \(config!.localProviderName) drafting model selected. Relay checks it on the first draft."
        } catch {
            status = "Draft model selection was not saved. " + error.localizedDescription
        }
    }
}
