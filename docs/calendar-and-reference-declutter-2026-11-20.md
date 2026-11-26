# Calendar capability and Reference-informed chat refinement

The user reported that Codex CLI could not create a meeting and rejected Relay's crowded chat. Their screenshot showed an empty visual-context acquisition panel, repeated assistant headings, permanent response/user toolbars, and deletion icons throughout History. They specifically requested Reference's cleaner icon treatment and gradient, and pointed to Desktop screenshots.

## Reference inspection

The installed upstream project app was inspected directly, without submitting tasks or changing its settings. The Desktop reference folder `upstream project Onboarding — 2026-11-19` was opened using Finder; screenshots `02 Home and feature examples/029-home-initial.png` and `030-home-double-tap-example.png` were read through Quick Look. Desktop terminal access was unavailable; no permission changes or workaround to bypass that restriction were made.

The reference's identity combines blue, wine, and amber light near the upper window edge, a quiet reading background, translucent surfaces, consistent outlined system symbols, a compact composer, and sparse message controls. The public official source was independently checked to distinguish current implementation from historical comparison images. See [verified reference notes](reference-declutter-reference-2026-11-20.md).

## Calendar defect and repair

The single-agent store only included the selected Calendar write destination when the local LiteRT path was active. Codex CLI, Claude CLI, hosted Codex, and the other configured providers consequently received no Calendar write schemas. Delegated execution also filtered these tools out. The screenshot's refusal was consistent with this routing defect; an event-workflow implementation existed, but was unreachable through the chosen provider.

Calendar write tools now reach the configured planners. A selected writable calendar is represented to the planner by an opaque `calendar_id=selected` alias; private calendar/account identifiers and titles remain in local review. Current device time and time zone are included for relative-date interpretation. Missing setup is explained as a supported capability requiring a selected write destination, rather than a blanket inability to create events.

Staging and committing retain their explicit review boundaries, selected-destination checks, one-use receipts, and independent readback. No grant, Calendar selection, external invitation, event creation, or rollback is performed merely to render the redesigned UI or advertise a tool. Attendee invitations remain unsupported and must never be silently omitted.

Calendar setup is discoverable from the composer's add menu and opens the existing Sources settings. It does not automatically request permission or select a calendar.

## Visual and interaction changes

- Static blue/wine/amber edge lights fade away from the reading area, with a small warm echo at the dock. The backdrop adapts to Light/Night; increased contrast and reduced transparency use plain surfaces. No continuous animation was added.
- The composer uses one add menu, a compact provider choice, dictation, and Send/Stop. The previous Work in app / Actions / long-provider shelf is removed. A selected attachment has a compact context chip; empty attachment mode has no panel. Meaningful attachment errors remain visible.
- Ordinary assistant responses are plain prose without repeated speaker headers. Secondary actions move to a small hover/focus gutter and contextual/accessible actions. Saved-note Open/Export and save failures appear after the relevant operation, preserving the preceding saved-result workflow.
- History uses a quiet row action menu, keyboard/accessibility actions, and recoverable Trash rather than persistent delete buttons beside every title.
- The top bar keeps primary navigation and Stop, reduces labels at compact widths, and groups settings, appearance, setup, and thread utilities into one workspace menu.

These changes target the actual conversation and composer, rather than introducing another decorative Home screen. Existing message history, draft recovery, Trash, saved-note identity, review authority, and source boundaries are preserved.

## Qualification

Automated and live results are appended after integration. Real writes to the user's Calendar are not implied by an inert transport fixture. A real meeting still requires Calendar access, an explicitly selected writable destination, and approval of the exact proposed event.

### Integration corrections

The first qualified run exposed a 24 KiB local-context regression from adding Calendar tools and guidance. The fix advertises write schemas only when a writable destination is ready, across every provider, and compacts paired advertised/native tool descriptions plus redundant prompt wording. The 24 KiB limit, 6,000-byte history requirement, complete fresh observation, and test assertions remain unchanged. Descriptions retain untrusted-data handling, scope, secure-field exclusions, fresh IDs, exact review/readback boundaries, and numeric bounds. No tool-result truncation was added.

Intermediate focused runs caught insufficient native-history room and missing explicit ASCII/Unicode guidance; both were corrected. The next full run passed 2,125 of 2,126 application tests, all 58 journal tests, and 24 XCTest checks. The remaining exact desktop-control guidance phrase was restored. All 65 affected tests then passed. The final selected Calendar + native-control + MCP measurement leaves **6,190 bytes** for history under the unchanged budget. A final full-suite result follows below.

### Signed-app inspection

The debug app was rebuilt and its signature verified with `codesign --verify --deep --strict`. Live inspection covered Light and Night, compact and wider windows, the user's existing meeting conversation, the new Add menu, and Calendar setup navigation. The empty visual-context panel, repeated assistant badges, permanent action strips, and per-row trash buttons are absent. Native accessibility exposes Copy/Reply/Save actions on messages; invoking Reply worked, and its preview was cancelled without sending. Saved response Open and Export controls and the secondary action menu remain available.

The existing Calendar permission was allowed, but the session had no writable destination selected and needed a calendar refresh before choosing one. Inspection did not refresh private calendars, change source selections or grant permissions. A separate synthetic chat through the actual configured Codex CLI returned: “Yes, calendar event creation is supported, but no write destination is currently selected,” followed by Settings → Sources → Apple Calendar setup guidance. No event creation, modification, deletion, or invitation was requested or performed. The original six threads were retained; the inert capability check adds one verification thread. The app is left open in Night for review.

Real account event creation remains unqualified until a writable calendar is explicitly selected and the exact proposed event is reviewed. Synthetic stage/commit/readback tests cover provider routing and the screenshot's three-turn clarification sequence, not a real account write. Attendee invitations remain unsupported.

### Final qualification

The final unchanged-source qualified serial run passed: **2,126 application tests in 330 suites** (112.782 s), **58 journal tests in 10 suites** (3.849 s), and **24 XCTest checks**. Opt-in external/account tests remain opt-in. The run enabled LM Studio, OpenRouter, custom Responses, and main-agent MCP loopback protocol fixtures plus Codex readiness. Logs: `/tmp/relay-calendar-declutter-final-qualified-2026-11-20.log`; signed build: `/tmp/relay-calendar-declutter-final-app-build-2026-11-20.log`. Final `git diff --check` and strict deep signature verification passed. No commits or publication were requested.
