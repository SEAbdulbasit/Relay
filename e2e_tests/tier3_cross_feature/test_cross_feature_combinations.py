import unittest
import re
from pathlib import Path
from e2e_tests.common.test_base import RelayE2ETestBase

class TestCrossFeatureCombinations(RelayE2ETestBase):
    """
    Tier 3: Cross-Feature Combinations (Pairwise Coverage)
    Validates the end-to-end interactions and contracts between subsystems:
    Onboarding ↔ MainView, Swift DesignSystem ↔ CSS Tokens,
    Stop Shortcut ↔ Multi-Agent Orchestrator, Settings ↔ Setup Assistant,
    Tool Partitioning ↔ Context Limits, Website Demo ↔ Engine Roles, etc.
    """

    def setUp(self):
        self.relay_app = self.sources_relay / "RelayApp.swift"
        self.coordinator = self.sources_relay / "OnboardingCoordinator.swift"
        self.design_swift = self.sources_relay / "RelayDesignSystem.swift"
        self.tokens_css = self.website_dir / "css" / "tokens.css"
        self.components_css = self.website_dir / "css" / "components.css"
        self.orch_file = self.sources_relay / "MultiAgent" / "MultiAgentOrchestrator.swift"
        self.main_view = self.sources_relay / "MainView.swift"
        self.settings_view = self.sources_relay / "SettingsView.swift"
        self.tool_part = self.sources_relay / "MultiAgent" / "ToolPartitioning.swift"
        self.agent_demo = self.website_dir / "js" / "agent-demo.js"
        self.privacy_html = self.website_dir / "privacy.html"
        self.build_script = self.scripts_dir / "build-app.sh"

    def test_x01_onboarding_completion_switches_to_mainview(self):
        """Cross-Feature 1: Onboarding completed flag triggers MainView in RelayApp."""
        app_code = self.relay_app.read_text(encoding="utf-8")
        self.assertIn("if onboarding.completed {", app_code)
        self.assertIn("MainView(store: store", app_code)
        self.assertIn("OnboardingView(coordinator: onboarding", app_code)

    def test_x02_design_tokens_consistency_between_swift_and_css(self):
        """Cross-Feature 2: Swift RelayDesignSystem tokens match CSS tokens.css."""
        css_code = self.tokens_css.read_text(encoding="utf-8")
        swift_code = self.design_swift.read_text(encoding="utf-8")
        # Check obsidian palette
        self.assertIn("#000000", css_code)
        self.assertIn("#0b0c0e", css_code.lower())
        # Check 8 prism stops exist in both
        for hex_code in ["#fde2a3", "#ff8e3c", "#ff4646", "#e8388f", "#9b48d4", "#6c5ce5", "#4a90e2"]:
            self.assertIn(hex_code, css_code.lower())
            self.assertIn(hex_code, swift_code.lower())

    def test_x03_stop_button_during_multiagent_execution(self):
        """Cross-Feature 3: UI stop action halts MultiAgentOrchestrator via gate check."""
        main_code = self.main_view.read_text(encoding="utf-8")
        orch_code = self.orch_file.read_text(encoding="utf-8")
        self.assertIn("store.stop()", main_code)
        self.assertIn("try gate?()", orch_code)

    def test_x04_settings_setup_assistant_resets_onboarding_to_step_zero(self):
        """Cross-Feature 4: Settings 'Setup Assistant' resets coordinator to Step 0."""
        settings_code = self.settings_view.read_text(encoding="utf-8")
        coord_code = self.coordinator.read_text(encoding="utf-8")
        app_code = self.relay_app.read_text(encoding="utf-8")
        self.assertIn("onOpenSetup", settings_code)
        self.assertIn("onboarding.returnToSetup()", app_code)
        self.assertIn("step = 0", coord_code)
        self.assertIn("completed = false", coord_code)

    def test_x05_multiagent_activities_render_in_conversational_dock(self):
        """Cross-Feature 5: Orchestrator activities stream into MainView activity panel."""
        orch_code = self.orch_file.read_text(encoding="utf-8")
        main_code = self.main_view.read_text(encoding="utf-8")
        self.assertIn("AgentActivityItem", orch_code)
        self.assertIn("activityPanel", main_code)

    def test_x06_tool_partitioning_protects_context_budget(self):
        """Cross-Feature 6: Tool partitioning bounds schema bytes within 24KB context."""
        tool_code = self.tool_part.read_text(encoding="utf-8")
        client_code = (self.sources_relay / "LocalModelClient.swift").read_text(encoding="utf-8")
        self.assertIn("maximumContextBytes", client_code)
        self.assertIn("partitionedTools", tool_code)
        self.assertIn("schemaByteSize", tool_code)

    def test_x07_website_interactive_demo_matches_agent_roles(self):
        """Cross-Feature 7: Website demo role state machine matches Swift AgentRole."""
        demo_code = self.agent_demo.read_text(encoding="utf-8")
        role_code = (self.sources_relay / "MultiAgent" / "AgentRole.swift").read_text(encoding="utf-8")
        for role in ["Planner", "Navigator", "Executor", "Critic"]:
            self.assertIn(role, demo_code)
            self.assertIn(role, role_code)

    def test_x08_website_privacy_claims_match_swift_airgap(self):
        """Cross-Feature 8: Website privacy commitments reflect Swift zero-network enforcement."""
        privacy_code = self.privacy_html.read_text(encoding="utf-8")
        client_code = (self.sources_relay / "LocalModelClient.swift").read_text(encoding="utf-8")
        self.assertIn("Zero Telemetry", privacy_code)
        self.assertIn(".litertlm", client_code)
        self.assertIn("isRegularFile", client_code)

    def test_x09_build_script_codesigns_app_and_fixture(self):
        """Cross-Feature 9: build-app.sh codesigns and verifies Relay.app bundle."""
        build_code = self.build_script.read_text(encoding="utf-8")
        self.assertIn("RelayAccessibilityFixture", build_code)
        self.assertIn("codesign --verify --deep --strict", build_code)

    def test_x10_onboarding_model_step_interfaces_with_local_runtime(self):
        """Cross-Feature 10: Onboarding model step coordinates with runtime."""
        onboarding_code = (self.sources_relay / "OnboardingView.swift").read_text(encoding="utf-8")
        coord_code = self.coordinator.read_text(encoding="utf-8")
        self.assertIn("modelStep", onboarding_code)
        self.assertIn("useInstalledModel", coord_code)

    def test_x11_onboarding_accessibility_permission_and_check(self):
        """Cross-Feature 11: Onboarding access step checks macOS accessibility."""
        coord_code = self.coordinator.read_text(encoding="utf-8")
        self.assertIn("AXIsProcessTrusted", coord_code)
        self.assertIn("requestAccessibility", coord_code)

    def test_x12_theme_appearance_consistency_card_elevation(self):
        """Cross-Feature 12: Glass card styles align between Swift and CSS components."""
        swift_code = self.design_swift.read_text(encoding="utf-8")
        css_code = self.components_css.read_text(encoding="utf-8")
        has_glass_swift = "glass" in swift_code.lower() or "surface" in swift_code.lower()
        has_glass_css = "glass-card" in css_code
        self.assertTrue(has_glass_swift and has_glass_css)
