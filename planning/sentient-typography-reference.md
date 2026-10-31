# Sentient OS typography reference

Inspected 31 October 2026, upstream revision `fe28c9c14ddb5b2e63902ca137594e9c4e6bfdac`.

Source: https://github.com/Sentient-OS-Labs/sentient-os/tree/fe28c9c14ddb5b2e63902ca137594e9c4e6bfdac

| Element | Verified upstream | Relay adjustment |
| --- | --- | --- |
| Conversation | SidekickMarkdown.Style: 14.5pt regular system, 5pt line spacing | Shared body 14.5pt; assistant paragraph spacing5 |
| Composer | SidekickComposer:15pt system | Composer and placeholder15pt |
| Onboarding heading | OnboardingModelDownloadView display(30); Theme.display medium system | 30pt medium system |
| Onboarding introduction | Model download:15pt regular,4pt line spacing | Introduction15pt; existing3pt spacing retained |
| Display tracking | Theme.display explicitly uses no manual tracking | Removed negative tracking on onboarding, greeting and Settings headings |
| Small UI | Typically11–13pt, some10.5 and9pt auxiliary labels | Shared caption12pt; readable existing12–14pt controls retained |

No upstream implementation copied. Existing white primary text, slate canvas, Relay illustrations, sidebar and side activity remain. This aligns selected typography; it is not a pixel-identical recreation. Serif remains absent from Relay's main UI. SF system resolves through SwiftUI, not a bundled font file.

Build log: /tmp/relay-sentient-type-build.log
