import Foundation

/// Presentation only: preserves the distinction between a response and a verified action.
nonisolated struct ActivityPresentation {
    let title: String
    let status: String
    let icon: String
    let verified: Bool
    let failed: Bool

    init(name: String, status rawStatus: String) {
        let labels = [
            "calculate": "Calculate locally", "search_files": "Find files", "search_finder": "Search Finder",
            "observe_app": "Inspect app", "set_value": "Enter text",
            "press_control": "Use app control", "scroll_control": "Scroll app",
            "open_app": "Open app", "open_file": "Open file",
            "list_apps": "Find installed apps", "read_file": "Read file",
            "write_file": "Save file", "list_files": "Browse folder",
            "read_calendar": "Read calendar", "search_knowledge": "Search knowledge",
            "read_browser_page": "Read webpage", "browser_navigate": "Navigate browser",
            "open_url": "Open website", "search_web": "Search the web",
            "create_document": "Create document", "create_spreadsheet": "Create spreadsheet",
            "preview_file_move": "Prepare file move", "move_file": "Move file",
            "Response finished": "Response ready", "Planning": "Plan next step",
            "Context window": "Prepare conversation context", "Checking next step": "Check next step"
        ]
        title = labels[name] ?? name.replacingOccurrences(of: "_", with: " ")
        let value = rawStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        verified = value == "verified"
        failed = value.hasPrefix("failed")
        if verified { status = "Result checked"; icon = "checkmark.circle.fill" }
        else if failed { status = "Couldn’t complete"; icon = "exclamationmark.circle" }
        else if value == "needs input" { status = "Needs your input"; icon = "hand.raised" }
        else if value == "finished" { status = "Response finished"; icon = "bubble.left" }
        else if value == "requested" { status = "Requested"; icon = "arrow.turn.down.right" }
        else if value == "planning" { status = "Planning"; icon = "sparkle" }
        else if value == "observed" { status = "Context checked"; icon = "eye" }
        else if value == "stopped" || value == "cancelled" { status = "Stopped"; icon = "stop.circle" }
        else { status = rawStatus; icon = "circle" }
    }
}
