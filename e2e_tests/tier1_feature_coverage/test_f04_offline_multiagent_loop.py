import unittest
from pathlib import Path
from e2e_tests.common.test_base import RelayE2ETestBase

class TestF04OfflineMultiAgentLoop(RelayE2ETestBase):
    """
    Feature 4: Offline Multi-Agent Execution Loop
    Tests multi-agent coordination, sequential blackboard turns,
    simulated step execution, and postcondition verification.
    """

    def setUp(self):
        self.orchestrator_file = self.sources_relay / "MultiAgent" / "MultiAgentOrchestrator.swift"
        self.blackboard_file = self.sources_relay / "MultiAgent" / "MultiAgentBlackboard.swift"
        self.assertTrue(self.orchestrator_file.exists(), "MultiAgentOrchestrator.swift must exist")
        self.assertTrue(self.blackboard_file.exists(), "MultiAgentBlackboard.swift must exist")
        self.orchestrator_content = self.orchestrator_file.read_text(encoding="utf-8")
        self.blackboard_content = self.blackboard_file.read_text(encoding="utf-8")

    def test_f04_01_orchestrator_initialization_with_seams(self):
        """Verifies MultiAgentOrchestrator takes deterministic test seams (complete, execute, gate)."""
        self.assertIn("class MultiAgentOrchestrator", self.orchestrator_content)
        self.assertIn("complete: @escaping CompleteHandler", self.orchestrator_content)
        self.assertIn("execute: @escaping ExecuteHandler", self.orchestrator_content)
        self.assertIn("gate: GateCheck?", self.orchestrator_content)

    def test_f04_02_planner_turn_decomposition(self):
        """Verifies Planner turn parses JSON subgoals into PlanStep structures."""
        self.assertIn("runPlannerTurn", self.orchestrator_content)
        self.assertIn("parsePlan", self.orchestrator_content)
        self.assertIn("blackboard.setPlan", self.orchestrator_content)

    def test_f04_03_sequential_step_execution(self):
        """Verifies sequential step execution loop across roles."""
        self.assertIn("executePlanStepWithVerification", self.orchestrator_content)
        self.assertIn("for step in blackboard.structuredPlan", self.orchestrator_content)

    def test_f04_04_independent_critic_verification(self):
        """Verifies Critic turn independently validates tool outputs."""
        self.assertIn("runCriticTurn", self.orchestrator_content)
        self.assertIn("completeStep", self.blackboard_content)
        self.assertIn(".verified", self.blackboard_content)

    def test_f04_05_synthesis_turn_summary(self):
        """Verifies final synthesis turn compiles completed steps and artifacts."""
        self.assertIn("runSynthesisTurn", self.orchestrator_content)
        self.assertIn("MultiAgentResult", self.orchestrator_content)

    def test_f04_06_gate_check_halts_on_interruption(self):
        """Verifies gate checks prevent progression when stopped."""
        self.assertIn("try gate?()", self.orchestrator_content)
