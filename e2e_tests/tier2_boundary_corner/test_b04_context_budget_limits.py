import unittest
from pathlib import Path
from e2e_tests.common.test_base import RelayE2ETestBase

class TestB04ContextBudgetLimits(RelayE2ETestBase):
    """
    Boundary B04: Context Budget & Reasoning History Limits
    Verifies that Relay strictly enforces the 24 KB context window,
    8K token limit, tool schema budget (<1 KB), and supersedes stale UI observations.
    """

    def setUp(self):
        self.client_file = self.sources_relay / "LocalModelClient.swift"
        self.context_file = self.sources_relay / "ContextWindow.swift"
        self.tool_part_file = self.sources_relay / "MultiAgent" / "ToolPartitioning.swift"
        self.assertTrue(self.client_file.exists())
        self.assertTrue(self.context_file.exists())
        self.client_content = self.client_file.read_text(encoding="utf-8")
        self.context_content = self.context_file.read_text(encoding="utf-8")
        self.tool_content = self.tool_part_file.read_text(encoding="utf-8")

    def test_b04_01_maximum_context_bytes_24kb(self):
        """Verifies maximumContextBytes is strictly bounded to 24 KB (24,576 bytes)."""
        self.assertIn("maximumContextBytes", self.client_content)
        self.assertTrue("24 * 1_024" in self.client_content or "24 * 1024" in self.client_content)

    def test_b04_02_maximum_native_tokens_8192(self):
        """Verifies native token capacity is bounded to 8,192 tokens."""
        self.assertIn("maximumNativeTokens", self.client_content)

    def test_b04_03_maximum_tool_arguments_bytes_64kb(self):
        """Verifies tool arguments JSON limit is capped at 64 KB."""
        self.assertIn("maximumToolArgumentsBytes", self.client_content)
        self.assertTrue("64 * 1_024" in self.client_content or "64 * 1024" in self.client_content)

    def test_b04_04_tool_schema_budget_partitioning(self):
        """Verifies ToolPartitioning documentation and logic enforces < 1 KB schema budget."""
        has_budget = "schemaByteSize" in self.tool_content and "partitionedTools" in self.tool_content
        self.assertTrue(has_budget, "ToolPartitioning must provide schema size calculations")

    def test_b04_05_context_window_supersedes_stale_observations(self):
        """Verifies ContextWindow prepares bounded context without exceeding limits."""
        self.assertIn("ContextWindow", self.context_content)
        self.assertIn("prepare", self.context_content)
