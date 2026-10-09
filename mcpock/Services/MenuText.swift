import Foundation

/// What the right-click menus copy (round 5: "right-click everywhere"). Pure, so
/// `MenuTextTests` checks the texts without a menu.
enum MenuText {
    /// The server menu's copy items (1.5.3: exactly two): the details of
    /// any row, and the errors of a row that has them. Plus "Ask an Agent" for
    /// a row that needs you. Menu items use title case; the card's buttons say
    /// the same in sentence case (`CardText`).
    static let copyDetailsTitle = "Copy Details"
    static let copyErrorsTitle = "Copy Errors"
    static let askAgentTitle = "Ask an Agent"

    /// "Copy Errors": the same report as ⌘C and the card's "Copy errors" for a
    /// broken or slow row; nil when the row has no error to copy, so the menu
    /// leaves the item out.
    static func copyError(for group: ServerGroup) -> String? {
        (group.state == .broken || group.state == .degraded) ? group.copyText : nil
    }

    /// "Copy All Problems" on an agent row (2026-10-03: errors were copied
    /// one server at a time). Every server that needs this agent's attention in
    /// one paste-ready block: the agent and its config file(s), then each server
    /// with this agent's own errors (masked like "Copy Errors") or, for a server
    /// set up differently, the row's note. nil when the agent has no problem,
    /// so the menu leaves the item out.
    static let copyAllProblemsTitle = "Copy All Problems"

    static func agentProblems(_ section: AgentSection, groups: [String: ServerGroup]) -> String? {
        let problems = section.problems
        guard !problems.isEmpty else { return nil }
        var lines = [ServerGroup.reportPreamble(plural: problems.count > 1), "", "Agent: \(section.displayName)"]
        if !section.paths.isEmpty {
            lines.append((section.paths.count == 1 ? "Config: " : "Configs: ") + section.paths.joined(separator: ", "))
        }
        for server in problems {
            lines.append("")
            lines.append("MCP server: \(server.name)")
            lines.append("Status: \(server.state.rawValue)")
            // The agent's own declarations only: "Code" or "Code (MyProject)",
            // never another agent's error for the same server.
            let own = groups[server.name]?.issues.filter {
                $0.label == section.agent || $0.label.hasPrefix(section.agent + " (")
            } ?? []
            if own.isEmpty {
                lines.append("- \(server.note ?? server.state.rawValue)")
            }
            for issue in own {
                lines.append("- \(issue.label): \(issue.reason)")
                if !issue.command.isEmpty { lines.append("  command: \(issue.command)") }
            }
        }
        return lines.joined(separator: "\n")
    }

    /// "Mark as Intended" (1.5.2, renamed in 1.5.3): the right-click item on a
    /// row whose agents are set up differently, and the one that takes it back.
    enum IntendedItem: Equatable {
        case mark
        case unmark

        var title: String {
            switch self {
            case .mark: return MenuText.markAsIntendedTitle
            case .unmark: return MenuText.unmarkAsIntendedTitle
            }
        }

        var systemImage: String {
            switch self {
            case .mark: return "checkmark.circle"
            case .unmark: return "arrow.uturn.backward"
            }
        }

        /// What choosing it sets the row to: marked, or not.
        var marks: Bool { self == .mark }
    }

    static let markAsIntendedTitle = "Mark as Intended"
    static let unmarkAsIntendedTitle = "Unmark as Intended"

    /// Which of the two the menu offers for a row, or nil when neither applies
    /// (the agents agree). A fully marked row is only ever offered Unmark; a
    /// marked row where another agent now differs (1.9.0, per-agent marks)
    /// is offered Mark again, for that agent.
    static func intendedItem(for group: ServerGroup) -> IntendedItem? {
        if group.isDiffering { return .mark }
        return group.isDifferentOnPurpose ? .unmark : nil
    }

    /// An agent's config files, one full path per line.
    static func configPaths(_ paths: [String]) -> String {
        paths.joined(separator: "\n")
    }

    /// "Copy Path", or "Copy Paths" for an agent with two files (round 8: the
    /// same words as every other path menu).
    static func copyPathsTitle(count: Int) -> String {
        count == 1 ? copyPathTitle : "Copy Paths"
    }

    /// Config path menus (round 8): Settings > Agents, Settings > General's
    /// status file, the card's "Used by", the Agents tab's paths and agent rows.
    /// One order everywhere: Show in Finder, Copy Path, a separator, then Open
    /// Config… last (it asks first; opening a config is the risky one).
    static let showInFinderTitle = "Show in Finder"
    static let copyPathTitle = "Copy Path"
    static let openConfigTitle = "Open Config\u{2026}"
    /// The status file isn't a config: same menu, its own word.
    static let openFileTitle = "Open File\u{2026}"

    /// The confirmation Open Config… shows.
    static func openConfigQuestion(path: String) -> String {
        "Open \((path as NSString).lastPathComponent)?"
    }

    static let openConfigWarning = "It opens in its default app. One accidental change can stop an agent "
        + "from loading its servers, so edit it only if you know what you're changing. mcpock itself only reads it."
    static let openConfigConfirm = "Open"

    /// Tooltip on a config path: the path, then the hint.
    static func configPathHelp(path: String) -> String {
        "\(path)\nRight-click for options"
    }
}
