# agent-desktop integration study

Studied 1 November 2026. Installed version: Vendor/agent-desktop/VERSION = 1.0.2; generated C header ABI major = 6. Official source tag v1.0.2 downloaded read-only to /tmp/relay-agent-desktop-study, commit a47ed664e0db00d1d4df364eb3fe8a5599882f3c. References below refer to that exact tag, not an assumed latest release.

## What the library actually supplies

The upstream AGENTS.md explicitly describes a native AX observation/action tool, not an agent or browser-page automation engine. It embeds no model. Relay still owns planning, approval, recovery, verification and the conversation. Adding the library does not itself confer Sentient parity.

Source inspected:

- src/cli/post_action_wait.rs: --wait-for and --wait-for-gone attach bounded element-state waits to snapshots/ref actions.
- crates/ffi/src/actions/resolve.rs: exact refs are validated using process-instance and typed native-identity evidence; malformed layouts and empty identities are refused.
- crates/ffi/src/commands/wait.rs: typed scoped wait arguments, structured envelopes, explicit timeout handling and adapter lifetime protection.
- crates/core/src/session/interaction_lease.rs: serializes desktop mutation leases. This is an important boundary to retain when optimizing calls.
- crates/core/src/actions/post_action.rs and action_result.rs: action dispatch is distinct from postcondition verification. Missing readback can remain a successful delivered_unverified result.
- docs/json-output.md: error disposition controls safe retry; ok=true does not mean effect verified, and element-state proof does not establish application persistence.
- Vendor/agent-desktop/include/agent_desktop.h: generated ABI exposes exact window/surface selection, snapshots, find/get/is, waits, trace, ref actions and post-state/delivery results.

Official source: https://github.com/vercel-labs/agent-desktop/tree/a47ed664e0db00d1d4df364eb3fe8a5599882f3c

## Relay's current integration

AgentDesktopBridge.swift locates the CLI and FFI, verifies ABI6 using a dynamic symbol, isolates AGENT_DESKTOP_HOME under Relay application support, and launches a fresh CLI subprocess per operation. The FFI is checked but is not the active observation/action transport.

MacTools.swift observe supports upstream skeleton/find/root-ref requests; ordinary full observation still uses Relay's direct AX walker. Snapshot-qualified refs are cached, checked for matching app/enabled state and age under 60 seconds, then invalidated after mutation. Direct AX and agent-desktop paths therefore have different freshness and verification behavior. A single task can encounter both engines.

Bridge.snapshot accepts a windowID but MacTools.observe does not currently provide one. App selection uses localized appName rather than the requested bundle ID as the upstream identifier. These are concrete opportunities to pin observations more precisely.

## Critical verification correction implemented with this study

Before this pass, MacTools.setValue marked any ok=true agent-desktop response verified. Upstream explicitly allows successful delivered_unverified. Added AgentDesktopEnvelope.verifiesTextValue: only a successful set-value response with delivery=delivered_verified and exact post_state.value readback proves the value. Missing/unknown disposition, missing or contradictory value, failed envelopes and unrelated commands all fail closed. The tool now reports uncertain dispatch without suggesting blind retry. Verified evidence explicitly limits its claim to the control value, not saving or persistence.

AgentDesktopDeliveryTests covers unverified/not-delivered/unknown dispositions, missing fields, contradictions, failed commands, empty string and Unicode. Targeted verification passed: 8 tests across AgentDesktopDeliveryTests and AgentDesktopProcessRunnerTests on 1 November 2026 (including parameterized delivery/Unicode cases). Full-suite and UI qualification remain with the coordinating agent.

## Remaining risks and unused capabilities

1. **Process I/O and cancellation — repaired for CLI commands.** AgentDesktopProcessRunner now uses queue-confined state and bounded nonblocking draining of both streams (1MiB each), cancellation, a deadline and termination with a 200ms SIGKILL fallback. It completes after the directly owned subprocess exits; inherited helper descriptors cannot force an EOF wait. A nonzero exit cannot be accepted as successful even if stdout says ok=true. Tests cover output beyond pipe capacity, output overflow, partial/nonzero output, cancellation and a child ignoring SIGTERM. Remaining scope: this does not kill arbitrary descendants, and the development-only vendor update subprocess still uses its old separate runner. Do not assume helper-process supervision is solved.
2. **Exact observation scope.** The bridge has windowID support, while the calling tool drops it. Add explicit window discovery and scoped observation rather than guessing among multiple app windows. Retain exact ref provenance in approval review.
3. **Observation consistency.** Do not expose different guarantees depending on optional mode. Move toward one canonical observation adapter with typed source/window/process identity and explicit stale-ref errors, while retaining qualified direct AX fallbacks only where justified.
4. **Waits instead of startup sleep.** Current observation retries any failed envelope once after 200ms. Use bounded read-only upstream wait predicates for window/control readiness; honor error retry disposition. Never apply this generic retry to mutations.
5. **Evidence and diagnostics.** parseEnvelope retains retrySafe for errors but drops success delivery metadata in its general model. The new exact value helper fixes one caller; a typed disposition/post-state representation should be shared by all future mutation tools. Integrate trace export selectively for a task's diagnostic bundle, with explicit private-content controls.
6. **FFI performance path.** A persistent session adapter could remove CLI startup/JSON overhead, but must preserve native-handle thread affinity, interaction leases, ABI layout/version checks, ownership/freeing and cancellation. Profile before replacing the safer process boundary. Do not assume this changes local-model latency.
7. **Browser limitation.** Native AX snapshots do not replace DOM-aware browser reading. Repair browser target identity and choose a dedicated browser transport when user-authorized tasks need page semantics. Do not claim arbitrary web-form parity from native ref actions.
8. **Updates/signing.** update-agent-desktop.sh defaults to latest and replaces vendor files in sequence after checksum verification. Pin a qualified version for releases, stage the whole CLI/helper/dylib/header set atomically, verify ABI, preserve licenses, and rebuild/sign a coherent app bundle. Runtime source-workspace updates are not a signed-distribution strategy.

## Prioritized implementation and tests

P0: exact post-action verification (implemented above), browser ambiguity repair, current-build permission recovery. Test duplicate tabs/windows, missing selected metadata, conflicting selection, unreadable page and navigation changed between approval and execution. Pass only when the intended page or explicit blocker is independently observed.

P1: process cancellation and bounded concurrent pipe draining (implemented for command transport; tests passed). Extend coverage with fake CLI fixtures that emit more than pipe capacity to both streams, never exit, ignore termination, return partial JSON, exit nonzero and finish concurrently with cancellation. Assert a single completion, no leaked child, bounded memory, and no invented effect proof.

P1: canonical scoped observations and explicit window IDs. Fixture two same-titled windows, app restart/PID reuse, disabled/secure elements, Unicode, expired refs, changed values after review, and window closing during action. Reject conflicting identity before dispatch; after uncertain dispatch, observe rather than replay.

P2: bounded wait predicates and surfaced recovery. Test controls appearing just before deadline, never appearing, disappearing after initial readiness, permission revocation and cancellation. UI should show what Relay is waiting for and a working Stop action.

P2: task trace and latency profiling. Separate model planning, observation, action, wait and verification durations. Compare identical task state across engines and local/hosted model configurations. Export only user-reviewed diagnostic material.

P3: persistent FFI adapter experiment after measurements identify subprocess overhead. Test ABI mismatch, malformed inputs, string ownership, thread-affinity, concurrent calls/lease contention and adapter destruction during a wait. Keep CLI fallback until equivalent qualification passes.

The strongest path beyond Sentient is reliable verified outcomes and clear recovery with local inference. More exposed commands alone do not establish a better product.
