# Relay polish and screen audit

31 October 2026

| Before | After | Why |
| --- | --- | --- |
| Activity selected alongside Conversation, with duplicate navigation | Single Activity toggle in header, close control in panel | One selected workspace and a clear way to dismiss activity |
| Raw tool names and status strings | Plain labels with distinct requested, failed, needs-input and checked-result states | A completed response must not imply a successful computer action |
| Flat activity log | Spaced activity cards; technical evidence under View details | Easier scanning without deleting evidence |
| Static “THIS CONVERSATION hi” block | Removed | It was not useful chat history navigation |
| Long calendar restore notice | Concise disclosure with Choose calendars action | Clear recovery while preserving the full explanation |
| Starter prompts could overwrite a draft | Empty-draft guard and disabled controls when draft has text | Protect unsent user input |
| Ready and merely detected model states competed | One loaded-model hero, optional change-model disclosure | Clear next action without another download |
| Welcome repeated setup paragraphs | Short trust statement and a Finder search illustration | Explain the experience through a concrete example |
| Permission illustration hid primary buttons at compact height | Removed redundant access illustration | Put the permission action before optional explanations/checks |
| Settings said 100% Offline | Local inference · On your Mac | Setup and requested browser tasks can use internet |
| Ready model still offered Load | Reload model when ready | Action matches current state |
| Accessibility check enabled with missing access | Disabled until permission exists | Avoid a check that predictably cannot run |
| Knowledge settings used serif heading | Same system sans heading as other Settings sections | Consistent typography |
| CLI/FFI/ABI information filled main Model screen | Advanced engine disclosure | Preserve diagnostics while simplifying setup |

## Validation
- Final `swift test`: 411 tests reported passing across67 suites,5.652 seconds. Optional hardware/model/desktop tests remain opt-in.
- Final app package built with deep strict signature verification.
- Independent code critique and visual critique performed by a separate agent. Draft overwrite, compact approval competition and permission action visibility findings were addressed.
- Existing chat and unsent draft preserved. No messages sent, exports saved, indexing triggered, permissions granted, microphone capture started, or model packages downloaded during this audit.

## Native visual coverage
Screenshots are in this directory with `polish-` prefixes.

- Conversation and Activity: wide, half-width and compact-height layouts. Compact capture approx901×649pt; this is not a claim of testing every800pt-wide combination.
- Settings Model, Access (upper/lower), Knowledge sources, Memory (upper/lower, includes export and diagnostics controls), Voice.
- Onboarding Welcome, Privacy, ready Model, Access (upper/lower), First task.
- Knowledge workspace: empty state.
- Voice input: idle transcript state; capture never started.

## Limits
All primary screens above were inspected. Every possible runtime state has not been visually qualified. Missing-model/downloading/download-error and verification-in-progress states, actual speech capture/playback, populated Knowledge, pending-approval runtime UI, native file pickers and export-save flows were not exercised visually in this pass. Existing automated tests cover portions of those behaviors, but do not replace their visual qualification. The backend browser refusal/compatibility issue is not claimed fixed by this UI work.

Logs: `/tmp/relay-polish-verified-tests.log`, `/tmp/relay-polish-delivery-build.log`.
