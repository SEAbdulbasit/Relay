import hashlib
import io
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest


UPDATER = Path(__file__).resolve().parents[1] / 'update-agent-desktop.sh'
VENDOR_TOOL = UPDATER.with_name('agent-desktop-vendor.py')


@unittest.skipUnless(platform.system() == 'Darwin', 'requires macOS directory exchange')
class AgentDesktopUpdateTests(unittest.TestCase):
    def test_failed_updates_keep_the_complete_previous_runtime(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scripts = root / 'Scripts'
            scripts.mkdir()
            script = scripts / UPDATER.name
            shutil.copyfile(UPDATER, script)
            shutil.copyfile(VENDOR_TOOL, scripts / VENDOR_TOOL.name)

            remote = root / 'remote'
            remote.mkdir()
            curl = root / 'curl'
            curl.write_text('#!/bin/bash\nset -eu\nshift\ncp "$RELAY_TEST_REMOTE/${1##*/}" "$3"\n')
            curl.chmod(0o755)
            env = dict(os.environ, RELAY_TEST_REMOTE=str(remote), PATH=f'{root}:{os.environ["PATH"]}')
            vendor = root / 'Vendor' / 'agent-desktop'

            def update(version):
                return subprocess.run(['/bin/bash', script, 'v' + version], env=env,
                                      capture_output=True, text=True)

            self.make_release(remote, '1.0.1')
            result = update('1.0.1')
            self.assertEqual(result.returncode, 0, result.stderr)
            old_files = self.contents(vendor)
            snapshot = root / 'snapshot'
            subprocess.run([sys.executable, VENDOR_TOOL, 'snapshot', vendor, snapshot],
                           check=True, capture_output=True)
            for failure in ['checksum', 'missing header', 'wrong version']:
                with self.subTest(failure=failure):
                    self.make_release(remote, '1.0.2', failure)
                    result = update('1.0.2')
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    self.assertEqual(self.contents(vendor), old_files)

            self.make_release(remote, '1.0.2')
            result = update('1.0.2')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((vendor / 'VERSION').read_text(), '1.0.2\n')
            self.assertEqual((vendor / 'include/agent_desktop.h').read_text(), '1.0.2')
            self.assertEqual(self.contents(snapshot), old_files)
            self.assertEqual(list(vendor.parent.iterdir()), [vendor])

            (vendor / 'lib/libagent_desktop_ffi.dylib').unlink()
            result = subprocess.run([sys.executable, VENDOR_TOOL, 'snapshot', vendor, root / 'invalid'],
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('libagent_desktop_ffi.dylib', result.stderr)
            self.assertFalse((root / 'invalid').exists())

    @staticmethod
    def contents(directory):
        return {p.relative_to(directory): p.read_bytes() for p in directory.rglob('*') if p.is_file()}

    @staticmethod
    def make_release(remote, version, failure=None):
        architecture = 'aarch64' if platform.machine() in ('arm64', 'aarch64') else 'x86_64'
        suffix = f'v{version}-{architecture}-apple-darwin'
        cli = remote / f'agent-desktop-{suffix}.tar.gz'
        ffi_root = f'agent-desktop-ffi-{suffix}'
        ffi = remote / f'{ffi_root}.tar.gz'
        reported_version = '0.0.0' if failure == 'wrong version' else version
        cli_script = f'#!/bin/sh\nprintf "%s\\n" \'{{"ok":true,"data":{{"version":"{reported_version}"}}}}\'\n'
        ffi_files = {'lib/libagent_desktop_ffi.dylib': version,
                     'lib/agent-desktop-macos-helper': version, 'LICENSE': version}
        if failure != 'missing header':
            ffi_files['include/agent_desktop.h'] = version

        for archive, files in [(cli, {'agent-desktop': cli_script, 'agent-desktop-macos-helper': version}),
                               (ffi, {f'{ffi_root}/{name}': body for name, body in ffi_files.items()})]:
            with tarfile.open(archive, 'w:gz') as tar:
                for name, body in files.items():
                    data = body.encode()
                    entry = tarfile.TarInfo(name)
                    entry.size = len(data)
                    tar.addfile(entry, io.BytesIO(data))

        (remote / 'checksums.txt').write_text(''.join(
            f'{hashlib.sha256(archive.read_bytes()).hexdigest()}  {archive.name}\n'
            for archive in (cli, ffi)))
        if failure == 'checksum':
            ffi.write_bytes(b'tampered')
