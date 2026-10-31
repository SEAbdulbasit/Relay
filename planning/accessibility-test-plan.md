# Accessibility interaction test cases

These tests distinguish a model choosing a tool from software actually operating a macOS interface. No test grants OS permissions automatically. Missing permission is a blocked/not-run result, not a successful desktop test.

## Native fixture: deterministic and model-independent

The bundled `RelayAccessibilityFixture.app` is a separate AppKit process containing an editable field, Apply button, result label and disabled control. It receives a random per-launch token and writes an independent JSON oracle to a private temporary directory. It never reads personal files or contacts a network. The runner uses the SAME `MacTools` accessibility observation, text-entry, review and press operations used by Relay.

| Case | Action | Independent expected result |
|---|---|---|
| AX-01 Observe | Locate input and Apply by exact accessibility identifiers | Exactly one of each; oracle launch token matches this process |
| AX-02 Type | Enter `Relay AX check 🌍` through AXValue | Exact accessibility readback matches, including Unicode |
| AX-03 Stale reference | Try the button token obtained before typing | Refused, no click |
| AX-04 Click | Observe again, bind review, authorize and AXPress Apply | Fresh visible result AND separate JSON state match text; clickCount exactly 1 |
| AX-05 Disabled | Attempt disabled button | Refused; clickCount stays 1 |
| AX-06 Changed review | Prepare Apply, then change the fixture input through an independent AX edit without clearing the controller cache | Old review rejected; clickCount stays 1 |
| AX-07 Invalidation | Prepare/authorize then invalidate pending click | No dispatch; clickCount stays 1 |

The fixture invalidation case is distinct from the `AssistantStore.stop()` dispatch-gate regression tests. A canceled fixture run rethrows cancellation and cannot report a pass.

`RELAY_FIXTURE_INCLUDE_SECURE=1` enables a dummy secure field for additional manual/negative fixture inspection. The default positive fixture omits it; secure-input windows deliberately refuse reviewed generic clicks. There is no fabricated secure-input end-to-end pass.

## Finder scenario

| Case | Request/action | Expected evidence |
|---|---|---|
| FINDER-01 Plan | Ask actual local Gemma “Open Finder and search for sf.webm” with production tools | Native `search_finder` call, query exactly `sf.webm`; no OS dispatch in planning test |
| FINDER-02 Query validation | Empty, control-character, newline or oversized input | Refused before opening or typing into Finder |
| FINDER-03 Visible execution | Execute the qualified Finder action with Accessibility enabled | Finder is opened/raised; actual search field receives exact query and confirms search |
| FINDER-04 Outcome boundary | Check final query readback | Confirms the search query, NEVER claims a matching file exists or all locations were searched |

Search operates Finder's UI, not an invisible filesystem search. A fixed Return event is used only if Finder's search field has no AXConfirm action, after verifying foreground/focus and targeting Finder's PID. No arbitrary model-generated keystrokes are exposed.

## Run

Permission-free checks:

```bash
./Scripts/test-accessibility.sh
```

Preferred real desktop check:

1. Build and open `build/Relay.app`.
2. Settings → Access → Request Accessibility; enable **Relay** yourself in macOS System Settings.
3. Relaunch Relay if macOS requires it.
4. Settings → Access → Run accessibility check.
5. Read each case's actual PASS/FAIL evidence. Stop cancels remaining cases; interrupted checks never count as passed.

Optional test-runner integration (the TEST PROCESS must separately have Accessibility):

```bash
./Scripts/test-accessibility.sh --desktop
# Explicitly visible Finder test; does not open or delete any match:
RELAY_RUN_FINDER_TEST=1 swift test --filter actualFinderSearchShowsExactRequestedQuery
```

Real-model planning (no OS interactions):

```bash
RELAY_GEMMA_MODEL_PATH="$HOME/Library/Application Support/Relay/Models/gemma-4-E2B-it.litertlm" swift test
```

When opt-in environment variables are absent, desktop tests are skipped and must not be described as executed. Native typing/clicking compatibility is not inferred from schema or model tests. Accessibility check runs exclude concurrent model execution in the same Relay store.

## Actual native run — 29 October 2026

After refreshing Relay's macOS permission entry, the in-app fixture runner executed and all seven cases passed. Real accessibility typing and AXPress were used against the separate fixture, and its independent oracle confirmed exactly one click and the exact Unicode text. Stale/disabled controls, an independently edited pending-review payload, and an invalidated queued click were refused. The dispatch timeout was corrected from the inspection deadline to a bounded 500 ms action deadline; earlier uncertain timeout runs were not counted as passes.

Final Finder retest: from a normal Home window, the actual Relay chat request “Open Finder and search for sf.webm.” dispatched `search_finder` through local Gemma. Relay recorded verified exact query readback and `Searching “This Mac”`; independent CUA inspection showed five results including `sf.webm`. Final focused Accessibility contract suite: four tests passed. Release build and signature verification passed; current build's Accessibility switch is on.
