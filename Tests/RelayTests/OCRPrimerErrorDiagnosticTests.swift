import CoreGraphics
import Foundation
import Testing
@testable import Relay

@MainActor struct OCRPrimerErrorDiagnosticTests {
    @Test func actualNSErrorRootAndAtMostThreeUnderlyingSDKIdentifiersAreRetainedWithoutPrivateUserInfo() throws {
        var error = NSError(domain: "SDK.Bottom", code: 7, userInfo: [NSLocalizedDescriptionKey: "PRIVATE_DESCRIPTION", "path": "/PRIVATE_SOURCE"])
        for index in (0..<6).reversed() {
            error = NSError(domain: "TextRecognition.Layer\(index)", code: index,
                userInfo: [NSUnderlyingErrorKey: error, NSLocalizedFailureReasonErrorKey: "PRIVATE_REASON"])
        }
        let records = LocalOCRExecution.primerSDKErrorRecords(error)
        #expect(records.count == 4)
        #expect(records.map(\.domain) == ["TextRecognition.Layer0", "TextRecognition.Layer1", "TextRecognition.Layer2", "TextRecognition.Layer3"])
        #expect(records.map(\.code) == [0, 1, 2, 3])
        let encoded = try JSONEncoder().encode(records), text = String(decoding: encoded, as: UTF8.self)
        #expect(!text.contains("PRIVATE") && !text.contains("userInfo") && !text.contains("description"))
        #expect(encoded.count < 1_024)
    }
    @Test(arguments: ["", "/private/path", "SDK Value", "SDK\nField", "SDK.Caf\u{00e9}", String(repeating: "x", count: 129)])
    func invalidOrOversizedDomainsAreReplacedInsteadOfTruncated(_ domain: String) {
        let records = LocalOCRExecution.primerSDKErrorRecords(NSError(domain: domain, code: -42))
        #expect(records == [.init(domain: "unavailable", code: -42)])
    }
    @Test func maximumBoundedASCIISDKIdentifierIsPreservedExactly() {
        let domain = "SDK." + String(repeating: "A", count: 124)
        let records = LocalOCRExecution.primerSDKErrorRecords(NSError(domain: domain, code: Int.min))
        #expect(records == [.init(domain: domain, code: Int.min)])
    }
    @Test func onlyActualGeneratedPrimerFailureGetsSDKDiagnosticsAndOrdinaryPrivateJobsStayClosed() async throws {
        let error = NSError(domain: "TextRecognition.CRImageReaderError", code: 1,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: "SDK.Underlying", code: -9),
                NSLocalizedDescriptionKey: "PRIVATE_DESCRIPTION", "body": "PRIVATE_BODY"])
        let ordinary = LocalOCRExecution { _ in throw error }
        let image = try DocumentOCRPreparation.makeBitmap(text: "Owned diagnostic bitmap")
        await #expect(throws: LocalOCRExecution.Failure.recognitionUnavailable) {
            _ = try await ordinary.recognize(image: image, orientation: .up, profile: .document)
        }
        await ordinary.drain()
        #expect(ordinary.documentPreparationChecks.isEmpty && ordinary.accountedPixelBytes == 0)
        let primer = LocalOCRExecution(requiresDocumentReadiness: true) { _ in throw error }
        await #expect(throws: LocalOCRExecution.Failure.documentRecognitionUnavailable) {
            try await primer.prepareDocumentReadiness()
        }
        await primer.drain()
        let check = try #require(primer.documentPreparationChecks.first)
        #expect(check.sdkErrorDomain == "TextRecognition.CRImageReaderError" && check.sdkErrorCode == 1)
        #expect(check.sdkUnderlyingErrors == [.init(domain: "SDK.Underlying", code: -9)])
        let encoded = String(decoding: try JSONEncoder().encode(primer.documentPreparationChecks), as: UTF8.self)
        #expect(!encoded.contains("PRIVATE") && !encoded.contains("description") && !encoded.contains("body"))
        #expect(primer.activeCount == 0 && primer.accountedPixelBytes == 0)
    }
}
