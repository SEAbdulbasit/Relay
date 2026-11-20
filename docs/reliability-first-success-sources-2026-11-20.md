# Real first result and calendar source clarity — 20 November 2026

## Implemented

The welcome screen now includes **Try local calculator**, an optional real operation separate from the fictional interface tours. A user edits an arithmetic expression and explicitly chooses **Calculate locally**. It invokes the production `MacTools.execute` calculator path, displays the expression actually evaluated, and shows the returned summary and evidence only as checked when `ToolResult.verified` is true. It performs no provider sign-in, download, private-source read, app automation, conversation submission, or simulated task-history insertion.

The default expression `(18 + 24) * 3` returns `Result: 126`. The expression can be changed for a user's own arithmetic. Invalid syntax and division by zero show the production error, with an editable expression and explicit retry. The button prevents duplicate invocation while running. Setup can be continued or finished later without running the calculator; no first-success outcome is manufactured for skipped setup. The evaluated expression stays attached to the result even if the input changes afterward.

Calendar permission no longer counts as selecting a background source. The source card and graph now open **Calendar access and daily preparation**, containing:

- The existing permission explanation and explicit permission/catalog refresh action.
- The existing current-catalog calendar selector, which commits exact selected IDs.
- A separate **Include selected calendars in daily preparation** toggle using the real scheduler's session-scoped `calendarRefreshIDs`.
- Proactive suggestions and the existing daily schedule controls, so selecting a calendar can be connected to a genuine scheduled read and resulting agenda.

The toggle can be disabled without revoking macOS permission. Changing calendar scope already clears the background inclusion through the store's invalidation callback. Session calendar scope remains session-only; it is not silently restored after relaunch. Existing scheduler logic performs the selected seven-day calendar read and publishes its agenda, and cancels when source selection changes. The UI labels calendar work as daily preparation rather than falsely claiming Markdown indexing.

## Verification

`swiftc -frontend -parse` passed for edited onboarding sources and tests. No simultaneous full build was launched; integrated build and runtime verification are owned by the coordinating agent.

Added tests in `OnboardingTests`:

- A newly initialized coordinator has no trial result or automatic tool invocation.
- Production calculator rejects division by zero, then succeeds on explicit retry with the actual checked `Result: 126` and local calculation evidence.
- An injected unverified tool response cannot be displayed as checked success.

The existing `PreparationSchedulerTests.selectedCalendarAgendaRequiresASeparateSessionOptIn` covers genuine calendar opt-in, agenda production, and clearing that agenda when inclusion is disabled. The settings/reliability agent owns scheduler tests and changes for this pass.

## Runtime checks for coordinator

1. Open welcome in light and dark appearances; enter an expression, choose Calculate locally, and inspect expression/result/evidence.
2. Enter `1 / 0`, inspect the error, then correct and retry. Continue without calculating and reopen setup to confirm returning-user skip remains available.
3. In Sources, inspect Calendar's unselected state even when macOS permission exists. Open the sheet; no source read is initiated by sheet presentation.
4. If explicitly authorized in a qualified calendar fixture, grant/list calendars, commit a subset, separately enable background inclusion, and run daily preparation. Disable inclusion and verify the agenda clears.
5. Change/clear selected calendars and verify background inclusion resets. Relaunch and verify session-only scope is not restored.

No private calendar reads, permission grants, provider requests, or schedule changes were performed by this agent. These are implementation and code-check results until the coordinating agent records actual runtime checks.
