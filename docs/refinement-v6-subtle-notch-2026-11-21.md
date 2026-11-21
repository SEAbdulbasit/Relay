# Subtle notch and secondary-screen check

The notch backdrop now renders at 22% opacity over its dark base, retaining a faint teal tint and the black hardware crown rather than the stronger full workspace atmosphere. Native expanded Sidekick inspection confirmed the quieter result.

Secondary-page inspection covered Sidekick & Shortcuts, Permissions, Knowledge & Memory (including expanded index/sharing content), Magic Reply, Automation, populated Morning Brief and idle Voice Input. Large disclosure outlines, repeated Details/Hide labels and circled chevrons added unnecessary visual weight across these screens. The shared disclosure style now uses a plain full-row control with one regular chevron, hover fill and an explicit keyboard-focus outline. Reduced Motion disables its expansion animation. Native Automation expansion/collapse and Voice Input rendering were checked after rebuilding. Magic Reply's duplicate workspace-provider explanation was removed; its live status remains visible and was verified.

Signed debug build and strict deep signature verification passed: `/tmp/relay-refinement-v6-qualified-build.log`. `git diff --check` passes. No new tests were added or run for these visual-only changes. Inspection used Night; Light, increased contrast, reduced transparency, actual keyboard focus and conditional loading/error states were not freshly exercised.

The existing workspace draft was restored exactly after reload and not submitted. No source, model, permission, scheduler, sharing or recording preference was changed, and no preparation or external action was executed. Sidekick is left expanded for review. Changes remain uncommitted.
