import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('relay_release', Path(__file__).resolve().parents[1] / 'release-app.py')
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


class ReleaseGateTests(unittest.TestCase):
    def fixture(self, folder):
        app = Path(folder) / 'Relay.app'
        for relative in ['Contents/MacOS/Relay', 'Contents/Resources/ThirdPartyNotices.txt',
                         'Contents/Resources/LiteRT-LM-LICENSE.txt',
                         'Contents/Resources/RelayAccessibilityFixture.app/Contents/MacOS/RelayAccessibilityFixture']:
            path = app / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'\xcf\xfa\xed\xfe' if '/MacOS/' in relative else b'license')
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'dev.relay.assistant', 'CFBundleExecutable': 'Relay',
            'CFBundleShortVersionString': '0.1.0', 'CFBundleVersion': '1'}))
        return app

    def test_only_exact_developer_id_with_private_key_is_selected(self):
        fingerprint = 'A' * 40
        output = f'1) {fingerprint} "Developer ID Application: Fixture (TEAM)"\n2) {"B" * 40} "Apple Development: Fixture (TEAM)"'
        self.assertEqual(release.choose_identity(fingerprint.lower(), output), fingerprint)
        for selected in ['', '-', 'Developer ID Application: Fixture (TEAM)', 'B' * 40, 'C' * 40]:
            with self.assertRaises(ValueError):
                release.choose_identity(selected, output)

    def test_bundle_rejects_private_data_and_escaping_symlinks(self):
        with tempfile.TemporaryDirectory() as temp:
            app = self.fixture(temp)
            self.assertEqual(release.validate_bundle(app), ('0.1.0', '1'))
            private = app / 'Contents/Resources/Models'
            private.mkdir()
            with self.assertRaises(ValueError):
                release.validate_bundle(app)
            private.rmdir()
            for filename in ['state.json', 'knowledge.json', 'writing-profile.json',
                             'suggestions.json', 'preparation-schedule.json', 'private.litertlm',
                             '.relay-download-fixture', '.relay-private-write-fixture']:
                item = app / 'Contents/Resources' / filename
                item.write_bytes(b'fixture')
                with self.assertRaises(ValueError, msg=filename):
                    release.validate_bundle(app)
                item.unlink()
            (app / 'Contents/Resources/escape').symlink_to(Path(temp).parent)
            with self.assertRaises(ValueError):
                release.validate_bundle(app)

    def test_nested_code_is_signed_before_containing_bundle(self):
        with tempfile.TemporaryDirectory() as temp:
            app = self.fixture(temp)
            framework = app / 'Contents/Frameworks/Test.framework'
            framework.mkdir(parents=True)
            (framework / 'Test').write_bytes(b'\xcf\xfa\xed\xfe')
            items = release.code_items(app)
            self.assertLess(items.index(framework / 'Test'), items.index(framework))
            fixture = app / 'Contents/Resources/RelayAccessibilityFixture.app'
            self.assertLess(items.index(fixture / 'Contents/MacOS/RelayAccessibilityFixture'), items.index(fixture))
            self.assertEqual(items[-1], app)

    def test_notarization_missing_credentials_never_signs_or_uploads(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            app = self.fixture(root / 'build')
            fingerprint = 'A' * 40
            identity = f'1) {fingerprint} "Developer ID Application: Fixture (TEAM)"'
            with patch.object(release, 'ROOT', root), patch.object(release, 'run', return_value=identity) as runner, patch.dict(
                    'os.environ', {'RELAY_RELEASE_IDENTITY': fingerprint, 'RELAY_NOTARY_PROFILE': ''}):
                with self.assertRaises(ValueError):
                    release.main(['--notarize'])
                self.assertEqual(runner.call_count, 1)
                self.assertEqual(runner.call_args.args[0][0], '/usr/bin/security')
                self.assertFalse((root / 'dist').exists())


if __name__ == '__main__':
    unittest.main()
