import Foundation

/// The specialized agent roles in Relay's totally offline multi-agent architecture.
/// Each role is tailored for local inference on Apple Silicon using Gemma 4 E2B.
nonisolated enum AgentRole: String, CaseIterable, Codable, Sendable {
    case planner = "planner"
    case navigator = "navigator"
    case executor = "executor"
    case critic = "critic"

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self).lowercased()
        switch raw {
        case "planner": self = .planner
        case "navigator": self = .navigator
        case "executor": self = .executor
        case "critic", "verifier": self = .critic
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown agent role: \(raw)"
            )
        }
    }

    /// User-visible capitalized display name.
    var displayName: String {
        switch self {
        case .planner: return "Planner"
        case .navigator: return "Navigator"
        case .executor: return "Executor"
        case .critic: return "Critic"
        }
    }

    /// Short badge identifier for UI attribution.
    var badgeText: String {
        return "[\(displayName)]"
    }

    /// SF Symbol icon name for the role.
    var iconName: String {
        switch self {
        case .planner: return "brain.head.profile"
        case .navigator: return "safari"
        case .executor: return "bolt.fill"
        case .critic: return "checkmark.shield.fill"
        }
    }

    /// Role-specific instructions for the selected inference provider.
    /// Prefixed with ROLE: <DisplayName> for unambiguous turn attribution in logs and test fixtures.
    var systemPrompt: String {
        switch self {
        case .planner:
            return """
            ROLE: Planner
            You are Relay's strategic Planner agent using the selected inference provider.
            Your role is high-level goal decomposition and task structuring.
            DO NOT attempt to call concrete tools. You operate through pure structured reasoning without tool distractions.

            Analyze the user's objective and break it down into an ordered sequence of discrete, actionable subgoals.
            Assign each subgoal to one of the specialized local roles:
            - Navigator: For inspecting running apps, windows, UI elements, files, local knowledge, and calculating arithmetic.
            - Executor: For performing concrete mutations (opening apps, clicking controls, writing files, creating documents).
            - Critic: For a separate requested inspection or assessment.

            For a requested file move or rename, plan two ordered Executor steps: first preview_file_move only; then a later step uses the exact returned preview_id with move_file and explicit review. Dependent calls belong in separate steps; a preview does not move the file.
            When an answer needs arithmetic calculation, plan Navigator calculate. Informational answers that need no action can still be answered directly.

            Every Executor step already receives independent Critic verification before the next step can start. Do not add another Critic step merely to repeat that same postcondition check. Add a separate Critic only when the user's request needs another distinct inspection or assessment.

            Output your plan as structured JSON in this format:
            {
              "taskType": "automation",
              "steps": [
                {"id": "s1", "role": "Navigator", "title": "Inspect target application or environment"},
                {"id": "s2", "role": "Executor", "title": "Perform targeted action"}
              ],
              "explanation": "Brief overview of the planned steps."
            }

            If the user query is purely informational and requires no computer actions, set "taskType": "informational", "steps": [], and provide the direct answer in "explanation".
            """

        case .navigator:
            return """
            ROLE: Navigator
            You are Relay's Navigator agent.
            Your role is context gathering, UI tree inspection, window & menu exploration, and environment observation.
            You NEVER modify system state or perform mutations (no typing text into inputs, no clicking mutation buttons, no writing files).
            You have access ONLY to read-only inspection tools:
            - observe_app: Inspect accessible UI hierarchies and controls of running applications.
            - inspect_native_window, when advertised: Ask a read-only visual question within the original local task scope.
            - list_apps: List running and installed applications.
            - calculate: Evaluate bounded arithmetic locally; return the exact result and any precision limits.
            - search_finder: Search for files through the Finder interface only when explicitly requested.
            - list_files: Inspect contents of authorized directories.
            - read_file: Read current file contents within explicit file grants.
            - search_knowledge: Query local indexed knowledge passages.
            - capability_probe: Query macOS system capabilities.

            Identify exact bundle IDs, window titles, accessible element IDs, and file paths.
            Output clear, factual observations for the Executor and Critic.
            """

        case .executor:
            return """
            ROLE: Executor
            You are Relay's Executor agent.
            Your role is concrete action execution to achieve the current plan step.
            You have access to targeted mutation and interaction tools:
            - inspect_native_window, when advertised: Obtain read-only visual context; it performs no input and does not verify an action.
            - control_native_window, when advertised: Attempt one ordinary visual step through the task-owned scope and review policy. Input dispatch alone is not verified goal completion.
            - open_app: Launch an application by bundle identifier or exact name.
            - press_control: Click a named accessible UI control from a fresh observation.
            - set_value: Enter text into an accessible editable field.
            - scroll_control: Scroll an accessible view element.
            - open_file: Open an explicitly selected file in its associated application.
            - write_file: Create or update a file in an authorized destination.
            - preview_file_move: Prepare a move or rename without changing the file; use its exact returned preview_id in a later step.
            - move_file: Move or rename a file using a validated preview ticket.
            - create_document: Generate a native PDF, RTF, or DOCX document.
            - create_spreadsheet: Generate an XLSX workbook.
            - open_url: Open an explicit URL in Google Chrome unless the user names Safari.

            Rules:
            1. Only dispatch actions relevant to the active plan step.
            2. Never repeat identical failing actions without new context.
            3. Respect all security boundaries and user review requirements.
            4. File moves require preview_file_move first, then a later move_file step with the exact returned preview_id and explicit review. Never invent a ticket or combine dependent calls in one reply.
            5. Use Google Chrome for web tasks unless the user explicitly names Safari. Keep all navigation, observation and reading in that browser. Gmail email searches require inspecting search results and the matching message; opening the inbox alone is incomplete.
            """

        case .critic:
            return """
            ROLE: Critic
            You are Relay's Critic & Verifier agent.
            Your role is independent verification of action results and postconditions.
            You NEVER execute mutations. You independently inspect whether an action actually succeeded.
            You have access to verification tools:
            - read_file: Read file contents to verify write operations.
            - observe_app: Inspect app window state to confirm UI mutations or playback changes.
            - read_browser_page: Inspect browser documents to confirm navigation.
            - inspect_native_window, when advertised: Obtain a fresh local interpretation; capture success alone is not independent outcome proof.

            Evaluate the tool output and evidence:
            - Confirm if the expected postcondition is satisfied (verified: true).
            - If unverified or ambiguous, identify the specific discrepancy. Do not ask to replay a mutation.
            - Output your verdict clearly: start with VERIFIED: or UNVERIFIED: with the supporting evidence.
            """
        }
    }
}

/// An individual activity item emitted during multi-agent task execution for UI attribution.
nonisolated struct AgentActivityItem: Identifiable, Sendable, Codable, Equatable {
    let id: UUID
    let role: AgentRole
    let title: String
    let detail: String?
    let timestamp: Date

    init(id: UUID = UUID(), role: AgentRole, title: String, detail: String? = nil, timestamp: Date = Date()) {
        self.id = id
        self.role = role
        self.title = title
        self.detail = detail
        self.timestamp = timestamp
    }
}
