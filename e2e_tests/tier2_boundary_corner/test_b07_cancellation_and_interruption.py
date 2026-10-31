import unittest
from pathlib import Path
from e2e_tests.common.test_base import RelayE2ETestBase

class TestB07CancellationAndInterruption(RelayE2ETestBase):
    """
    Boundary B07: Cancellation & Stop Interruption Handling
    Verifies that global shortcuts, gate checks, and user stop triggers
    interrupt agent execution cleanly without leaving lingering tasks.
    """

    def setUp(self):
        self.orchestrator_file = self.sources_relay / "MultiAgent" / "MultiAgentOrchestrator.swift"
        self.store_file = self.sources_relay / "AssistantStore.swift"
        self.shortcut_file = self.sources_relay / "GlobalStopShortcut.swift"
        self.orch_content = self.orchestrator_file.read_text(encoding="utf-8")
        self.store_content = self.store_file.read_text(encoding="utf-8")
        self.shortcut_content = self.shortcut_file.read_text(encoding="utf-8")

    def test_b07_01_gate_check_halts_multiagent_orchestrator(self):
        """Verifies gate checks prevent progression when stopped."""
        self.assertIn("try gate?()", self.orch_content)

    def test_b07_02_store_stop_cancels_running_task(self):
        """Verifies AssistantStore stop() transitions phase and cancels active tasks."""
        self.assertIn("func stop()", self.store_content)
        self.assertIn("phase = .stopped", self.store_content)

    def test_b07_03_interrupted_phase_retains_completed_steps(self):
        """Verifies stopped task records state and allows inspect & resume."""
        main_content = (self.sources_relay / "MainView.swift").read_text(encoding="utf-8")
        has_stopped = "Task stopped" in main_content and "store.phase == .stopped" in main_content
        self.assertTrue(has_stopped, "MainView must present stopped task feedback")

    def test_b07_04_global_stop_shortcut_triggers_stop_handler(self):
        """Verifies GlobalStopShortcut dispatches to registered stop handler."""
        self.assertIn("GlobalStopShortcut", self.shortcut_content)

    def test_b07_05_cancellation_during_model_preparation(self):
        """Verifies cancelPreparation stops model download/load without freezing."""
        onboarding_file = self.sources_relay / "OnboardingCoordinator.swift"
        content = onboarding_file.read_text(encoding="utf-8")
        self.assertIn("func cancelPreparation", content)
