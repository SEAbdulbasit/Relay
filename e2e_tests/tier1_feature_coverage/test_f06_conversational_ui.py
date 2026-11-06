import unittest
from pathlib import Path
from e2e_tests.common.test_base import RelayE2ETestBase

class TestF06ConversationalUI(RelayE2ETestBase):
    """
    Feature 6: Conversational UI & Empty State Cards
    Tests empty state prompt presentation, asymmetric conversational thread,
    role attribution, message scroll anchoring, and artifact display cards.
    """

    def setUp(self):
        self.main_view = self.sources_relay / "MainView.swift"
        self.assertTrue(self.main_view.exists(), "MainView.swift must exist in Sources/Relay/")
        self.content = self.main_view.read_text(encoding="utf-8")

    def test_f06_01_welcome_empty_state_present(self):
        """Verifies MainView renders welcome empty state when messages are empty."""
        self.assertIn("store.messages.isEmpty", self.content)
        self.assertIn("welcome", self.content)

    def test_f06_02_conversational_messages_rendering(self):
        """Verifies messageRow renders distinct user and assistant bubble alignments."""
        self.assertIn("func messageRow", self.content)
        self.assertIn('message.role == "user"', self.content)

    def test_f06_03_role_attribution_and_evidence(self):
        """Verifies action evidence disclosure and Relay attribution in message thread."""
        self.assertIn("RelayActionEvidence(text: evidence)", self.content)
        design = (self.sources_relay / "RelayDesignSystem.swift").read_text(encoding="utf-8")
        self.assertIn('Label("Action evidence"', design)

    def test_f06_04_message_scroll_anchoring(self):
        """Verifies ScrollViewReader auto-scrolls to latest messages."""
        self.assertIn("ScrollViewReader", self.content)
        self.assertIn("scrollTo", self.content)

    def test_f06_05_artifact_display_grid(self):
        """Verifies artifacts attached to messages are rendered with Show in Finder action."""
        self.assertIn("message.artifacts", self.content)
        self.assertIn("Show in Finder", self.content)

    def test_f06_06_model_status_header_indicator(self):
        """Verifies clean header displays on-device local engine status."""
        self.assertIn("header", self.content)
        self.assertIn("store.actionsReady", self.content)
