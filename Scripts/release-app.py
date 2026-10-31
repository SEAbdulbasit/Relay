#!/usr/bin/env python3
"""Explicit distribution gates. Default is local preflight; never uploads implicitly."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parent.parent
MACHO = {b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xce\xfa\xed\xfe',
         b'\xfe\xed\xfa\xce', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca',
         b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'}


def run(args, capture=False):
    result = subprocess.run([str(x) for x in args], check=True,
                            stdout=subprocess.PIPE if capture else None,
                            stderr=subprocess.PIPE if capture else None)
    return result.stdout.decode('utf-8') if capture else ''


def developer_ids(output):
    return {fingerprint.upper(): name for fingerprint, name in
            re.findall(r'\b([0-9A-Fa-f]{40})\s+"(Developer ID Application: [^"\r\n]+)"', output)}


def choose_identity(requested, output):
    if not requested or not re.fullmatch(r'[0-9A-Fa-f]{40}', requested):
        raise ValueError('Set RELAY_RELEASE_IDENTITY to the exact40-character SHA1 of a Developer ID Application identity. No identity is selected automatically.')
    fingerprint = requested.upper()
    if fingerprint not in developer_ids(output):
        raise ValueError('The selected identity is not an available Developer ID Application identity with a private key. Development, ad-hoc and unrelated identities are refused.')
    return fingerprint


def validate_bundle(app):
    if app.is_symlink() or not app.is_dir():
        raise ValueError('Expected an ordinary app bundle.')
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != 'dev.relay.assistant' or info.get('CFBundleExecutable') != 'Relay':
        raise ValueError('Unexpected bundle identity or executable.')
    version = info.get('CFBundleShortVersionString', '')
    build = info.get('CFBundleVersion', '')
    if not re.fullmatch(r'\d+(?:\.\d+){1,2}', version) or not re.fullmatch(r'\d+(?:\.\d+){0,2}', build):
        raise ValueError('Release version/build must be numeric and safe for artifact names.')
    for relative in ['Contents/MacOS/Relay', 'Contents/Resources/ThirdPartyNotices.txt',
                     'Contents/Resources/LiteRT-LM-LICENSE.txt',
                     'Contents/Resources/RelayAccessibilityFixture.app/Contents/MacOS/RelayAccessibilityFixture']:
        if not (app / relative).is_file():
            raise ValueError('Missing required runtime, fixture or license resource: ' + relative)
    for path in app.rglob('*'):
        if path.is_symlink() and not path.resolve().is_relative_to(app.resolve()):
            raise ValueError('Bundle contains an escaping symlink.')
        if (path.name in {'TestWorkspace', 'Models', 'conversation.json', '.env', 'state.json',
                          'knowledge.json', 'writing-profile.json', 'suggestions.json',
                          'preparation-schedule.json'} or path.suffix.lower() == '.litertlm'
                or path.name.startswith(('.relay-download-', '.relay-private-write-'))):
            raise ValueError('Development/user data must not be packaged: ' + path.name)
    return version, build


def code_items(app):
    """Sign Mach-O leaves, then enclosing bundles from the inside out; no --deep signing."""
    leaves = []
    for path in app.rglob('*'):
        if path.is_file() and not path.is_symlink():
            with path.open('rb') as stream:
                if stream.read(4) in MACHO:
                    leaves.append(path)
    if app / 'Contents/MacOS/Relay' not in leaves:
        raise ValueError('Main executable is not Mach-O.')
    bundles = [p for p in app.rglob('*') if p.is_dir() and not p.is_symlink()
               and p.suffix in {'.framework', '.app', '.xpc', '.appex'}]
    return sorted(set(leaves + bundles), key=lambda p: (-len(p.parts), str(p))) + [app]


def sign(app, identity, public):
    for item in code_items(app):
        if item.is_file():
            architectures = run(['/usr/bin/lipo', '-archs', item], capture=True).split()
            if 'arm64' not in architectures:
                raise ValueError('Every embedded executable/library must support arm64; this release does not claim Intel support.')
    if run(['/usr/bin/lipo', '-archs', app / 'Contents/MacOS/Relay'], capture=True).split() != ['arm64']:
        raise ValueError('This release pipeline qualifies an arm64 main executable only. Update artifact naming and test coverage before distributing another architecture.')
    for item in code_items(app):
        command = ['/usr/bin/codesign', '--force', '--sign', identity, '--options', 'runtime']
        command += ['--timestamp'] if public else ['--timestamp=none']
        if item == app or item == app / 'Contents/MacOS/Relay':
            command += ['--entitlements', ROOT / 'Resources/Release.entitlements']
        run(command + [item])
    run(['/usr/bin/codesign', '--verify', '--deep', '--strict', '--verbose=2', app])
    details = subprocess.run(
        ['/usr/bin/codesign', '-d', '--verbose=4', str(app)], check=True, capture_output=True, text=True).stderr
    if 'runtime' not in details:
        raise ValueError('Hardened runtime flag was not verified.')
    if public and 'Authority=Developer ID Application:' not in details:
        raise ValueError('Public distribution authority was not verified.')
    entitlement_result = subprocess.run(['/usr/bin/codesign', '-d', '--entitlements', ':-', str(app)],
                                        check=True, capture_output=True)
    actual = plistlib.loads(entitlement_result.stdout)
    expected = plistlib.loads((ROOT / 'Resources/Release.entitlements').read_bytes())
    if actual != expected:
        raise ValueError('Entitlements differ from the reviewed minimal release set.')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument('--check', action='store_true', help='local prerequisite check, no build/sign/upload')
    modes.add_argument('--prepare', action='store_true', help='copy and distribution-sign the existing build, no upload')
    modes.add_argument('--notarize', action='store_true', help='sign, submit to Apple, require Accepted, staple, assess, archive')
    modes.add_argument('--runtime-candidate', '--runtime-check', dest='runtime_check', action='store_true', help='construct an ad-hoc hardened candidate only; does not launch or qualify runtime behavior')
    args = parser.parse_args(argv)
    app = ROOT / 'build/Relay.app'
    version, build = validate_bundle(app)
    identities = run(['/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning'], capture=True)
    profile = os.environ.get('RELAY_NOTARY_PROFILE', '').strip()
    requested = os.environ.get('RELAY_RELEASE_IDENTITY', '').strip()
    if args.check or not any([args.prepare, args.notarize, args.runtime_check]):
        reasons = []
        try:
            choose_identity(requested, identities)
        except ValueError as error:
            reasons.append(str(error))
        if not profile:
            reasons.append('RELAY_NOTARY_PROFILE must name credentials already stored with notarytool; no credentials are read or created here.')
        print(json.dumps({'version': version, 'build': build,
                          'availableDeveloperIDIdentities': len(developer_ids(identities)),
                          'publicPrerequisitesReady': not reasons, 'blockers': reasons,
                          'note': 'Local preflight only; profile validity, notarization and Gatekeeper remain separate gates.'}, indent=2))
        return 2 if reasons else 0
    identity = '-' if args.runtime_check else choose_identity(requested, identities)
    if args.notarize and not profile:
        raise ValueError('Set RELAY_NOTARY_PROFILE before preparing a submission. No upload occurred.')
    # Unique candidate: never overwrite the installed/running build or an older release.
    destination = ROOT / ('build/runtime-candidates' if args.runtime_check else 'dist/candidates') / uuid.uuid4().hex
    destination.mkdir(parents=True, mode=0o700)
    candidate = destination / 'Relay.app'
    run(['/usr/bin/ditto', app, candidate])
    validate_bundle(candidate)
    sign(candidate, identity, public=not args.runtime_check)
    if not args.notarize:
        print(('STATIC SIGNATURE VERIFIED; RUNTIME NOT TESTED; LOCAL CANDIDATE ONLY: ' if args.runtime_check else 'SIGNED, NOT NOTARIZED; RUNTIME QUALIFICATION STILL REQUIRED: ') + str(candidate))
        return 0
    submission = destination / 'submission.zip'
    run(['/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', candidate, submission])
    result = json.loads(run(['/usr/bin/xcrun', 'notarytool', 'submit', submission,
                             '--keychain-profile', profile, '--wait', '--output-format', 'json'], capture=True))
    (destination / 'notary-result.json').write_text(json.dumps(result, indent=2))
    if result.get('status') != 'Accepted':
        raise ValueError('Apple did not return Accepted. Candidate preserved for diagnosis; no release archive created.')
    run(['/usr/bin/xcrun', 'stapler', 'staple', candidate])
    run(['/usr/bin/xcrun', 'stapler', 'validate', candidate])
    run(['/usr/bin/codesign', '--verify', '--deep', '--strict', candidate])
    run(['/usr/sbin/spctl', '--assess', '--type', 'execute', '--verbose=2', candidate])
    archive = destination / f'Relay-{version}-{build}-macOS-arm64.zip'
    run(['/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', candidate, archive])
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    (destination / (archive.name + '.sha256')).write_text(digest + '  ' + archive.name + '\n')
    print('NOTARIZED AND STAPLED: ' + str(archive))
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, OSError, subprocess.CalledProcessError, plistlib.InvalidFileException) as error:
        # Never echo subprocess arguments/output: they may include a local keychain profile name.
        print('Release gate failed: ' + (str(error) if isinstance(error, ValueError) else type(error).__name__), file=sys.stderr)
        sys.exit(1)
