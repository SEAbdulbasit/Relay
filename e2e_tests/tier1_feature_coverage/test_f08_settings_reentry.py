import unittest
from pathlib import Path
from e2e_tests.common.test_base import RelayE2ETestBase

class TestF08SettingsReentry(RelayE2ETestBase):
    """
    Feature 8: Settings View Refinement
    Tests Settings navigation tabs, model diagnostics, setup assistant
    re-entry button, accessibility access panel, and local indicators.
    """

    def setUp(self):
        self.settings_file = self.sources_relay / "SettingsView.swift"
        self.assertTrue(self.settings_file.exists(), "SettingsView.swift must exist in Sources/Relay/")
        self.content = self.settings_file.read_text(encoding="utf-8")

    def test_f08_01_settings_tabs_inventory(self):
        """Verifies Model, Access, Knowledge, Memory, Voice tabs defined in SettingsView."""
        for tab in ["Model", "Access", "Knowledge", "Memory", "Voice"]:
            self.assertIn(f'"{tab}"', self.content)

    def test_f08_02_setup_assistant_reentry_button(self):
        """Verifies 'Setup assistant' re-entry button triggers onOpenSetup callback."""
        has_setup = "Setup assistant" in self.content or "Setup Assistant" in self.content
        self.assertTrue(has_setup, "SettingsView must offer Setup Assistant re-entry")
        self.assertIn("onOpenSetup", self.content)

    def test_f08_03_model_status_and_diagnostics_display(self):
        """Verifies local intelligence section displays model status and configuration."""
        has_model_section = "Local Intelligence" in self.content or "Your local intelligence" in self.content
        self.assertTrue(has_model_section, "Model settings must describe on-device local intelligence")
        self.assertIn("store.configuration.modelPath", self.content)

    def test_f08_04_access_permissions_management(self):
        """Verifies accessSettings presents permission and security controls."""
        self.assertIn("accessSettings", self.content)
        self.assertIn("accessibilityGranted", self.content)

    def test_f08_05_keyboard_shortcut_dismiss(self):
        """Verifies close button supports keyboard cancel shortcut (Escape)."""
        self.assertIn(".keyboardShortcut(.cancelAction)", self.content)

    def test_f08_06_offline_local_badge_in_settings(self):
        """Verifies local-only indicator in settings navigation sidebar."""
        has_offline = "100% Offline" in self.content or "Runs on your Mac" in self.content
        self.assertTrue(has_offline, "Settings navigation must include local offline badge")
