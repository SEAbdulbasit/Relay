import unittest
from pathlib import Path
from e2e_tests.common.test_base import RelayE2ETestBase

class TestF02AgentRoles(RelayE2ETestBase):
    """
    Feature 2: Multi-Agent Role Definitions & Models
    Tests Planner, Navigator, Executor, Critic role types, message attribution,
    icon mapping, system prompt specializations, and AgentActivityItem.
    """

    def setUp(self):
        self.role_file = self.sources_relay / "MultiAgent" / "AgentRole.swift"
        self.assertTrue(self.role_file.exists(), "AgentRole.swift must exist in Sources/Relay/MultiAgent/")
        self.content = self.role_file.read_text(encoding="utf-8")

    def test_f02_01_all_four_agent_roles_defined(self):
        """Verifies all 4 required roles: planner, navigator, executor, critic."""
        for role in ["planner", "navigator", "executor", "critic"]:
            self.assertIn(f"case {role}", self.content, f"AgentRole must define case {role}")

    def test_f02_02_role_display_names_and_badges(self):
        """Verifies displayName and badgeText formatting (e.g. [Planner], [Navigator])."""
        self.assertIn("displayName", self.content)
        self.assertIn("badgeText", self.content)
        for name in ["Planner", "Navigator", "Executor", "Critic"]:
            self.assertIn(f'"{name}"', self.content)

    def test_f02_03_role_attribution_icons(self):
        """Verifies SF Symbol icon assignment for each role."""
        self.assertIn("iconName", self.content)
        for icon in ["brain.head.profile", "safari", "bolt.fill", "checkmark.shield.fill"]:
            self.assertIn(icon, self.content, f"Icon {icon} must be mapped to an agent role")

    def test_f02_04_system_prompts_configured_for_all_roles(self):
        """Verifies distinct system prompts for all 4 roles."""
        self.assertIn("ROLE: Planner", self.content)
        self.assertIn("ROLE: Navigator", self.content)
        self.assertIn("ROLE: Executor", self.content)
        self.assertIn("ROLE: Critic", self.content)

    def test_f02_05_agent_activity_item_structure(self):
        """Verifies AgentActivityItem contains required fields."""
        self.assertIn("struct AgentActivityItem", self.content)
        self.assertIn("role: AgentRole", self.content)
        self.assertIn("title: String", self.content)
        self.assertIn("detail: String?", self.content)

    def test_f02_06_role_decoder_supports_verifier_alias(self):
        """Verifies custom Decoder in AgentRole handles 'verifier' as critic."""
        self.assertIn('"verifier"', self.content)
        self.assertIn("case .critic", self.content)
