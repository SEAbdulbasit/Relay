import Testing
@testable import Relay

struct ActivityPresentationTests {
    @Test(arguments: ["finished", "requested", "planning", "observed", "needs input", "stopped", "cancelled", "failed / inspect before retry", "unrecognized"])
    func nonVerifiedOutcomesNeverReceiveSuccessTreatment(status: String) {
        let presentation = ActivityPresentation(name: "Response finished", status: status)
        #expect(!presentation.verified)
        #expect(presentation.icon != "checkmark.circle.fill")
        #expect(presentation.status != "Result checked")
    }

    @Test func responseCompletionIsDifferentFromCheckedToolResult() {
        let response = ActivityPresentation(name: "Response finished", status: "finished")
        let action = ActivityPresentation(name: "search_finder", status: "verified")
        #expect(!response.verified)
        #expect(action.verified)
        #expect(response.status != action.status)
    }

    @Test func failureKeepsFailureTreatmentRatherThanFriendlySuccess() {
        let presentation = ActivityPresentation(name: "read_calendar", status: "failed / inspect before retry")
        #expect(presentation.failed)
        #expect(!presentation.verified)
        #expect(presentation.title == "Read calendar")
    }
}

struct WorkspaceTaskPresentationTests {
    @Test(arguments: [RunPhase.stopped, .failed, .needsInput, .awaitingReview])
    func interruptedRunNeverClaimsLiveExecutionOrCompletion(phase: RunPhase) {
        let status = WorkspaceTaskPresentation(phase: phase).status
        #expect(!status.contains("Using tools"))
        #expect(!status.contains("finished"))
    }

    @Test func planningDoesNotClaimComputerActions() {
        #expect(WorkspaceTaskPresentation(phase: .thinking).status == "Planning the next step…")
        #expect(WorkspaceTaskPresentation(phase: .acting).status == "Using tools for your request…")
    }
}

struct UncertainActivityPresentationTests {
    @Test func uncertainEffectsRequireAttentionWithoutClaimingFailureOrSuccess() {
        let presentation = ActivityPresentation(name: "write_file", status: "effect uncertain")
        #expect(presentation.needsAttention)
        #expect(!presentation.failed)
        #expect(!presentation.verified)
        #expect(presentation.icon == "exclamationmark.triangle")
    }
}
