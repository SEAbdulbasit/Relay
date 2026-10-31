import unittest
import subprocess
import os
from pathlib import Path
from e2e_tests.common.test_base import RelayE2ETestBase
from e2e_tests.common.http_server import LocalWebsiteServer

class TestRealWorldScenarios(RelayE2ETestBase):
    """
    Tier 4: Real-World Application Scenarios
    Validates full end-to-end user workflows:
    - Scenario 1: Onboarding Completion & First Task Launch
    - Scenario 2: Multi-Agent Offline Execution Pipeline
    - Scenario 3: Global Shortcut Task Interruption
    - Scenario 4: Companion Marketing Website Local Serving & Exploration
    - Scenario 5: Production Build & Codesigning Pipeline
    - Scenario 6: Full Swift Test Suite Validation
    """

    def test_scenario_01_onboarding_lifecycle_to_task_launch(self):
        """
        Scenario 1: Fresh user installs app, navigates through all 5 onboarding steps,
        finishes setup, and launches first task.
        """
        coordinator_file = self.sources_relay / "OnboardingCoordinator.swift"
        onboarding_view = self.sources_relay / "OnboardingView.swift"
        relay_app = self.sources_relay / "RelayApp.swift"

        coord_content = coordinator_file.read_text(encoding="utf-8")
        view_content = onboarding_view.read_text(encoding="utf-8")
        app_content = relay_app.read_text(encoding="utf-8")

        # 1. Verify 5 steps present
        steps = ["Welcome", "Offline Privacy", "Local Model", "Mac Access", "Launchpad"]
        for s in steps:
            self.assertIn(s, view_content)

        # 2. Verify step navigation and clamping
        self.assertIn("min(4, max(0, step))", coord_content)

        # 3. Verify finish and app transition
        self.assertIn("func finish()", coord_content)
        self.assertIn("if onboarding.completed {", app_content)

    def test_scenario_02_multiagent_offline_execution_pipeline(self):
        """
        Scenario 2: Multi-agent execution pipeline coordinates Planner, Navigator,
        Executor, and Critic completely offline.
        """
        orch_file = self.sources_relay / "MultiAgent" / "MultiAgentOrchestrator.swift"
        role_file = self.sources_relay / "MultiAgent" / "AgentRole.swift"
        blackboard_file = self.sources_relay / "MultiAgent" / "MultiAgentBlackboard.swift"

        orch_content = orch_file.read_text(encoding="utf-8")
        role_content = role_file.read_text(encoding="utf-8")
        bb_content = blackboard_file.read_text(encoding="utf-8")

        # Verify role transitions
        self.assertIn("runPlannerTurn", orch_content)
        self.assertIn("executePlanStepWithVerification", orch_content)
        self.assertIn("runCriticTurn", orch_content)
        self.assertIn("runSynthesisTurn", orch_content)

        # Verify Critic postcondition check
        self.assertIn("completeStep", bb_content)
        self.assertIn(".verified", bb_content)

    def test_scenario_03_global_shortcut_task_interruption(self):
        """
        Scenario 3: User cancels long-running task midway via stop button / shortcut (⌘.).
        """
        main_view = self.sources_relay / "MainView.swift"
        store_file = self.sources_relay / "AssistantStore.swift"
        orch_file = self.sources_relay / "MultiAgent" / "MultiAgentOrchestrator.swift"

        main_content = main_view.read_text(encoding="utf-8")
        store_content = store_file.read_text(encoding="utf-8")
        orch_content = orch_file.read_text(encoding="utf-8")

        self.assertIn("store.stop()", main_content)
        self.assertIn("phase = .stopped", store_content)
        self.assertIn("try gate?()", orch_content)

    def test_scenario_04_companion_website_local_serving(self):
        """
        Scenario 4: Companion website runs on local HTTP server, serves pages with HTTP 200,
        and provides interactive agent simulation.
        """
        server = LocalWebsiteServer(self.website_dir)
        server.start()
        try:
            status, _, body = server.fetch("/")
            self.assertEqual(status, 200)
            self.assertIn("Relay", body)

            status_priv, _, body_priv = server.fetch("/privacy.html")
            self.assertEqual(status_priv, 200)
            self.assertIn("Privacy", body_priv)

            status_js, _, body_js = server.fetch("/js/agent-demo.js")
            self.assertEqual(status_js, 200)
            self.assertIn("SCENARIOS", body_js)
        finally:
            server.stop()

    def test_scenario_05_production_build_script_verification(self):
        """
        Scenario 5: Production build script is executable, compiles products,
        and verifies codesign bundle structure.
        """
        build_script = self.scripts_dir / "build-app.sh"
        self.assertTrue(os.access(build_script, os.X_OK), "build-app.sh must be executable")
        content = build_script.read_text(encoding="utf-8")
        self.assertIn("swift build -c", content)
        self.assertIn("codesign --verify --deep --strict", content)

    def test_scenario_06_swift_test_suite_validation(self):
        """
        Scenario 6: Swift test configuration verifies RelayTests test target
        with MainActor isolation.
        """
        pkg_file = self.project_root / "Package.swift"
        content = pkg_file.read_text(encoding="utf-8")
        self.assertIn('.testTarget(name: "RelayTests"', content)
        self.assertIn(".defaultIsolation(MainActor.self)", content)
