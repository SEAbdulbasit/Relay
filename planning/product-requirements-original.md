# Local Desktop Assistant PRD

**Status:** Draft  
**Platform:** macOS first  
**Product name:** Working title  
**Core principle:** Local models interpret the task; software manages execution and verifies results.

## 1. Product summary

Build a desktop assistant that completes a small set of useful workflows using locally hosted open models and open-source computer-control software.

The assistant reads user-selected content, prepares structured information, and performs actions across supported desktop apps and websites. Users can inspect its progress, stop execution, correct mistakes, and review completed work.

The initial product prioritizes repeatable workflows over unrestricted computer control. Broader capabilities become available only after they meet measured reliability targets.

**Initial promise:** “Give it a routine task in a supported workflow, and get completed work or a clear explanation of what needs your input.”

## 2. Problem

Routine administrative work frequently combines interpretation and repetitive interaction:

- Reading a document and entering its details into a form.
- Copying information between apps.
- Updating records from notes.
- Preparing a reply using relevant documents.
- Checking that information was transferred correctly.

Traditional automation struggles with changing layouts and ambiguous inputs. General computer-use agents can adapt, but long workflows create opportunities for mistakes, stalls, and incorrect success claims.

Users need an assistant that combines model judgment with explicit workflow state, reliable tools, and outcome verification.

## 3. Target users

**Primary audience:** Individuals and small teams doing recurring administrative work on a Mac, particularly users who value local processing.

**Initial design partner profile:**

- Repeats the same workflow several times per week.
- Uses a reasonably consistent set of apps.
- Can explain what successful completion looks like.
- Will review prepared work during early releases.
- Has hardware capable of running a supported local model.

**Excluded initially:** Organizations requiring centrally managed deployment, complex enterprise permissions, or audited regulatory workflows.

## 4. Product goals

1. Complete supported workflows with low user intervention.
2. Keep task inference and task data local by default.
3. Make every run understandable and interruptible.
4. Verify outcomes independently of the model’s success claim.
5. Support replaceable models and computer-control drivers.
6. Establish an evaluation process that determines what the product can honestly promise.

### Non-goals for the first release

- Universal control of arbitrary applications.
- Continuous screen recording.
- Autonomous inbox monitoring or overnight work.
- A comprehensive personal knowledge graph.
- Payments, purchases, account administration, or unattended message sending.
- Training a foundation model.
- Windows and Linux feature parity.
- A marketplace of user-created workflows.

## 5. Product assumptions

These are proposed starting decisions, subject to prototype validation.

| Area | Starting decision |
|---|---|
| Platform | Apple silicon macOS |
| Inference | Local by default |
| Model strategy | Small model for extraction; optional larger model for planning and recovery |
| Control layer | Evaluate Cua Driver first |
| Agent loop | Product-owned orchestration |
| First integrations | One browser and one target web application |
| Execution | User starts every run |
| Final external actions | Explicit review for sending, submitting, or publishing |
| Knowledge | User-selected files and task context |
| Offline support | Local tasks work offline after setup; websites require connectivity |

The exact minimum memory and supported operating-system version must be established through testing with the selected model and driver.

## 6. Initial workflows

### Workflow A — Enter document details into a form

**Example:** Extract receipt information and prepare an expense entry.

**Input:** A user-selected receipt and an open supported expense form.

**Expected behavior:**

1. Extract merchant, date, amount, currency, and description.
2. Show missing or ambiguous fields.
3. Map extracted values to the form.
4. Enter supported fields.
5. Attach the original document when supported.
6. Read the form back and compare it with the intended values.
7. Leave the entry ready for review.

**Success:** Required fields contain verified values and the intended attachment is present.

**Boundary:** No final submission in the first release.

### Workflow B — Update a record from notes

**Example:** Use meeting notes to prepare a CRM update.

**Input:** Selected notes and a user-selected record.

**Expected behavior:**

1. Extract proposed changes.
2. Show the intended record and field changes.
3. Resolve missing or conflicting information with the user.
4. Apply authorized changes.
5. Verify saved values.

**Success:** The correct record contains the approved values.

**Boundary:** No record deletion, bulk updates, or inferred changes to financial fields.

### Workflow C — Prepare a contextual reply

**Example:** Draft a customer update using selected notes and documents.

**Input:** A selected conversation and explicitly selected context.

**Expected behavior:**

1. Identify the recipient and latest request.
2. Extract relevant facts from supplied context.
3. Draft a response.
4. Flag facts that need confirmation.
5. Present the draft in the assistant.
6. Insert it into the supported application when requested.
7. Verify the inserted text.

**Success:** A relevant draft is ready for review in the intended location.

**Boundary:** Sending requires a separate explicit action.

**Delivery order:** Workflow A first. Workflows B and C follow after the shared execution and verification foundations pass acceptance testing.

## 7. User experience

### Setup

The assistant guides the user through:

1. Hardware and available-memory checks.
2. Model selection and download.
3. Required computer-control permissions.
4. A synthetic read-and-action test.
5. A short demonstration workflow.

Setup must distinguish:

- Model installation.
- Model readiness.
- Driver readiness.
- Operating-system permissions.
- Supported application readiness.

A working model does not imply working computer control.

### Start a task

The user opens the assistant, chooses a workflow, supplies context, and selects the target app or record.

Before execution, the assistant displays:

- The task it understood.
- The target destination.
- The expected changes.
- Any required missing information.
- The point at which review will be required.

Read-only preparation can begin immediately. Mutations follow the user’s chosen workflow and approved scope.

### During execution

The interface shows concrete progress:

> Extracted receipt details  
> Entering the expense form  
> Checking the amount and currency

It also provides:

- A persistent Stop control.
- A preview of the current target.
- The latest verified step.
- A clear waiting state when user input is needed.
- A visible indication when the agent needs foreground interaction.

### Completion

Every run ends in one of four outcomes:

| Outcome | Meaning |
|---|---|
| Completed | Required outcomes were verified |
| Ready for review | Preparation is complete; a final action remains |
| Needs input | Progress depends on a specific user decision |
| Stopped or failed | Execution ended; applied and uncertain changes are disclosed |

The result must state what changed, what was verified, and what remains unfinished.

## 8. Functional requirements

### Task context

| ID | Requirement | Priority |
|---|---|---|
| CTX-01 | Accept a task, selected files, and an explicit target | P0 |
| CTX-02 | Capture relevant target-app state on demand | P0 |
| CTX-03 | Treat app, website, and document content as untrusted task data | P0 |
| CTX-04 | Keep run context separate from unrelated runs | P0 |
| CTX-05 | Allow users to inspect and remove saved context | P1 |

### Model runtime

| ID | Requirement | Priority |
|---|---|---|
| MOD-01 | Support a local model through a replaceable adapter | P0 |
| MOD-02 | Validate vision and tool-call behavior before enabling execution | P0 |
| MOD-03 | Validate generated tool arguments against schemas | P0 |
| MOD-04 | Bound context, output length, memory use, and inference time | P0 |
| MOD-05 | Record model, quantization, runtime, and prompt versions per run | P0 |
| MOD-06 | Support separate extraction and planning models | P1 |
| MOD-07 | Never silently fall back to hosted inference | P0 |

### Computer interaction

| ID | Requirement | Priority |
|---|---|---|
| ACT-01 | Inspect applications, windows, and available controls | P0 |
| ACT-02 | Prefer accessibility identifiers and semantic controls | P0 |
| ACT-03 | Use screenshots when structured state is insufficient | P0 |
| ACT-04 | Support text entry, clicking, scrolling, and target selection | P0 |
| ACT-05 | Require fresh relevant state before mutation | P0 |
| ACT-06 | Verify the effects of important actions | P0 |
| ACT-07 | Detect stale targets and require observation before continuing | P0 |
| ACT-08 | Support background interaction where the driver and app allow it | P1 |

### Workflow orchestration

Each workflow must define:

- Required inputs.
- Allowed destinations.
- Allowed actions.
- Steps and dependencies.
- Preconditions and postconditions.
- Review boundaries.
- Recovery limits.
- Completion criteria.

The executor must persist verified progress and distinguish between an action being requested, executed, and verified.

**A model saying “done” must never be sufficient to mark a workflow complete.**

### Recovery

- Retry failed observations within bounded limits.
- Inspect current state before retrying an action whose effects are uncertain.
- Never blindly repeat sends, submissions, or record creation.
- Detect repeated identical actions and lack of progress.
- Ask a focused question when ambiguity prevents correct execution.
- Report partial changes when the task cannot finish.
- Do not promise automatic rollback unless a workflow implements and verifies it.

### Stop and resume

Stop must immediately prevent new actions from being dispatched.

An action already in progress may complete. The assistant must then report its known or uncertain effects.

Resuming requires refreshing app state and checking workflow preconditions. Historical coordinates or element references cannot be reused without validation.

## 9. Architecture

```text
Task UI and review interface
            |
Task scope and workflow definition
            |
Product-owned executor
     |              |
Model adapter   Policy checks
     |
Local inference runtime
            |
Validated action request
            |
Computer-control adapter
            |
Supported apps and websites
            |
Observation and verification
            |
Workflow state and result
```

### Model adapter

Expose a consistent interface for:

- Text and image input.
- Tool definitions.
- Structured output.
- Cancellation.
- Usage and timing information.
- Capability checks.

LiteRT-LM is a candidate inference runtime. The product must verify that the chosen integration preserves required image input, prompting, and tool-call behavior. It must not assume an API compatibility layer already exists.

### Computer-control adapter

Keep the driver replaceable behind operations such as:

```text
observe_target()
find_control()
set_text()
click_control()
scroll_target()
capture_target()
```

Driver-specific identifiers and behavior remain inside the adapter.

### Verification layer

Use the strongest available evidence:

1. Structured application state or saved-record values.
2. Accessibility values.
3. Deterministic text comparisons.
4. Screenshot interpretation when stronger evidence is unavailable.

A screenshot-based model judgment must be identified as weaker evidence than a direct saved-value check.

## 10. Model strategy

### Small model responsibilities

- Document classification.
- Field extraction.
- Summarization.
- Simple intent routing.
- Short, constrained decisions.

### Larger model responsibilities

- Planning within the workflow.
- Resolving ambiguous mappings.
- Interpreting complex screens.
- Choosing recovery actions.

A larger model is optional only if the supported workflows meet release criteria without it.

### Selection criteria

Evaluate candidates on:

- End-to-end workflow completion.
- Correct tool selection and valid arguments.
- Text and numeric extraction accuracy.
- Recovery behavior.
- False success claims.
- Latency and memory use.
- Performance under the shipped quantization.

General reasoning benchmarks can inform candidate selection. They cannot substitute for product-task evaluations.

## 11. Privacy and action boundaries

### Local processing

- Task prompts, screenshots, selected documents, and inference remain on-device by default.
- Model downloads and software updates must be distinguishable from task-data transmission.
- Any hosted inference option requires explicit configuration and clear disclosure.

### Data access

- Access user-selected files and task-relevant application state.
- Avoid continuous capture.
- Do not request broad disk access unless a supported feature requires it.
- Exclude password fields and authentication secrets from model context where technically possible.
- Ask the user to complete authentication directly.

### Data retention

Proposed defaults:

| Data | Default behavior |
|---|---|
| Raw screenshots | Transient; no persistent retention |
| Selected source files | Referenced in place; copied only when required |
| Run metadata | Stored locally for history |
| Sensitive field values | Excluded from diagnostic logs |
| Debug traces | Explicit opt-in with preview and deletion controls |

### External effects

Sending, publishing, purchasing, deleting, and final submission require explicit workflow support and a review boundary.

The action must remain bound to the reviewed destination and content. A changed recipient, record, or payload invalidates the pending approval.

## 12. Reliability and performance targets

These are proposed release gates, not claims about current capabilities.

| Metric | Initial target |
|---|---|
| Verified completion on supported benchmark tasks | At least 90% |
| Clean completion without intervention | At least 80% |
| Critical field correctness in completed runs | At least 99% |
| Incorrect success claims | Zero observed in release suite |
| Unapproved external-effect actions | Zero observed in release suite |
| Stop acknowledgment | Within 1 second |
| New action dispatch after Stop | None |
| Task acceptance feedback | Within 1 second |
| Hardware stability | No out-of-memory termination in supported test matrix |

Task-duration targets should be set after baseline measurements. The product must measure whether a workflow saves user effort even when local inference increases elapsed time.

## 13. Evaluation plan

Create a versioned test suite before expanding workflow coverage.

### Initial suite

At least 100 task instances across the initial workflows, including:

- Normal completion.
- Missing fields.
- Ambiguous dates and currencies.
- Multiple similar records.
- Duplicate documents.
- Loading states.
- Layout changes.
- Permission loss.
- Authentication expiry.
- App closure.
- User interruption.
- Partial action completion.
- Malicious instructions embedded in documents or websites.

Use synthetic accounts and documents for automated testing.

### Scoring

Record:

- Verified completion.
- Field correctness.
- Intervention count.
- Wrong-target actions.
- Repeated actions.
- Recovery success.
- False completion.
- Time to completion.
- Memory and inference timing.

Completion verification must be independent of the executing model’s final answer.

### Reporting

Report results separately by workflow, model configuration, hardware tier, and application version.

A high aggregate score must not hide a failing workflow or critical error category. Zero observed failures are a release criterion for the tested suite, not proof that failure is impossible.

## 14. Release plan

### Phase 1 — Technical feasibility

Deliver:

- One local model integration.
- One computer-control adapter.
- Product-owned observe–decide–act–verify loop.
- Synthetic form workflow.
- Stop and partial-result reporting.
- Initial evaluation harness.

**Exit:** A repeatable end-to-end workflow works locally, with observable failures and verified outcomes.

### Phase 2 — Single-workflow alpha

Deliver:

- Receipt-to-form workflow.
- One supported browser and expense application.
- Review interface.
- Local task history.
- Recovery for common failures.

**Exit:** Workflow A meets the release gates on its supported test set.

### Phase 3 — Design partner beta

Deliver:

- Limited real-user deployment.
- Opt-in diagnostic export.
- Model and hardware comparison.
- Workflows B and C as separate qualified capabilities.

**Exit:** Users repeatedly complete useful work, intervention decreases, and each enabled workflow meets its own acceptance criteria.

### Phase 4 — Broader release

Deliver:

- Published compatibility matrix.
- Stable setup and updates.
- Clear hardware requirements.
- Support and recovery documentation.
- Regression gating for model, driver, prompt, and workflow changes.

## 15. Main risks

| Risk | Mitigation |
|---|---|
| Small model misinterprets a task | Constrain scope; compare larger models on identical tasks |
| Model enters incorrect values | Structured extraction and independent readback |
| UI changes break execution | Semantic controls, target validation, regression tests |
| Repeated actions create duplicates | Persist action state; inspect uncertain outcomes |
| Local inference feels slow | Short contexts, bounded image input, model reuse, measured routing |
| Background interaction is inconsistent | Publish per-app support; request foreground access when needed |
| Driver API or license changes | Adapter boundary and pinned, reviewed dependencies |
| User expects universal autonomy | Explicit workflow selection and visible compatibility |
| Sensitive context enters logs | Minimal logging and inspectable diagnostic export |

## 16. Decisions required before implementation

1. Which single workflow offers the strongest recurring value?
2. Which target application will be supported first?
3. What hardware tier should the first release serve?
4. Which model and quantization pass the actual workflow tests?
5. Does Cua Driver meet the required control and observation behavior?
6. Which actions end at a draft, and which may save changes?
7. What local history should be retained by default?

**Recommended starting scope:** Receipt-to-form preparation on macOS, one browser, one expense application, local inference, and a final review step. This provides a concrete environment for proving extraction, interaction, verification, and recovery before expanding the product.