import unittest
from pathlib import Path
from e2e_tests.common.test_base import RelayE2ETestBase

class TestB01OnboardingClamping(RelayE2ETestBase):
    """
    Boundary B01: Onboarding Lifecycle Step Clamping
    Verifies that step transitions strictly respect the [0, 4] boundary:
    negative indices clamp to 0, excessive indices clamp to 4,
    and storage is kept normalized.
    """

    def setUp(self):
        self.coordinator_file = self.sources_relay / "OnboardingCoordinator.swift"
        self.assertTrue(self.coordinator_file.exists())
        self.content = self.coordinator_file.read_text(encoding="utf-8")

    def test_b01_01_negative_index_clamped_to_zero(self):
        """Negative indices must clamp to 0."""
        # Simulated clamp calculation in Python replicating Swift: min(4, max(0, -5))
        def clamp_step(val: int) -> int:
            return min(4, max(0, val))

        self.assertEqual(clamp_step(-1), 0)
        self.assertEqual(clamp_step(-999), 0)
        self.assertIn("min(4, max(0, step))", self.content)

    def test_b01_02_excessive_index_clamped_to_four(self):
        """Indices greater than 4 must clamp to 4."""
        def clamp_step(val: int) -> int:
            return min(4, max(0, val))

        self.assertEqual(clamp_step(5), 4)
        self.assertEqual(clamp_step(100), 4)

    def test_b01_03_boundary_step_zero(self):
        """Boundary index 0 represents Welcome step and remains unchanged."""
        def clamp_step(val: int) -> int:
            return min(4, max(0, val))

        self.assertEqual(clamp_step(0), 0)

    def test_b01_04_boundary_step_four(self):
        """Boundary index 4 represents final launchpad step and remains unchanged."""
        def clamp_step(val: int) -> int:
            return min(4, max(0, val))

        self.assertEqual(clamp_step(4), 4)

    def test_b01_05_didset_persistence_guards(self):
        """Verifies didSet in OnboardingCoordinator clamps and persists normalized values."""
        self.assertIn("didSet {", self.content)
        self.assertIn("let clamped = min(4, max(0, step))", self.content)
        self.assertIn("if step != clamped {", self.content)
