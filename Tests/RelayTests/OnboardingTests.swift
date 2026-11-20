import Foundation
import Testing
@testable import Relay

@MainActor
struct OnboardingTests {
    @Test func compatibilityDistinguishesArchitectureOSAndMemory() {
        let gb: UInt64 = 1_073_741_824
        #expect(MacReadiness.evaluate(architecture: "arm64", osMajor: 15, memoryBytes: 16 * gb, freeBytes: 10_000_000_000).supported)
        #expect(!MacReadiness.evaluate(architecture: "Intel", osMajor: 27, memoryBytes: 32 * gb, freeBytes: 10_000_000_000).supported)
        #expect(!MacReadiness.evaluate(architecture: "arm64", osMajor: 14, memoryBytes: 32 * gb, freeBytes: 10_000_000_000).supported)
        #expect(!MacReadiness.evaluate(architecture: "arm64", osMajor: 27, memoryBytes: 4 * gb, freeBytes: 10_000_000_000).supported)
    }

    @Test func firstRunPersistsProgressAndCanReopenWithoutNetworking() throws {
        let suite = "relay-onboarding-test-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = OnboardingCoordinator(defaults: defaults)
        #expect(!first.completed)
        #expect(first.step == 0)
        #expect(first.download.phase == .idle)
        first.step = 2
        let resumed = OnboardingCoordinator(defaults: defaults)
        #expect(resumed.step == 2)
        #expect(resumed.download.phase == .idle)
        resumed.finish()
        let completed = OnboardingCoordinator(defaults: defaults)
        #expect(completed.completed)
        completed.returnToSetup()
        #expect(!completed.completed)
        #expect(completed.step == 0)
        #expect(completed.download.phase == .idle)
    }

    @Test func calculatorTrialUsesCheckedProductionToolAndRecoversFromInvalidInput() async throws {
        let suite = "relay-onboarding-calculator-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let setup = OnboardingCoordinator(defaults: defaults)
        if case .idle = setup.calculatorTrial {} else { Issue.record("Trial must not run on initialization") }
        await setup.tryLocalCalculator("1 / 0")
        if case .failed = setup.calculatorTrial {} else { Issue.record("Invalid arithmetic must remain retryable") }
        await setup.tryLocalCalculator("(18 + 24) * 3")
        guard case .checked(let expression, let result) = setup.calculatorTrial else {
            Issue.record("Expected real checked tool output")
            return
        }
        #expect(expression == "(18 + 24) * 3")
        #expect(result.summary == "Result: 126")
        #expect(result.verified)
        #expect(result.evidence.contains("Calculated locally"))
        #expect(setup.download.phase == .idle)
        #expect(!setup.completed)
    }

    @Test func calculatorTrialRejectsUncheckedToolResult() async throws {
        let suite = "relay-onboarding-calculator-unchecked-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let setup = OnboardingCoordinator(defaults: defaults)
        await setup.tryLocalCalculator("2 + 2", execute: { _ in
            ToolResult(summary: "Claimed result", evidence: "Unchecked", verified: false)
        })
        guard case .failed(let message) = setup.calculatorTrial else {
            Issue.record("Unchecked result must not be presented as success")
            return
        }
        #expect(message.contains("unchecked"))
    }

    @Test func interruptedSetupKeepsProviderAndModelChoice() throws {
        let suite = "relay-onboarding-choices-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let hardware = MacReadiness.evaluate(architecture: "arm64", osMajor: 15,
                                            memoryBytes: 16 * 1_073_741_824, freeBytes: 20_000_000_000)
        let first = OnboardingCoordinator(defaults: defaults, hardware: hardware)
        first.selectedProvider = .lmStudio
        first.selectedGemmaVariant = .gemma4E2B
        first.step = 1

        let resumed = OnboardingCoordinator(defaults: defaults, hardware: hardware)
        #expect(resumed.selectedProvider == .lmStudio)
        #expect(resumed.selectedGemmaVariant.filename == ModelManifest.gemma4E2B.filename)
        #expect(resumed.step == 1)
        #expect(resumed.download.phase == .idle)
        #expect(!resumed.completed)
    }

    @Test func invalidSavedModelChoiceFallsBackToHardwareRecommendation() throws {
        let suite = "relay-onboarding-invalid-model-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("missing-model.litertlm", forKey: OnboardingCoordinator.gemmaVariantKey)
        let hardware = MacReadiness.evaluate(architecture: "arm64", osMajor: 15,
                                            memoryBytes: 16 * 1_073_741_824, freeBytes: 20_000_000_000)
        let resumed = OnboardingCoordinator(defaults: defaults, hardware: hardware)
        #expect(resumed.selectedGemmaVariant.filename == ModelManifest.gemma4E4B.filename)
    }

    @Test func damagedSavedStepCannotEscapeSetupScreens() throws {
        let suite = "relay-onboarding-test-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(999, forKey: "relay.setup.step")
        #expect(OnboardingCoordinator(defaults: defaults).step == 4)
        defaults.set(-99, forKey: "relay.setup.step")
        #expect(OnboardingCoordinator(defaults: defaults).step == 0)
    }
    @Test func usingCurrentVerifiedModelDoesNotRehashOrReplaceChosenBackend() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let spec = ModelManifest(displayName: "Fixture", filename: "fixture.litertlm", sourceURL: URL(string: "https://example.com/fixture.litertlm")!, size: 3,
                                 sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        try Data("abc".utf8).write(to: directory.appendingPathComponent(spec.filename))
        let download = ModelDownload(manifest: spec, directory: directory)
        await download.verifyExisting()
        let suite = "relay-onboarding-test-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let hardware = MacReadiness.evaluate(architecture: "arm64", osMajor: 15, memoryBytes: 16 * 1_073_741_824, freeBytes: 10_000_000_000)
        var loads = 0
        let onboarding = OnboardingCoordinator(defaults: defaults, hardware: hardware, download: download, prepare: { store in
            loads += 1
            store.actionsReady = true // Synthetic readiness only; does not run a local model.
        })
        let store = AssistantStore(persistenceURL: nil)
        store.configuration.computeBackend = "gpu"
        await onboarding.useInstalledModel(store: store)
        #expect(loads == 1)
        #expect(download.verificationAttempts == 1)
        #expect(store.configuration.modelPath == download.destinationURL.path)
        #expect(store.configuration.computeBackend == "gpu")
        #expect(!onboarding.isPreparingModel)
        #expect(onboarding.modelSetupError == nil)
    }

    @Test func supportsGemma4E2BAndE4BDownloadersHardwareRecommendationsAndModelActivation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let e2bSpec = ModelManifest(
            displayName: "Gemma 4 E2B",
            filename: ModelManifest.gemma4E2B.filename,
            sourceURL: URL(string: "https://example.com/e2b.litertlm")!,
            size: 3,
            sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        let e4bSpec = ModelManifest(
            displayName: "Gemma 4 E4B",
            filename: ModelManifest.gemma4E4B.filename,
            sourceURL: URL(string: "https://example.com/e4b.litertlm")!,
            size: 3,
            sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )

        let e2bDownload = ModelDownload(manifest: e2bSpec, directory: directory)
        let e4bDownload = ModelDownload(manifest: e4bSpec, directory: directory)

        let suite = "relay-onboarding-variants-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let gb: UInt64 = 1_073_741_824
        let hardware8GB = MacReadiness.evaluate(architecture: "arm64", osMajor: 15, memoryBytes: 8 * gb, freeBytes: 20_000_000_000)
        let hardware16GB = MacReadiness.evaluate(architecture: "arm64", osMajor: 15, memoryBytes: 16 * gb, freeBytes: 20_000_000_000)

        let coordinator8 = OnboardingCoordinator(defaults: defaults, hardware: hardware8GB, download: e2bDownload, e4bDownload: e4bDownload)
        #expect(coordinator8.recommendedGemmaVariant.filename == ModelManifest.gemma4E2B.filename)
        #expect(coordinator8.selectedGemmaVariant.filename == ModelManifest.gemma4E2B.filename)

        var activatedLoads = 0
        let coordinator16 = OnboardingCoordinator(
            defaults: defaults,
            hardware: hardware16GB,
            download: e2bDownload,
            e4bDownload: e4bDownload,
            prepare: { store in
                activatedLoads += 1
                store.actionsReady = true
            }
        )
        #expect(coordinator16.recommendedGemmaVariant.filename == ModelManifest.gemma4E4B.filename)
        #expect(coordinator16.selectedGemmaVariant.filename == ModelManifest.gemma4E4B.filename)
        #expect(coordinator16.downloader(for: .gemma4E2B) === e2bDownload)
        #expect(coordinator16.downloader(for: .gemma4E4B) === e4bDownload)
        #expect(!coordinator16.isModelInstalled(e2bSpec))
        #expect(!coordinator16.isModelInstalled(e4bSpec))

        // Install and verify E4B fixture, then test isModelInstalled(_:) and activateModel(_:store:)
        try Data("abc".utf8).write(to: directory.appendingPathComponent(e4bSpec.filename))
        await e4bDownload.verifyExisting()
        #expect(coordinator16.isModelInstalled(e4bSpec))
        #expect(!coordinator16.isModelInstalled(e2bSpec))

        let store = AssistantStore(persistenceURL: nil)
        await coordinator16.activateModel(e4bSpec, store: store)
        #expect(activatedLoads == 1)
        #expect(coordinator16.selectedGemmaVariant.filename == e4bSpec.filename)
        #expect(store.configuration.backend == .liteRTLM)
        #expect(store.configuration.modelPath == e4bDownload.destinationURL.path)
        #expect(store.configuration.model == e4bSpec.displayName)
        #expect(coordinator16.modelSetupError == nil)

        // Install and verify E2B fixture, then activate E2B as well
        try Data("abc".utf8).write(to: directory.appendingPathComponent(e2bSpec.filename))
        await e2bDownload.verifyExisting()
        #expect(coordinator16.isModelInstalled(e2bSpec))

        await coordinator16.activateModel(e2bSpec, store: store)
        #expect(activatedLoads == 2)
        #expect(coordinator16.selectedGemmaVariant.filename == e2bSpec.filename)
        #expect(store.configuration.modelPath == e2bDownload.destinationURL.path)
        #expect(store.configuration.model == e2bSpec.displayName)
        #expect(coordinator16.modelSetupError == nil)
    }

}
