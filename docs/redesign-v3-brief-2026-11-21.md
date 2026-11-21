# Morning Brief: shared Relay page language

This lane changed only `Sources/Relay/MorningBriefView.swift`. It uses the shared Relay page typography, background and panels supplied by the parent rather than the prior multicolor badge/card treatment.

The page header now has a 24 pt title and Done action, a 13 pt source/read-only explanation, and a separate compact action row. The segmented view choice, Instructions and Prepare/Stop actions remain present; the two-row arrangement avoids crowding the 820 pt minimum sheet. Empty states use 24 pt outlined symbols and 14 pt section headings instead of oversized gold artwork. Body copy is 13 pt, metadata 12 pt, peer symbols 14 pt regular, and paging targets 32 pt. Neutral panels and teal affordances connect the Brief to Home, Settings and Knowledge. Verification, warning and failure colors remain semantic.

The card deck, editable artifacts and welcome-note banner use the shared panel vocabulary. The inset artifact editor remains a distinct form surface so field boundaries are readable. No content preparation, source access, scope, launch, review, verification, cancellation, editing, snooze or dismissal behavior was changed. All existing accessibility identifiers were retained. The factual read-only explanation and source/verification qualifiers remain visible.

Validation in this lane: Swift frontend parsing and scoped `git diff --check` passed. No builds, runtime tests, account operations or native UI interactions were performed; the parent owns integration and rendered verification.

## Secondary page follow-up

At the parent's explicit request, this lane also aligned `VoiceInputView.swift`, `SpeechOutputView.swift`, `WritingProfileView.swift`, `DiagnosticsView.swift` and `ConversationTrashView.swift`. Full-sheet Voice Input and Conversation Trash use 24 pt page titles and the shared page background. Embedded speech, writing-profile and diagnostics sections use 14 pt section titles so they do not compete with Settings' own page heading. Forms use 13 pt type, metadata 12 pt, and section symbols 14 pt regular. Decorative coral/purple/green icon tiles and lit/glass card treatments were replaced with neutral outlined symbols and shared panels. Recording/error/success colors and every operational qualifier remain intact; the transcript stays 15 pt. Voice Input is 660 pt wide to accommodate the shared title scale and its labelled footer actions.

No permission, recording, recognition, diagnostics export, writing approval, restore or destructive action was executed or changed. The diagnostics exporter and log/data formatting remain unchanged. Scoped Swift frontend parsing and `git diff --check` passed for all five additional files. The parent owns compilation and native render checks.
