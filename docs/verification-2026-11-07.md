# Local workflow milestone verification — 7 November 2026

This verifies a bounded implementation milestone. **It does not establish full Sentient OS parity or production integration readiness.** The [260-item source-backed plan](sentient-parity-plan.md) remains the acceptance contract. No Relay account is required.

## Frozen regression and package

- Final default Swift run: **831 executed and passed, 56 explicitly skipped opt-in declarations, 887 registered declarations, 149 suites**, 10.223 seconds. Parameter cases are included beneath declarations and are not added again to the test total.
- Ten Python browser-fixture/release tests passed. The 149 repository scenario checks passed; these inspect source/assets/fixtures and are not native product E2E tests.
- `Scripts/build-app.sh release` built the app and its fixture. Strict deep signature verification passed. This is an ad hoc development signature, not Developer ID signing or notarization.
- The rebuilt app launched, restored existing conversation history, loaded the installed Gemma 4 E4B using its existing GPU setting, and passed its structured-tool readiness probe. A public, tool-free local chat check returned the exact requested sentence.
- Models, Voice, Sidekick and System settings were inspected through the packaged app. Expanded and collapsed Sidekick states were observed. Existing source/voice/shortcut preferences were retained; no macOS permissions were granted and no unrelated app content was read.

## Actual native and browser workflows

The final strict Gemma 4 E2B CPU workflow passed in **84.124 seconds** using the production `AssistantStore`, full native schemas and its default private `MacTools` executor. It performed four real generations and three proposed calls: observe the signed inert fixture, enter exact Unicode text, then request Apply. A product-owned readback preserved the original window and supplied a fresh reference before review. The test approved exactly the expected complete form, independently verified exactly one Apply click and the exact resulting text, observed the result again and checked that an unrelated draft was unchanged. No executor override or fixture-specific product adapter was used.

An earlier frozen run stopped after entering text and correctly failed the independent oracle. The repair adds one bounded whole-request audit after verified effects. Scripted regressions prove continuation after a truthful partial answer, preservation of completed tool pairs, no invented/repeated action and Stop during the audit. The final actual-model run completed directly; it is not represented as a forced real-model partial-answer recovery test.

Additional live qualification passed:

- Ten native scope/form/lifecycle cases in two suites, 11.668 seconds: exact-window readback, foreign/expired/Stop refusal, cached identity, complete-form checkbox/radio/popup/row drift and a workspace view actually appearing/disappearing while its app-owned task continued. Old Apply approvals dispatched zero clicks after drift.
- Original-window browser metadata/background guard, 4.853 seconds: another owned window refused and focus preserved.
- Two disposable Chrome profiles, 8.626 seconds: only the intended profile received the exact synthetic field value; switching profiles refused the bound readback, left the other profile untouched and invalidated references after process closure.

The tests used owned, signed inert apps and loopback profiles. They did not send mail, submit a real web form, inspect personal browser sessions or change system permission settings. Temporary processes/profiles were cleaned up.

## Provider and local-source qualification

- Official signed CLI build `a11ce3314a7adeaca2a1283051ee2f0b41070d5a` passed the production planner sandbox/arguments/catalog/schema against three independent loopback modes: answer, validated Relay proposal and malicious native-shell-call refusal. Native tools advertised: zero. Only fabricated credentials were used in those loopback tests. The unsupported native call was independently observed in the fixture's follow-up request.
- Offline readiness using the existing ChatGPT login and a real public synthetic hosted request passed; the latter took 8.217 seconds. No computer action or private source input was sent.
- The separate native observation client and exact-target adapter passed actual signed-fixture reads, including an unknown fixture token in the native AX text, exact process/window metadata, namespaced references and bounded in-memory JPEG decoding. This is not model vision qualification. **Native mutation and vision-control integration remain incomplete.**
- SiYuan/dependency/drafting regression: 120 executed and passed, three skipped opt-ins, 123 registered, 16 suites, 11.279 seconds. Fixtures cover selected workspaces, open/closed notebooks, database-only drift, provenance and dependent cache/brief withdrawal.
- A separate real local Gemma grounded-draft check passed in 15.440 seconds with exact synthetic facts and one inert insertion. The model-only payload omitted local paths; local revision receipts still controlled validation.

## Reproduce the core checks

Run default checks and package first:

```bash
swift test --scratch-path .build/native-workflow-qa --jobs 3
python3 -m unittest discover -s Scripts/Tests -v
python3 e2e_tests/runner.py
./Scripts/build-app.sh release
codesign --verify --deep --strict build/Relay.app
```

The native tests require the test host's existing Accessibility grant. They never grant it. The selected model must already exist locally:

```bash
relay_model_package=/absolute/path/gemma-4-E2B-it.litertlm
RELAY_RUN_NATIVE_MODEL_TEST=1 RELAY_GEMMA_MODEL_PATH="$relay_model_package" \
  swift test --scratch-path .build/native-workflow-qa --skip-build \
  --filter NativeModelWorkflowIntegrationTests/actualGemmaFillsAndReviewsOneInertNativeFormWithIndependentOutcomeOracle
```

Other opt-ins and their scope are declared with their test fixtures in `Tests/RelayTests`. Do not enable unrelated live/service tests as a batch against personal accounts. Raw machine logs are retained locally under ignored `.build/verification`; no private runtime state is part of this commit.

## Open gates

The packaged Relay app still reported missing its own Accessibility permission. A test host's permission does not establish Relay's permission identity. Physical microphone/notch/multiple-display/Spaces behavior, live service-account integrations, privileged wake, signed distribution/update migration and the open software rows in the parity plan remain unqualified. This milestone must not be labeled “100% parity.”
