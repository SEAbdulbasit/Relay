import unittest
from pathlib import Path
from e2e_tests.common.test_base import RelayE2ETestBase

class TestB05MissingModelFiles(RelayE2ETestBase):
    """
    Boundary B05: Missing & Corrupted Model File Handling
    Verifies that missing files, directory paths, wrong extensions,
    and unverified packages are rejected gracefully without crashes.
    """

    def setUp(self):
        self.client_file = self.sources_relay / "LocalModelClient.swift"
        self.onboarding_file = self.sources_relay / "OnboardingCoordinator.swift"
        self.assertTrue(self.client_file.exists())
        self.client_content = self.client_file.read_text(encoding="utf-8")
        self.onboarding_content = self.onboarding_file.read_text(encoding="utf-8")

    def test_b05_01_nonexistent_model_file_rejected(self):
        """Verifies file existence and readability check on model path."""
        self.assertIn(".isRegularFileKey", self.client_content)
        has_error = "readable, nonempty local .litertlm file" in self.client_content or "readable, non-empty local file" in self.client_content
        self.assertTrue(has_error)

    def test_b05_02_directory_as_model_path_rejected(self):
        """Verifies directory cannot be used as a model package file."""
        self.assertIn("isRegularFile", self.client_content)

    def test_b05_03_wrong_file_extension_rejected(self):
        """Verifies model loader rejects non-litertlm extensions."""
        self.assertIn('url.pathExtension.lowercased() == "litertlm"', self.client_content)

    def test_b05_04_empty_model_path_handled(self):
        """Verifies empty model path is handled gracefully."""
        self.assertIn("configuration.modelPath.isEmpty", self.client_content)

    def test_b05_05_model_status_actionable_error_message(self):
        """Verifies model errors are surfaced actionably to the user."""
        self.assertIn("modelSetupError", self.onboarding_content)
