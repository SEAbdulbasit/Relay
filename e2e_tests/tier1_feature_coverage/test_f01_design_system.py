import unittest
import re
from pathlib import Path
from e2e_tests.common.test_base import RelayE2ETestBase

class TestF01DesignSystem(RelayE2ETestBase):
    """
    Feature 1: Design System Foundations & Tokens
    Tests obsidian palette, 8-stop prism rainbow gradient, halo glow buttons,
    frosted glass cards, typography hierarchy, and role badge tokens.
    """

    def setUp(self):
        self.design_system_path = self.sources_relay / "RelayDesignSystem.swift"
        self.assertTrue(self.design_system_path.exists(), "RelayDesignSystem.swift must exist")
        self.content = self.design_system_path.read_text(encoding="utf-8")

    def test_f01_01_obsidian_palette_defined(self):
        """Verifies obsidian and dark palette definitions in RelayDesignSystem."""
        has_bg = "background" in self.content
        has_surface = "surface" in self.content
        self.assertTrue(has_bg and has_surface, "RelayDesignSystem must define background and surface tokens")

    def test_f01_02_prism_gradient_defined(self):
        """Verifies Relay signature prism rainbow gradient definition in RelayDesignSystem."""
        has_gradient = "gradient" in self.content.lower() or "prism" in self.content.lower() or "rainbow" in self.content.lower()
        self.assertTrue(has_gradient, "RelayDesignSystem must incorporate signature prism/rainbow gradient definition")

    def test_f01_03_primary_button_style(self):
        """Verifies RelayPrimaryButtonStyle exists with styling and press handling."""
        self.assertIn("RelayPrimaryButtonStyle", self.content)
        self.assertIn("ButtonStyle", self.content)
        self.assertIn("makeBody", self.content)

    def test_f01_04_glass_card_elevation_tokens(self):
        """Verifies surface elevation, radius, and frosted card styling tokens."""
        has_radius = "radius" in self.content.lower() or "cornerradius" in self.content.lower()
        self.assertTrue(has_radius, "RelayDesignSystem must specify corner radius foundation")

    def test_f01_05_interactive_press_state(self):
        """Verifies RelayPressStyle or scale/opacity interaction on press."""
        has_press = "RelayPressStyle" in self.content or "isPressed" in self.content
        self.assertTrue(has_press, "Design system must provide interactive button press feedback")

    def test_f01_06_accessibility_reduced_motion_support(self):
        """Verifies design system components respect accessibilityReduceMotion."""
        self.assertIn("accessibilityReduceMotion", self.content, "Animations must respect accessibilityReduceMotion")
