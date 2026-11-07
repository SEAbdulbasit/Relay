import Foundation
import Testing
@testable import Relay

struct NativeTextAreaReviewAvailabilityTests {
    @Test func qualifiedTextareaKeepsEnabledUnknownAndItsProofInTheReviewFingerprint() throws {
        #expect(NativeTextAreaReviewAvailability.accepts(proof))
        let field = AXReviewField(identity: "original-window|draft|AXTextArea", label: "Existing draft",
            value: "Exact original café 🌍", enabled: nil, availabilityEvidence: .writableNativeTextArea)
        #expect(field.enabled == nil && field.availabilityDescription.contains("AXEnabled not reported"))
        let encoded = try JSONDecoder().decode([String: JSONValue].self, from: JSONEncoder().encode(field))
        #expect(encoded["enabled"] == nil && encoded["availabilityEvidence"] == .string("writableNativeTextArea"))
        let context = AXReviewContext(windowIdentity: "owned-window", title: "Fixture", buttonFingerprint: "Apply", fields: [field])
        var assumed = field
        assumed.enabled = true
        assumed.availabilityEvidence = nil
        var missingProof = field
        missingProof.availabilityEvidence = nil
        #expect(context.fingerprint != AXReviewContext(windowIdentity: context.windowIdentity, title: context.title,
            buttonFingerprint: context.buttonFingerprint, fields: [assumed]).fingerprint)
        #expect(context.fingerprint != AXReviewContext(windowIdentity: context.windowIdentity, title: context.title,
            buttonFingerprint: context.buttonFingerprint, fields: [missingProof]).fingerprint)
    }

    @Test(arguments: ["role", "advertised", "query-failed", "nontext", "readonly-value", "nonfocusable",
                      "readonly-selection", "invalid-range", "secure", "detached"])
    func missingEnabledCannotBypassAnyRequiredNativeTextareaCapability(reason: String) {
        var candidate = proof
        switch reason {
        case "role": candidate.role = "AXTextField"
        case "advertised": candidate.enabledResponse = .advertised
        case "query-failed": candidate.enabledResponse = .failed
        case "nontext": candidate.valueIsText = false
        case "readonly-value": candidate.valueWritable = false
        case "nonfocusable": candidate.focusWritable = false
        case "readonly-selection": candidate.selectionWritable = false
        case "invalid-range": candidate.validSelection = false
        case "secure": candidate.secure = true
        case "detached": candidate.attachedToOriginalWindow = false
        default: Issue.record("Unknown capability-refusal case")
        }
        #expect(!NativeTextAreaReviewAvailability.accepts(candidate))
    }

    private var proof: NativeTextAreaReviewAvailability.Proof {
        .init(role: "AXTextArea", enabledResponse: .absent, valueIsText: true, valueWritable: true,
            focusWritable: true, selectionWritable: true, validSelection: true, secure: false, attachedToOriginalWindow: true)
    }
}
