# Native summary and vision reliability investigation

The coordinator's initial full-suite baseline recorded 16 issues in `NativeDocumentSummaryCoordinatorTests` and two issues in `NativeVisionPlanningTests`. That run is preserved at `/tmp/relay-reliability-baseline-full.log`. The summary failures clustered at the test helper's three-second deadline; the vision assertions concerned text/vision/text runtime identity and routing.

## Changes

`LocalModelClient.load` previously had an uncommitted shortcut that accepted an already loaded vision runtime for a subsequent text-mode request. That contradicted its separate runtime factories and the explicit text/vision/text boundary test. The shortcut alone was removed. Exact model/backend/mode identities now govern reuse; text after vision reloads the text runtime, preserving text-mode routing. No assertion or expected result was weakened.

`NativeDocumentSummaryCoordinatorTests.until` used a hot MainActor `Task.yield` poll while the subject handed work to detached capture/grouping tasks and back to MainActor. The helper now actually suspends for one millisecond between observations. The same three-second deadline, final condition, source identity, coverage, generation count, and output assertions remain in place. This reduces test-generated ready-queue pressure; it is not a production timeout extension.

## Verification record

An initial isolated test attempt stopped at an onboarding binding compile error, corrected by using explicit get/set and `suggestions.setEnabled`. The next attempt stopped at an undefined power-source constant in the independently owned scheduler lane; that owner was notified. Neither attempt reached tests and neither establishes an isolated test outcome.

Final isolated results will be appended after the integrated compile succeeds. The intended command is `swift test -j 6 --filter 'NativeDocumentSummaryCoordinatorTests|NativeVisionPlanningTests'`, with output at `/tmp/relay-reliability-summary-isolated.log`.

Final isolated run: **PASS**, exit code 0. The command above completed its integrated build in 169.22 seconds, then all **15 tests in two suites passed in 0.050 seconds**. Native summary cases completed within 0.049 seconds and native vision cases within 0.045 seconds. The text/vision/text identity and content assertions passed unchanged. This confirms the fixes in the isolated integrated build; full-suite load behavior remains for the coordinating reviewer to re-run. No real native app data, model weights, provider request, or screenshot was used by these inert fixtures.
