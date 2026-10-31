# Independent review — Sentient-grounded revision

29 October 2026 · Reviewed the actual saved dark HTML/CSS source against the source audit in [sentient-design-reference.md](sentient-design-reference.md), pinned to Sentient commit `f064441a6d4309b7ae810de08e27b15e688f9a0b`. This replaces prior aesthetic verdicts.

## Current verdict

The major structural divergence is corrected. The specimen now uses a black canvas, quiet top navigation, localized upper-edge illumination, a centered 744px conversation/composer column, neutral near-white controls and asymmetric message styling. It is substantially closer to the inspected reference's composition. This is source-based correspondence, not rendered visual quality sign-off.

| Before | After in actual saved source | Why |
| --- | --- | --- |
| Permanent sage sidebar and breadcrumb dashboard | No sidebar; compact wordmark and top navigation | Restores the reference's quiet canvas hierarchy. |
| Warm white surfaces and green primary controls | Black shell, neutral white-opacity surfaces and near-white circular send | Matches the inspected palette/material direction. |
| Promotional illustration and large form-like task surface | Restrained central empty state, conversation and persistent floor composer | Keeps the assistant workspace as the primary surface. |
| Generic rounded panels for every response | User bubble inset 58px; assistant prose directly on canvas | Aligns with the actual transcript's asymmetric hierarchy. |
| Broad flat palette without a light source | Blurred spectrum confined to the upper edge | Uses reference atmosphere as local illumination rather than a colored reading surface. |

## Differences that remain explicit

The reference transcript is capped at 800pt separately from its 744pt composer; this specimen caps both at 744px. Sentient uses native material/glass with opaque and increased-contrast alternatives; the HTML approximates surfaces with fills and borders. Its edge lighting is a CSS approximation of Sentient's separate blurred shapes. The specimen keeps speaker labels and a smaller 12px user-bubble radius, whereas the inspected source uses an 18pt bubble and quieter per-message chrome. These are source-observable differences, not a claim that the rendered result fails.

Functional direction remains the revised PRD: one chat for answers/tasks/steering, optional activity and evidence, approved fact/preference memory, local models only, and user-requested internet tasks permitted. Do not inherit the reference's hosted-provider paths, proactive scheduling or automatic knowledge ingestion. Seeded examples remain clearly labeled and do not establish general execution capability.

Next check is the rendered native composition: visual balance of the light, real text sizes, contrast, resizing, keyboard/VoiceOver, persistent Stop and composer focus during progress updates. The source has small 9–11px secondary labels; native validation should confirm legibility rather than copying these blindly. No screenshot or running application was inspected, and no downloaded reference app was executed. The earlier browser rendering restriction was respected.

## Native iteration — 29 October 2026

| Before | After | Why |
|---|---|---|
| Old transcript position at launch | Latest message initially visible, with a return-to-latest button | Recent results remain findable in long conversations |
| Full tool-probe diagnostics in composer | Gemma · on this Mac, diagnostics retained in Settings/help | Readable primary action area |
| Evidence printed as a long paragraph | Expandable Action evidence under each result | Keep the response readable while preserving its proof |
| Oldest Activity first | Newest entries first | Inspect current work immediately |
| Review/fixture states labeled Thinking | Distinct waiting/check labels | Status reflects actual operation |
| Decorative glow and early-build badge | Restrained surfaces, clearer type and quiet identity | Consistent native Mac assistant tone |

Release build and permission-free suite passed, including three new Finder-query regressions. Source critique found no blockers. Native inspection verified evidence expansion, newest-first Activity, Settings selected tabs and Escape dismissal. Final native seven-case fixture passed on retry; first launch returned “That application is not running.” This transient fixture-launch issue needs a cold-launch regression. Minimum-size combined review/error/six-line draft, full VoiceOver and reduced-motion audit remain not run. The older HTML prototype is not the shipping native design.

## Readability and visibility pass 30 October 2026

| Before | After | Why |
|---|---|---|
| Supporting text often10–12pt | Supporting/body text14–16pt, small badges12pt | Readable at actual window scale |
| Muted copy and faint boundaries | Brighter secondary text and stronger borders | Visible grouping and contrast |
| Gray primary buttons looked disabled | Explicit blue primary style with clear disabled state | Distinguish available actions |
| Footer hint squeezed buttons | Separate hint row and persistent footer | Compact-window navigation remains visible |
| Next setup step retained old scroll offset | Scroll container resets for each step | New headings and permission explanations start visible |
| Faint composer prompt, empty Send looked active | Explicit prompt color and disabled Send treatment | Clear input and availability |

Native Settings and onboarding visually inspected, including an approximately900×650pt compact window selected via macOS Move & Resize. Lower model controls were reachable by scrolling; footer remained visible. Verified scroll-to-bottom on model then Back produced Welcome scroll offset0. Release build and signature verification passed. Exact800×620pt and full VoiceOver audit remain unqualified. Preview: planning/onboarding-readable.png.
