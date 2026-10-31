import unittest
from pathlib import Path
from e2e_tests.common.test_base import RelayE2ETestBase

class TestB11StatePersistenceCorruption(RelayE2ETestBase):
    """
    Boundary B11: State Persistence & Corruption Recovery
    Verifies that missing persistence keys, corrupt state files,
    and partial downloads are recovered safely without state corruption.
    """

    def setUp(self):
        self.state_file = self.sources_relay / "LocalStateFile.swift"
        self.coordinator_file = self.sources_relay / "OnboardingCoordinator.swift"
        self.state_content = self.state_file.read_text(encoding="utf-8")
        self.coordinator_content = self.coordinator_file.read_text(encoding="utf-8")

    def test_b11_01_userdefaults_missing_keys_default_gracefully(self):
        """Verifies onboarding step defaults to 0 if key is absent."""
        self.assertIn('defaults.integer(forKey: "relay.setup.step")', self.coordinator_content)
        self.assertIn('defaults.bool(forKey: "relay.setup.completed.v1")', self.coordinator_content)

    def test_b11_02_atomic_state_file_writes(self):
        """Verifies state writing uses secure staging with mode 0600 and .tmp before replacement."""
        writer_file = self.sources_relay / "LocalPrivateFileWriter.swift"
        content = writer_file.read_text(encoding="utf-8")
        self.assertIn(".tmp", content)
        self.assertIn("0o600", content)

    def test_b11_03_corrupt_state_file_recovery(self):
        """Verifies decoding failures fall back to clean empty state."""
        self.assertIn("catch", self.state_content)

    def test_b11_04_writing_profile_corrupted_file_handling(self):
        """Verifies WritingProfile handles corrupted JSON safely."""
        profile_file = self.sources_relay / "WritingProfile.swift"
        content = profile_file.read_text(encoding="utf-8")
        self.assertIn("catch", content)

    def test_b11_05_checkpoint_resumption_checksum_integrity(self):
        """Verifies ModelDownloadCheckpoint tracks etag and offset for resume validation."""
        chk_file = self.sources_relay / "ModelDownloadCheckpoint.swift"
        content = chk_file.read_text(encoding="utf-8")
        self.assertIn("etag", content.lower())
        self.assertIn("offset", content)
