# Onboarding and workspace refresh

31 October 2026

| Before | After | Why |
| --- | --- | --- |
| Mixed serif, small monospace and sans typography | System sans headings/body, 18pt conversation text, 13–16pt secondary labels | More consistent and readable hierarchy |
| Black canvas with bright rainbow composer glow | Slate canvas, white primary text, restrained blue focus border | Clearer surfaces with less visual competition |
| Header-only navigation | Persistent wide-window sidebar for conversation, Knowledge, setup and settings | Predictable places to navigate without clearing chat |
| Activity squeezed above composer | Right activity panel on wide windows; bounded panel on narrower windows | Follow work while keeping the conversation visible |
| Plain onboarding descriptions | Native illustrated Finder example, local-model and permission scenes | Explain supported functionality without fabricated activity |
| Small transfer indicator | Actual percentage, transferred bytes, linear progress, pause/resume and separate verification state | Distinguish downloading from package checking |
| Approval content could expand indefinitely | Bounded approval scroll region with separate visible buttons | Preserve space for user decisions |

## Validation
- `swift test`: 408 tests across 66 suites passed; optional hardware tests remained opt-in.
- Debug app package built and signature verification succeeded.
- Native visual inspection: existing conversation preserved, navigation sidebar and populated side activity; all five onboarding stages inspected through native UI. Screenshots saved as `onboarding-refresh-*.png` in this directory.
- Independent source critique caught review height, duplicate navigation, status wrapping and footer crowding; these were addressed.
- No model re-download, permission changes, microphone capture or task submission performed during visual review.

## Limits
The model was already installed, so the live downloading state was not triggered for a screenshot. Progress uses the existing downloader's real state and its existing download/resume tests. Compact-window breakpoints are implemented but minimum-window visual qualification remains pending. Sidebar shows the existing conversation; multiple saved chat threads are not added in this change.
