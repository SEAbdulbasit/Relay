import Foundation
import Testing
@testable import Relay

struct DiagnosticsTests {
    @Test func technicalStatusesExportAsLocalJSONWithoutCollectingAnything() throws {
        var input = DiagnosticsInput()
        input.appVersion = "0.2.1"
        input.appBuild = "42"
        input.runtimeVersion = "0.18.1"
        input.osVersion = "27.0"
        input.architecture = .appleSilicon
        input.computeBackend = .cpu
        input.modelSelected = true
        input.modelLoaded = true
        input.toolProbe = .passed
        input.accessibility = .allowed
        input.microphone = .notRequested
        input.runState = .idle
        input.indexedSourceCount = 3
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        let data = try LocalDiagnostics.exportJSON(input, generatedAt: when)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["app"] as? String == "Relay")
        #expect(object["runtimeVersion"] as? String == "0.18.1")
        #expect(object["inferenceMode"] as? String == "localOnly")
        #expect(object["accessibility"] as? String == "allowed")
        #expect(object["indexedSourceCount"] as? Int == 3)
        #expect(data.count < 16_384)
        #expect(!data.isEmpty)
    }

    @Test func personalPathsChatSecretsAndURLsAreRejectedRatherThanPartiallyRedacted() throws {
        let sensitive = [
            "/Users/Alice/Private/medical-notes.md", "file:///Users/Alice/model.litertlm",
            "C:\\Users\\Alice\\private.txt", "https://private.example/?token=abc123",
            "My password is very-secret", "0.2.1\nPRIVATE_CHAT_MARKER", "0.2+Alice", "0.2.1 /tmp/session",
            "~/Documents/private", "إصدار خاص", String(repeating: "sensitive", count: 100)
        ]
        for value in sensitive {
            var input = DiagnosticsInput()
            input.appVersion = value
            input.appBuild = value
            input.runtimeVersion = value
            input.osVersion = value
            let report = LocalDiagnostics.makeReport(input)
            #expect(report.appVersion == "[omitted]")
            #expect(report.appBuild == "[omitted]")
            #expect(report.runtimeVersion == "[omitted]")
            #expect(report.osVersion == "[omitted]")
            let json = String(decoding: try LocalDiagnostics.exportJSON(input), as: UTF8.self)
            #expect(!json.contains(value))
            #expect(!json.contains("Alice"))
            #expect(!json.contains("PRIVATE_CHAT_MARKER"))
            #expect(!json.contains("abc123"))
        }
    }

    @Test func unsupportedVersionSyntaxAndUnicodeDigitsCannotSmuggleMetadata() {
        for value in ["", " 1.2.3 ", "1..2", ".1", "1.", "1.2.3.4.5", "١.٢", "１２.３", "1.2-beta", "999999999"] {
            var input = DiagnosticsInput()
            input.appVersion = value
            #expect(LocalDiagnostics.makeReport(input).appVersion == "[omitted]")
        }
        #expect(LocalDiagnostics.makeReport(DiagnosticsInput()).appVersion == nil)
        #expect(LocalDiagnostics.makeReport(DiagnosticsInput()).modelLoaded == nil)
    }

    @Test func issueCodesProduceFixedRecoveryWithoutRawErrorsAndCountsAreBounded() throws {
        var input = DiagnosticsInput()
        input.issues = Array(repeating: .modelLoadFailed, count: 500) + [.localPersistenceFailed]
        input.indexedSourceCount = -10
        input.approvedMemoryCount = Int.max
        input.recentActivityCount = Int.min
        input.recentFailureCount = Int.max
        let report = LocalDiagnostics.makeReport(input)
        #expect(report.issues.count == 1)
        #expect(report.issues.first?.code == .modelLoadFailed)
        #expect(report.issues.first?.recovery.contains("CPU/GPU") == true)
        #expect(report.indexedSourceCount == 0)
        #expect(report.approvedMemoryCount == 1_000_000)
        #expect(report.recentActivityCount == 0)
        #expect(report.recentFailureCount == 1_000_000)
        #expect(try LocalDiagnostics.exportJSON(input).count < 16_384)
    }

    @Test func exportSchemaHasNoContentPathOrIdentifierSlots() throws {
        let object = try #require(JSONSerialization.jsonObject(with: LocalDiagnostics.exportJSON(DiagnosticsInput())) as? [String: Any])
        let keys = Set(object.keys)
        #expect(keys.isDisjoint(with: ["messages", "chat", "selectedText", "sourceText", "sourcePaths", "modelPath", "modelName", "username", "deviceID", "serialNumber", "errorMessage", "writingSamples"]))
        #expect(object["privacyNotice"] as? String != nil)
    }
}
