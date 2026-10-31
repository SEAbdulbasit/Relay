# Test Infrastructure: Relay End-to-End Test Suite

## Overview
This document specifies the end-to-end (E2E) testing infrastructure for **Relay**—a 100% offline multi-agent intelligent assistant for macOS, accompanied by a companion marketing website. The E2E test suite validates all 12 project features defined in `PROJECT.md` through an opaque-box, requirement-driven methodology spanning 4 systematic tiers.

## 4-Tier Test Architecture

```
========================================================================================
                              RELAY E2E TEST ARCHITECTURE
========================================================================================

  Tier 1: Feature Coverage (72 tests)
  ├── F1:  Design System Foundations & Tokens (Obsidian palette, 8-stop prism gradient)
  ├── F2:  Multi-Agent Role Definitions (Planner, Navigator, Executor, Critic)
  ├── F3:  Tool Schema Partitioning (>75% overhead reduction, <1 KB budget)
  ├── F4:  Offline Multi-Agent Execution Loop (Blackboard turn coordination)
  ├── F5:  5-Step Modern Onboarding Lifecycle (Steps 0-4, clamping, persistence)
  ├── F6:  Conversational UI & Empty State Cards (Starter cards, thread, evidence)
  ├── F7:  Streamlined Composer & Reasoning Trails (Dock, shortcut ⌘., activity panel)
  ├── F8:  Settings View Refinement (Model diagnostics, setup assistant re-entry)
  ├── F9:  Companion Marketing Website Core (index.html, hero, demo, bento grid)
  ├── F10: Dedicated Privacy Architecture Page (privacy.html, flow visualizer)
  ├── F11: Web Design System & CSS Tokens (tokens.css, base.css, components.css)
  └── F12: Dual Track E2E Verification Suite (build-app.sh, Package.swift, swift test)

  Tier 2: Boundary & Corner Cases (60 tests)
  ├── B01: Onboarding step clamping [0, 4] (negative clamping, excessive clamping)
  ├── B02: Zero-network airgap enforcement (no telemetry, no remote endpoints)
  ├── B03: Empty & whitespace prompt handling (trimmed inputs, placeholder)
  ├── B04: Context budget & token limits (24 KB ceiling, 8K tokens, 64 KB tool args)
  ├── B05: Missing & corrupt model packages (non-existent, wrong extension, empty path)
  ├── B06: Website 404 links & asset crawl (zero broken hrefs, internal anchors, SVGs)
  ├── B07: Cancellation & stop interruption (global shortcut ⌘., gate checks)
  ├── B08: Malformed inputs & unknown roles (DecodingError fallback, error recovery)
  ├── B09: Design token edge values & numeric bounds (RGB, opacity, monotone stops)
  ├── B10: Extreme payloads & action repetition guards (<= 3 loop limit, 64KB cap)
  ├── B11: State persistence & corruption recovery (mode 0600, atomic writes, etag)
  └── B12: Process signals & script exit integrity (set -euo pipefail, willTerminate)

  Tier 3: Cross-Feature Combinations (12 tests)
  ├── Pairwise interactions across Onboarding ↔ MainView, Swift ↔ CSS tokens,
  └── Stop Shortcut ↔ Multi-Agent Loop, Settings ↔ Setup Assistant, etc.

  Tier 4: Real-World Application Scenarios (6 scenarios)
  ├── Scenario 1: Fresh user onboarding completion to first task launch
  ├── Scenario 2: Multi-agent offline plan-navigate-execute-critic workflow
  ├── Scenario 3: Global stop shortcut midway task interruption
  ├── Scenario 4: Companion website local HTTP serving & exploration
  ├── Scenario 5: Production build script codesigning & verification
  └── Scenario 6: Full Swift unit test suite execution
========================================================================================
```

## Directory Layout
```
Relay/
├── e2e_tests/
│   ├── run_all.sh                         # Executable bash test runner entrypoint
│   ├── runner.py                          # Structured Python test runner with ANSI reporting
│   ├── common/
│   │   ├── __init__.py
│   │   ├── test_base.py                   # Base test fixture & assertion helpers
│   │   ├── http_server.py                 # Ephemeral Python HTTP server for website
│   │   └── offline_guard.py               # Airgap and telemetry scanner
│   ├── tier1_feature_coverage/            # 12 test modules (F1 through F12, 72 tests)
│   ├── tier2_boundary_corner/             # 12 test modules (B01 through B12, 60 tests)
│   ├── tier3_cross_feature/               # Cross-feature combinations (12 tests)
│   └── tier4_real_world_scenarios/        # Real-world scenarios (6 tests)
├── TEST_INFRA.md                          # Test infrastructure documentation (this file)
└── TEST_READY.md                          # Readiness publication & feature inventory
```

## How to Execute

### 1. Run Complete E2E Suite (All Tiers)
```bash
./e2e_tests/run_all.sh
```

### 2. Run Specific Tier
```bash
# Tier 1 only (Feature Coverage)
./e2e_tests/run_all.sh --tier 1

# Tier 2 only (Boundary & Corner Cases)
./e2e_tests/run_all.sh --tier 2

# Tier 3 only (Cross-Feature Combinations)
./e2e_tests/run_all.sh --tier 3

# Tier 4 only (Real-World Application Scenarios)
./e2e_tests/run_all.sh --tier 4
```

### 3. Filter by Specific Feature in Tier 1
```bash
# Test Feature 2 (Agent Roles) with verbose output
./e2e_tests/run_all.sh --tier 1 --feature f02 -v
```

### 4. Direct Python Invocation
```bash
python3 e2e_tests/runner.py --verbose
```

## Isolation and Offline Guarantees
- **Zero Remote Dependencies**: Tests run completely offline and require no Internet access.
- **Local Web Server**: Tier 1 and Tier 4 use `LocalWebsiteServer` binding to `127.0.0.1` on ephemeral unprivileged ports to verify HTTP 200 responses, MIME types, and DOM structure.
- **Airgap Scanning**: `OfflineAirGapChecker` verifies zero tracking, telemetry, or remote API endpoints in Swift source code and HTML templates.
- **MainActor Concurrency**: Verifies strict Swift 6 concurrency models across all subsystems.
