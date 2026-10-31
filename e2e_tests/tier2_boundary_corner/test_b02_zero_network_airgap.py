import unittest
import re
from pathlib import Path
from e2e_tests.common.test_base import RelayE2ETestBase
from e2e_tests.common.offline_guard import OfflineAirGapChecker

class TestB02ZeroNetworkAirgap(RelayE2ETestBase):
    """
    Boundary B02: Zero-Network Airgap Enforcement
    Verifies that Relay contains zero telemetry SDKs, external cloud endpoints,
    or remote model dependencies in Swift source, package configuration, and website.
    """

    def test_b02_01_no_third_party_telemetry_in_sources(self):
        """Scans all Swift sources in Sources/Relay/ for disallowed telemetry/analytics domains."""
        violations = []
        for swift_file in self.sources_relay.rglob("*.swift"):
            file_violations = OfflineAirGapChecker.scan_for_telemetry_or_remote_calls(swift_file)
            if file_violations:
                violations.extend([(str(swift_file.name), v) for v in file_violations])
        self.assertEqual(violations, [], f"Found disallowed telemetry/remote calls in sources: {violations}")

    def test_b02_02_model_runtime_forbids_remote_endpoints(self):
        """Verifies LocalModelClient rejects non-local or wrong model packages."""
        client_file = self.sources_relay / "LocalModelClient.swift"
        self.assertTrue(client_file.exists())
        content = client_file.read_text(encoding="utf-8")
        self.assertIn(".litertlm", content)
        self.assertIn(".isRegularFileKey", content)
        self.assertIn("standardizedFileURL", content)

    def test_b02_03_no_external_network_dependencies_in_package_swift(self):
        """Verifies Package.swift contains zero remote git URLs or external network packages."""
        pkg_file = self.project_root / "Package.swift"
        content = pkg_file.read_text(encoding="utf-8")
        self.assertNotIn("url: \"http", content)
        self.assertNotIn("url: \"https", content)
        self.assertIn('path: "Vendor/LiteRTLM"', content)

    def test_b02_04_multiagent_orchestrator_runs_offline(self):
        """Verifies MultiAgentOrchestrator coordinates roles locally in memory without networking."""
        orch_file = self.sources_relay / "MultiAgent" / "MultiAgentOrchestrator.swift"
        content = orch_file.read_text(encoding="utf-8")
        self.assertNotIn("URLSession", content)
        self.assertNotIn("Network.framework", content)

    def test_b02_05_companion_website_zero_external_scripts(self):
        """Verifies website HTML contains no external script tags or CDNs."""
        for html_file in [self.website_dir / "index.html", self.website_dir / "privacy.html"]:
            content = html_file.read_text(encoding="utf-8")
            script_srcs = re.findall(r'<script[^>]+src=["\']([^"\']+)["\']', content)
            for src in script_srcs:
                self.assertFalse(src.startswith("http://") or src.startswith("https://") or src.startswith("//"),
                                 f"Disallowed external script in {html_file.name}: {src}")
