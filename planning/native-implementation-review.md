# Native implementation — independent correctness review

29 October 2026 · Read-only source review of AssistantStore, MacTools, ToolPolicy, LocalModelClient and the embedded SDK boundary, using write-swift. No shared application source was edited. Actual Gemma inference was not exercised; model provisioning remains pending.

## Findings

### P1 — A verified observation can mark an unfinished requested task Completed

`Sources/Relay/AssistantStore.swift:97–104` marks the run `.completed` whenever at least one tool returned verified and no tool failed. `list_apps`, `read_file` and `observe_app` all return verified for their observations. Consequently a request to create a document can call only list_apps, then emit “Done”, and get Completed without creating anything. The appended evidence disclaimer does not correct the terminal state or the untrusted completion narrative.

**Fix:** Track requested outcome postconditions separately from verified tool operations. Until independent outcome checks exist, terminate as a response/preparation or Needs input rather than Completed solely because any observation succeeded. Add a regression where list_apps succeeds, the next model reply claims a save, and no file exists.

### P1 — Existing-file changes during the review window are accepted rather than invalidating approval

`AssistantStore.swift:117–133` awaits review and only afterward calls authorize. `MacTools.swift:78` captures the existing-file fingerprint at that later time, through `effectFingerprint` at lines 86–88. If another app edits the file while the review is open, the user approves the originally presented replacement but the newly changed file becomes the accepted baseline and is overwritten at lines 242–243.

**Fix:** Capture exact resolved destination and existing contents/hash before presenting review, include the relevant current→proposed state, and require the same snapshot at approval and dispatch. A file edit during the pending review must invalidate it. Also bind the resolved destination so a link retargeted during review cannot silently move the overwrite to a different authorized file.

### P1 — Reviewed UI press is bound to the button, not the destination/content it will submit

`MacTools.swift:81–85` binds approval to an element fingerprint. The fingerprint at lines 338–342 contains only that element's role/title/description/identifier/value/enabled state; `freshRecord` checks those same attributes at lines 345–352. A Send/Submit button can remain unchanged while its recipient, document/record, form content or browser destination changes. The action still passes the reviewed fingerprint and is pressed at line 429.

**Fix:** Bind consequential press approval to the relevant containing target identity and outgoing content snapshot, freshly revalidate them at dispatch, and show them in the review. If the generic accessibility adapter cannot establish that binding, do not offer consequential submission through a generic button review. Test unchanged Send button with a changed recipient and body.

### P1 — Explicit application selection can turn document opening into interpreter execution

`MacTools.swift:166–173` validates the selected file's extension/type/executable bit but permits any installed application in the `app` argument. A non-executable ordinary text file passes these file checks; routing it to Terminal or another interpreter-capable application can execute its contents instead of opening it as a document. There is no application safety check before `workspace.open` at line 175. This defeats the stated no-shell boundary without requiring a .sh extension or executable bit.

**Fix:** Restrict open_file to qualified document/media application-and-type combinations, reject shells/interpreters/automation runners, and validate the default handler as well as explicit app selection. Regression: granted non-executable .txt plus Terminal must be refused before NSWorkspace dispatch.

## Boundaries that looked sound in this inspection

Stop/steering increments a revision, cancels the old task and waits for it before the next run; dispatch gates exist between batched calls and after awaited review. Static symlinks, including dangling paths, are walked before file scope comparison. Existing approvals are single-use and call-fingerprinted. The embedded model path has no HTTP fallback. LocalModelClient sets automaticToolCalling:false and uses the non-streaming SDK branch; RelayActionTool.run throws instead of dispatching an action. These observations do not establish end-to-end inference reliability or remove the findings above.

Residual filesystem concern: canonical path validation and Foundation pathname writes are not an atomic directory-handle/no-follow operation. A concurrent parent-directory replacement between validation and write can defeat static symlink checks. Prefer descriptor-relative safe writes if a hard race-resistant filesystem boundary is part of the release claim.


## Resolution in the integrated alpha

The coordinator removed model-turn-to-completion inference: final replies leave the run idle and show only independently checked tool outcomes. Tools now capture a prepared review baseline before waiting, including canonical destination plus content hash; authorization and execution recheck it. Generic UI presses/final submission stay manual, avoiding unsupported destination/payload binding; only qualified exact player controls can run. File opening uses the same safe-handler allowlist for explicit and default applications. Added regression coverage for review-time changes and same-content symlink retargeting. These changes do not establish arbitrary goal completion or full application coverage.
