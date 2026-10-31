import re
from pathlib import Path
from typing import List, Tuple

class OfflineAirGapChecker:
    """
    Enforces that Relay's local model inference, multi-agent loops,
    and runtime engines contain zero remote endpoints, analytics calls,
    or telemetry beacons.
    """

    ALLOWED_LOCAL_PATTERNS = [
        r"127\.0\.0\.1",
        r"localhost",
        r"::1",
        r"https://github\.com",       # Documented links or notices only
        r"https://sentient-os\.ai",   # Reference links only
        r"https://apple\.com",        # System documentation references
    ]

    DISALLOWED_REMOTE_KEYWORDS = [
        "api.openai.com",
        "api.anthropic.com",
        "generativelanguage.googleapis.com",
        "mixpanel.com",
        "segment.io",
        "firebase-analytics",
        "sentry.io",
        "google-analytics.com",
        "datadoghq.com",
        "amplitude.com",
        "import Sentry",
        "import Mixpanel",
        "import FirebaseAnalytics",
    ]

    @classmethod
    def scan_for_telemetry_or_remote_calls(cls, filepath: Path) -> List[Tuple[int, str, str]]:
        """
        Scans a file line by line and returns violations: (line_no, line_content, matched_keyword).
        """
        violations = []
        if not filepath.exists():
            return violations

        text = filepath.read_text(encoding="utf-8", errors="ignore")
        lines = text.splitlines()

        for idx, line in enumerate(lines, start=1):
            line_lower = line.lower()
            # Ignore comments in test files
            stripped = line.strip()
            if stripped.startswith("//") or stripped.startswith("#"):
                continue

            for keyword in cls.DISALLOWED_REMOTE_KEYWORDS:
                if keyword in line_lower:
                    violations.append((idx, line, keyword))

        return violations
