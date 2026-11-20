# Onboarding review — 20 November 2026

## Assessment and direction

Relay already has resumable setup, six real provider choices, model download/verification/cancellation, direct macOS permission links, and optional source selection. Those are valuable foundations. The main trust problem was that several illustrative or estimated elements were presented as live results. Setup should describe what has been selected, what is ready, and what still depends on permissions or a provider.

The retained visual direction is a native productivity setup with a restrained type hierarchy, a stable progress rail, one primary continuation action, and a bounded scrolling content region. The existing five stages and stable persisted IDs remain intact. No reference-product behavior is claimed here; reference research is recorded by the coordinating reviewer.

## Prioritized audit and implementation

Severity describes user impact. “Confirmed” means visible in inspected source, not independently reproduced in the running app by this agent.

| Severity / evidence | Location | Before | After | Why |
| --- | --- | --- | --- | --- |
| High / confirmed | `OnboardingView.localModelCard` | Fixed ~65/~95 token/s and computed free RAM displayed as runtime telemetry | Actual machine memory/disk snapshot and qualified runtime guidance; removed fixed speed claims | Users should not choose a model using invented performance measurements |
| High / confirmed | `OnboardingView.readyStep`, `liveMemoryVaultConstellationBar` | Enabling sources instantly displayed ~85/~40 notes, fabricated note/link totals, and sample generated paths | Selection count and explicit distinction between selection and completed indexing | Avoids presenting work as completed before access/indexing succeeds |
| High / confirmed | Welcome and shortcut demo components | Fictional content lacked a persistent, prominent practice label | Visible fictional-example/practice labels | Makes preview outcomes distinguishable from actual app actions |
| Medium / confirmed | `OnboardingView.cliSubscriptionCard` | Disconnected provider status read “CLI Ready” | “Not connected” until verified | Readiness should reflect connection state |
| Medium / confirmed | `OnboardingView.topBar` | Accessibility names used the old step ordering | Names now match visible progress order | Screen-reader navigation should describe the destination accurately |
| Medium / confirmed | `OnboardingCoordinator.selectedGemmaVariant` | Model variant reset to hardware recommendation after interruption | Persisted catalog choice, invalid-value fallback, targeted tests | Resumed setup preserves the user's decision |
| Medium / confirmed | `OnboardingView.canContinue` | Unsupported local hardware blocked welcome continuation before alternative providers | Provider setup remains reachable; local activation still enforces compatibility | Local model requirements should apply at local activation |
| Medium / layout risk from source | Top bar and pinned footer | Centered ZStacks independently placed controls at the same vertical coordinates | Controls/progress and primary/footer accessories occupy separate rows | Removes structural overlap without fragile width offsets |
| Medium / confirmed | Source cards and graph buttons | Selection communicated visually through color/checkmarks only | Explicit accessible selection values and selected traits | Source choices can be inspected without relying on color |
| Low / design opportunity | Setup copy | “Architecture”, absolute privacy/action claims, and live-graph language | More direct descriptions of optional setup, cloud context, permissions, and indexing prerequisites | Sets expectations using the actual available controls |

## Coverage checklist

| Area/state | Inspected | Verification and remaining limit |
| --- | --- | --- |
| Welcome and three product example modes | Source | Added fictional-data label; actual screenshot QA delegated to coordinating reviewer |
| Instant Draft, summary and takeover lessons | Source | Existing local key monitor and task cleanup inspected; practice label added; these remain scripted lessons |
| Provider selector: Gemma, custom model, Claude, Codex, OpenRouter, LM Studio | Source | Connection/settings actions retained; no credentials submitted, CLI sign-in, or live provider inference run |
| Model download, verification, loading and cancellation | Coordinator/source | Existing cancellation/revision checks retained; no multi-GB download initiated |
| Unsupported hardware | Source, existing hardware unit coverage | Welcome no longer blocks provider choice; local activation checks retained |
| Mac Accessibility and Screen Recording access | Source | Existing direct settings links and foreground refresh retained; system permissions not changed |
| Full Disk Access | Source | Permission remains optional; no permission grant or private database ingestion performed |
| Local source/folder selection and graph | Source | False completed-work counts removed; actual source ingestion remains dependent on grants and background execution |
| Background indexing and MCP guide sheets | Source | Real settings/guide controls retained; no server session started or schedule changed |
| Privacy sheet and telemetry popover | Source | Cloud/provider copy qualified; full sheet scrolling at minimum height still needs runtime inspection |
| Resume/returning setup | Source + targeted tests added | Provider, step and model choice covered; final execution by coordinating reviewer |
| Light/dark and reduced motion | Source | Existing environment/transaction handling retained; visual contrast and VoiceOver output still need runtime checks |
| Compact/default window and long content | Structural source review | Chrome no longer overlaps by independent centering; final widths/screenshots to be checked centrally |
| Keyboard navigation | Source | Default continuation action and selection accessibility added; full tab order needs runtime verification |

## Verification performed by this agent

`xcrun swiftc -frontend -parse` passed for `OnboardingView.swift`, `OnboardingCoordinator.swift`, `OnboardingMagicReplyDemoView.swift`, `OnboardingWelcomePreview.swift`, and `OnboardingTests.swift`.

Two meaningful model-choice persistence tests were added to `OnboardingTests`: interrupted setup retains choices without starting a download, and corrupt model preference falls back to the hardware recommendation. Integrated compilation and test execution are coordinated centrally to avoid simultaneous SwiftPM builds.

## Remaining issues and limits

Follow-up implementation: [real first result and separate calendar inclusion](reliability-first-success-sources-2026-11-20.md) addresses the first-success and Calendar selection gaps listed in this initial audit. The descriptions below preserve what was identified in the initial pass, rather than representing the final implementation.

The five-stage setup still contains several richly illustrated practice modes. They are now explicitly labeled, but they are not substitutes for an end-to-end real first task after connecting a provider. Setup does not auto-run a task or claim that practice outcomes are verified real work.

Calendar access is controlled by macOS and cannot be revoked by tapping the calendar source again. The selected state means calendar permission is available, while other source selections are app preferences. A future separate “include calendar in background indexing” preference would need an actual scheduling/data implementation, so no cosmetic toggle was added.

This agent did not independently operate the running app, change permissions, inspect private source data, or measure inference/rendering performance. Treat source review and parse checks as such; runtime screenshots, integrated test results, and remaining app-wide limitations belong in the coordinating review.
