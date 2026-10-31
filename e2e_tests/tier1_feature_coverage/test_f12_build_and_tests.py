import unittest
import os
from pathlib import Path
from e2e_tests.common.test_base import RelayE2ETestBase

class TestF12BuildAndTests(RelayE2ETestBase):
    """
    Feature 12: Build Script & Test Suite Verification
    Tests build-app.sh structure, execution permissions, codesigning integrity,
    Package.swift target definitions, and unit test suites layout.
    """

    def setUp(self):
        self.build_script = self.scripts_dir / "build-app.sh"
        self.package_swift = self.project_root / "Package.swift"
        self.assertTrue(self.build_script.exists(), "Scripts/build-app.sh must exist")
        self.assertTrue(self.package_swift.exists(), "Package.swift must exist")
        self.script_content = self.build_script.read_text(encoding="utf-8")
        self.package_content = self.package_swift.read_text(encoding="utf-8")

    def test_f12_01_build_script_exists_and_executable(self):
        """Verifies build-app.sh has executable permissions."""
        is_executable = os.access(self.build_script, os.X_OK)
        self.assertTrue(is_executable, "Scripts/build-app.sh must be executable")

    def test_f12_02_build_script_targets_release_and_debug(self):
        """Verifies build-app.sh accepts configuration and builds both products."""
        self.assertIn("configuration=", self.script_content)
        self.assertIn("swift build -c", self.script_content)
        self.assertIn("--product Relay", self.script_content)
        self.assertIn("--product RelayAccessibilityFixture", self.script_content)

    def test_f12_03_build_script_codesign_and_verification(self):
        """Verifies build script performs strict deep codesigning and verification."""
        self.assertIn("codesign --force --deep", self.script_content)
        self.assertIn("codesign --verify --deep --strict", self.script_content)

    def test_f12_04_package_swift_declares_test_target(self):
        """Verifies Package.swift declares RelayTests testTarget."""
        self.assertIn('.testTarget(name: "RelayTests"', self.package_content)

    def test_f12_05_package_swift_isolated_mainactor(self):
        """Verifies strict Swift 6 concurrency and MainActor isolation settings."""
        self.assertIn(".defaultIsolation(MainActor.self)", self.package_content)

    def test_f12_06_unit_test_suites_inventory(self):
        """Verifies essential test suites exist in Tests/RelayTests/."""
        relay_tests_dir = self.tests_dir / "RelayTests"
        self.assertTrue(relay_tests_dir.exists(), "Tests/RelayTests must exist")
        for expected in ["OnboardingTests.swift", "CompletionLoopTests.swift", "LocalModelTests.swift"]:
            suite_path = relay_tests_dir / expected
            self.assertTrue(suite_path.exists(), f"Expected unit test suite {expected} must exist")
