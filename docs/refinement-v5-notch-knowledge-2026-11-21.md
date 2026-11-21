# Notch atmosphere and Knowledge reader

The user's screenshot identified competing title/action hierarchy and overly wide paragraphs in Knowledge. This pass keeps the accepted dashboard unchanged.

- Expanded Sidekick now reuses `RelayWorkspaceBackdrop` in dark appearance, replacing its old animated multicolor wash. The physical camera crown and closed hardware shell stay black. Reduced Transparency and Increased Contrast use a solid fallback. Attention/review behavior and geometry are unchanged.
- Knowledge's toolbar is 52 pt instead of 64 pt, with a 17 pt workspace heading and a subordinate New note action. Note actions use the shared ghost style. The reader header, divider and body share a centered 640 pt maximum column (including horizontal padding), making text lines shorter without changing note contents.

Qualification: 31 tests across four suites passed in 6.459 seconds, covering notch design parity, palette readability and Knowledge draft/navigation recovery. Log: `/tmp/relay-notch-knowledge-v5-tests.log`. The signed app built with strict deep verification; final log: `/tmp/relay-notch-knowledge-v5-final-build.log`. Native Night inspection confirmed the expanded Sidekick teal atmosphere and black crown, reduced Knowledge toolbar, quiet actions, centered paragraph wrapping and aligned divider. The last divider-alignment change was rebuilt and visually inspected after the test run. Other appearances, accessibility display modes and compact/notched hardware variants were not separately rendered in this pass.

An existing unsent workspace draft was restored exactly after app reloads and was never submitted. Notes were not edited and no model, permission, sharing or external action was executed. Relay is left on Knowledge for review. Changes remain uncommitted; whitespace checks pass.
