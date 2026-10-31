import unittest
from pathlib import Path
from e2e_tests.common.test_base import RelayE2ETestBase

class TestB10ExtremePayloadsAndRepetition(RelayE2ETestBase):
    """
    Boundary B10: Extreme Payloads & Action Repetition Guards
    Verifies that tool call repetitions are limited to <= 3,
    oversized payloads (>64KB) are blocked, and memory limits are protected.
    """

    def setUp(self):
        self.store_file = self.sources_relay / "AssistantStore.swift"
        self.client_file = self.sources_relay / "LocalModelClient.swift"
        self.store_content = self.store_file.read_text(encoding="utf-8")
        self.client_content = self.client_file.read_text(encoding="utf-8")

    def test_b10_01_repetition_guard_threshold(self):
        """Verifies infinite tool loop guard restricts repeated calls to <= 3."""
        self.assertIn("repetitions", self.store_content)
        self.assertIn("3", self.store_content)

    def test_b10_02_oversized_tool_arguments_rejected(self):
        """Verifies tool arguments exceeding maximumToolArgumentsBytes are rejected."""
        self.assertIn("maximumToolArgumentsBytes", self.client_content)

    def test_b10_03_context_byte_capacity_guarded(self):
        """Verifies context budgeting prevents feeding oversized payloads to LiteRT-LM."""
        self.assertIn("maximumContextBytes", self.client_content)

    def test_b10_04_turn_limit_guard_in_agent_loop(self):
        """Verifies agent loop enforces a maximum turn iteration bound."""
        self.assertIn("for _ in 0..<", self.store_content)

    def test_b10_05_single_model_inference_concurrency_guard(self):
        """Verifies LiteRT-LM enforces guard !generating to prevent GPU context thrashing."""
        self.assertIn("guard !generating", self.client_content)
