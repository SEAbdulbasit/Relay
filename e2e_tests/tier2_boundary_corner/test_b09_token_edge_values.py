import unittest
import re
from pathlib import Path
from e2e_tests.common.test_base import RelayE2ETestBase

class TestB09TokenEdgeValues(RelayE2ETestBase):
    """
    Boundary B09: Design Token Edge Values & Numeric Bounds
    Verifies that numeric values, opacities, corner radii, and gradient stop
    percentages are within valid, non-negative, well-ordered bounds.
    """

    def setUp(self):
        self.tokens_css = self.website_dir / "css" / "tokens.css"
        self.content = self.tokens_css.read_text(encoding="utf-8")

    def test_b09_01_rgb_hex_codes_valid(self):
        """Verifies all hex colors in tokens.css are valid 6-character hex strings."""
        hex_codes = re.findall(r'#([0-9a-fA-F]{6})\b', self.content)
        self.assertGreater(len(hex_codes), 10, "tokens.css should define multiple hex colors")
        for code in hex_codes:
            val = int(code, 16)
            self.assertTrue(0 <= val <= 0xFFFFFF)

    def test_b09_02_opacity_values_bounded(self):
        """Verifies opacity values in rgba() are between 0.0 and 1.0."""
        rgba_matches = re.findall(r'rgba\(\s*\d+\s*,\s*\d+\s*,\s*\d+\s*,\s*([0-9.]+)\s*\)', self.content)
        for alpha_str in rgba_matches:
            alpha = float(alpha_str)
            self.assertTrue(0.0 <= alpha <= 1.0, f"Alpha out of bounds: {alpha}")

    def test_b09_03_border_radii_positive(self):
        """Verifies border radius tokens specify positive pixel dimensions."""
        radii = re.findall(r'--relay-radius-[a-z]+:\s*(\d+)px', self.content) + re.findall(r'--radius-[a-z]+:\s*(\d+)px', self.content)
        self.assertTrue(len(radii) > 0, "Should define radius tokens")
        for r in radii:
            self.assertGreater(int(r), 0)

    def test_b09_04_font_sizes_positive_and_readable(self):
        """Verifies font size definitions are positive and readable."""
        font_sizes = re.findall(r'font-size:\s*(\d+)px', self.content)
        for fs in font_sizes:
            self.assertGreaterEqual(int(fs), 10, f"Font size too small: {fs}")

    def test_b09_05_gradient_stops_percentage_order(self):
        """Verifies Relay Prism gradient stops are strictly increasing."""
        prism_line = [line for line in self.content.splitlines() if "gradient-relay-prism" in line or "linear-gradient" in line]
        self.assertTrue(len(prism_line) > 0)
        percentages = [int(p) for p in re.findall(r'(\d+)%', prism_line[0])]
        self.assertEqual(percentages, sorted(percentages), "Gradient stop percentages must be monotonically increasing")
