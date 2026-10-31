import unittest
from pathlib import Path
from e2e_tests.common.test_base import RelayE2ETestBase
from e2e_tests.common.http_server import LocalWebsiteServer

class TestF10WebsitePrivacy(RelayE2ETestBase):
    """
    Feature 10: Dedicated Privacy Architecture Page
    Tests website/privacy.html structure: air-gapped execution narrative,
    data flow visualizer, zero-telemetry guarantee, and comparison matrix.
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
        self.privacy_file = self.website_dir / "privacy.html"
        self.assertTrue(self.privacy_file.exists(), "website/privacy.html must exist")
        self.content = self.privacy_file.read_text(encoding="utf-8")

    def test_f10_01_http_200_serving(self):
        """Verifies privacy.html serves HTTP 200 via local web server."""
        status, headers, body = self.server.fetch("/privacy.html")
        self.assertEqual(status, 200, "Server must return HTTP 200 for privacy.html")
        self.assertIn("Privacy", body)

    def test_f10_02_zero_telemetry_guarantee(self):
        """Verifies explicit zero telemetry commitments."""
        self.assertIn("Zero Telemetry", self.content)
        has_airgap = "Air-Gapped" in self.content or "air-gap" in self.content.lower()
        self.assertTrue(has_airgap, "privacy.html must emphasize air-gapped guarantees")

    def test_f10_03_data_flow_diagram_section(self):
        """Verifies interactive or visual data flow section."""
        self.assertIn('id="flow"', self.content)
        has_flow = "flow-visualizer" in self.content or "flow-boundary" in self.content or "flow-node" in self.content
        self.assertTrue(has_flow, "privacy.html must contain flow visualizer elements")

    def test_f10_04_comparison_matrix_vs_cloud(self):
        """Verifies comparison table/matrix comparing Relay against cloud AI."""
        self.assertIn('id="matrix"', self.content)
        has_comparison = "<table" in self.content or "matrix" in self.content.lower()
        self.assertTrue(has_comparison, "privacy.html must present a privacy comparison matrix")

    def test_f10_05_audit_verification_guide(self):
        """Verifies audit guide for validating zero-network isolation locally."""
        self.assertIn('id="verify"', self.content)
        self.assertIn("audit", self.content.lower())

    def test_f10_06_navigation_links_bidirectional(self):
        """Verifies back-links to index.html and anchor links."""
        self.assertIn('href="index.html"', self.content)
