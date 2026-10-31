# Computer-control integration — Cua Driver

Research recommendation · 29 October 2026. No driver was installed, no application was controlled, and no macOS permission was requested or changed. The current tools remain untouched. Source tree inspected at `trycua/cua` revision `b269d38db580afbd7b9f3b1d8409d0df540e1b21`; the Rust workspace declares `0.38.0`. A source version is not proof that matching signed release artifacts have been qualified for Relay.

## Recommendation

Replace custom desktop interaction behind a `ComputerControlAdapter` with Cua Driver. Keep Relay's local model, task scope, review binding, verification, Stop gate and user experience product-owned. Cua executes native operations; it does not require hosted model inference. Its official local-model guide demonstrates local serving, recommends filtering the exposed tool inventory and bounding observations. Gemma remains Relay's inference choice; this research has not established Gemma's end-to-end computer-use accuracy. [Local-model guide](https://cua.ai/docs/cua-driver/guides/local-models)

For the initial native Swift integration, prefer a **private embedded daemon plus stdio MCP proxy**, launched directly by Relay. This uses the documented Swift host pattern and supports the driver cursor without introducing a Python/Node runtime. Do not adopt a nonexistent assumed Swift package or silently replace a working app with an untested SDK topology.

## Supported embedding choices

| Choice | What is established | Relay decision |
| --- | --- | --- |
| Private daemon and MCP | Official embedding guide includes a Swift `Process` host. The host directly starts an embedded driver, then a proxy on a private socket. | Recommended first integration. |
| Native C ABI | Distributed stable native header exists with versioned symbols, opaque handles, buffers and asynchronous callbacks. | Feasible later native wrapper; additional lifecycle/FFI ownership work. |
| Python / TypeScript SDK | Official public SDK documentation describes these packages and their macOS daemon preference. | Valid upstream surfaces, unnecessary runtime dependency for our Swift shell. |
| First-party Swift SDK | No released Swift package is documented in the inspected current public SDK surfaces or checked-in driver tree. | Do not describe one as shipped. The Swift embedding example is a host example, not a Swift SDK package. |

The current SDK guide says macOS `create()` normally connects to or launches `CuaDriver.app`, while forced in-process use lacks the visible cursor without an AppKit host adapter. `connect()` explicitly selects a daemon. Action tokens belong to their snapshots; successful dispatch still requires a subsequent independent state check. Background delivery must not silently retry in foreground. Timeouts can leave uncertain effects. [SDK guide](https://cua.ai/docs/cua-driver/guides/use-the-sdk)

## Native Swift host lifecycle

Recommended topology, not implemented code:

1. Ship a pinned, signed nested driver resource. Relay owns permissions.
2. Spawn it directly using `Process`: `serve --embedded --socket <private-path>`, with `CUA_DRIVER_EMBEDDED=1` and Relay's bundle identifier. `open`/`NSWorkspace` would break TCC inheritance.
3. After readiness, spawn `mcp --embedded --socket <same-path>`; negotiate MCP and discover matching schemas.
4. Check host attribution through `check_permissions` and bundle identity through `health_report`. Relay explains permission needs; missing grants are readiness failures.
5. Permission changes require child restart and invalidating old clients, sessions, tokens and reviews. Shutdown closes admission, ends sessions, closes proxies and drains/stops the child. Reconcile uncertain mutations after crashes.

The [embedding contract](https://github.com/trycua/cua/blob/b269d38db580afbd7b9f3b1d8409d0df540e1b21/libs/cua-driver/rust/Skills/cua-driver/EMBEDDING.md) assumes a non-sandboxed host; it does not establish App Store compatibility. Prefer standard or reviewed bounded mode. Never make unrestricted launch configuration model-editable.

## C ABI alternative

The pinned header reports ABI **1.1.0**. A wrapper must first call `cua_driver_abi_version_v1` / `cua_driver_abi_is_compatible_v1`; create with `cua_driver_create_v1`; discover with `cua_driver_list_tools_json_v1`; invoke through `cua_driver_invoke_v1` or a trusted session handle; and bridge its exactly-once completion callback into Swift safely. Release every returned buffer using `cua_driver_buffer_free_v1`. Retain operation/context ownership until callback completion, then release the operation. Shutdown drains admitted work before destroying the driver. `cua_driver_operation_cancel_v1` requests cancellation; this is not evidence that native effects were rolled back or immediately stopped. [Generated native ABI header](https://github.com/trycua/cua/blob/b269d38db580afbd7b9f3b1d8409d0df540e1b21/libs/cua-driver/rust/include/cua_driver_abi.h)

The stable `cua_driver_*_v1` ABI is distinct from private UniFFI glue. Import its generated C header through a Clang module rather than hand-declaring Rust symbols. [Native ABI ownership guide](https://github.com/trycua/cua/blob/b269d38db580afbd7b9f3b1d8409d0df540e1b21/libs/cua-driver/rust/include/README.md)

## Proposed adapter surface

```swift
// Product-owned API sketch; not a claim of an upstream Swift SDK.
start(configuration) async throws -> DriverGeneration
checkReadiness() async throws -> DriverReadiness
listApplications() async throws -> [ApplicationIdentity]
listWindows(application) async throws -> [WindowIdentity]
observe(window, limits) async throws -> Observation
setText(target, text, observation) async throws -> ActionReceipt
click(target, observation, authorization) async throws -> ActionReceipt
scroll(target, direction, observation) async throws -> ActionReceipt
cancel(operation) async -> CancellationReceipt
endSession() async
shutdown() async
```

Retain upstream `pid`, `window_id`, snapshot token/capture identity, error/refusal codes, degraded/truncated flags and action interruption state. Bound text/images before adding them to model context. Resolve an exact app/window, observe, act, and observe again. Product review binds the actual destination/payload, not merely a button label. Stop first closes Relay's admission gate; admitted native work is reconciled before replay. No automatic foreground fallback or uncertain-action retry. Start with a narrow tool allowlist and expand through fixture evidence.

## macOS limits and remote boundary

Cua's quickstart lists **macOS 14+**, requires Accessibility and Screen Recording, and notes that launching apps or some input can still need foreground interaction. Relay's existing macOS 15 deployment floor need not be lowered merely because the driver supports 14. [Quickstart](https://cua.ai/docs/cua-driver/quickstart)

Upstream qualifies AppKit, SwiftUI, Electron, Tauri and WKWebView coverage, but some background scrolling/dragging refuses. Off-Space SwiftUI, minimized keyboard commits and HID-only apps remain boundaries. Chrome has a specialized browser route; Safari/Firefox use native accessibility/pixels rather than assuming Chrome DOM parity. An off-Space cursor may not paint. These are compatibility constraints, not universal background-control guarantees. [Platform support](https://cua.ai/docs/cua-driver/concepts/platform-support)

This recommendation concerns applications on the **same Mac**. If the user means a second physical MacBook, the driver must run in that machine's authorized desktop session, with a separately scoped authenticated transport. Remote ownership, identity, connectivity and permission setup require a separate design; no listener or remote access is configured here.

## Licensing and acceptance

The repository's MIT license permits redistribution subject to retaining its copyright and license notice; preserve notices for the exact shipped artifact and dependencies. [License](https://github.com/trycua/cua/blob/b269d38db580afbd7b9f3b1d8409d0df540e1b21/LICENSE.md)

Default Driver is MIT and works without model artifacts. Its optional `cua-perception` extension has a separate boundary: the OmniParser icon detector is AGPL-3.0-only. Do not bundle that extension as if it were covered by the Driver's MIT license. [Driver README and perception notice](https://github.com/trycua/cua/blob/b269d38db580afbd7b9f3b1d8409d0df540e1b21/libs/cua-driver/README.md)

Before switching the working app, qualify signed host attribution, permission denial/regrant, read-only app discovery, a synthetic form with independent saved-state oracle, media playback observed from app state, stale-token refusal, Stop before/after native dispatch, timeout/unknown effects, crash cleanup, foreground disclosure, model image support and context limits. Retain the current adapter until those tests establish the replacement. No release reliability claim follows from this document.
