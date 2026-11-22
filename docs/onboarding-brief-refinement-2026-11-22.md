# Onboarding simplification and Morning Brief scrolling

## Changes

The Instant Draft step now teaches the real Magic Reply name through a single message/reply example. App context and tone are compact menus, with one primary Try action. The fictional-data/no-app-changes boundary remains explicit. The other action simulators, Memory/Brief preview and command-bar preview remain available under a disclosure. Legacy hardware-style simulators keep a dark surface when expanded so their white foregrounds remain readable in either surrounding appearance.

Model selection uses quiet wrapping controls rather than a capsule strip. Provider setup loses its outer card; routing illustrations are disclosed below the connection actions. All connection, verification, model-selection and error handlers remain intact. Source choices use neutral symbols and restrained selection treatment, with an adaptive grid for local-folder choices. Apple Mail selection copy no longer asserts a permission result from a selection flag. The large handoff banner becomes a plain status section. Back/Finish-later controls use the shared button styles, and setup shares the workspace atmosphere.

The background-indexing dialog uses a 17 pt compact title, open rows, neutral icons, shared action buttons and full wrapping text. Indexing, scheduler, login-item and finish actions retain their existing behavior. No operational button was executed during visual checks.

Morning Brief plans open in a readable preview with numbered steps and complete notes. Edit plan restores the existing editable title/goal/target/steps controls and their update bindings; Done editing returns to reading without a new save boundary. Other artifact editors remain available. The header occupies fewer rows and initial focus goes to Done rather than automatically selecting the first title field. The card deck retains its intrinsic vertical size, initial scroll position is top-aligned, and content has edge padding. Pager drags now run simultaneously with scrolling and only turn pages when horizontal travel dominates vertical travel. This addresses the screenshot's cramped scroll region and the gesture competition that could prevent reaching the footer.

## Verification

- **46 tests across five suites passed** in 41.318 seconds: onboarding, notch parity, palette readability, Brief handoffs and proactive suggestions. Log: `/tmp/relay-onboarding-brief-v7-tests.log`.
- Signed debug app and strict deep signature verification passed. Final log: `/tmp/relay-onboarding-brief-v7-qualified-build.log`.
- Native Night checks covered the simplified demo at wide and compact tiled sizes, fictional Try → ready/unsent state, compact model setup, source setup and the background-indexing dialog.
- Native Brief checks confirmed the initial top position, readable plan preview, available editor, and fully visible Snooze/Dismiss/Run actions after scrolling to the bottom in both reading and editing modes. No card text was edited and no plan was run.
- The final visual adjustments after the test run were compiled. Alternate provider forms, advanced simulator variants, Light/accessibility display modes and empty/error states were not all freshly rendered; they are not claimed as universally passed.

The original workspace draft was restored exactly after reloads and not submitted. The previous window layout was restored after the compact check. Real sources, permissions, accounts, scheduler and login registration were not changed during qualification. Changes are uncommitted for review.
