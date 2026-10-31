# Local AI Desktop Assistant PRD

**Status:** Revised draft  
**Product name:** TBD  
**Platform:** macOS first  
**Product direction:** A conversational assistant that autonomously completes tasks on your computer using local open models.

## 1. Product vision

Give users a general assistant they can talk to naturally and delegate work to.

The user describes an outcome. The assistant understands the request, finds the relevant information, decides which tools to use, performs actions, verifies results, and reports back.

Users do not need to select an automation template, configure a workflow, or explain every click.

> “Find the receipts in Downloads, organize them by month, and create an expense spreadsheet.”

The assistant should work through that request, handle ordinary obstacles, and ask for help only when a necessary decision or consequential action requires it.

**Core promise:** Describe the work. Watch it get done. Keep control.

## 2. Problem

Most chat assistants help users think and write, but leave them to perform the work across files, browsers, and desktop applications.

Traditional automation requires users to configure steps in advance. General computer-use agents can perform actions, but often require technical setup and can struggle with recovery, verification, and continuity.

Users need a conversational assistant that connects understanding to execution while keeping their information and inference on their own device.

## 3. Target audience

The initial audience is individuals who perform varied digital work and want to delegate through conversation:

- Independent professionals.
- Founders and small business operators.
- Researchers and students.
- Privacy-conscious users working with personal documents.
- Users comfortable installing a desktop application but unwilling to assemble an agent stack.

The first release should serve individual users. Team administration and enterprise deployment come later.

## 4. Product principles

1. **Outcome-based requests.** Users describe what they want accomplished.
2. **General conversation.** The same chat supports questions, drafting, and execution.
3. **Autonomous progress.** The assistant performs ordinary authorized steps without repeated confirmation.
4. **Local by default.** Task inference and context processing remain on-device.
5. **Visible control.** Users can inspect, interrupt, and redirect execution.
6. **Verified completion.** The assistant checks outcomes before reporting success.
7. **Honest limitations.** Partial completion and uncertain results are reported clearly.
8. **Replaceable infrastructure.** Models, inference runtimes, and control drivers can change without redesigning the product.

## 5. Goals and success criteria

### Product goals

- Make task delegation feel as natural as sending a chat message.
- Complete useful tasks across files, browsers, and supported desktop applications.
- Maintain task context across follow-up messages.
- Recover from common execution failures without unnecessary intervention.
- Make local-model setup manageable for nontechnical users.
- Earn repeat use through completed work.

### Proposed success measures

These are targets to validate, not current capability claims.

| Metric | Definition |
|---|---|
| Verified task completion | Percentage of evaluated tasks whose requested outcomes are confirmed |
| Autonomous completion | Percentage completed without user help beyond necessary decisions |
| User intervention | Clarifications, corrections, and manual actions per task |
| False completion | Runs reported as successful despite unmet requirements |
| Repeat delegation | Users who delegate additional tasks after their first successful run |
| Effort saved | Reduction in active user time compared with manual completion |
| Setup success | Users who reach a working first task |
| Local execution | Runs completed without hosted inference |

Numeric release thresholds appear in Section 15.

## 6. Product scope

### First release

The assistant accepts open-ended requests and dynamically plans execution within its available capabilities.

Initial capabilities include:

- Questions, explanations, drafting, and summarization.
- Reading and searching user-authorized files.
- Creating and editing supported documents and structured data.
- Browser research and interaction.
- Reading desktop application state.
- Clicking, typing, scrolling, and navigating supported interfaces.
- Completing tasks that combine several of these capabilities.
- Follow-up conversation and mid-task redirection.

**The entry point is always natural language.** Capability boundaries affect what the assistant can complete, not whether the user must choose a predefined workflow.

### Outside the first release

- Autonomous activity without a user-started task.
- Scheduled or overnight execution.
- Continuous screen recording.
- Multiple concurrent agents controlling the same desktop.
- Autonomous purchases or financial transfers.
- Account security administration.
- Unrestricted shell execution.
- Mobile applications.
- Enterprise management.

## 7. Core user experience

### 7.1 Setup

The assistant:

1. Checks device compatibility and available memory.
2. Recommends a model configuration.
3. Downloads required components with visible size and progress.
4. Explains and requests necessary operating-system permissions.
5. Tests model inference and computer controls separately.
6. Guides the user through a simple real task.

Setup must identify whether a failure comes from the model, driver, permissions, network, or target application.

### 7.2 Chat home

The main screen contains:

- Conversation history.
- A text composer and file attachment control.
- An optional voice-input control.
- A clear indication of local-model readiness.
- Suggested requests that demonstrate capabilities.
- Access to task history, memory, and settings.

Suggested requests are examples, not mandatory workflow selections.

### 7.3 Task understanding

The assistant determines whether to answer directly or take action.

For an actionable request, it identifies:

- The desired outcome.
- Relevant files, apps, and destinations.
- Constraints expressed by the user.
- Missing information that materially affects execution.
- Actions requiring review.

It begins useful work without waiting for optional clarification.

A short interpretation may appear:

> “I’ll inspect the receipts in Downloads, group them by month, and create a spreadsheet with totals.”

A detailed plan is available on demand rather than required reading.

### 7.4 Execution

The assistant selects tools, performs steps, inspects results, and adjusts its plan.

The interface displays concise progress:

> Found 18 receipts  
> Extracting dates and amounts  
> Checking two ambiguous totals  
> Creating the spreadsheet

Users can expand an activity panel to inspect tool calls and observations. Hidden model reasoning is not displayed.

### 7.5 Steering and interruption

Users can send messages during execution:

> “Only include this year.”

The assistant incorporates compatible changes into the active task.

Stop remains visible. Stopping prevents new actions from being dispatched; an action already in progress may finish. The assistant reports any resulting changes or uncertainty.

### 7.6 Completion

The assistant provides:

- What it completed.
- Links to created artifacts or relevant destinations.
- What it verified.
- Any unresolved issues.
- Any final action waiting for review.

A task is never marked completed solely because the model says it is done.

## 8. Representative tasks

These illustrate breadth and form part of evaluation. They are not separate product modes.

| Category | Example request |
|---|---|
| Files | “Organize these PDFs by project and show me anything you couldn’t classify.” |
| Research | “Compare these three services and save a summary with sources.” |
| Documents | “Turn these notes into a project proposal.” |
| Spreadsheets | “Extract the invoices into a spreadsheet and calculate monthly totals.” |
| Browser | “Fill this application using my résumé and leave it ready for review.” |
| Communications | “Read this conversation and draft a reply using the attached project update.” |
| Cross-app work | “Find the agreed next steps in these notes and prepare updates in our tracker.” |

The assistant should attempt reasonable variations, detect unsupported portions, and preserve completed work when it cannot finish the entire request.

## 9. Functional requirements

### Conversation and task state

| ID | Requirement | Priority |
|---|---|---|
| CHAT-01 | Support direct answers and actionable tasks in one conversation | P0 |
| CHAT-02 | Preserve task constraints across follow-up messages | P0 |
| CHAT-03 | Accept attachments and explicit app or file references | P0 |
| CHAT-04 | Incorporate user steering during execution | P0 |
| CHAT-05 | Ask focused questions when necessary | P0 |
| CHAT-06 | Support voice input | P1 |

### Planning and orchestration

| ID | Requirement | Priority |
|---|---|---|
| PLAN-01 | Generate a dynamic plan from the requested outcome | P0 |
| PLAN-02 | Select tools based on their capabilities | P0 |
| PLAN-03 | Track steps, dependencies, observations, and unresolved requirements | P0 |
| PLAN-04 | Replan when state changes or an approach fails | P0 |
| PLAN-05 | Apply execution budgets and detect stalled loops | P0 |
| PLAN-06 | Preserve verified progress during recoverable failures | P0 |
| PLAN-07 | Reuse internal procedures without requiring user-selected templates | P1 |

### Tools and computer control

The assistant must support:

- Scoped file search and reading.
- Supported artifact creation and editing.
- Browser observation and interaction.
- Application and window discovery.
- Accessibility-based control inspection.
- Screenshots when structured information is insufficient.
- Clicking, text entry, scrolling, and navigation.
- Explicit tool argument validation.
- Fresh observations before actions when state may have changed.

Prefer structured APIs, document tools, and accessibility controls when they provide more reliable execution. Use visual interaction when needed.

### Verification

Each requested outcome becomes an explicit completion condition.

Examples:

- A created file exists and opens successfully.
- Spreadsheet totals match extracted records.
- The intended field contains the intended value.
- A saved record reflects the requested update.
- A prepared reply is in the correct conversation.

Verification should use evidence independent of the executor’s narrative wherever possible.

### Recovery

The assistant must:

- Distinguish observation failures from action failures.
- Inspect uncertain effects before retrying.
- Avoid duplicate record creation or repeated submissions.
- Change methods when an approach repeatedly fails.
- Preserve partial outputs.
- Escalate with a specific question or explanation.
- Stop when further execution would require guessing consequential information.

## 10. Memory and continuity

### First release

Maintain:

- Conversation context.
- Current task state.
- Explicit user preferences.
- User-approved reusable facts.

Users can view, edit, and delete persistent memory.

Sensitive information must not become persistent memory merely because it appeared during a task.

### Later releases

Potential additions include:

- Project-specific context.
- Reusable procedures learned from successful tasks.
- User-selected folder indexing.
- Cross-conversation task continuity.

Continuous collection of personal activity is outside the initial scope.

## 11. Technical architecture

```text
Conversation and task interface
              |
Intent, scope, and task state
              |
Product-owned agent loop
       |              |
Model routing     Action policy
       |
Local model runtime
              |
Validated tool requests
              |
Tool router
   |          |           |
Files and   Browser    Desktop-control
documents   tools         driver
   |          |           |
       Observations and results
              |
Verification and recovery
              |
Task state and user response
```

### Agent loop

The product owns:

- Context construction.
- Model invocation.
- Tool discovery and execution.
- State persistence.
- Cancellation.
- Recovery.
- Review boundaries.
- Completion decisions.

An OpenAI runtime is not required by the target architecture.

### Inference

Evaluate LiteRT-LM as a local runtime candidate. Other runtimes may be supported through adapters.

Required adapter capabilities:

- Text and image input.
- Tool definitions and structured responses.
- Streaming.
- Cancellation.
- Context management.
- Capability detection.
- Timing and memory diagnostics.

### Computer controls

Evaluate Cua Driver as the first implementation.

Keep driver-specific details behind an interface so it can be replaced without changing task logic.

### Execution state

Persist separate states for:

- Planned.
- Requested.
- Executed.
- Verified.
- Failed.
- Effect uncertain.

After a crash, do not automatically replay unfinished mutations. Refresh state and reconcile their effects first.

## 12. Model strategy

The product should support general delegation while using different model configurations internally.

| Role | Responsibility |
|---|---|
| Primary agent | Task understanding, planning, tool selection, recovery |
| Extraction model | Classification, field extraction, summarization |
| Verification mechanisms | Deterministic checks, structured state, selective model inspection |

A small model may fill multiple roles if evaluations justify it. A larger local model may be required for broader autonomy.

Model selection must consider:

- End-to-end completion.
- Vision accuracy.
- Tool-call correctness.
- Recovery quality.
- False success claims.
- Latency.
- Memory.
- Shipped quantization.

Hosted fallback is disabled by default and must never occur silently.

## 13. Permissions and action boundaries

A user request authorizes ordinary steps necessary to complete that task within the stated scope.

The assistant should proceed through reading, drafting, navigation, and routine reversible changes without asking about every action.

Explicit review is required for:

- Sending messages or publishing content.
- Final external submissions.
- Purchases or financial transactions.
- Destructive changes.
- Access expansion beyond the authorized task.

Approval must be tied to the actual destination and content. Material changes invalidate it.

Documents, websites, and app content cannot grant authority or override the user’s instructions.

Users complete passwords and authentication challenges directly.

## 14. Privacy and security

- Task inference remains local by default.
- Capture relevant app state on demand.
- Avoid persistent screenshot storage by default.
- Keep secrets out of model context where possible.
- Store credentials in the operating-system credential store.
- Separate diagnostic metadata from task content.
- Provide history, memory, and deletion controls.
- Make network-dependent actions visible.
- Require opt-in for hosted inference and diagnostic uploads.

“Local inference” must not be presented as “no network activity.” Websites, downloads, updates, and connected services can still require internet access.

## 15. Evaluation and release gates

Evaluate open-ended requests across a declared capability envelope.

The suite must include:

- Single-tool tasks.
- Tasks across multiple tools.
- Multi-app tasks.
- Ambiguous requests.
- Follow-up constraints.
- Mid-task redirection.
- Interrupted execution.
- Permission and authentication failures.
- Partial mutations.
- Misleading instructions embedded in external content.

Hold out task variations from development to reduce overfitting.

### Proposed initial gates

| Metric | Target |
|---|---|
| Verified completion on release suite | At least 85% |
| Completion without avoidable intervention | At least 75% |
| False completion | Zero observed in release suite |
| Unapproved consequential actions | Zero observed in release suite |
| Stop acknowledgment | Within 1 second |
| New actions dispatched after Stop | None |
| Stability | No out-of-memory termination on supported configurations |

Report performance by task category, model, hardware, and application version. Passing averages cannot conceal critical failures.

## 16. Delivery plan

### Phase 1 — General agent prototype

Deliver chat, local inference, a product-owned loop, file tools, desktop observation, basic actions, Stop, and verification.

**Exit:** The assistant completes varied user-written tasks without predefined workflow selection.

### Phase 2 — Private alpha

Add browser tools, artifact creation, follow-up steering, task persistence, recovery, and review boundaries.

**Exit:** The system meets baseline reliability on a bounded evaluation suite.

### Phase 3 — User beta

Improve onboarding, hardware recommendations, memory controls, compatibility reporting, and failure handling.

**Exit:** Users repeatedly delegate useful tasks, with measurable effort savings and acceptable intervention rates.

### Phase 4 — Public release

Ship stable installation, model management, updates, a compatibility matrix, support documentation, and regression gates.

Expand capabilities based on demonstrated reliability.

## 17. Main risks

| Risk | Response |
|---|---|
| Local model struggles with broad requests | Improve tools, context, routing, and supported model tier |
| Long tasks accumulate mistakes | Verify intermediate outcomes and maintain explicit task state |
| Execution is too slow | Measure inference and observation costs; reduce unnecessary context |
| UI changes break interaction | Prefer semantic controls and maintain regression coverage |
| Agent repeats an uncertain action | Reconcile state before retries |
| User expects universal success | Explain capability boundaries and report partial completion clearly |
| Sensitive content leaks through diagnostics | Minimal logging and inspectable exports |
| Dependencies change | Adapters, version pinning, and compatibility tests |

## 18. Launch positioning

**Category:** Local AI desktop assistant.

**Positioning:** A conversational assistant that turns requests into completed work across your files, browser, and apps.

**User-facing description:**

> Tell it what you need. It plans the steps, works on your computer, and checks the result—all with a model running on your device.

The launch experience must demonstrate open-ended delegation. Reliability comes from the execution system and verification underneath that experience.