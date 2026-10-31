# Relay for macOS

A native SwiftUI personal assistant with embedded **LiteRT-LM + local Gemma**, a product-owned tool loop, real macOS actions, explicit context grants and verified tool results. This is an early executable alpha, not the HTML design specimen.

## At a glance

- Native macOS chat interface built with SwiftUI.
- Local Gemma inference through Google's LiteRT-LM; no hosted inference account required.
- Desktop-control integration with Vercel Labs' `agent-desktop`, alongside Relay's native Accessibility tools.
- Explicit file and folder grants, inspectable activity, and checked tool outcomes.
- Early alpha: build from source; desktop workflows and hardware support are still being qualified.

## Built with

| Component | Role |
| --- | --- |
| Swift + SwiftUI | Native macOS app and interface |
| [Google LiteRT-LM](https://github.com/google-ai-edge/LiteRT-LM) | Embedded local inference runtime |
| Gemma | Separately downloaded local model in `.litertlm` format |
| [Vercel Labs agent-desktop](https://github.com/vercel-labs/agent-desktop) | Desktop-control CLI, native helper, and C FFI integration |
| macOS Accessibility + AppKit | Native observations, app interaction, and independent checks |

Thanks to the teams behind these projects. Relay is an independent project; these credits do not imply endorsement.

## Build and run

Requires Apple silicon or Intel macOS 15+, Xcode 26+ / Swift 6.2+. The current build is validated on the development Mac; no wider hardware qualification is claimed.

```bash
git clone https://github.com/SEAbdulbasit/Relay.git
cd Relay
./Scripts/build-app.sh
open build/Relay.app
```

Open `Package.swift` in Xcode to edit/debug. No cloud account or inference server is required. First build downloads the pinned official LiteRT-LM macOS binary. The 13-file Swift wrapper is vendored verbatim with Apache-2.0 license and exact upstream commit in `Vendor/LiteRTLM/UPSTREAM.md`; this avoids fetching the upstream repository's large model/history objects. The vendored source commit and official binary checksum pin the dependency. A local build is ad-hoc signed; production distribution needs a developer identity, hardened-runtime qualification and notarization.

### Desktop-control dependency

The repository includes `agent-desktop` 1.0.2 binaries and its Apache-2.0 license under `Vendor/agent-desktop/`. The build script bundles the CLI, macOS helper, and FFI library into Relay.app. To fetch binaries for your Mac's architecture or refresh this version before building:

```bash
./Scripts/update-agent-desktop.sh v1.0.2
./Scripts/build-app.sh
```

The updater downloads official Vercel Labs release archives and verifies their published SHA-256 checksums. Accessibility permission must be granted by the user in macOS System Settings. Integration does not establish support for every application or workflow.

## Set up a model

1. Open Relay. The first-run assistant checks this Mac and explains local inference. Reopen it later from Settings → Run setup assistant.
2. Download the pinned recommended Gemma package (2.59 GB), check an existing downloaded package, or import a **Gemma `.litertlm` package with native tool-call support**. Downloads are explicit; real progress, cancellation and SHA-256 verification are shown. Cancellation restarts the transfer rather than resuming. GGUF/Ollama packages are not compatible.
3. Load and check the model. Relay initializes the embedded engine and requests a side-effect-free structured-call probe. A saved model path does not count as a loaded model after relaunch. Recommended setup starts with CPU; GPU remains available in Settings for supported packages.
4. Review Accessibility access and optionally run the independent local control fixture. You can skip computer control and add selected files later; no broad disk permission is requested.
5. Choose a first request. Setup puts it in chat without executing it. You send it when ready. Setup can be dismissed and reopened without deleting conversation history.

Models stay outside the app bundle. The app uses native URLSession for the explicit recommended-model download, validates byte count and SHA-256, and refuses to overwrite an unknown existing model. The development alternative downloads the same pinned public Gemma 4 E2B package using `python3 Scripts/download-gemma.py`, checks the published SHA-256 and records provenance under `~/Library/Application Support/Relay/Models/`. No account, hosted inference or license click-through is required for that public Apache-2.0 artifact. A successful probe does not establish vision, task accuracy or support for every Mac application. The app currently consumes text and accessibility observations; screenshot/vision inference is not implemented. LiteRT-LM's non-streaming API is deliberate: the pinned SDK streaming callback can auto-execute tools despite its flag. Native tools in Relay are schema-only at the SDK layer, and only Relay's executor dispatches actions.

## Use it

Speak naturally in one conversation. The imported model dynamically chooses available tools; there is no keyword router or mandatory template selection.

- “Open VLC.” App launch is checked using NSWorkspace process state.
- Attach a text document or text-based PDF, then ask for a summary.
- Add a folder and explicitly enable writing in Context before asking Relay to create a Markdown, text or CSV file. Existing-file replacement requires review; bytes are read back independently.
- “Fill the form in Safari using this attached document, and leave it unsubmitted.” Grant Accessibility to Relay in System Settings when requested. The app must expose accessible editable controls. Each text entry is read back, fresh observations are required after mutations, secure controls are excluded, and final controls are left for the user to activate manually.
- Attach a media file and ask to open it in VLC/QuickTime. Known exact playback buttons can be used without repeated confirmation. Launching a player is never labeled as verified playback.

Ordinary scoped observations, app opening, new-file creation, supported scrolling and text entry can run autonomously. URL navigation and existing-file replacement show a review bound to the exact request and state captured before review. Generic UI presses, including sending, publishing and final form submission, remain manual until destination/content binding is qualified. These conservative review rules intentionally exceed the final product's intended intervention rate while app-specific capabilities are qualified. Obvious financial, security and destructive controls are excluded, not unlocked by approval.

During execution you can send a follow-up instruction. Relay cancels old planning, waits for any in-flight tool to settle, invalidates approvals and resumes with the new constraint. **Stop** blocks new dispatch immediately; an in-progress operation may finish. Resume asks the model to refresh state; stale UI references cannot be reused. Crash recovery never replays unfinished mutations automatically.

Activity shows actual tool evidence, errors and uncertain effects. The model response is accompanied by software-generated checked outcomes. A “finished” run is not a claim that an arbitrary user goal or an evaluation suite has passed.

## Boundaries

- All inference is embedded and local. No hosted fallback, API-key field or inference network client exists.
- User-requested websites may be opened after destination review; the browser may use the internet and an existing session. Network dependence differs from local inference.
- Files are limited to explicitly granted paths, resolved against symlink escape. No broad disk scan.
- Text/PDF extraction and output are bounded. Scanned PDFs need OCR, which is not implemented.
- AX control requires user-granted Accessibility. Canvas apps, inaccessible controls and unsupported scrolling report limitations; no screenshot-coordinate fallback is claimed.
- No unrestricted shell, scheduled work, purchases, account administration, automatic passwords or mobile app.
- No persistent screenshots or telemetry. Conversation, activity, explicit memory and grants are stored locally in `~/Library/Application Support/Relay/state.json` with user-only permissions. Clear Conversation removes conversation/activity; memory and context are removable separately. Selected originals stay in place. No task content becomes memory automatically.
- File/model loading and native inference can fail or run slowly. Task loop and model inference have budgets; already-applied changes are not rolled back.

## Verification

```bash
swift test
# Optional native CPU initialization test using a compatible test fixture:
RELAY_LITERT_TEST_MODEL=/absolute/path/test.litertlm swift test
```

Tests cover action dispatch after Stop, false model narratives, interrupted-state restore, schema/scope/symlink checks, review invalidation, file/PDF readback and native model-message handling. Release targets in `planning/` are future gates, not achieved performance claims.

## Accessibility interaction checks

See [the test cases](planning/accessibility-test-plan.md). Settings → Access → **Run accessibility check** operates a bundled harmless native window: real text entry, a reviewed Apply click, AX readback plus an independent JSON oracle, stale/disabled control rejection, review drift and queued-click invalidation. It needs user-granted Accessibility. No model is used for this controller test.

`search_finder` opens Finder and enters the requested query through its visible accessibility search field. It confirms the query, not the existence of a matching file. Actual Finder execution is an explicit desktop integration test; model planning is tested separately.

Benign named AXButton clicks are now available with complete window/editable-field review binding. Incomplete/secure/oversized contexts refuse. Final submission, sends, publication and consequential controls remain excluded.


## Repository layout

| Path | Contents |
| --- | --- |
| `Sources/Relay/` | SwiftUI app, local model loop, tool execution, and desktop bridge |
| `Sources/RelayAccessibilityFixture/` | Native fixture for Accessibility checks |
| `Tests/` | Swift test suite |
| `Scripts/` | Build, dependency updates, model download, and release tooling |
| `Vendor/` | Third-party runtime wrappers and desktop-control dependencies |
| `Resources/` | App metadata, icons, and third-party notices |
| `website/` | Static project website |
| `planning/` | Product plans, design artifacts, and qualification notes |
| `e2e_tests/` | Additional Python validation scenarios |
| `TestWorkspace/` | Small manual verification fixtures |

## Contributing

Issues and pull requests are welcome. Include your macOS version, Mac architecture, model package, reproduction steps, and expected versus observed behavior. Remove personal conversation content and file paths from logs before sharing them. For code changes, run `swift test` and describe any manual checks; desktop integration checks require a Mac and user-granted permissions.

## Third-party licenses

LiteRT-LM and Vercel Labs' `agent-desktop` include their Apache-2.0 licenses in `Vendor/`. See [third-party notices](Resources/ThirdPartyNotices.txt) and [LiteRT-LM provenance](Vendor/LiteRTLM/UPSTREAM.md). Model packages are downloaded separately and carry their own publisher's terms. This repository currently does not declare a license for Relay's original code.
