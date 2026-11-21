# Sentient rendered-reference study for Relay redesign v2

Date: 20 November 2026. Read-only visual study by a separate agent. No Relay implementation changes, account actions, settings changes, task submission, or permission grants occurred in this lane. The native computer-use session is released.

## What was actually inspected

The installed running Sentient OS app (`jesai.Sentient-OS-macOS`) was raised and its current rendered conversation/error-recovery state inspected. Its current request had failed with a provider connection error; this is useful evidence of task-state presentation, not evidence of working event creation.

Finder opened the existing Desktop collection `Sentient OS Onboarding — 2026-11-19`. Each of these images was opened and visually read in Quick Look, not inferred from filenames:

| Folder | Exact filename | Visual evidence |
| --- | --- | --- |
| `02 Home and feature examples` | `029-home-initial.png` | Empty Home, broad atmosphere, single-row dock, prompt suggestions, setup panel |
| `02 Home and feature examples` | `031-home-proactive-example.png` | Expanded example, prepared-work cards, bounded contextual panel |
| `02 Home and feature examples` | `037-knowledge-project-note.png` | Project-note hierarchy, connected-note links, bounded detail surface |
| `04 Settings` | `060-settings-knowledge-sources.png` | Settings sidebar, source categories, familiar application marks, source rows |
| `04 Settings` | `061-settings-notch-shortcuts.png` | Preference rows, aligned trailing controls, large explanatory illustration |
| `05 Knowledge Analysis and notch` | `103-knowledge-empty.png` | Dedicated Knowledge toolbar, centered empty state |
| `05 Knowledge Analysis and notch` | `104-knowledge-reader-empty.png` | Reader sidebar, notes search, dedicated list/detail layout |
| `05 Knowledge Analysis and notch` | `106-sidekick-notch-idle.png` | Compact overlay, one active command, secondary text commands, minimal input |

Finder showed iCloud upload-quota warnings, but the inspected captures rendered successfully. No attempt was made to bypass Desktop terminal-access restrictions, copy the images, or change iCloud settings. Quick Look was closed at the end; Finder remains in the final reference folder.

## Observations, distinct from proposed implementation values

### Main canvas

Sentient Home is not a dashboard shell. Its main canvas has no permanent conversation-history column. A small brand and keyboard hint sit at upper left, while two named destinations and Settings occupy upper right. The header floats over the canvas without a horizontal bottom rule. Large areas remain visually empty. The title/greeting is a short human sentence rather than a dashboard heading or a grid of equal-weight cards.

The default dock is one horizontal input row with mic/send controls. Suggestions sit immediately above it. The model/provider does not occupy a second footer row inside the input. No large empty attachment-acquisition panel is visible. In the live failed-task state, the dock grows to contain recovery guidance and relevant controls; that growth communicates a real state.

The transcript and dock share a clear central alignment. User input is a softly filled, lightly outlined rounded surface; assistant text sits directly on the canvas. A small subdued work-status disclosure precedes the result. No repeated assistant avatar/name or full response toolbar is visible at rest. Named Copy/Reply actions are exposed in the accessibility tree.

### Atmosphere and materials

The Home atmosphere is broad, irregular, and diffuse. Blue occupies upper left, wine/red spreads near upper middle, a pale amber/olive light occupies the upper right/middle, and a warm brown light reaches the far right. The body becomes near-black. These lights are not confined to a visibly rectangular header strip. There is no hard cutoff line separating the colored header from the conversation. The app window shape clips the entire composition.

Controls and panels are low-chroma charcoal, with subtle borders. Most icons are monochrome outlined system symbols. Brighter white fills are reserved for a genuinely primary action. The reference does contain color in status, prepared-work accents, links, and application brands; it does not make every icon teal or give every control its own capsule.

The Settings and Knowledge screenshots constrain atmosphere to the narrow titlebar region while their working content is plain black. Home's broad glow is not repeated underneath dense preference or editor content.

### Settings

Settings uses a separate, purpose-built navigation arrangement: Home/back affordance, Settings title, grouped destination rows, and one selected row. The content begins with a page title and short explanation. Sections group related settings. Trailing menus/toggles align consistently. Preferences use separators inside one bounded group rather than nested card-on-card styling for every label.

The source page distinguishes categories with plain headings and familiar application marks. Its rows have one meaningful state/action at the end. The desktop-folder selection chips are visibly selected, communicating access. This is more informative than a decorative control grid, although the very wide source page leaves substantial unused horizontal space.

### Knowledge

Knowledge has its own Home/back and title, with two explicit view/sharing destinations. Its empty state is centered and restrained, with one illustration, one heading, and a short sentence. Reader view introduces a notes sidebar only when the user is in a browsing task. That sidebar contains a title/count, relevant status, search, and add action, with the detail pane reserved for the document.

The project example uses a small category label, a strong document title, body copy, a quiet divider, and simple linked-note rows. The example's serif document titles are distinct from the sans-serif application controls. This is a content-specific typographic choice, not a reason to introduce display type everywhere.

### Compact overlay

The notch capture has one highlighted active command, with other commands as quieter text. A brand mark, expand control, and Send define the top row. It does not repeat the entire main-window navigation. The content has a strong spatial relationship to the notch shape and one clear input/action hierarchy.

## Interpretation for Relay

The previous Relay checkpoint adopted the colors and hid response buttons, but retained a dense application shell: a persistent 256-point history wall, prominent segmented navigation, filter field, footer utilities, a ruled header, and a two-row composer. These structural choices continue to dominate the interface. Merely lowering opacity cannot address them.

The most useful reference principle is **show the surface needed for the current task**. Conversation is a quiet reading/writing space; History is a drawer; Knowledge is a list/detail workspace; Settings is preferences; task recovery expands near the composer only when needed. These surfaces should not all be visible at once.

## Concrete Relay design contract proposals

These are proposed implementation starting values, not pixel measurements claimed from the screenshots:

1. Main chat starts with History closed; one small History control opens a transient panel. Keep accessible New Chat, history search, recoverable Trash, and keyboard shortcuts inside that panel. Do not remove data or hide pending work behind it.
2. Use a continuous canvas and floating 52–60-point header with no decorative bottom rule. Left: compact Relay identity and History/New Chat affordance. Right: two meaningful destinations and Settings. Limit peer icons to one optical size/weight.
3. Center transcript and dock on the same axis, around 720–760 points maximum. On compact windows use approximately 24-point side margins; do not reserve an empty permanent sidebar column.
4. Use a one-row idle composer around 60–68 points high. Add/context, input, mic, Send share the row. Move provider selection to a compact control outside or adjacent to the dock rather than a full second shelf. Multiline drafts and real attachment/reply/recovery states may grow the composer.
5. Keep ordinary assistant prose bare, user bubbles quiet, secondary actions in one reserved hover/focus gutter. Maintain named accessibility actions and context menus. Preserve saved-note confirmation and Open/Export only after saving.
6. Use broad atmosphere behind Home, but fade it through the upper body instead of drawing a colored top band. Keep a flat, low-chroma reading region. Avoid a hard header rule and opaque sidebar masking the light. Increased Contrast/Reduced Transparency need defined solid surfaces.
7. New-chat empty state should contain a short helpful invitation and at most a few task-specific suggestions close to the composer. Remove the large numbered starter-card presentation and ornamental eyebrow. Do not add fictional productivity metrics or duplicate readiness panels.
8. Task status, review, error, Stop, and recovery remain explicit in the active task. Quiet design must not conceal the exact proposed action, chosen source, or whether a result was independently verified.
9. Give Knowledge and Settings their own purpose-specific navigation and flatter grouping. Do not carry the chat History panel and workspace header through every destination.

## Avoid copying the reference's weaknesses

- The setup-unlock panel consumes a large part of Home and duplicates capabilities already suggested near the dock. Relay does not need that permanent marketing panel.
- Sentient's live provider error is repeated in activity, result, and recovery. Relay can show one concise problem with optional technical detail and one clear recovery route.
- The illustrated orbital brand and exact wording belong to Sentient; use Relay's own identity.
- Empty Knowledge should explain the next real action clearly. Poetic imagery alone is insufficient when a user can create or import a note now.
- Do not infer Light appearance, compact-window behavior, hover animation timing, or functioning integrations from these dark still images. Root must inspect Relay's actual implementations and interactions.

## Finish checks for the implementation

Inspect the real new-chat and existing-chat surfaces at compact and wider window sizes. Check History open/close and search, long titles, multiline drafting, attachment/reply chips, active Stop/review/recovery, saved-note Open/Export, and keyboard/accessibility actions. The benchmark is reduced competing hierarchy and a coherent spatial structure, not simply fewer visible icons. No source code, screenshots, assets, or account state from Sentient were copied.

## Focused typography, icon, and color study

This section responds to the user's explicit request to refine fonts, sizes, icons, and colors. The screenshot observations establish relationships and optical hierarchy; the point sizes below are proposed Relay values. Quick Look scaling does not establish exact upstream font metrics or RGB values.

| Element | Observed relationship in the references | Proposed Relay rule |
| --- | --- | --- |
| Conversation and input | Normal sans-serif prose, clearly larger than metadata; no heavy assistant heading before each answer | System font, 15 pt regular, around 4–5 pt extra line spacing in transcript. Input also 15 pt. Preserve selection and multiline behavior. |
| Empty greeting | One restrained heading with normal sentence case; no numbered cards or ornamental eyebrow in initial Home | 25 pt medium, slightly tightened tracking (about −0.4), short copy. Supporting invitation 14–15 pt regular. |
| Header navigation | Icon and label are optical peers, compact but comfortably readable | 13 pt medium labels; 14 pt regular outlined symbols. 12.5 pt is acceptable as a secondary control, not a universal main-navigation size. |
| History destination/filter/rows | History itself is not shown in the inspected default Home; Settings/Knowledge navigation demonstrates comfortable readable destination labels | Main interactive labels and chat titles 13 pt. Metadata 11.5 pt. Do not use 10.5–11.5 pt for all interactive row labels merely to fit more rows. |
| Metadata | Subdued status/date/caption text; does not compete with prose | 11.5–12 pt regular or medium. Small counts/chevrons may be smaller; never put necessary explanation only in microcopy. |
| Document title | The Knowledge example uses a serif title distinct from application controls | A document-specific hierarchy is optional. Do not introduce a second font family into the chat, header, or settings just because the sample note uses one. |
| Primary command | Send or primary setup action has the strongest local contrast | 36 pt Send target with a 15–16 pt arrow. 32 pt targets for ordinary peer icons; 14 pt symbol weight regular. |
| Small symbol details | Down-chevron and separators are subordinate | 8–9 pt chevrons are reasonable; do not extend this size to standalone meaningful icon controls. |

### Icon consistency

The reference uses outlined system symbols at a consistent optical weight. The symbols identify the destination/action; their surrounding shapes identify interaction/state. Large circular surfaces do not appear around every ordinary navigation icon. Familiar full-color application logos occur on the source-selection page because they help identify an external app. Status may use a semantic accent. Those are intentional exceptions to the otherwise monochrome system.

Relay should use SF Symbols with regular weight for peer header controls, and optically comparable 14-point glyphs. Use stable 32-point hit regions even when the glyph is smaller. Selected/hover states can receive a faint neutral surface; at rest, keep chrome low-emphasis. Keep the Send circle, destructive semantic color only where the action is actually destructive, and a visible focus ring. Avoid mixed 11-point semibold and 16-point regular peer icons. Avoid making all icons teal; brand accent should be rare enough to carry meaning.

### Palette consistency

Observed Home palette: near-black reading area; charcoal input/panels; white primary text; neutral gray secondary text; blue/wine/amber diffuse edge light. Warm amber is a glow, not a gold border around every surface. In the examples, green and red identify distinct prepared-work states, blue identifies links, and app logos retain their recognizable color. Settings and Knowledge are quieter than Home.

Proposed Relay palette behavior:

- Use one neutral text hierarchy across the entire shell. Primary text should read white/off-white in Night and dark graphite in Light. Secondary text remains readable; reserve the most muted gray for truly optional metadata.
- Keep resting controls neutral. Use a single accent for focus/selection where needed, rather than simultaneously emphasizing brand, input border, every icon, every link, and every card.
- Use three low-opacity edge-light hues only as atmosphere. Keep the transcript neutral and do not create an opaque colored header band. A composer surface can catch some light without becoming a brightly outlined box.
- Use semantic success/warning/error colors only for real state, paired with text or an icon. Preserve sufficient contrast in Light/Night, Increased Contrast, and Reduce Transparency.
- The inspected stills do not establish Light-mode colors or exact RGB values. Those need native Relay rendering checks, not copied screenshot guesses.

### Current implementation watchpoints

At the focused source-read moment, `relayConversation` was still 14 pt even though the intended redesign body/input value is 15 pt. The sidebar filter and mode labels still referenced 11.5-point caption tokens, with 10.5-point micro metadata. Root should confirm the final version follows the readable interaction hierarchy above. Source is being edited by other lanes; this is a watchpoint, not a claim about the final rendered result.

## Independent implementation review

### This agent's direct checks

After integration, a read-only source review confirmed the 15-point conversation token, 15-point input, 25-point empty heading, 13-point history/filter, and 14-point regular header symbols. History defaults closed using the new canvas preference, and its search and thread rows remain available. The conversation/dock use a shared 720-point maximum column. Draft binding, steering submission, exact review content, reply/attachment state, stable saved-note Open/Export, and named accessible message actions remain wired.

The source review identified a consequential new state interaction: converting Activity to a modal sheet obscured the main window's Stop control. It also found the history Activity entry could reopen that sheet over a pending review. These findings were reported to root with concrete locations and a request for visible in-sheet Stop plus guards on every Activity entry.

This agent then raised the actual rebuilt Relay window and visually inspected its empty canvas at approximately 900 logical points wide. No draft was entered, task submitted, source selection changed, or appearance preference changed during this independent pass. Findings:

- The atmosphere is now broad and continuous, with an appropriately quiet reading area. The 25-point greeting and 15-point input are legible, and the small suggestion labels remain readable.
- The Add symbol rendered below the input/mic/Send centerline.
- A full-width bordered “From your day” disclosure repeated the composer's wide surface hierarchy.
- Excess vertical space separated heading/suggestions from input.
- Native Menu controls rendered Add and the header ellipsis in mint while peer icons were neutral, despite the label foreground styling; the inherited global tint needed an explicit neutral override.
- A tighter native-titlebar/header arrangement was a lower-priority refinement. Any manual leading reservation needed checks for window controls, fullscreen, and dragging.

The independent computer-use session ended with its completion summary and was released to root. No implementation source edits were made by this agent.

### Root-reported corrections and verification

The following are root's reports from its subsequent source fixes and native inspection, not a second direct visual check by this agent:

- Add and ellipsis now render neutral, and Add aligns with the composer controls in both Light and Night.
- The welcome spacing was tightened. The duplicate “From your day” surface and separate sheet were removed; the actual prepared-work deck remains accessible through Morning Brief, which already contains it.
- Activity includes a visible Stop control and the entry points guard pending review. Root ran a synthetic task through actual Codex, clicked `activity.stop`, observed “Task stopped,” and confirmed Resume remained visible.
- Recovery was reduced to a compact contextual row. The header uses a clear background with native window dragging.
- Root inspected compact/wider layouts, including the 900-point case, and reported clear window controls plus the shared 720-point reading column.

Root owns final build, signature checks, automated qualification, and any final native inspection. These reports should not be presented as independent reinspection by this lane.
