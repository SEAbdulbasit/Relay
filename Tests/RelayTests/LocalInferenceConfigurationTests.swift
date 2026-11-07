import Foundation
import Testing
@testable import Relay

@MainActor struct LocalInferenceConfigurationTests {
    @Test func existingEmbeddedJSONKeepsItsValuesWithoutANewProviderField() throws {
        let bytes = Data(#"{"backend":"liteRTLM","modelPath":"/SYNTHETIC/model.litertlm","computeBackend":"gpu","model":"Original Gemma"}"#.utf8)
        let configuration = try JSONDecoder().decode(ModelConfiguration.self, from: bytes)
        #expect(configuration.backend == .liteRTLM && configuration.lmStudio == nil)
        #expect(configuration.modelPath == "/SYNTHETIC/model.litertlm" && configuration.computeBackend == "gpu")
        #expect(try JSONDecoder().decode(ModelConfiguration.self, from: JSONEncoder().encode(configuration)) == configuration)
    }
    @Test func providerSwitchRoundTripPreservesIndependentNativeAndServerChoices() throws {
        var configuration = ModelConfiguration(modelPath: "/SYNTHETIC/original.litertlm", computeBackend: "gpu", model: "Original")
        let nativeIdentity = configuration.inferenceIdentity
        configuration.lmStudio = try LMStudioConfiguration(endpoint: LMStudioEndpoint(port: 2345), modelID: "synthetic-server-model")
        configuration.backend = .lmStudio
        let restored = try JSONDecoder().decode(ModelConfiguration.self, from: JSONEncoder().encode(configuration))
        #expect(restored == configuration && restored.inferenceIdentity != nativeIdentity)
        configuration = restored; configuration.backend = .liteRTLM
        #expect(configuration.inferenceIdentity == nativeIdentity)
        #expect(configuration.lmStudio?.modelID == "synthetic-server-model" && configuration.lmStudio?.endpoint.port == 2345)
    }
    @Test func pendingServerSetupIsNotAnImplicitEmbeddedModelAfterRestart() throws {
        let configuration = ModelConfiguration(backend: .lmStudio, modelPath: "/SYNTHETIC/preserved.litertlm")
        let restored = try JSONDecoder().decode(ModelConfiguration.self, from: JSONEncoder().encode(configuration))
        #expect(restored.backend == .lmStudio && !restored.hasConfiguredInferenceModel)
        #expect(restored.inferenceIdentity == nil && restored.modelPath == configuration.modelPath)
        #expect(throws: (any Error).self) { try LocalModelClient.validatedModelURL(restored) }
    }
    @Test func unknownProviderAndMalformedEndpointCannotSilentlyDecodeAsGemma() throws {
        for json in [#"{"backend":"future-provider"}"#, #"{"backend":null}"#,
                     #"{"backend":"lmStudio","lmStudio":{"endpoint":{"host":"example.invalid","port":1234},"modelID":"model"}}"#,
                     #"{"backend":"lmStudio","lmStudio":{"endpoint":{"host":"127.0.0.1","port":0},"modelID":"model"}}"#] {
            #expect(throws: (any Error).self) { try JSONDecoder().decode(ModelConfiguration.self, from: Data(json.utf8)) }
        }
    }
    @Test func readinessIdentityIncludesEndpointAndExactModelButIgnoresDormantNativeFields() throws {
        var a = ModelConfiguration(backend: .lmStudio, lmStudio: try .init(endpoint: LMStudioEndpoint(), modelID: "one"))
        var b = a; b.modelPath = "/SYNTHETIC/dormant.litertlm"; b.computeBackend = "gpu"
        #expect(a.inferenceIdentity == b.inferenceIdentity)
        b.lmStudio = try .init(endpoint: LMStudioEndpoint(port: 2345), modelID: "one")
        #expect(a.inferenceIdentity != b.inferenceIdentity)
        b.lmStudio = try .init(endpoint: LMStudioEndpoint(), modelID: "two")
        #expect(a.inferenceIdentity != b.inferenceIdentity)
        a.backend = .liteRTLM
        #expect(a.inferenceIdentity != b.inferenceIdentity)
    }
    @Test func independentDraftEndpointPersistsAndInvalidSavedChoiceRequiresExplicitRecovery() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "relay-provider-preferences-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appending(path: "draft.json")
        let preferences = DraftModelPreferences(location: path)
        let selected = ModelConfiguration(backend: .lmStudio, lmStudio: try .init(endpoint: LMStudioEndpoint(), modelID: "draft-model"))
        preferences.selectLMStudio(selected)
        #expect(DraftModelPreferences(location: path).model?.inferenceIdentity == selected.inferenceIdentity)
        let bad = Data(#"{"version":1,"model":{"backend":"future-provider"}}"#.utf8)
        try bad.write(to: path)
        let invalid = DraftModelPreferences(location: path)
        #expect(invalid.hasInvalidSelection && invalid.model == nil)
        #expect(try Data(contentsOf: path) == bad)
        invalid.useChatModel()
        #expect(!DraftModelPreferences(location: path).hasInvalidSelection)
    }
}
