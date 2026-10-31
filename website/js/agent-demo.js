/**
 * Relay Marketing Website - Interactive Multi-Agent Demo & Site Logic
 * Simulates genuine on-device Planner, Navigator, Executor, and Critic coordination.
 */

(function () {
  'use strict';

  // ==========================================================================
  // 1. Multi-Agent Demonstration Scenarios Data
  // ==========================================================================
  const SCENARIOS = [
    {
      id: 'taxes',
      title: 'Organize Downloads & Summarize Tax Invoices',
      userPrompt: 'Please find all 2026 Q1 tax receipts in my Downloads folder, move them into Documents/Taxes/2026, and summarize the total spent.',
      scopedContext: '~/Downloads, ~/Documents/Taxes',
      steps: [
        {
          role: 'planner',
          roleName: 'Planner',
          badgeClass: 'planner',
          timestamp: '14:02:11.204',
          thought: 'Decomposing user prompt into sequential subgoals. Partitioning tools: Planner has 0 tool schemas, pure reasoning mode.',
          content: 'I have broken this task into 4 sequential stages:\n1. Inspect ~/Downloads for tax documents matching 2026 dates.\n2. Verify destination ~/Documents/Taxes/2026 exists or prepare folder.\n3. Execute scoped atomic move operations.\n4. Verify all moved file hashes and calculate sum of invoice amounts.',
          plan: [
            { text: 'Inspect Downloads for 2026 tax documents', status: 'active' },
            { text: 'Ensure ~/Documents/Taxes/2026 destination exists', status: 'pending' },
            { text: 'Execute file moves with safety gate verification', status: 'pending' },
            { text: 'Verify file postconditions and calculate total sum', status: 'pending' }
          ]
        },
        {
          role: 'navigator',
          roleName: 'Navigator',
          badgeClass: 'navigator',
          timestamp: '14:02:12.015',
          thought: 'Inspecting local filesystem and macOS Finder state via read-only inspection tools.',
          toolCall: 'find_files(path: "~/Downloads", patterns: ["*2026*.pdf", "*tax*.pdf", "*receipt*"])',
          content: 'Reconnaissance complete. Found 6 invoice PDFs totaling 14.2 MB. Located matching files:\n• AWS_Invoice_Jan2026.pdf ($240.00)\n• Figma_Feb2026.pdf ($45.00)\n• JetBrains_Q1_2026.pdf ($289.00)\n• GitHub_Enterprise_Jan.pdf ($210.00)\n• GoogleCloud_Feb.pdf ($180.50)\n• AppleDev_2026.pdf ($99.00)\nDestination folder ~/Documents/Taxes/2026 is ready.',
          plan: [
            { text: 'Inspect Downloads for 2026 tax documents', status: 'completed' },
            { text: 'Ensure ~/Documents/Taxes/2026 destination exists', status: 'completed' },
            { text: 'Execute file moves with safety gate verification', status: 'active' },
            { text: 'Verify file postconditions and calculate total sum', status: 'pending' }
          ]
        },
        {
          role: 'executor',
          roleName: 'Executor',
          badgeClass: 'executor',
          timestamp: '14:02:13.440',
          thought: 'Executing scoped file transfer operations. Safe sandbox check passed: all paths lie within authorized user context.',
          toolCall: 'move_files(sources: [6 files], destination: "~/Documents/Taxes/2026")',
          content: 'Transferred 6 invoice files to ~/Documents/Taxes/2026. Atomic transaction committed without overwriting existing files.',
          plan: [
            { text: 'Inspect Downloads for 2026 tax documents', status: 'completed' },
            { text: 'Ensure ~/Documents/Taxes/2026 destination exists', status: 'completed' },
            { text: 'Execute file moves with safety gate verification', status: 'completed' },
            { text: 'Verify file postconditions and calculate total sum', status: 'active' }
          ]
        },
        {
          role: 'critic',
          roleName: 'Critic',
          badgeClass: 'critic',
          timestamp: '14:02:14.180',
          thought: 'Validating postconditions: inspecting destination directory count, checking for unhandled exceptions, and calculating financial sum.',
          toolCall: 'verify_destination(path: "~/Documents/Taxes/2026", expectedFiles: 6)',
          content: 'Verification passed: 6/6 files verified at target directory with identical SHA-256 integrity. Total expenditures calculated: $1,063.50 across 6 services. All actions completed offline.',
          plan: [
            { text: 'Inspect Downloads for 2026 tax documents', status: 'completed' },
            { text: 'Ensure ~/Documents/Taxes/2026 destination exists', status: 'completed' },
            { text: 'Execute file moves with safety gate verification', status: 'completed' },
            { text: 'Verify file postconditions and calculate total sum', status: 'completed' }
          ]
        },
        {
          role: 'assistant',
          roleName: 'Relay Assistant',
          badgeClass: 'critic',
          timestamp: '14:02:14.610',
          content: 'Done! I have organized your 6 tax receipts into `~/Documents/Taxes/2026`.\n\n**Summary of Q1 2026 Expenses:**\n• Total: **$1,063.50**\n• Items: AWS ($240.00), Figma ($45.00), JetBrains ($289.00), GitHub ($210.00), Google Cloud ($180.50), Apple ($99.00).\n\nAll operations ran 100% locally with zero cloud network access.',
          plan: [
            { text: 'Inspect Downloads for 2026 tax documents', status: 'completed' },
            { text: 'Ensure ~/Documents/Taxes/2026 destination exists', status: 'completed' },
            { text: 'Execute file moves with safety gate verification', status: 'completed' },
            { text: 'Verify file postconditions and calculate total sum', status: 'completed' }
          ]
        }
      ]
    },
    {
      id: 'calendar',
      title: 'Extract Meeting Action Items from Mail into Notes',
      userPrompt: 'Read the latest thread from Sarah in Mail about the Q3 Product Launch, extract the decisions, and save a formatted brief in Apple Notes.',
      scopedContext: 'Mail.app, Notes.app (Accessibility Scoped)',
      steps: [
        {
          role: 'planner',
          roleName: 'Planner',
          badgeClass: 'planner',
          timestamp: '16:45:01.100',
          thought: 'Decomposing inter-app workflow. Ensuring human confirmation gate is active for any outbound communication.',
          content: 'Execution plan:\n1. Inspect Mail.app message list for recent thread from "Sarah".\n2. Extract key milestones, owner assignments, and target launch dates.\n3. Format markdown note with headings and checklists.\n4. Create note in local Apple Notes database and verify presence.',
          plan: [
            { text: 'Search Mail for thread from Sarah', status: 'active' },
            { text: 'Extract decisions and deliverables', status: 'pending' },
            { text: 'Format structured Markdown summary', status: 'pending' },
            { text: 'Write to Apple Notes and verify', status: 'pending' }
          ]
        },
        {
          role: 'navigator',
          roleName: 'Navigator',
          badgeClass: 'navigator',
          timestamp: '16:45:02.320',
          thought: 'Querying Mail via macOS Accessibility AXUIElement tree.',
          toolCall: 'mail_query(sender: "Sarah", subjectFilter: "Q3 Launch")',
          content: 'Located 3 emails in thread "Q3 Launch Schedule". Found approved milestones: Beta freeze on Nov 12, Security audit on Nov 18, Public launch on Dec 1.',
          plan: [
            { text: 'Search Mail for thread from Sarah', status: 'completed' },
            { text: 'Extract decisions and deliverables', status: 'completed' },
            { text: 'Format structured Markdown summary', status: 'active' },
            { text: 'Write to Apple Notes and verify', status: 'pending' }
          ]
        },
        {
          role: 'executor',
          roleName: 'Executor',
          badgeClass: 'executor',
          timestamp: '16:45:03.540',
          thought: 'Dispatching safe creation of Note in local Notes store.',
          toolCall: 'notes_create(folder: "Projects", title: "Q3 Product Launch Brief", format: "markdown")',
          content: 'Created note "Q3 Product Launch Brief" in folder "Projects" with 3 milestones and 4 action items.',
          plan: [
            { text: 'Search Mail for thread from Sarah', status: 'completed' },
            { text: 'Extract decisions and deliverables', status: 'completed' },
            { text: 'Format structured Markdown summary', status: 'completed' },
            { text: 'Write to Apple Notes and verify', status: 'active' }
          ]
        },
        {
          role: 'critic',
          roleName: 'Critic',
          badgeClass: 'critic',
          timestamp: '16:45:04.110',
          thought: 'Verifying note creation in Notes.app and checking formatting fidelity.',
          toolCall: 'verify_note_exists(title: "Q3 Product Launch Brief")',
          content: 'Verification successful. Note verified in Apple Notes with exact title and content checksum matching.',
          plan: [
            { text: 'Search Mail for thread from Sarah', status: 'completed' },
            { text: 'Extract decisions and deliverables', status: 'completed' },
            { text: 'Format structured Markdown summary', status: 'completed' },
            { text: 'Write to Apple Notes and verify', status: 'completed' }
          ]
        },
        {
          role: 'assistant',
          roleName: 'Relay Assistant',
          badgeClass: 'critic',
          timestamp: '16:45:04.500',
          content: 'I have extracted Sarah\'s email thread and created a new note in **Apple Notes** titled **"Q3 Product Launch Brief"** with the full milestone breakdown.',
          plan: [
            { text: 'Search Mail for thread from Sarah', status: 'completed' },
            { text: 'Extract decisions and deliverables', status: 'completed' },
            { text: 'Format structured Markdown summary', status: 'completed' },
            { text: 'Write to Apple Notes and verify', status: 'completed' }
          ]
        }
      ]
    },
    {
      id: 'storage',
      title: 'Audit System Caches & Suggest Disk Reclamation',
      userPrompt: 'Scan my user Library caches for stale build artifacts from Xcode and Swift Package Manager, and tell me how much space I can safely reclaim.',
      scopedContext: '~/Library/Caches, ~/Library/Developer/Xcode/DerivedData',
      steps: [
        {
          role: 'planner',
          roleName: 'Planner',
          badgeClass: 'planner',
          timestamp: '09:15:30.010',
          thought: 'Establishing read-only boundary for system audit. Non-destructive safety gate strictly enforced.',
          content: 'Audit Strategy:\n1. Scan DerivedData directory for inactive build folders older than 14 days.\n2. Calculate disk usage of SPM artifact caches.\n3. Verify no running Xcode compilation processes before suggesting cleanup.',
          plan: [
            { text: 'Scan Xcode DerivedData for stale build folders', status: 'active' },
            { text: 'Analyze SwiftPM cache storage', status: 'pending' },
            { text: 'Confirm zero active compilation locks', status: 'pending' },
            { text: 'Generate reclamation report with safety commands', status: 'pending' }
          ]
        },
        {
          role: 'navigator',
          roleName: 'Navigator',
          badgeClass: 'navigator',
          timestamp: '09:15:31.250',
          thought: 'Inspecting filesystem directories without modifying files.',
          toolCall: 'directory_stats(paths: ["~/Library/Developer/Xcode/DerivedData", "~/.swiftpm/cache"])',
          content: 'Scan completed. Found 18 inactive project folders in DerivedData consuming 24.8 GB. SPM cache contains 3.2 GB of superseded binary targets.',
          plan: [
            { text: 'Scan Xcode DerivedData for stale build folders', status: 'completed' },
            { text: 'Analyze SwiftPM cache storage', status: 'completed' },
            { text: 'Confirm zero active compilation locks', status: 'active' },
            { text: 'Generate reclamation report with safety commands', status: 'pending' }
          ]
        },
        {
          role: 'executor',
          roleName: 'Executor',
          badgeClass: 'executor',
          timestamp: '09:15:32.400',
          thought: 'Running lock inspection. Verifying Xcode and swift-frontend process status.',
          toolCall: 'check_process_locks(processes: ["Xcode", "swift-frontend"])',
          content: 'Zero active build locks detected. All 28.0 GB of identified artifacts are safely reclaimable without affecting active work.',
          plan: [
            { text: 'Scan Xcode DerivedData for stale build folders', status: 'completed' },
            { text: 'Analyze SwiftPM cache storage', status: 'completed' },
            { text: 'Confirm zero active compilation locks', status: 'completed' },
            { text: 'Generate reclamation report with safety commands', status: 'active' }
          ]
        },
        {
          role: 'critic',
          roleName: 'Critic',
          badgeClass: 'critic',
          timestamp: '09:15:32.900',
          thought: 'Verifying report figures and ensuring deletion commands require manual confirmation gate.',
          toolCall: 'validate_safety_gate(actionType: "reclamation_advice")',
          content: 'Audit validated. Recommending manual cleanup button or terminal command; no destructive actions taken without explicit prompt.',
          plan: [
            { text: 'Scan Xcode DerivedData for stale build folders', status: 'completed' },
            { text: 'Analyze SwiftPM cache storage', status: 'completed' },
            { text: 'Confirm zero active compilation locks', status: 'completed' },
            { text: 'Generate reclamation report with safety commands', status: 'completed' }
          ]
        },
        {
          role: 'assistant',
          roleName: 'Relay Assistant',
          badgeClass: 'critic',
          timestamp: '09:15:33.200',
          content: 'You can safely reclaim **28.0 GB** of disk space:\n• **Xcode DerivedData**: 24.8 GB across 18 dormant projects\n• **Swift Package Manager Cache**: 3.2 GB\n\nBecause Relay enforces strict safety gates, no files were deleted automatically. Click "Clean Caches" in Settings or run `rm -rf ~/Library/Developer/Xcode/DerivedData/*` when ready.',
          plan: [
            { text: 'Scan Xcode DerivedData for stale build folders', status: 'completed' },
            { text: 'Analyze SwiftPM cache storage', status: 'completed' },
            { text: 'Confirm zero active compilation locks', status: 'completed' },
            { text: 'Generate reclamation report with safety commands', status: 'completed' }
          ]
        }
      ]
    }
  ];

  // ==========================================================================
  // 2. Multi-Agent Preview Engine Controller
  // ==========================================================================
  class AgentDemoController {
    constructor() {
      this.currentScenarioIndex = 0;
      this.currentStepIndex = -1; // -1 means initial user prompt only
      this.isPlaying = false;
      this.playInterval = null;
      this.stepDelay = 2200; // ms

      // DOM Elements
      this.scenarioSelect = document.getElementById('demo-scenario-select');
      this.feedContainer = document.getElementById('demo-feed-container');
      this.planList = document.getElementById('demo-plan-list');
      this.activeRoleBadge = document.getElementById('demo-active-role-badge');
      this.scopedContextEl = document.getElementById('demo-scoped-context');
      this.goalTextEl = document.getElementById('demo-goal-text');
      this.playBtn = document.getElementById('demo-btn-play');
      this.stepBtn = document.getElementById('demo-btn-step');
      this.resetBtn = document.getElementById('demo-btn-reset');
      this.stepProgressEl = document.getElementById('demo-step-counter');

      if (!this.feedContainer) return; // Not on page with demo

      this.init();
    }

    init() {
      if (this.scenarioSelect) {
        this.scenarioSelect.addEventListener('change', (e) => {
          this.switchScenario(e.target.value);
        });
      }

      if (this.playBtn) {
        this.playBtn.addEventListener('click', () => this.togglePlay());
      }

      if (this.stepBtn) {
        this.stepBtn.addEventListener('click', () => this.nextStep());
      }

      if (this.resetBtn) {
        this.resetBtn.addEventListener('click', () => this.reset());
      }

      // Briefing cards click handler
      const briefingCards = document.querySelectorAll('.sentient-briefing-card[data-scenario]');
      briefingCards.forEach(card => {
        card.addEventListener('click', () => {
          briefingCards.forEach(c => c.classList.remove('active'));
          card.classList.add('active');
          const scenarioId = card.getAttribute('data-scenario');
          if (this.scenarioSelect) this.scenarioSelect.value = scenarioId;
          this.switchScenario(scenarioId);
        });
      });

      // Initial render + advance 1 step so Planner decomposition is immediately visible
      this.renderInitialState();
      this.nextStep();
    }

    getCurrentScenario() {
      return SCENARIOS[this.currentScenarioIndex];
    }

    switchScenario(scenarioId) {
      this.pause();
      const idx = SCENARIOS.findIndex(s => s.id === scenarioId);
      if (idx !== -1) {
        this.currentScenarioIndex = idx;
        this.reset();
        this.nextStep();
      }
    }

    reset() {
      this.pause();
      this.currentStepIndex = -1;
      this.renderInitialState();
    }

    togglePlay() {
      if (this.isPlaying) {
        this.pause();
      } else {
        this.play();
      }
    }

    play() {
      const scenario = this.getCurrentScenario();
      if (this.currentStepIndex >= scenario.steps.length - 1) {
        // Already finished, restart
        this.currentStepIndex = -1;
        this.renderInitialState();
      }

      this.isPlaying = true;
      this.updatePlayBtnState();
      this.playInterval = setInterval(() => {
        const hasNext = this.nextStep();
        if (!hasNext) {
          this.pause();
        }
      }, this.stepDelay);
    }

    pause() {
      this.isPlaying = false;
      if (this.playInterval) {
        clearInterval(this.playInterval);
        this.playInterval = null;
      }
      this.updatePlayBtnState();
    }

    updatePlayBtnState() {
      if (!this.playBtn) return;
      if (this.isPlaying) {
        this.playBtn.innerHTML = `
          <svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor">
            <rect x="6" y="4" width="4" height="16" />
            <rect x="14" y="4" width="4" height="16" />
          </svg>
          Pause
        `;
      } else {
        this.playBtn.innerHTML = `
          <svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor">
            <polygon points="5 3 19 12 5 21 5 3" />
          </svg>
          Play
        `;
      }
    }

    nextStep() {
      const scenario = this.getCurrentScenario();
      if (this.currentStepIndex < scenario.steps.length - 1) {
        this.currentStepIndex++;
        this.renderStep(this.currentStepIndex);
        return true;
      }
      return false;
    }

    renderInitialState() {
      const scenario = this.getCurrentScenario();
      if (this.goalTextEl) this.goalTextEl.textContent = scenario.title;
      if (this.scopedContextEl) this.scopedContextEl.textContent = scenario.scopedContext;
      if (this.activeRoleBadge) {
        this.activeRoleBadge.className = 'role-badge';
        this.activeRoleBadge.textContent = 'READY';
      }
      if (this.stepProgressEl) {
        this.stepProgressEl.textContent = `0 / ${scenario.steps.length}`;
      }

      // Clear and render user prompt
      if (this.feedContainer) {
        this.feedContainer.innerHTML = `
          <div class="chat-bubble user-bubble">
            ${this.escapeHTML(scenario.userPrompt)}
          </div>
        `;
      }

      // Initial plan steps
      if (this.planList) {
        this.planList.innerHTML = `
          <li class="plan-step-item">
            <span class="step-icon">○</span>
            <span>Awaiting on-device Planner decomposition...</span>
          </li>
        `;
      }
    }

    renderStep(stepIdx) {
      const scenario = this.getCurrentScenario();
      const step = scenario.steps[stepIdx];
      if (!step) return;

      if (this.stepProgressEl) {
        this.stepProgressEl.textContent = `${stepIdx + 1} / ${scenario.steps.length}`;
      }

      // Update active role badge
      if (this.activeRoleBadge) {
        this.activeRoleBadge.className = `role-badge ${step.badgeClass}`;
        this.activeRoleBadge.textContent = step.roleName.toUpperCase();
      }

      // Append bubble to feed
      if (this.feedContainer) {
        const bubble = document.createElement('div');
        bubble.className = 'chat-bubble agent-bubble';

        let inner = `
          <div class="agent-bubble-header">
            <span class="role-badge ${step.badgeClass}">[${step.roleName}]</span>
            <span class="agent-timestamp">${step.timestamp}</span>
          </div>
        `;

        if (step.thought) {
          inner += `
            <div class="thought-trail">
              <strong>Thinking:</strong> ${this.escapeHTML(step.thought)}
            </div>
          `;
        }

        if (step.toolCall) {
          inner += `
            <div class="tool-call-box">
              <strong>Tool Dispatch:</strong> <code>${this.escapeHTML(step.toolCall)}</code>
            </div>
          `;
        }

        inner += `<div style="margin-top: 0.65rem; white-space: pre-line;">${this.formatContent(step.content)}</div>`;

        bubble.innerHTML = inner;
        this.feedContainer.appendChild(bubble);

        // Smooth scroll to bottom
        this.feedContainer.scrollTop = this.feedContainer.scrollHeight;
      }

      // Update plan list
      if (this.planList && step.plan) {
        this.planList.innerHTML = step.plan.map(p => {
          let icon = '○';
          let cls = 'plan-step-item';
          if (p.status === 'completed') {
            icon = '✓';
            cls += ' completed';
          } else if (p.status === 'active') {
            icon = '●';
            cls += ' active';
          }
          return `
            <li class="${cls}">
              <span class="step-icon">${icon}</span>
              <span>${this.escapeHTML(p.text)}</span>
            </li>
          `;
        }).join('');
      }
    }

    formatContent(raw) {
      return this.escapeHTML(raw)
        .replace(/\*\*(.*?)\*\*/g, '<strong>$1</strong>')
        .replace(/`([^`]+)`/g, '<code>$1</code>')
        .replace(/• /g, '&bull; ');
    }

    escapeHTML(str) {
      return str
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#039;');
    }
  }

  // ==========================================================================
  // 3. Terminal Copy Pill Utility
  // ==========================================================================
  function initTerminalCopy() {
    const copyBtns = document.querySelectorAll('.terminal-copy-btn');
    copyBtns.forEach(btn => {
      btn.addEventListener('click', async () => {
        const cmdEl = btn.closest('.terminal-pill')?.querySelector('.terminal-pill-cmd');
        const textToCopy = cmdEl ? cmdEl.textContent.trim() : 'brew install --cask relay-ai';

        try {
          if (navigator.clipboard && window.isSecureContext) {
            await navigator.clipboard.writeText(textToCopy);
          } else {
            // Fallback for non-https contexts
            const textarea = document.createElement('textarea');
            textarea.value = textToCopy;
            textarea.style.position = 'fixed';
            textarea.style.opacity = '0';
            document.body.appendChild(textarea);
            textarea.focus();
            textarea.select();
            document.execCommand('copy');
            document.body.removeChild(textarea);
          }

          // Visual Feedback
          btn.classList.add('copied');
          const originalHTML = btn.innerHTML;
          btn.innerHTML = `
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
              <polyline points="20 6 9 17 4 12" />
            </svg>
            Copied!
          `;

          setTimeout(() => {
            btn.classList.remove('copied');
            btn.innerHTML = originalHTML;
          }, 2200);
        } catch (err) {
          console.error('Failed to copy to clipboard', err);
        }
      });
    });
  }

  // ==========================================================================
  // 4. Header Scroll & Mobile Navigation
  // ==========================================================================
  function initHeaderAndNav() {
    const header = document.querySelector('.site-header');
    if (header) {
      window.addEventListener('scroll', () => {
        if (window.scrollY > 20) {
          header.classList.add('scrolled');
        } else {
          header.classList.remove('scrolled');
        }
      }, { passive: true });
    }

    const toggleBtn = document.querySelector('.nav-toggle-btn');
    const navLinks = document.querySelector('.nav-links');
    if (toggleBtn && navLinks) {
      toggleBtn.addEventListener('click', () => {
        navLinks.classList.toggle('is-open');
        const isExpanded = navLinks.classList.contains('is-open');
        toggleBtn.setAttribute('aria-expanded', isExpanded ? 'true' : 'false');
      });
    }
  }

  // ==========================================================================
  // 5. Privacy Flow Visualizer Interactive Inspector
  // ==========================================================================
  function initPrivacyFlowVisualizer() {
    const nodes = document.querySelectorAll('.flow-node');
    const detailTitle = document.getElementById('flow-detail-title');
    const detailBody = document.getElementById('flow-detail-body');
    const detailBadge = document.getElementById('flow-detail-badge');

    if (!nodes.length || !detailTitle || !detailBody) return;

    const NODE_DETAILS = {
      'source': {
        title: 'Local Context Ingestion (Zero-Network)',
        badge: 'Air-Gapped Source',
        desc: 'Relay accesses files, Notes, Mail, or window elements exclusively via macOS sandboxed security-scoped bookmarks and Accessibility APIs. Data never traverses network sockets or unmanaged disk locations.'
      },
      'blackboard': {
        title: 'Sequential Multi-Agent Blackboard',
        badge: 'In-Memory State',
        desc: 'The Blackboard pattern maintains a turn-based memory store in macOS Unified Memory. Roles (Planner, Navigator, Executor, Critic) exchange structured messages locally without external RPCs or cloud databases.'
      },
      'litert': {
        title: 'Pinned Gemma 4 E2B on LiteRT-LM Runtime',
        badge: 'Apple Silicon Hardware Accelerated',
        desc: 'Inference runs entirely on-chip via LiteRT-LM v0.18.1 compiled for Apple Silicon Neural Engine (NPU) and Metal GPU. Zero tokens leave device memory. No remote telemetry or weights updates.'
      },
      'executor': {
        title: 'Safe Scoped Execution & Critic Verification',
        badge: 'User Safety Gates',
        desc: 'The Executor dispatches targeted system actions under strict safety gates. Consequential mutations require explicit confirmation. The Critic inspects postconditions before returning the final response.'
      }
    };

    nodes.forEach(node => {
      node.addEventListener('click', () => {
        nodes.forEach(n => n.classList.remove('active'));
        node.classList.add('active');

        const stepKey = node.getAttribute('data-step');
        const info = NODE_DETAILS[stepKey];
        if (info) {
          detailTitle.textContent = info.title;
          detailBody.textContent = info.desc;
          if (detailBadge) detailBadge.textContent = info.badge;
        }
      });
    });
  }

  // ==========================================================================
  // 6. Sentient OS 3D Particle Sphere & Glowing Orbital Ring (readme_hero.jpg)
  // ==========================================================================
  function initSentientParticleOrb() {
    const canvas = document.getElementById('sentient-orb-canvas');
    if (!canvas) return;
    const ctx = canvas.getContext('2d');
    if (!ctx) return;

    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    const size = 520;
    canvas.width = size * dpr;
    canvas.height = size * dpr;
    ctx.scale(dpr, dpr);

    const cx = size / 2;
    const cy = size / 2;
    const radius = 148;

    // Generate Fibonacci / Latitude-Longitude sphere particles
    const particles = [];
    const latBands = 22;
    const lonSteps = 38;
    for (let i = 1; i < latBands; i++) {
      const phi = (Math.PI * i) / latBands;
      for (let j = 0; j < lonSteps; j++) {
        const theta = (2 * Math.PI * j) / lonSteps;
        const x = Math.sin(phi) * Math.cos(theta);
        const y = Math.cos(phi);
        const z = Math.sin(phi) * Math.sin(theta);
        particles.push({ x, y, z, phi, theta });
      }
    }

    let angleY = 0.45;
    const tiltX = 0.32;
    const prefersReducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

    function drawFrame() {
      ctx.clearRect(0, 0, size, size);

      // 1. Back half of the tilted glowing orbital ring
      ctx.save();
      ctx.translate(cx, cy);
      ctx.rotate(-0.42);
      ctx.beginPath();
      ctx.ellipse(0, 0, radius * 1.44, radius * 0.46, 0, Math.PI, 2 * Math.PI);
      ctx.strokeStyle = 'rgba(187, 101, 255, 0.35)';
      ctx.lineWidth = 2.5;
      ctx.shadowColor = 'rgba(187, 101, 255, 0.7)';
      ctx.shadowBlur = 14;
      ctx.stroke();
      ctx.restore();

      // 2. Dark glassy inner sphere body
      const sphereGrad = ctx.createRadialGradient(
        cx - radius * 0.28,
        cy - radius * 0.28,
        radius * 0.05,
        cx,
        cy,
        radius
      );
      sphereGrad.addColorStop(0, 'rgba(54, 48, 88, 0.85)');
      sphereGrad.addColorStop(0.55, 'rgba(14, 14, 24, 0.92)');
      sphereGrad.addColorStop(1, 'rgba(4, 4, 8, 0.96)');
      ctx.beginPath();
      ctx.arc(cx, cy, radius * 0.98, 0, Math.PI * 2);
      ctx.fillStyle = sphereGrad;
      ctx.fill();

      // 3. Project & sort 3D particles
      const cosY = Math.cos(angleY);
      const sinY = Math.sin(angleY);
      const cosX = Math.cos(tiltX);
      const sinX = Math.sin(tiltX);

      const projected = particles.map(p => {
        // Rotate around Y
        const x1 = p.x * cosY - p.z * sinY;
        const z1 = p.z * cosY + p.x * sinY;
        // Tilt around X
        const y2 = p.y * cosX - z1 * sinX;
        const z2 = z1 * cosX + p.y * sinX;
        return {
          px: cx + x1 * radius,
          py: cy + y2 * radius,
          z: z2,
          phi: p.phi
        };
      });

      projected.sort((a, b) => a.z - b.z);

      for (const pt of projected) {
        const depth = (pt.z + 1) * 0.5; // 0 (back) to 1 (front)
        if (depth < 0.12) continue;
        const dotRadius = 0.8 + depth * 1.75;
        const alpha = 0.12 + Math.pow(depth, 1.7) * 0.82;

        // Color blend across latitude: gold -> coral/violet -> sky blue
        const t = pt.phi / Math.PI;
        let r = 253, g = 226, b = 163;
        if (t < 0.45) {
          r = 253; g = 215; b = 165;
        } else if (t < 0.72) {
          r = 195; g = 125; b = 255;
        } else {
          r = 110; g = 185; b = 255;
        }

        ctx.beginPath();
        ctx.arc(pt.px, pt.py, dotRadius, 0, Math.PI * 2);
        ctx.fillStyle = `rgba(${r}, ${g}, ${b}, ${alpha.toFixed(3)})`;
        ctx.fill();
      }

      // 4. Glowing White Heart Core (Sentient Orb signature)
      const coreGlow = ctx.createRadialGradient(cx, cy, 0, cx, cy, radius * 0.42);
      coreGlow.addColorStop(0, 'rgba(255, 255, 255, 0.98)');
      coreGlow.addColorStop(0.22, 'rgba(253, 226, 163, 0.65)');
      coreGlow.addColorStop(0.55, 'rgba(187, 101, 255, 0.22)');
      coreGlow.addColorStop(1, 'rgba(0, 0, 0, 0)');
      ctx.beginPath();
      ctx.arc(cx, cy, radius * 0.42, 0, Math.PI * 2);
      ctx.fillStyle = coreGlow;
      ctx.fill();

      // Rim light on sphere
      ctx.beginPath();
      ctx.arc(cx, cy, radius, 0, Math.PI * 2);
      ctx.strokeStyle = 'rgba(255, 255, 255, 0.18)';
      ctx.lineWidth = 1.2;
      ctx.stroke();

      // 5. Front half of the tilted glowing orbital ring
      ctx.save();
      ctx.translate(cx, cy);
      ctx.rotate(-0.42);
      const ringGrad = ctx.createLinearGradient(-radius * 1.44, 0, radius * 1.44, 0);
      ringGrad.addColorStop(0, 'rgba(74, 144, 226, 0.45)');
      ringGrad.addColorStop(0.35, 'rgba(253, 226, 163, 0.92)');
      ringGrad.addColorStop(0.65, 'rgba(255, 255, 255, 0.95)');
      ringGrad.addColorStop(1, 'rgba(187, 101, 255, 0.55)');

      ctx.beginPath();
      ctx.ellipse(0, 0, radius * 1.44, radius * 0.46, 0, 0, Math.PI);
      ctx.strokeStyle = ringGrad;
      ctx.lineWidth = 2.6;
      ctx.shadowColor = 'rgba(253, 226, 163, 0.75)';
      ctx.shadowBlur = 16;
      ctx.stroke();

      // Orbiting satellite node on front ring
      const satAngle = (angleY * 1.4) % Math.PI;
      const sx = Math.cos(satAngle) * radius * 1.44;
      const sy = Math.sin(satAngle) * radius * 0.46;
      ctx.beginPath();
      ctx.arc(sx, sy, 4.2, 0, Math.PI * 2);
      ctx.fillStyle = '#ffffff';
      ctx.shadowColor = '#fde2a3';
      ctx.shadowBlur = 12;
      ctx.fill();
      ctx.restore();

      if (!prefersReducedMotion) {
        angleY += 0.0055;
        requestAnimationFrame(drawFrame);
      }
    }

    drawFrame();
  }

  // ==========================================================================
  // 7. Living Notch Sidekick & Double Tap (⌘⌘) CaretSwirl Showcase
  // ==========================================================================
  function initLivingNotchAndDoubleTap() {
    const notchPill = document.getElementById('demo-living-notch');
    const toggleNotchBtn = document.getElementById('btn-toggle-notch');
    const drawer = document.getElementById('notch-expanded-drawer');
    const rolePill = document.getElementById('notch-role-pill');
    const statusTitle = document.getElementById('notch-status-title');

    if (notchPill && drawer) {
      const toggleNotch = () => {
        const expanded = notchPill.classList.toggle('is-expanded');
        drawer.style.display = expanded ? 'block' : 'none';
        if (rolePill) {
          rolePill.textContent = expanded ? 'PLANNER → EXECUTOR' : 'IDLE · ⌘⇧Space';
          rolePill.className = expanded ? 'role-badge executor' : 'role-badge planner';
        }
        if (statusTitle) {
          statusTitle.textContent = expanded
            ? 'Sidekick · Working on Northstar SSO checklist'
            : 'Sidekick · Click notch to hand off a task';
        }
      };
      notchPill.addEventListener('click', toggleNotch);
      if (toggleNotchBtn) toggleNotchBtn.addEventListener('click', toggleNotch);
    }

    // Double Tap 3-Comet CaretSwirl Canvas
    const doubleTapBtn = document.getElementById('btn-trigger-doubletap');
    const swirlCanvas = document.getElementById('caret-swirl-canvas');
    const replyOutput = document.getElementById('doubletap-reply-output');
    if (doubleTapBtn && swirlCanvas && replyOutput) {
      const ctx = swirlCanvas.getContext('2d');
      const drafts = [
        "Hey Alex — yes, let's expand the Northstar pilot to 80 seats. I'll send over the SSO checklist ahead of Thursday's security review so we're all set for Friday's rollout.",
        "Hi Carl — Wednesday at 2:00 PM works great for the venue walkthrough, and the $4,800 catering cap is approved. See you there!",
        "Hi Sarah — I reviewed the Q3 launch milestones and saved the action items in Apple Notes. Ready for Friday's freeze."
      ];
      let draftIdx = 0;

      const runSwirl = () => {
        doubleTapBtn.classList.add('is-tapped');
        setTimeout(() => doubleTapBtn.classList.remove('is-tapped'), 240);
        draftIdx = (draftIdx + 1) % drafts.length;
        const start = performance.now();
        const colors = ['#fde2a3', '#bb65ff', '#6fb6ff'];

        const step = (now) => {
          const t = Math.min(1, (now - start) / 680);
          ctx.clearRect(0, 0, swirlCanvas.width, swirlCanvas.height);
          if (t < 1) {
            const cx = 190;
            const cy = 48;
            const radius = (1 - t) * 110 + 8;
            for (let i = 0; i < 3; i++) {
              const angle = t * Math.PI * 4 + (i * Math.PI * 2) / 3;
              const x = cx + Math.cos(angle) * radius;
              const y = cy + Math.sin(angle) * (radius * 0.42);
              ctx.beginPath();
              ctx.arc(x, y, 4.5 * (1 - t * 0.4), 0, Math.PI * 2);
              ctx.fillStyle = colors[i];
              ctx.shadowColor = colors[i];
              ctx.shadowBlur = 12;
              ctx.fill();
            }
            requestAnimationFrame(step);
          } else {
            ctx.clearRect(0, 0, swirlCanvas.width, swirlCanvas.height);
            replyOutput.textContent = drafts[draftIdx];
          }
        };
        requestAnimationFrame(step);
      };

      doubleTapBtn.addEventListener('click', runSwirl);
    }
  }

  // ==========================================================================
  // 8. 60fps Constellation Knowledge Graph & 2-Pane Obsidian Reader
  // ==========================================================================
  function initConstellationVault() {
    const canvas = document.getElementById('sentient-constellation-canvas');
    const titleEl = document.getElementById('vault-note-title');
    const domainEl = document.getElementById('vault-note-domain');
    const bodyEl = document.getElementById('vault-note-body');
    const clockBadge = document.getElementById('vault-clock-badge');
    const btn03 = document.getElementById('btn-vault-03am');
    const btn09 = document.getElementById('btn-vault-09am');

    const NOTES = {
      'README.md': {
        domain: 'CORE VAULT · UPDATED OVERNIGHT',
        color: '#fde2a3',
        body: 'Your personal knowledge graph lives as plain Markdown files inside <code>~/Documents/Relay</code>. Linked notes like <span class="wikilink-pill" data-target="Northstar pilot.md">[[Northstar pilot.md]]</span> and <span class="wikilink-pill" data-target="writingstyle.md">[[writingstyle.md]]</span> power both Sidekick and Double Tap without a single byte leaving your Mac.'
      },
      'Northstar pilot.md': {
        domain: 'WORK & PILOTS · 3 BACKLINKS',
        color: '#bb65ff',
        body: 'Alex Chen requested expanding the Northstar pilot from 25 to 80 seats ahead of Friday rollout. Pending item: send SSO security checklist before Thursday review. Linked to <span class="wikilink-pill" data-target="writingstyle.md">[[writingstyle.md]]</span>.'
      },
      'writingstyle.md': {
        domain: 'VOICE PROFILE · DOUBLE TAP (⌘⌘)',
        color: '#4ade80',
        body: 'Tone: concise, warm, direct. Opens with "Hey [Name] —", states the decision in sentence one, and closes with concrete next steps. Used automatically when you double-tap Right ⌘.'
      },
      'Apple silicon.md': {
        domain: 'TECHNOLOGY & RESEARCH · M-SERIES NPU',
        color: '#6fb6ff',
        body: 'Pinned Gemma 4 E2B runs inside Unified Memory via LiteRT-LM v0.18.1. Zero outbound sockets; Planner, Navigator, Executor, and Critic share an in-memory Blackboard.'
      },
      'Interface taste.md': {
        domain: 'DESIGN SYSTEM · OLED OBSIDIAN',
        color: '#ffc371',
        body: 'Pure #000000 OLED canvas, editorial Instrument Serif & Newsreader headlines, tracked JetBrains Mono whispers, and a living Notch silhouette.'
      },
      'Event Venue Quote.md': {
        domain: 'PLANS & TRAVEL · OVERDUE REPLY',
        color: '#ff5c5c',
        body: 'Carl followed up twice regarding Wednesday walkthrough at 2:00 PM and the $4,800 catering cap. Linked to <span class="wikilink-pill" data-target="README.md">[[README.md]]</span>.'
      }
    };

    const selectNote = (noteName) => {
      const info = NOTES[noteName];
      if (!info) return;
      document.querySelectorAll('.vault-note-btn').forEach(b => {
        b.classList.toggle('active', b.getAttribute('data-note') === noteName);
      });
      if (titleEl) titleEl.textContent = noteName;
      if (domainEl) {
        domainEl.textContent = info.domain;
        domainEl.style.color = info.color;
      }
      if (bodyEl) {
        bodyEl.innerHTML = info.body;
        bodyEl.querySelectorAll('.wikilink-pill').forEach(pill => {
          pill.addEventListener('click', () => selectNote(pill.getAttribute('data-target')));
        });
      }
    };

    document.querySelectorAll('.vault-note-btn').forEach(btn => {
      btn.addEventListener('click', () => selectNote(btn.getAttribute('data-note')));
    });
    document.querySelectorAll('.wikilink-pill').forEach(pill => {
      pill.addEventListener('click', () => selectNote(pill.getAttribute('data-target')));
    });

    if (btn03 && clockBadge) {
      btn03.addEventListener('click', () => {
        clockBadge.textContent = '03:00 AM · Overnight Synthesis';
      });
    }
    if (btn09 && clockBadge) {
      btn09.addEventListener('click', () => {
        clockBadge.textContent = '09:00 AM · Morning Briefing Ready';
      });
    }

    if (!canvas) return;
    const ctx = canvas.getContext('2d');
    const nodes = [
      { name: 'README.md', x: 280, y: 220, r: 9, color: '#fde2a3', isSun: true },
      { name: 'Northstar pilot.md', x: 150, y: 120, r: 6.5, color: '#bb65ff' },
      { name: 'writingstyle.md', x: 420, y: 130, r: 6.5, color: '#4ade80' },
      { name: 'Apple silicon.md', x: 140, y: 310, r: 6, color: '#6fb6ff' },
      { name: 'Interface taste.md', x: 430, y: 315, r: 6, color: '#ffc371' },
      { name: 'Event Venue Quote.md', x: 285, y: 95, r: 6, color: '#ff5c5c' }
    ];

    let tick = 0;
    const renderConstellation = () => {
      tick += 0.015;
      ctx.clearRect(0, 0, canvas.width, canvas.height);

      // Curved quadratic Bézier filaments from central Sun to domain nodes
      const sun = nodes[0];
      for (let i = 1; i < nodes.length; i++) {
        const n = nodes[i];
        const nx = n.x + Math.cos(tick + i) * 4;
        const ny = n.y + Math.sin(tick + i * 1.3) * 4;
        ctx.beginPath();
        ctx.moveTo(sun.x, sun.y);
        ctx.quadraticCurveTo((sun.x + nx) / 2, (sun.y + ny) / 2 - 18, nx, ny);
        ctx.strokeStyle = 'rgba(253, 226, 163, 0.22)';
        ctx.lineWidth = 1.2;
        ctx.stroke();
      }

      // Draw star nodes + labels
      nodes.forEach((n, idx) => {
        const nx = idx === 0 ? n.x : n.x + Math.cos(tick + idx) * 4;
        const ny = idx === 0 ? n.y : n.y + Math.sin(tick + idx * 1.3) * 4;
        n._px = nx;
        n._py = ny;

        ctx.beginPath();
        ctx.arc(nx, ny, n.r, 0, Math.PI * 2);
        ctx.fillStyle = n.color;
        ctx.shadowColor = n.color;
        ctx.shadowBlur = idx === 0 ? 18 : 10;
        ctx.fill();
        ctx.shadowBlur = 0;

        ctx.fillStyle = 'rgba(238, 237, 243, 0.88)';
        ctx.font = '11px "JetBrains Mono", monospace';
        ctx.fillText(n.name, nx + n.r + 6, ny + 4);
      });
    };

    renderConstellation();
    if (!window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
      setInterval(renderConstellation, 50);
    }

    canvas.addEventListener('click', (e) => {
      const rect = canvas.getBoundingClientRect();
      const scaleX = canvas.width / rect.width;
      const scaleY = canvas.height / rect.height;
      const mx = (e.clientX - rect.left) * scaleX;
      const my = (e.clientY - rect.top) * scaleY;
      for (const n of nodes) {
        const dx = mx - (n._px || n.x);
        const dy = my - (n._py || n.y);
        if (Math.hypot(dx, dy) < 28) {
          selectNote(n.name);
          break;
        }
      }
    });
  }

  // ==========================================================================
  // 9. Dog-Eared LetterPaper <dialog> Modal & PlanEditor
  // ==========================================================================
  function initLetterDialogModal() {
    const dialog = document.getElementById('sentient-letter-dialog');
    const kickerEl = document.getElementById('letter-dialog-kicker');
    const titleEl = document.getElementById('letter-dialog-title');
    const summaryEl = document.getElementById('letter-dialog-summary');
    const editorEl = document.getElementById('letter-plan-editor');
    const runBtn = document.getElementById('letter-dialog-run-btn');
    if (!dialog) return;

    const LETTERS = {
      carl: {
        kicker: 'OVERDUE · 3 DAYS · GMAIL',
        title: 'You ghosted Carl.',
        summary: 'Drafted in your voice using local writingstyle.md and Event Venue Quote.md:',
        plan: '1. Open Apple Mail thread "Re: Q4 Offsite Venue Quote" from Carl.\n2. Confirm Wednesday at 2:00 PM for the walkthrough.\n3. Approve the $4,800 catering cap and leave draft for your review.'
      },
      canva: {
        kicker: 'RENEWS TOMORROW · $119 · COMPUTER USE',
        title: 'Canva Pro trial ends tomorrow.',
        summary: '4-step local computer-use plan prepared by Planner & Navigator:',
        plan: '1. Open Safari to Canva Billing & Teams settings.\n2. Navigate to Subscriptions -> Canva Pro Annual ($119.00/yr).\n3. Click "Cancel trial" and select reason "Just trying it out".\n4. Verify cancellation confirmation banner with Critic.'
      },
      amtrak: {
        kicker: 'THIS WEEKEND · COMPUTER USE',
        title: 'Amtrak to New York.',
        summary: 'Prepared from your Weekend Plans note and Calendar:',
        plan: '1. Open Amtrak booking tab for Acela 2154 (Friday 08:15 AM).\n2. Select Coach Quiet Car, Window Seat 7A.\n3. Pre-fill traveler profile and pause at checkout for your confirmation.'
      },
      denver: {
        kicker: 'DUE FRIDAY · 11 RECEIPTS · GMAIL',
        title: 'Denver trip expenses.',
        summary: 'Matched 11 PDF receipts in ~/Downloads against your Denver itinerary:',
        plan: '1. Consolidate 11 PDF receipts into ~/Documents/Expenses/Denver-2026.\n2. Generate Denver_Reimbursement.xlsx totaling $1,428.40.\n3. Verify SHA-256 file integrity and attach to draft email.'
      },
      hawaii: {
        kicker: 'GROUP PLAN · RESEARCHED · WHATSAPP',
        title: 'Hawaii trip dates & flights.',
        summary: 'Cross-referenced group chat dates with your November calendar:',
        plan: '1. Compare 4 friends\' shared dates against your macOS Calendar.\n2. Highlight Nov 14–19 Kauai window (0 conflicts).\n3. Draft group reply with nonstop flight options.'
      },
      welcome: {
        kicker: 'PERSONAL LETTER · SEALED ENVELOPE',
        title: 'Welcome to Relay.',
        summary: 'A personal note from your air-gapped Mac assistant:',
        plan: 'Dear Friend,\n\nEvery model weight, Markdown note, and 4-agent turn runs 100% offline inside your Mac\'s Unified Memory.\n\nClick the notch to hand off a task, or double-tap Right ⌘ to draft in your voice.'
      }
    };

    document.querySelectorAll('.sentient-briefing-card[data-letter-id]').forEach(card => {
      card.addEventListener('click', () => {
        const key = card.getAttribute('data-letter-id');
        const data = LETTERS[key];
        if (!data) return;
        if (kickerEl) kickerEl.textContent = data.kicker;
        if (titleEl) titleEl.textContent = data.title;
        if (summaryEl) summaryEl.textContent = data.summary;
        if (editorEl) editorEl.value = data.plan;
        if (typeof dialog.showModal === 'function') {
          dialog.showModal();
        }
      });
    });

    if (runBtn) {
      runBtn.addEventListener('click', () => {
        dialog.close();
        const multiAgentSection = document.getElementById('multi-agent');
        if (multiAgentSection) {
          multiAgentSection.scrollIntoView({ behavior: 'smooth' });
        }
      });
    }
  }

  // ==========================================================================
  // Document Ready Execution
  // ==========================================================================
  document.addEventListener('DOMContentLoaded', () => {
    initTerminalCopy();
    initHeaderAndNav();
    new AgentDemoController();
    initPrivacyFlowVisualizer();
    initSentientParticleOrb();
    initLivingNotchAndDoubleTap();
    initConstellationVault();
    initLetterDialogModal();
  });
})();
