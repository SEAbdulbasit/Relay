import Foundation

/// Partitions tool definitions by agent role to reduce schema context consumption by >75%.
/// Instead of injecting all 21 tools (~4.5 KB) on every turn, each agent receives only
/// the 0 to 9 tools required for its specialized task, preserving the 24 KB context window for Gemma 4 E2B.
nonisolated enum ToolPartitioning {

    /// Tool names allowed for each specialized agent role.
    static func allowedToolNames(for role: AgentRole) -> Set<String> {
        switch role {
        case .planner:
            // Pure text reasoning. Zero tools to eliminate distraction and avoid malformed tool hallucination.
            return []

        case .navigator:
            // Read-only environment inspection & discovery.
            return [
                "observe_app",
                "list_apps",
                "search_finder",
                "list_files",
                "search_knowledge",
                "capability_probe"
            ]

        case .executor:
            // Concrete mutations, file operations, UI interaction, and app control.
            return [
                "open_app",
                "press_control",
                "set_value",
                "scroll_control",
                "write_file",
                "move_file",
                "create_document",
                "create_spreadsheet",
                "open_url"
            ]

        case .critic:
            // Independent verification and postcondition inspection.
            return [
                "read_file",
                "observe_app",
                "read_browser_page"
            ]
        }
    }

    /// Filters the full suite of tool definitions down to the role's allowed subset.
    static func partitionedTools(for role: AgentRole, from allTools: [ToolDefinition]) -> [ToolDefinition] {
        let allowed = allowedToolNames(for: role)
        guard !allowed.isEmpty else { return [] }
        return allTools.filter { allowed.contains($0.name) }
    }

    /// Calculates the encoded JSON schema byte size for an array of tool definitions.
    static func schemaByteSize(for tools: [ToolDefinition]) -> Int {
        guard !tools.isEmpty else { return 0 }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(tools) else { return 0 }
        return data.count
    }

    /// Computes the percentage byte reduction achieved for a specific role compared to the full tool suite.
    static func schemaByteReduction(for role: AgentRole, against allTools: [ToolDefinition]) -> Double {
        let totalBytes = schemaByteSize(for: allTools)
        guard totalBytes > 0 else { return 0.0 }
        let subsetBytes = schemaByteSize(for: partitionedTools(for: role, from: allTools))
        return Double(totalBytes - subsetBytes) / Double(totalBytes)
    }

    /// Computes the average schema byte size across all 4 agent roles.
    static func averagePartitionedSchemaBytes(from allTools: [ToolDefinition]) -> Int {
        let roles = AgentRole.allCases
        guard !roles.isEmpty else { return 0 }
        let sum = roles.reduce(0) { $0 + schemaByteSize(for: partitionedTools(for: $1, from: allTools)) }
        return sum / roles.count
    }
}
