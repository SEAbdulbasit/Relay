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

}
