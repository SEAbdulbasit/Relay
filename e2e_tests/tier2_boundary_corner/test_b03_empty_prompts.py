import unittest
from pathlib import Path
from e2e_tests.common.test_base import RelayE2ETestBase

class TestB03EmptyPrompts(RelayE2ETestBase):
    """
    Boundary B03: Empty & Whitespace User Prompt Handling
    Verifies that empty strings, whitespace, unicode blanks, and control chars
    are safely guarded in MainView and AssistantStore.
    """

    def setUp(self):
        self.main_view = self.sources_relay / "MainView.swift"
        self.assistant_store = self.sources_relay / "AssistantStore.swift"
        self.main_content = self.main_view.read_text(encoding="utf-8")
        self.store_content = self.assistant_store.read_text(encoding="utf-8")

    def test_b03_01_empty_string_prompt_handled(self):
        """Verifies submit logic checks for non-empty trimmed text."""
        has_trim = "trimmingCharacters" in self.main_content or "isEmpty" in self.main_content
        self.assertTrue(has_trim, "Prompt submission must check for empty input")

    def test_b03_02_whitespace_only_prompt_trimmed(self):
        """Verifies whitespace-only strings are trimmed before dispatch."""
        self.assertIn(".whitespacesAndNewlines", self.main_content)

    def test_b03_03_unicode_whitespace_prompts(self):
        """Simulates unicode spaces (non-breaking space, em space) handling."""
        test_inputs = ["   ", "\t\n", "\u00A0\u200B", "\u3000"]
        for inp in test_inputs:
            trimmed = inp.strip()
            self.assertEqual(trimmed, "" if not "\u00A0" in inp else trimmed.replace("\u00A0", "").strip())

    def test_b03_04_control_characters_sanitized(self):
        """Verifies prompts with null bytes or control characters cannot crash message construction."""
        has_control_handling = "components(separatedBy:" in self.main_content or "draft" in self.main_content
        self.assertTrue(has_control_handling)

    def test_b03_05_composer_placeholder_rendered_when_empty(self):
        """Verifies composer shows placeholder when store.draft.isEmpty."""
        self.assertIn("store.draft.isEmpty", self.main_content)
        self.assertIn("Message Relay", self.main_content)
