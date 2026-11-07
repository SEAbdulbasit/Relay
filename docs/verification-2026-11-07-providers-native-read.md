# Local provider and ordinary native-read verification

Follow-up to `e43459f95d674a07dabf43bf5b97f86c17dee59c`, against the unchanged Sentient OS source baseline `6214cc8b6bf30769f2af2272273931c41d14e744`. This is a scoped implementation and qualification record. **Full parity and release integration readiness remain open.** No Relay account was introduced.

## Behavior in this batch

- An optional keyless LM Studio connection supports chat, structured task calls, text actions, an independently selected drafting model and transient image inspection. The endpoint is an explicit literal loopback address and port. Discovery does not load a model or establish tool/vision capability. Selection never starts a server, copies CLI credentials, follows endpoint redirects or silently falls back to the embedded model.
- One inference router serializes the selected embedded/server runtime across chat, auxiliary work, drafting and native vision. Provider/configuration/source identity, Stop and drain are checked around asynchronous results and errors. A transport admission cannot unsend bytes already handed to a local server. LM Studio's own downstream data handling is outside Relay's loopback transport guarantee.
- Structured protocol IDs are compared as exact UTF-8 bytes. Model catalog/picker/capability identity, tool call/result IDs, core compaction and interrupted-result reconciliation do not alias NFC/NFD spellings. Result names must match the original call. A scripted interruption test confirms one dispatch with distinct settled/unconfirmed receipts for byte-distinct IDs.
- The ordinary local planner advertises `inspect_native_window`. App-owned task authority binds the actual admitted app process, launch and canonical application path. A tool-free specialist interprets transient exact-window pixels/text and returns one ordinary tool result, so the main planner can continue compound work. Single- and multi-agent runs share their task reader. The result explicitly distinguishes verified capture scope from potentially inaccurate model interpretation.
- Native read failures return bounded actionable text. A definitely broken read connection is retired; only a later explicit read opens another connection. The failing request is not internally replayed. Images remain memory-only and are absent from persisted history and feedback.
- Provider labels and settings copy are consistent across the workspace and Sidekick. Switching provider clears the prior provider's stale service error while retaining the embedded model choice.
- Native window inventories explicitly state that child controls have not been inspected and show the scoped full-read step. Window IDs remain inspection/focus references, never editable text controls. Generic planner guidance now distinguishes already-running apps from apps that need launching; this did not resolve the strict CPU launch proposal described below.

The generic native action controller, its AX insertion capability and the durable SQLite journal are **not promoted in this batch**. The ordinary planner's new visual read is not a general visual action loop. Hosted Codex tasks do not receive the local native-read tool.

## Frozen source and test host

The first expanded-catalog qualified-host source manifest is `.build/verification/native-expanded-catalog-qualified-host-source.json`, covering 348 package/source/vendor inputs. That rebuilt host SHA-256 is `d122e04c2cf13efb5201ac64e416d5d3561e86d762578ecb9c6ac0645656687c`. New native-read model and Store suites were positively verified in that binary before any `--skip-build` runtime claim.

The earlier host was stale: it contained neither the new model test nor its registered Store suite. It was rejected as evidence and rebuilt. Its SHA-256 was `d20968fb763accd480e60e4dbcf68358d2429019eb6e171a74cb4c5de75b05ec`. The current-host focused build passed 22 executed declarations with nine opt-in skips out of 31 registered, in 0.536 seconds. See `native-expanded-catalog-qualified-host-build.log`.

After the inventory guidance and diagnostic/setup changes, the current host is `9eb4013ef5d0273fd65a0b6bdd20157f66ddda6a428cb37f343c3e5ff51480f5`. Root independently verified all 348 source hashes, host and complete default log against `native-form-diagnostic-qualified-host.json` (SHA-256 `21a0054559e49f391efbe96ad3b62b73a8c66e7e7ebd690bb6ddd87f49688407`).

The current complete native SDK tool schema is 15,519 bytes and system prompt 3,196 bytes, leaving 5,861 bytes for history. The capacity check retains the full 4,396-byte fresh target-last observation and 5,100-byte next-turn history. This is a bounded fixture capacity check, not proof of unlimited task context. The first expanded-catalog host had a 15,456-byte schema and 6,027-byte history budget; its results below are labeled separately.

## Regression and protocol evidence

All logs below are under `.build/verification/` unless another location is given. Counts distinguish registered declarations from executed cases; opt-in native/service/hardware cases are not silently counted as passes.

| Gate | Observed result | Log |
|---|---|---|
| Exact core call/result identity | 59 declarations, 11 suites, 0.987 s | `exact-core-protocol-ids-focused.log` |
| Full pre-provider core regression | 972 registered; 910 executed, 62 skips; 159 suites, 17.171 s | `exact-core-protocol-ids-default.log` |
| Isolated final LM Studio candidate | 85 registered; 84 executed, one model skip; 13 suites, 2.553 s; includes four actual HTTP cases | `.build/lmstudio-next/integration-qa/` final qualification |
| Integrated provider regression | 1,034 registered; 968 executed, 66 skips; 167 suites, 15.712 s | `local-provider-integrated-default.log` |
| Actual loopback HTTP integration | Four passed, 2.146 s | `local-provider-integrated-http.log` |
| Python loopback fixtures | Ten passed, 3.068 s | `local-provider-python.log` |
| Stale provider error regression | 20 declarations, three suites, 0.563 s | `local-provider-switch-error-focused.log` |
| Isolated native-read integration | 97 registered; 89 executed, eight skips; 21 suites, 1.268 s | `.build/native-planner-next/apply-ready/QUALIFICATION.md` |
| Initial combined native-read default regression | 1,057 registered; 990 executed, 67 skips; 173 suites, 16.018 s | `native-read-integrated-default.log` |
| Repository/static checks | 149 passed, 1.93 s | `native-read-repository-checks.log` |
| Inventory guidance default regression | 1,059 registered; 991 executed, 68 skips; 173 suites, 22.717 s | `native-window-inventory-default.log` |
| Owned window inventory → refused window write → explicit control read | One passed, 0.722 s; zero pointer, text, click, result or draft changes | `native-window-inventory-zero-effect-live.log` |
| Final guidance/diagnostic default regression | 1,060 registered; 992 executed, 68 skips; 173 suites, 17.826 s | `native-form-diagnostic-default.log` |
| Updated repository/static checks | 149 passed, 1.93 s | `native-inventory-repository-checks.log` |
| Final repository/static checks | 149 passed, 1.91 s | `provider-native-read-final-repository-checks.log` |

The repository checks inspect source and fixture behavior; they are not native desktop end-to-end evidence. One older account-free settings wording expectation initially failed after the explanatory sentence changed. That source-only expectation was corrected. The retained original failure is not represented as a product workflow failure or hidden by the corrected run.

The HTTP fixtures exercise the actual transport using synthetic loopback inputs: strict UTF-8/SSE and terminal structured calls, exact opaque IDs, redirects/auth refusal, cancellation, source/configuration changes and image capability receipts. A synthetic protocol pass does not establish real LM Studio model quality.

## Actual model and owned native workflows

### Ordinary planner: image-only code to exact artifact

Actual Gemma 4 E4B GPU passed the production Store/native reader/local inference workflow in **146.476 seconds** (148.551 seconds including wrapper). The marker was generated inside an owned fixture window and absent from initial planner context and the independent accessible-text probe. The planner made four primary generations, one explicit native visual read and one exact scoped artifact write. The final answer included the code; file bytes matched the independent oracle exactly. UI input, form changes and Apply count remained zero. Owned fixture and temporary artifact cleanup assertions passed.

The planner received the production local tool catalog. A qualification guard refused any model proposal outside the owned app/read/artifact destination before dispatch; it did not supply the marker, modify a reply or replace the production executor. The fixture's visual answer and exact output were checked independently. See `native-expanded-catalog-read-artifact-e4b-gpu.log` and `NativeWindowTaskModelIntegrationTests`.

### Strict native form matrix: retained first attempt

The expanded-catalog E4B GPU form passed in **115.536 seconds** (118.601 s wrapper), with five primary generations, four proposed fixture calls, exactly one review and one Apply. Exact original Unicode input/result, fresh final observation and untouched draft assertions passed. The ordinary button receipt retained its required uncertainty until separate observation. Four declarations were registered in the suite: three executed and the independent review-load opt-in was skipped. See `native-expanded-catalog-form-e4b-gpu.log`.

The first expanded-catalog E2B CPU form **failed in 39.215 seconds** (42.043 s wrapper), before mutation: zero reviews and zero clicks. The first observation contained only a 384-byte AXWindow record. The model then proposed `set_value` with that latest exact window ID rather than an independently proven input control. The unchanged qualification guard refused it before returning the reply to Store. This is a wrong-role proposal; no Unicode write/readback was attempted. See `native-expanded-catalog-form-e2b-cpu.log`.

Compaction did not remove the field: turn-two history used only 1,016 of 6,027 available bytes, and the native Activity result itself was 384 bytes. The passing current E4B run had the same initial inventory shape and then requested a further observation, obtaining a 3,086-byte field-containing result. The earlier smaller-catalog CPU run obtained a 3,084-byte result immediately. Original observation arguments were not retained, so the precise failed-run mode string cannot be proved from captured arguments; the result shape and E4B sequence strongly support a windows-only inventory. No AX timeout or truncation marker was retained.

The frozen first-attempt runtime manifest is `native-expanded-catalog-runtime-matrix.json` (SHA-256 `d24b20494362a3de0c47d18e2403a9abda70a44a772f9d63e83270e89b44a1b3`). Its 348 source hashes and exact host/fixture hashes remained unchanged across all three model gates. Owned fixture and native observation workspace inventories were zero afterward. This matrix is not represented as green.

A generic production fix labels a windows-only result as an inventory, explains the scoped full-read step and distinguishes window IDs from editable-control IDs. It adds no fixture-specific hints, automatic replay or validator relaxation. The complete default and direct owned live checks passed as recorded above. The inventory host was `3e2de09165080305c0267f3c122bf2b6f35ba1ac9a3788311316b893c1f51103`; root independently verified its source and log hashes before a model attempt.

That CPU attempt failed **before an observation**, proposing `open_app` outside the unchanged strict allowlist (21.116 s suite / 24.215 s wrapper). The fixture was not foreground according to the timing diagnostics. Its call arguments were not retained, so its selector cannot be classified. No observation, write, review or click was dispatched. See `native-window-inventory-form-e2b-cpu.log` and `native-window-inventory-cpu-first-failure.json` (SHA-256 `104f2bc0cd46e4ac33dbf30f17360ce3a417d42660ed38a1ae8c5608da3afd14`). This did not exercise or establish a fix for the earlier inventory confusion.

The next change made setup reproducible and diagnostics sufficient: activate only the exclusively owned fixture once, require its exact PID foreground before the first inference, never reactivate mid-task, and retain bounded proposal selectors/refs and observation shapes without text values or source bodies. Foreground state is absent from the planner's input; normalization is not presented as a causal product fix. The generic system prompt also clarified that an already-running app can be inspected directly while honoring explicit open/focus requests.

The single CPU attempt on that combined source still failed (19.081 s suite / 22.054 s wrapper). Setup and before/after inference all proved foreground=true with no drift. The retained call was exactly `open_app(app: dev.relay.accessibility-fixture)`: the owned app, not a foreign target. The unchanged allowlist refused this redundant launch before dispatch. There was no observation, write, review or click. See `native-form-diagnostic-form-e2b-cpu.log` and `native-form-diagnostic-cpu-first-failure.json` (SHA-256 `457d3ca5739b0b9939880b9c48bec51cebaebe9dfbda4229dd386646996e9028`). The guidance did not qualify CPU planning. No further CPU retry or prompt tuning is claimed.

Strict CPU qualification remains **open**. The task, call allowlist and exact Unicode/review/one-Apply/result/draft assertions have not changed. Previous smaller-catalog successes remain historical evidence in [the preceding follow-up record](verification-2026-11-07-followup.md).

### Independent current-source E4B GPU qualification

Both primary E4B GPU gates passed on the final guidance/diagnostic host, independently of the open CPU gate:

- Strict form: actual workflow **56.818 seconds**, suite 56.824 s, wrapper 59.149 s. Four generations and three proposals; one exact review and one Apply click; exact original Unicode input/result, fresh outcome observation and unchanged draft. No Activity failures. Exact owned foreground setup passed. Log: `native-form-diagnostic-form-e4b-gpu.log`.
- Ordinary image-only read to exact artifact: **77.535 seconds**, wrapper 79.440 s. Four primary generations, one explicit native visual read and one exact artifact write. Unknown marker absent from initial context/AX; exact final answer and file bytes; zero UI input. Log: `native-form-diagnostic-read-artifact-e4b-gpu.log`.

Root independently checked the complete 348-file source manifest, current host and all three current runtime log hashes against `native-form-diagnostic-runtime-matrix.json` (SHA-256 `77601a10cffd7fdd8e37bc451ee52b983b30d5d24f04089deea6360f5fa1f371`). Exact owned fixture process count, native temporary workspace count and read-artifact temporary directory count were all zero. This is primary-GPU qualification with a blocked strict CPU case, **not a green all-model matrix**.

## Packaged app and presentation

The integrated provider Release build and strict deep ad hoc development signature passed before the native-read cutover. Through CUA, the packaged app completed native E4B readiness, reported the default LM Studio service unavailable without fallback, retained the native E4B/GPU choice when switching back, and returned exactly `Relay native provider restored.` to one public tool-free QA request. The composer was left empty and the app was quit. Existing history was retained; no OS/source/account/microphone grant changed.

The first inspection found a stale unavailable-service error surviving the provider switch. The explicit switch now clears it, with the focused regression above. Combined provider/native-read Release packaging and strict deep ad hoc signature passed in `provider-native-read-release-build.log`. A second CUA inspection observed readable unavailable-service feedback, no stale error after switching back, retained native E4B/GPU selection, restored actual readiness, the shared “On this Mac” Sidekick label, legible empty prompts and unchanged history. The current settings were observed at 820 × 620 points, with vertical scrolling and no horizontal control clipping. Sidekick was returned to compact mode and Relay quit; app inventory confirmed it was not running. This second check added no chat messages or OS/source/account/microphone grants.

The later already-running-app system guidance and test-only setup/diagnostics were not in that intermediate package. Final current-source Release packaging passed in `provider-native-read-final-release.log`, followed by an independent strict deep signature verification. CUA then observed the rebuilt app reach native E4B model/tool readiness, preserve its visible history and empty composer with Activity hidden, and quit successfully. App inventory confirmed it was not running. No new chat message or OS/source/account/microphone grant was added.

Final package manifest: `provider-native-read-final-package.json`, SHA-256 `89eb30641a8d38f6d9968c88241537ef738ca5691260b176ed7f684d024ac35c`. Release executable SHA-256: `5b1ac17561fc2aa5eb3fce0b1ba28dcd61f5217e01af25a3d6bc0c547f7a444d`. The manifest binds the current 348 source hashes, qualified test host, package files, final build/static logs and observed cleanup. Ad hoc signing does not establish Developer ID/notarization or durable permission identity.

## Boundaries and next implementation

Subsequent qualification found an unattributed pointer event in a separate owned read diagnostic. The full retained failure and its evidence limits are in [the presentation/controller follow-up](verification-2026-11-07-presentation-control.md). The read/artifact results above retain their exact file/form oracles; their zero-input report must not be interpreted as proof that every pointer event was monitored. General native zero-input qualification remains unresolved.

- The default LM Studio service was unavailable. Actual LM Studio model, tool and image-quality qualification remains open; no model was downloaded or server started on the user's behalf for this test.
- Relay's packaged Accessibility grant remains distinct from test-host access. Screen Recording/source/microphone, hardware displays/notch/Spaces, service accounts, wake behavior and signed distribution retain their separate gates.
- Native task read authority is currently memory-only. Same-process Stop/Resume retains it; process-restored tasks need an explicit fresh binding that preserves any original restrictions. Restoring history must not mint unrestricted scope or executable effects.
- A separate ignored controller draft has qualified finite native click/drag/key mechanics and an upfront focused AX insertion capability. The raw keyboard provider lost non-layout Unicode in a real editor; its Unicode preflight now refuses before effects. Exact AX insertion separately passed decomposed accents, Chinese and emoji while preserving unmodified authored formatting and caret. That capability is still being integrated under the native FIFO/Stop/request-ID gate. It is not a completed production autonomous action loop.
- The ignored real SQLite journal has fault/crash qualification, but Store dispatch cutover, history tools and validated completed-prefix compaction are unfinished. No primitive is counted as the complete durable conversation feature.
- Broader providers, live sources, semantic knowledge/proactive research, browser proofreading/Undo, combined summaries/video/same-chat continuation, managed wake, hosted phone knowledge and release migration remain in the unchanged 260-row [parity plan](sentient-parity-plan.md).

The next milestone must connect generic ordinary visual actions to the planner with original task scope, current target/effect review and independent outcome evidence, and put durable intent acknowledgement before every dispatch path. Successful screenshots, process exits and model narration do not prove the requested effect.
