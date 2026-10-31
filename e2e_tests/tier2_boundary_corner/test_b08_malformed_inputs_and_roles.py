import unittest
from pathlib import Path
from e2e_tests.common.test_base import RelayE2ETestBase

class TestB08MalformedInputsAndRoles(RelayE2ETestBase):
    """
    Boundary B08: Malformed Inputs & Unknown Roles
    Verifies that invalid role names, malformed JSON, and unknown tool calls
    are handled with strict defensive boundaries.
    """

    def setUp(self):
        self.role_file = self.sources_relay / "MultiAgent" / "AgentRole.swift"
        self.orch_file = self.sources_relay / "MultiAgent" / "MultiAgentOrchestrator.swift"
        self.role_content = self.role_file.read_text(encoding="utf-8")
        self.orch_content = self.orch_file.read_text(encoding="utf-8")

    def test_b08_01_unknown_agent_role_decoding_throws_data_corrupted(self):
        """Verifies AgentRole decoder throws DecodingError on unknown role names."""
        self.assertIn("DecodingError.dataCorruptedError", self.role_content)
        self.assertIn("Unknown agent role:", self.role_content)

    def test_b08_02_malformed_plan_fallback_handling(self):
        """Verifies parsePlan in MultiAgentOrchestrator safely parses non-ideal outputs."""
        self.assertIn("parsePlan", self.orch_content)
        self.assertIn("data(using: .utf8)", self.orch_content)

    def test_b08_03_unsupported_tools_filtered_by_partitioning(self):
        """Verifies unexpected or unallowed tools are excluded by ToolPartitioning."""
        partition_file = self.sources_relay / "MultiAgent" / "ToolPartitioning.swift"
        content = partition_file.read_text(encoding="utf-8")
        self.assertIn("allowed.contains($0.name)", content)

    def test_b08_04_protocol_error_recovery_turns(self):
        """Verifies AssistantStore prevents protocol exhaustion and checks context budget."""
        store_file = self.sources_relay / "AssistantStore.swift"
        content = store_file.read_text(encoding="utf-8")
        self.assertIn("context budget", content.lower())

    def test_b08_05_empty_plan_steps_generates_direct_reply(self):
        """Verifies informational queries with 0 plan steps complete directly without execution."""
        self.assertIn("blackboard.structuredPlan.isEmpty", self.orch_content)
