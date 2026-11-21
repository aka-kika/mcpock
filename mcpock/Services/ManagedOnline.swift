import Foundation

/// An agent whose MCP servers are set up on the vendor's website, not in a
/// file on this Mac (premium look, 22 Nov, Kika's pick: its own section, one
/// row each). mcpock cannot read or check those servers: the row is a way to
/// the vendor's page, with the names she typed herself if she wants them listed.
struct ManagedOnlineAgent: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    /// Where its servers are managed. Only pages checked against the
    /// vendor's own docs go deeper than the front page.
    let url: String
    /// The agents on this Mac that belong to the same product: the row shows
    /// when one of them is found.
    let localAgents: [String]
    /// The row's tooltip.
    let help: String
}

enum ManagedOnline {
    static let all: [ManagedOnlineAgent] = [
        ManagedOnlineAgent(id: "grok", name: "Grok web", url: "https://grok.com",
                           localAgents: ["grok", "grok bot"],
                           help: "Grok on the web and its bots keep their servers at grok.com. Opens grok.com."),
        ManagedOnlineAgent(id: "chatgpt", name: "ChatGPT", url: "https://chatgpt.com",
                           localAgents: ["codex"],
                           help: "ChatGPT keeps its connected apps in its own Settings. Opens chatgpt.com."),
        ManagedOnlineAgent(id: "cursor", name: "Cursor cloud", url: "https://cursor.com/agents",
                           localAgents: ["cursor"],
                           help: "Cursor's cloud agents take their servers from the MCP menu at cursor.com/agents."),
        ManagedOnlineAgent(id: "gemini", name: "Gemini", url: "https://gemini.google.com",
                           localAgents: ["gemini", "gemini cli", "antigravity"],
                           help: "Gemini on the web keeps its connected apps in its own Settings. Opens gemini.google.com."),
    ]

    /// The rows to show: the products with an agent on this Mac, in the
    /// table's order; none when she turned the section off.
    static func shown(localAgents: [String], enabled: Bool) -> [ManagedOnlineAgent] {
        guard enabled else { return [] }
        let found = Set(localAgents.map { AgentBadge.agentName(fromLabel: $0).lowercased() })
        return all.filter { agent in agent.localAgents.contains(where: found.contains) }
    }

    /// "notion, canva ,  " as she typed it: the names, trimmed, no blanks, no repeats.
    static func names(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}
