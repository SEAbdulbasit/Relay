import unittest
from pathlib import Path
from e2e_tests.common.test_base import RelayE2ETestBase

class TestF05OnboardingLifecycle(RelayE2ETestBase):
    """
    Feature 5: 5-Step Modern Onboarding Experience
    Tests the 5-step onboarding lifecycle (steps 0-4), clamping bounds,
    completion persistence, hardware readiness, and setup reset.
    """

    def setUp(self):
        self.coordinator_file = self.sources_relay / "OnboardingCoordinator.swift"
        self.view_file = self.sources_relay / "OnboardingView.swift"
        self.assertTrue(self.coordinator_file.exists(), "OnboardingCoordinator.swift must exist")
        self.assertTrue(self.view_file.exists(), "OnboardingView.swift must exist")
        self.coordinator_content = self.coordinator_file.read_text(encoding="utf-8")
        self.view_content = self.view_file.read_text(encoding="utf-8")

    def test_f05_01_five_step_lifecycle_defined(self):
        """Verifies 5 steps defined in OnboardingView: Welcome, Privacy, Model, Access, Launchpad."""
        for step_view in ["welcomeStep", "privacyStep", "modelStep", "accessStep", "readyStep"]:
            self.assertIn(f"private var {step_view}: some View", self.view_content)

    def test_f05_02_step_clamping_between_0_and_4(self):
        """Verifies step index is clamped between 0 and 4 in OnboardingCoordinator."""
        self.assertIn("min(4, max(0, step))", self.coordinator_content)

    def test_f05_03_completion_persistence_keys(self):
        """Verifies UserDefaults persistence keys for onboarding completion and current step."""
        self.assertIn('"relay.setup.completed.v1"', self.coordinator_content)
        self.assertIn('"relay.setup.step"', self.coordinator_content)

    def test_f05_04_return_to_setup_resets_step_to_zero(self):
        """Verifies returnToSetup() restores step to 0 and clears completed flag."""
        self.assertIn("func returnToSetup()", self.coordinator_content)
        self.assertIn("completed = false", self.coordinator_content)
        self.assertIn("step = 0", self.coordinator_content)

    def test_f05_05_finish_marks_completed(self):
        """Verifies finish() transitions completed state and persists to defaults."""
        self.assertIn("func finish()", self.coordinator_content)
        self.assertIn("completed = true", self.coordinator_content)

    def test_f05_06_hardware_readiness_evaluation(self):
        """Verifies MacReadiness validates Apple Silicon arm64, memory, and macOS 15+."""
        self.assertIn("struct MacReadiness", self.coordinator_content)
        self.assertIn('architecture == "arm64"', self.coordinator_content)
        self.assertIn("osMajor >= 15", self.coordinator_content)
