# Knowledge: shared Relay page language

This lane edits only `KnowledgeView.swift` and `KnowledgeDeskOverview.swift`. It extends the shared ink/porcelain, restrained teal and rounded control language owned by the parent implementation. It does not change note storage, source selection, graph data, sharing policy, or guarded navigation.

## Visual changes

- Knowledge has a 24 pt shared page title and a 64 pt working toolbar, with flat 32 pt Library/Constellation controls and teal selected state. The old nested segmented card is removed; source/note counts remain available in the wide layout.
- The library sidebar is 240 pt, with a 13 pt search field and 32 pt targets. Domain filters use quiet rounded rectangles rather than gold-outlined capsules. Folder and note chrome uses neutral symbols with teal selection, while graph content retains its data model.
- Reader titles use the shared 24 pt scale. Note/source classifications use 12 pt sentence-case metadata; prose and generated excerpts use readable 15 pt system type. Heading, bullet, quote and link styling no longer introduces a separate gold/purple palette.
- Library overview uses a compact factual heading, small real counts and plain document rows with separators. It removes the independent 40 pt editorial hero, tracked eyebrow and highlighted card behind every row.
- Knowledge preferences use the shared solid page panel treatment. Existing sharing, source indexing, error/warning states and recovery paths remain available.

## Preservation and verification

All callbacks, bindings, accessibility identifiers, note identities, editor checkpointing, navigation guards, Trash actions, source revalidation and share actions are retained. No account or native UI actions were performed in this lane. No tests or builds were started, avoiding shared SwiftPM contention.

Both edited Swift files pass `swiftc -frontend -parse`; scoped `git diff --check` passes. The parent owns compilation, native rendering at narrow/wide sizes, keyboard/accessibility interaction, draft/recovery regression tests and final signature verification. In particular, the header's ViewThatFits fallback retains Library/Constellation labels while omitting wide metadata and reducing adaptive button labels.
