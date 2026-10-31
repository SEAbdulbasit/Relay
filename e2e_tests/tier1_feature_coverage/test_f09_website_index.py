import unittest
from pathlib import Path
from e2e_tests.common.test_base import RelayE2ETestBase
from e2e_tests.common.http_server import LocalWebsiteServer

class TestF09WebsiteIndex(RelayE2ETestBase):
    """
    Feature 9: Companion Marketing Website Core
    Tests website/index.html structure: hero section, halo CTA,
    multi-agent interactive demo, bento grid showcases, technical specs, and FAQ.
    """

    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.server = LocalWebsiteServer(cls.website_dir)
        cls.server.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.stop()

    def setUp(self):
        self.index_file = self.website_dir / "index.html"
        self.assertTrue(self.index_file.exists(), "website/index.html must exist")
        self.content = self.index_file.read_text(encoding="utf-8")

    def test_f09_01_http_200_serving(self):
        """Verifies index.html serves HTTP 200 via local web server."""
        status, headers, body = self.server.fetch("/")
        self.assertEqual(status, 200, "Server must return HTTP 200 for index.html")
        self.assertIn("Relay", body)

    def test_f09_02_hero_section_and_eyebrow(self):
        """Verifies hero headline, prism text gradient, and offline eyebrow badge."""
        self.assertIn("hero-section", self.content)
        self.assertIn("eyebrow-badge", self.content)
        self.assertIn("text-prism", self.content)

    def test_f09_03_multiagent_interactive_demo_section(self):
        """Verifies interactive multi-agent demo section with role cards/badges."""
        self.assertIn('id="multi-agent"', self.content)
        for role in ["Planner", "Navigator", "Executor", "Critic"]:
            self.assertIn(role, self.content)

    def test_f09_04_feature_bento_grid(self):
        """Verifies feature showcase bento grid cards."""
        self.assertIn('id="features"', self.content)
        self.assertIn("bento-grid", self.content)

    def test_f09_05_technical_specifications(self):
        """Verifies hardware and model specifications section."""
        self.assertIn('id="specs"', self.content)
        self.assertIn("Apple Silicon", self.content)
        self.assertIn("Gemma", self.content)

    def test_f09_06_accessible_faq_accordion(self):
        """Verifies FAQ accordion structure with details/summary or button toggles."""
        self.assertIn('id="faq"', self.content)
        has_faq = "<details" in self.content or "accordion" in self.content
        self.assertTrue(has_faq, "FAQ section must feature interactive accordion elements")
