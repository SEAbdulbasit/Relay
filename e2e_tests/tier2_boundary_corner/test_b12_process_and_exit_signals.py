import unittest
from pathlib import Path
from e2e_tests.common.test_base import RelayE2ETestBase

class TestB12ProcessAndExitSignals(RelayE2ETestBase):
    """
    Boundary B12: Process Signals & Script Exit Integrity
    Verifies that shell scripts use strict error modes (set -euo pipefail),
    app handles termination signals cleanly, and rpath linking is verified.
    """

    def setUp(self):
        self.build_script = self.scripts_dir / "build-app.sh"
        self.download_script = self.scripts_dir / "download-gemma.py"
        self.main_view = self.sources_relay / "MainView.swift"
        self.build_content = self.build_script.read_text(encoding="utf-8")
        self.main_content = self.main_view.read_text(encoding="utf-8")

    def test_b12_01_build_script_uses_strict_flags(self):
        """Verifies build-app.sh enables set -euo pipefail for bulletproof error handling."""
        self.assertIn("set -euo pipefail", self.build_content)

    def test_b12_02_build_script_path_isolation(self):
        """Verifies build script establishes clean safe PATH."""
        self.assertIn('export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"', self.build_content)

    def test_b12_03_app_handles_will_terminate_notification(self):
        """Checks app-owned termination registration independent of workspace views."""
        lifetime = (self.sources_relay / "AssistantApplicationLifetime.swift").read_text(encoding="utf-8")
        store = (self.sources_relay / "AssistantStore.swift").read_text(encoding="utf-8")
        self.assertIn("willTerminateNotification", lifetime)
        self.assertIn("applicationLifetime = AssistantApplicationLifetime", store)
        self.assertIn("self?.stopForTermination()", store)

    def test_b12_04_download_script_checks_sha256(self):
        """Verifies download-gemma.py checks SHA-256 checksum."""
        if self.download_script.exists():
            content = self.download_script.read_text(encoding="utf-8")
            has_sha = "hashlib" in content or "sha256" in content.lower()
            self.assertTrue(has_sha)

    def test_b12_05_rpath_configuration_avoids_dylib_load_failure(self):
        """Verifies install_name_tool adds @executable_path/../Frameworks rpath."""
        self.assertIn("install_name_tool -add_rpath", self.build_content)
        self.assertIn("@executable_path/../Frameworks", self.build_content)
