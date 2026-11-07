#!/usr/bin/env python3
"""
Relay repository scenario checks.
These tiers inspect source, assets and fixtures; they do not drive the native
product end to end. Live desktop/model acceptance is in opt-in Swift tests.
"""

import sys
import os
import unittest
import time
import argparse
from pathlib import Path

# Add project root to sys.path so modules can import common utilities
PROJECT_ROOT = Path(__file__).resolve().parent.parent
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

# ANSI Color codes for clean output
GREEN = "\033[92m"
RED = "\033[91m"
YELLOW = "\033[93m"
CYAN = "\033[96m"
BOLD = "\033[1m"
RESET = "\033[0m"

class ColoredTextTestResult(unittest.TextTestResult):
    def addSuccess(self, test):
        super().addSuccess(test)
        if self.showAll:
            sys.stderr.write(f" {GREEN}[PASS]{RESET}\n")

    def addError(self, test, err):
        super().addError(test, err)
        if self.showAll:
            sys.stderr.write(f" {RED}[ERROR]{RESET}\n")

    def addFailure(self, test, err):
        super().addFailure(test, err)
        if self.showAll:
            sys.stderr.write(f" {RED}[FAIL]{RESET}\n")

    def addSkip(self, test, reason):
        super().addSkip(test, reason)
        if self.showAll:
            sys.stderr.write(f" {YELLOW}[SKIP]{RESET}\n")

def run_tier(tier_name: str, tier_dir: Path, pattern: str = "test_*.py", verbose: bool = False) -> tuple:
    """Runs tests in a specific directory and returns (total, passed, failed, errors, duration)."""
    loader = unittest.TestLoader()
    suite = loader.discover(start_dir=str(tier_dir), pattern=pattern)
    
    stream = sys.stderr
    verbosity = 2 if verbose else 1
    runner = unittest.TextTestRunner(
        stream=stream,
        verbosity=verbosity,
        resultclass=ColoredTextTestResult
    )
    
    start_time = time.time()
    result = runner.run(suite)
    duration = time.time() - start_time
    
    total = result.testsRun
    failed = len(result.failures)
    errors = len(result.errors)
    passed = total - failed - errors
    
    return total, passed, failed, errors, duration

def main():
    parser = argparse.ArgumentParser(description="Relay repository scenario checks")
    parser.add_argument("--tier", type=str, choices=["1", "2", "3", "4", "all"], default="all",
                        help="Specify tier to run (1, 2, 3, 4, or all)")
    parser.add_argument("--feature", type=str, default=None,
                        help="Filter by feature (e.g. f01, f02... for Tier 1)")
    parser.add_argument("-v", "--verbose", action="store_true",
                        help="Verbose test execution output")
    args = parser.parse_args()

    tests_base = PROJECT_ROOT / "e2e_tests"
    tiers = {
        "Tier 1: Feature Coverage (F1..F12)": (tests_base / "tier1_feature_coverage", "test_*.py" if not args.feature else f"test_{args.feature.lower()}*.py"),
        "Tier 2: Boundary & Corner Cases": (tests_base / "tier2_boundary_corner", "test_*.py"),
        "Tier 3: Cross-Feature Combinations": (tests_base / "tier3_cross_feature", "test_*.py"),
        "Tier 4: Real-World Application Scenarios": (tests_base / "tier4_real_world_scenarios", "test_*.py"),
    }

    selected_tiers = {}
    if args.tier == "all":
        selected_tiers = tiers
    elif args.tier == "1":
        selected_tiers = {"Tier 1: Feature Coverage (F1..F12)": tiers["Tier 1: Feature Coverage (F1..F12)"]}
    elif args.tier == "2":
        selected_tiers = {"Tier 2: Boundary & Corner Cases": tiers["Tier 2: Boundary & Corner Cases"]}
    elif args.tier == "3":
        selected_tiers = {"Tier 3: Cross-Feature Combinations": tiers["Tier 3: Cross-Feature Combinations"]}
    elif args.tier == "4":
        selected_tiers = {"Tier 4: Real-World Application Scenarios": tiers["Tier 4: Real-World Application Scenarios"]}

    print(f"\n{BOLD}{CYAN}========================================================================{RESET}")
    print(f"{BOLD}{CYAN}                   RELAY REPOSITORY SCENARIO CHECKS                     {RESET}")
    print("Source and fixture checks; this is not native product E2E qualification.")
    print(f"{BOLD}{CYAN}========================================================================{RESET}\n")

    summary_rows = []
    grand_total = 0
    grand_passed = 0
    grand_failed = 0
    grand_errors = 0
    grand_duration = 0.0

    for name, (directory, pattern) in selected_tiers.items():
        print(f"{BOLD}▶ Running {name}...{RESET}")
        total, passed, failed, errors, duration = run_tier(name, directory, pattern=pattern, verbose=args.verbose)
        summary_rows.append((name, total, passed, failed, errors, duration))
        grand_total += total
        grand_passed += passed
        grand_failed += failed
        grand_errors += errors
        grand_duration += duration
        print()

    # Print structured report
    print(f"{BOLD}{CYAN}------------------------------------------------------------------------{RESET}")
    print(f"{BOLD}                       REPOSITORY CHECK SUMMARY                        {RESET}")
    print(f"{BOLD}{CYAN}------------------------------------------------------------------------{RESET}")
    print(f"{'Tier / Suite':<45} | {'Total':<6} | {'Passed':<6} | {'Failed':<6} | {'Time (s)':<8}")
    print("-" * 79)
    for name, total, passed, failed, errors, duration in summary_rows:
        color = GREEN if (failed == 0 and errors == 0) else RED
        print(f"{name:<45} | {total:<6} | {color}{passed:<6}{RESET} | {failed + errors:<6} | {duration:<8.2f}")
    print("-" * 79)
    total_color = GREEN if (grand_failed == 0 and grand_errors == 0) else RED
    print(f"{BOLD}{'GRAND TOTAL':<45} | {grand_total:<6} | {total_color}{grand_passed:<6}{RESET}{BOLD} | {grand_failed + grand_errors:<6} | {grand_duration:<8.2f}{RESET}")
    print(f"{BOLD}{CYAN}========================================================================{RESET}\n")

    if grand_failed == 0 and grand_errors == 0:
        print(f"{BOLD}{GREEN}✓ ALL {grand_total} REPOSITORY CHECKS PASSED!{RESET}\n")
        return 0
    else:
        print(f"{BOLD}{RED}✗ TEST RUN FAILED with {grand_failed} failures and {grand_errors} errors.{RESET}\n")
        return 1

if __name__ == "__main__":
    sys.exit(main())
