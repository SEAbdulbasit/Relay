# Relay distribution gates

30 October 2026. Public distribution is blocked by missing Developer ID Application identity/private key and notary credentials on this Mac. Two Apple Development identities were available; neither was selected or substituted. No Apple account/certificate was created, no agreement accepted, no password read and no binary uploaded.

## Implemented pipeline

`python3 Scripts/release-app.py --check` performs local preflight only. Exit2 and a JSON blocker list are expected until prerequisites exist. It never builds, signs or uploads by default.

`--prepare` copies the existing release build into a new unique candidate, validates bundle identity/licenses/no escaping symlinks or known development-data folders, checks arm64 support in all embedded Mach-O code and arm64-only main executable, signs leaves and enclosing bundles inside out with hardened runtime and secure timestamps, then verifies signatures, authority and exact reviewed entitlements. The current bundle identifier stays `dev.relay.assistant`, preserving the existing app identity. This mode does not upload or claim notarization.

Set `RELAY_RELEASE_IDENTITY` to the exact40-character certificate SHA1 for a usable **Developer ID Application** identity. Names, development identities, ad-hoc and unavailable identities are refused. The script never auto-selects another person's account. `RELAY_NOTARY_PROFILE` names an existing notarytool keychain credential profile; credentials are never supplied on the command line by this script or printed in its failure messages.

`--notarize` explicitly signs a unique candidate, archives only that app, submits to Apple, requires status **Accepted**, staples/validates the ticket, verifies the signature and requires Gatekeeper assessment before creating the final ZIP and SHA256. Failed candidates remain for diagnosis; the installed/running app and prior release files are not overwritten. The script does not publish a website, release or download link. Profile validity, server acceptance and Gatekeeper cannot be certified by local preflight.

`--runtime-candidate` (legacy alias `--runtime-check`) constructs a separate ad-hoc hardened candidate for local engine testing, with no upload and explicit **STATIC SIGNATURE VERIFIED; RUNTIME NOT TESTED; LOCAL CANDIDATE ONLY** output. This is not a distribution signature or Gatekeeper approval. Library/team validation may differ from actual Developer ID signing, so it cannot replace the final certificate-backed test.

The reviewed host entitlements contain Audio Input and Calendars because those existing optional features access protected resources; user consent is still required separately. No get-task-allow, JIT exception, unsigned executable memory or disabled-library-validation entitlement is added speculatively. Fixture/helper code receives no host entitlements. Any LiteRT incompatibility under hardening must be investigated and qualified before adding a narrowly justified exception.

## Checks and remaining gates

Eight Python tests cover both browser fixture and release gates. Release cases check exact identity type/private-key inventory, private-data/escaping-symlink refusal, inside-out ordering and missing notarization credentials refusing before signing/upload/candidate creation. Actual release preflight reports zero Developer ID identities and no configured profile. Main executable is arm64; embedded LiteRT dylib includes arm64 and x86_64; Relay does not claim an Intel main build.

Public release still requires: owner's certificate/private key; existing notary profile; actual certificate-backed hardened model/AX/microphone/calendar tests; Apple Accepted response; stapled-ticket validation; Gatekeeper assessment; clean second-Mac/quarantine launch; offline model readiness and device/browser matrices. Local ad-hoc success does not satisfy these gates.

Apple references: [notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution), [inside-out signing](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac), [hardened runtime](https://developer.apple.com/documentation/security/hardened-runtime), [Audio Input entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.audio-input).

## Actual hardened candidate result

`--runtime-check` successfully copied and signed a separate candidate inside out, verified nested code/hardened flags/exact entitlements and printed LOCAL HARDENED TEST ONLY. Native launch then failed before UI with DYLD Library missing for `@rpath/libCLiteRTLM_mac.dylib`; the main bundle has the packaged Frameworks rpath. The crash report reason is OS-truncated, so a Team-ID/library-validation cause is a hypothesis, not established evidence. No runtime exception was added and no Gatekeeper/security setting was weakened. This is a failed hardened launch, not model qualification. The regular ad-hoc build subsequently relaunched and passed its Gemma tool probe. The candidate remains under build/runtime-candidates for diagnosis, not distribution.

The failed candidate was preserved as `build/runtime-candidates/6bb8395cbb904410b08706f1f815d4e2/Relay.hardened-launch-failed` so it no longer advertises a second runnable .app. The latest preflight remains blocked with zero Developer ID identities; no Apple upload was attempted.
