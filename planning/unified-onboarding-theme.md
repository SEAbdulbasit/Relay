# Onboarding theme unification

31 October 2026

The previous onboarding used the same colors but a different layout language. This revision makes setup a workspace in the same macOS app.

| Before | After | Why |
| --- | --- | --- |
| Centered marketing hero,30pt heading and eyebrow | Left-aligned22pt medium heading,14.5pt body | Matches the app's settings/workspace hierarchy |
| Separate horizontal step-progress header | Same56pt toolbar as Main;208pt setup sidebar on wide windows | Shared navigation geometry |
| Large blue gradient illustration panel | Neutral cardBG,10pt radius and restrained focus accents | Same surfaces as the main app |
| Footer actions stretched to window edges |680pt content/footer bounds share alignment | Consistent reading and action column |
| Repeated privacy cards | Separated rows | Less container noise |
| Setup presented as a separate landing page | Neutral background, shared glyph, borders, type and controls | Clear continuity into the product |

## Verification
-411 tests across67 suites passed,5.450 seconds.
-Debug app package built with strict deep signature verification.
-Native captures: wide and compact welcome; compact Privacy, loaded Model, Access, First task.
-No permission changes, model downloads, recording or task submission. User navigation/input changes were respected after refreshing UI state.

Screenshots in this directory: `unified-onboarding-wide.png`, `unified-onboarding-compact.png`, `unified-onboarding-privacy.png`, `unified-onboarding-model.png`, `unified-onboarding-access.png`, `unified-onboarding-first-task.png`.

Live download/errors and active recording remain outside this visual qualification. Existing real progress and permission guards are preserved.
