import unittest
from pathlib import Path
from e2e_tests.common.test_base import RelayE2ETestBase

class TestF11WebsiteTokens(RelayE2ETestBase):
    """
    Feature 11: Web Design System & CSS Tokens
    Tests website/css/ tokens matching macOS app tokens 1:1,
    frosted glass styling, halo glowing buttons, and animations.
    """

    def setUp(self):
        self.css_dir = self.website_dir / "css"
        self.tokens_css = self.css_dir / "tokens.css"
        self.base_css = self.css_dir / "base.css"
        self.components_css = self.css_dir / "components.css"
        self.animations_css = self.css_dir / "animations.css"

    def test_f11_01_all_four_css_files_exist(self):
        """Verifies modular CSS structure: tokens.css, base.css, components.css, animations.css."""
        for css_file in [self.tokens_css, self.base_css, self.components_css, self.animations_css]:
            self.assertTrue(css_file.exists(), f"Missing required stylesheet: {css_file.name}")

    def test_f11_02_tokens_css_defines_obsidian_colors(self):
        """Verifies obsidian palette custom properties in tokens.css."""
        content = self.tokens_css.read_text(encoding="utf-8")
        self.assertIn("--color-bg-canvas", content)
        self.assertIn("--color-bg-deep", content)
        self.assertIn("#000000", content)
        self.assertIn("#0b0c0e", content.lower())

    def test_f11_03_tokens_css_defines_prism_gradient(self):
        """Verifies 8-stop Relay Prism gradient custom property in tokens.css."""
        content = self.tokens_css.read_text(encoding="utf-8")
        self.assertIn("--gradient-relay-prism", content)
        for hex_code in ["#fde2a3", "#ff8e3c", "#ff4646", "#e8388f", "#9b48d4", "#6c5ce5", "#4a90e2"]:
            self.assertIn(hex_code, content.lower())

    def test_f11_04_components_css_frosted_glass(self):
        """Verifies frosted glass card elevations in components.css."""
        content = self.components_css.read_text(encoding="utf-8")
        self.assertIn("backdrop-filter", content)
        self.assertIn("blur", content)

    def test_f11_05_components_css_halo_button(self):
        """Verifies halo glowing buttons in components.css."""
        content = self.components_css.read_text(encoding="utf-8")
        self.assertIn("btn-halo", content)
        self.assertIn("btn-primary", content)

    def test_f11_06_animations_css_keyframes(self):
        """Verifies keyframe animations for pulses, glows, or shimmers."""
        content = self.animations_css.read_text(encoding="utf-8")
        self.assertIn("@keyframes", content)
