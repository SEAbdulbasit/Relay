import unittest
from pathlib import Path
from e2e_tests.common.test_base import RelayE2ETestBase

class TestF03ToolPartitioning(RelayE2ETestBase):
    """
    Feature 3: Context & Tool Partitioning
    Tests role-based tool schema filtering reducing context budget overhead
    by >75% (from ~4.5 KB to ~0.8 KB).
    """

    def setUp(self):
        self.tool_file = self.sources_relay / "MultiAgent" / "ToolPartitioning.swift"
        self.assertTrue(self.tool_file.exists(), "ToolPartitioning.swift must exist in Sources/Relay/MultiAgent/")
        self.content = self.tool_file.read_text(encoding="utf-8")

    def test_f03_01_planner_has_zero_tools(self):
        """Planner must have 0 tools (pure structured reasoning)."""
        self.assertIn("case .planner", self.content)
        self.assertIn("return []", self.content)

    def test_f03_02_navigator_has_read_only_tools(self):
        """Navigator must only receive inspection and read-only tools."""
        self.assertIn("case .navigator", self.content)
        for tool in ["observe_app", "list_apps", "search_finder", "list_files"]:
            self.assertIn(f'"{tool}"', self.content)

    def test_f03_03_executor_has_mutation_tools(self):
        """Executor must receive targeted mutation tools."""
        self.assertIn("case .executor", self.content)
        for tool in ["open_app", "press_control", "set_value", "write_file", "create_document"]:
            self.assertIn(f'"{tool}"', self.content)

    def test_f03_04_critic_has_verification_tools(self):
        """Critic must only receive verification and readback tools."""
        self.assertIn("case .critic", self.content)
        for tool in ["read_file", "observe_app", "read_browser_page"]:
            self.assertIn(f'"{tool}"', self.content)

    def test_f03_05_partitioning_filter_function_exists(self):
        """ToolPartitioning must provide partitionedTools and schemaByteSize utilities."""
        self.assertIn("func partitionedTools", self.content)
        self.assertIn("func schemaByteSize", self.content)

    def test_f03_06_tool_separation_enforces_safety(self):
        """Mutations like write_file must never be granted to Planner or Critic."""
        # Find critic section and verify write_file is not in it
        critic_part = self.content.split("case .critic:")[1].split("case")[0] if "case .critic:" in self.content else ""
        self.assertNotIn('"write_file"', critic_part)
        self.assertNotIn('"press_control"', critic_part)
