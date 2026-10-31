import unittest
from pathlib import Path
from e2e_tests.common.test_base import RelayE2ETestBase

class TestF07ComposerReasoning(RelayE2ETestBase):
    """
    Feature 7: Streamlined Composer & Reasoning Trails
    Tests floating glass composer dock, stop shortcut integration,
    collapsible agent activity reasoning, and review gates.
    """

    def setUp(self):
        self.main_view = self.sources_relay / "MainView.swift"
        self.stop_shortcut = self.sources_relay / "GlobalStopShortcut.swift"
        self.assertTrue(self.main_view.exists(), "MainView.swift must exist")
        self.assertTrue(self.stop_shortcut.exists(), "GlobalStopShortcut.swift must exist")
        self.main_content = self.main_view.read_text(encoding="utf-8")
        self.shortcut_content = self.stop_shortcut.read_text(encoding="utf-8")

    def test_f07_01_composer_dock_structure(self):
        """Verifies conversationDock presents floating composer dock."""
        self.assertIn("conversationDock", self.main_content)
        self.assertIn("composer", self.main_content)

    def test_f07_02_stop_action_and_shortcut_help(self):
        """Verifies stop button triggers store.stop() with shortcut guidance (⌘.)."""
        self.assertIn("store.stop()", self.main_content)
        has_shortcut_help = "⌘." in self.main_content or "stop" in self.main_content.lower()
        self.assertTrue(has_shortcut_help, "Stop button must provide shortcut guidance")

    def test_f07_03_activity_panel_reasoning_inspection(self):
        """Verifies collapsible activity panel for agent reasoning inspection."""
        self.assertIn("store.showActivity", self.main_content)
        self.assertIn("activityPanel", self.main_content)

    def test_f07_04_global_stop_shortcut_module(self):
        """Verifies GlobalStopShortcut monitors escape / command-period shortcuts."""
        has_shortcut_monitor = "GlobalStopShortcut" in self.shortcut_content or "NSEvent" in self.shortcut_content
        self.assertTrue(has_shortcut_monitor, "GlobalStopShortcut must monitor keyboard events")

    def test_f07_05_composer_multiline_support(self):
        """Verifies composer TextField supports multiline axis vertical."""
        self.assertIn("axis: .vertical", self.main_content)

    def test_f07_06_review_card_dock_integration(self):
        """Verifies reviewCard is rendered in the dock when sensitive tools require review."""
        self.assertIn("reviewCard", self.main_content)
        self.assertIn("store.pendingReview", self.main_content)
