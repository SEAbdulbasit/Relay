# Reference reference: remove competing controls

20 November 2026. Independent reference review for the user's complaint about Relay's busy chat. No app, account, source selection, or provider configuration was changed in this lane. No upstream implementation was copied.

## Evidence and limits

The official website (upstream link removed) and official repository (upstream link removed) were verified today. The site presents short task handoffs and demonstrations; it does not establish that Relay can perform the same actions.

Current public `main` source was read through the official raw GitHub host. This establishes present implementation intent, not rendered appearance of the installed version. Root owns live inspection of the installed reference.

The local screenshot `planning/comparison-reference-completed.png` is an actual Reference conversation from the earlier November comparison. It shows a top navigation strip, a centered transcript, a compact composer, and per-task work disclosures. It is historical evidence. **`planning/reference-type-workspace.png` actually depicts Relay**, despite its filename; do not use it as a Reference screenshot.

## Gradient and material follow-up

The user explicitly likes Reference's gradient. Root subsequently inspected the installed app and Desktop references `upstream project Onboarding — 2026-11-19/02 Home and feature examples/029-home-initial.png` and `030-home-double-tap-example.png` through Finder Quick Look. Root observed blue at the upper left, wine near the upper center, amber at the upper right, fading into quiet black content with translucent controls. These are root's native visual observations, distinct from this lane's web/source inspection.

The current official atmosphere/material implementation (upstream link removed) confirms blurred light shapes overlapping the top edge and a smaller composer echo. Native interactive glass has an opaque accessibility fallback. The exact crown RGB values were not established in this lane; root's observed colors are the visual reference.

For Relay, retain a visible colored crown while removing competing controls. Keep the center and lower reading area neutral, soften light boundaries, and let translucent interactive surfaces catch the edge color. Check the treatment at both narrow and wide widths. A static backdrop can express this identity without introducing a continuously running animation; reduced-transparency and contrast settings still need appropriate solid surfaces. The gradient is part of the requested direction and should remain recognizable in the new composition.

## What creates the quietness

**Conversation text receives the attention.** The current transcript implementation uses a user bubble and unboxed assistant Markdown, without a repeated speaker badge. Secondary copy/date controls appear on hover in a reserved gutter, so their arrival does not move the text. Context-menu and accessibility actions remain available independently of hover. The source bounds the transcript at 800 points and uses 18-point row spacing. Official transcript source, lines 79–132 and 296–359 (upstream link removed).

**The composer is an input, not a feature shelf.** The current source places the field, dictation, and Send/Stop in one primary row. Input is 15-point system type, expands to five lines, and uses a 36-point primary control. Reply/recovery context appears conditionally. This does not support keeping an empty visual-context acquisition panel open during an ordinary calendar conversation. Official composer source, lines 39–167 (upstream link removed).

**Navigation adapts to the active task.** Home's conversation toolbar compresses navigation labels at narrow widths. Status belongs in the Analysis popover, not a permanent competing dashboard. The composer has a 744-point maximum width. The historical completed-work screenshot also demonstrates task activity as a local disclosure rather than a permanently occupied side column. Official Home source, lines 369–406 and 943–967 (upstream link removed).

## Apply to Relay, in this order

1. **Remove the empty visual-context panel.** Attachment acquisition belongs in one Add menu. Show a compact context chip only for an actual selected item; an explicit picker can be transient. Preserve removal and scope visibility.
2. **Remove repeated message furniture.** Ordinary responses should read as prose. Move Copy/Save/Reply/Regenerate into a small reachable action menu or hover gutter, while maintaining keyboard and accessibility access. Saved-result confirmation and errors can remain explicit when an action occurs.
3. **Remove persistent row deletion buttons.** History is for finding a conversation. Put recoverable Trash in the selected row's menu and a stable History action entry rather than drawing a trash can beside every title.
4. **Reduce composer decisions.** Keep one visible attachment affordance, a compact model selector, input, dictation, and Send/Stop. Group optional transformations in the attachment/action menu. Avoid a second execution button that competes with Send.
5. **Unify icon treatment.** Use one system-symbol weight and optical size for peer controls; remove unnecessary circular/pill backgrounds around secondary icons. Reserve shape/emphasis for the primary action and meaningful state.
6. **Keep status close to the relevant work.** Retain a concise current-task line and optional evidence detail. Stop, pending approval, errors, and recovery must remain discoverable; quiet presentation must not conceal a consequential decision.

These recommendations are a design interpretation of the verified reference and the user's Relay screenshot. The useful change is a smaller number of competing elements. Another palette, larger hero, or extra decorative card would not resolve the reported clutter.

## Finish gate

Compare the user's calendar conversation at the same window size before/after: no empty attachment banner; no repeated assistant badge; no permanently visible full action strip on every message; no row of trash cans; Send and Stop unambiguous. Check pointer, keyboard, and accessibility action access, saved-note Open/Export, and approval/recovery states. Calendar creation still requires its own provider/tool routing and exact review/readback qualification.
