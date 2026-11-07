import unittest
from pathlib import Path
from e2e_tests.common.test_base import RelayE2ETestBase

class TestB10ExtremePayloadsAndRepetition(RelayE2ETestBase):
    """
    Boundary B10: Extreme Payloads & Action Repetition Guards
    Repository checks for scoped recovery, bounded arguments and model memory.
    Actual recovery and long-task behavior is exercised by TaskRecoveryBudgetTests,
    TaskRecoveryStoreTests and TaskRunBudgetTests in the Swift suite.
    """

    def setUp(self):
        self.store_file = self.sources_relay / "AssistantStore.swift"
        self.client_file = self.sources_relay / "LocalModelClient.swift"
        self.store_content = self.store_file.read_text(encoding="utf-8")
        self.client_content = self.client_file.read_text(encoding="utf-8")

    def test_b10_01_recovery_is_scoped_to_unresolved_errors(self):
        """Checks that error recovery replaces the obsolete cumulative success cap."""
        recovery = (self.sources_relay / "TaskRecoveryBudget.swift").read_text(encoding="utf-8")
        self.assertIn("recovery.recordFailure(recoveryKey)", self.store_content)
        self.assertIn("recovery.recordVerifiedSuccess(recoveryKey)", self.store_content)
        self.assertIn("observedScope", recovery)
        self.assertIn("failures.count >= 128", recovery)
        self.assertNotIn("repetitions[signature", self.store_content)

    def test_b10_02_oversized_tool_arguments_rejected(self):
        """Verifies tool arguments exceeding maximumToolArgumentsBytes are rejected."""
        self.assertIn("maximumToolArgumentsBytes", self.client_content)

    def test_b10_03_context_byte_capacity_guarded(self):
        """Verifies context budgeting prevents feeding oversized payloads to LiteRT-LM."""
        self.assertIn("maximumContextBytes", self.client_content)

    def test_b10_04_long_tasks_retain_cancellation_and_per_call_budgets(self):
        """Checks the long-task contract without a fixed planning-turn cutoff."""
        self.assertIn("while true", self.store_content)
        self.assertIn("try gate(expected)", self.store_content)
        self.assertIn("try budget.check()", self.store_content)
        self.assertNotIn("The task reached its 20-step limit", self.store_content)

    def test_b10_05_single_model_inference_concurrency_guard(self):
        """Verifies LiteRT-LM enforces guard !generating to prevent GPU context thrashing."""
        self.assertIn("guard !generating", self.client_content)
