import unittest
import os
import sys
import re
from pathlib import Path

# Authoritative project root
PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent
SOURCES_RELAY = PROJECT_ROOT / "Sources" / "Relay"
WEBSITE_DIR = PROJECT_ROOT / "website"
SCRIPTS_DIR = PROJECT_ROOT / "Scripts"
TESTS_DIR = PROJECT_ROOT / "Tests"

class RelayE2ETestBase(unittest.TestCase):
    """
    Base class for Relay opaque-box E2E tests providing common helpers,
    path resolvers, file content caching, and domain-specific assertions.
    """

    @classmethod
    def setUpClass(cls):
        cls.project_root = PROJECT_ROOT
        cls.sources_relay = SOURCES_RELAY
        cls.website_dir = WEBSITE_DIR
        cls.scripts_dir = SCRIPTS_DIR
        cls.tests_dir = TESTS_DIR

    def read_source(self, rel_path: str) -> str:
        """Reads a file relative to project root or Sources/Relay."""
        target = self.project_root / rel_path
        if not target.exists():
            target = self.sources_relay / rel_path
        if not target.exists():
            target = self.website_dir / rel_path
        self.assertTrue(target.exists(), f"Expected file does not exist: {target}")
        return target.read_text(encoding="utf-8")

    def assert_file_contains(self, rel_path: str, pattern: str, is_regex: bool = False):
        content = self.read_source(rel_path)
        if is_regex:
            match = re.search(pattern, content)
            self.assertIsNotNone(match, f"Regex '{pattern}' not found in {rel_path}")
        else:
            self.assertIn(pattern, content, f"Substring '{pattern}' not found in {rel_path}")

    def assert_file_does_not_contain(self, rel_path: str, pattern: str):
        content = self.read_source(rel_path)
        self.assertNotIn(pattern, content, f"Forbidden pattern '{pattern}' found in {rel_path}")
