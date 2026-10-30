import Foundation

/// What to do about a row that needs you: the line under its reason on the
/// card, in `status.md` and in `mcpock_problems`, so she and an agent are told
/// the same thing (1.13). Fixed wording only, never anything a server printed,
/// so nothing here needs masking. Pure; `NextStepTests` pins the table.
enum NextStep {
    /// The line for a whole row, or nil when there is nothing to add: a row
    /// that is fine, paused or still unchecked, and the rows whose reason
    /// already says it ("run /mcp there", "Allow this file", "Needs Wake open").
    static func line(for group: ServerGroup) -> String? {
        switch group.state {
        case .broken, .degraded:
            guard let issue = group.issues.first else { return nil }
            return line(forReason: issue.reason, remote: group.sources.contains { $0.transport != .stdio })
        case .healthy:
            guard !group.droppedInSession, group.differsNeedsAttention else { return nil }
            return "Compare the setups, then fix the odd one or Mark as intended."
        case .unknown, .paused, .selfManaged, .needsApp:
            return nil
        }
    }

    /// The line for one failure text (`ProbeError`'s wordings, as `ShortReason`
    /// reads them).
    static func line(forReason reason: String, remote: Bool) -> String {
        let head = (reason.components(separatedBy: " — ").first ?? reason).trimmingCharacters(in: .whitespacesAndNewlines)
        let printedError = reason.contains(" — ")

        if head.hasPrefix(HealthMonitor.noEndpointReason) || head.hasPrefix("Spawn error: Missing command") {
            return "Add a command or url to this entry, or remove it."
        }
        if head.hasPrefix(HealthMonitor.agentSignInPrefix) {
            return "Nothing to do unless the agent fails too: then sign in again there."
        }
        if head.hasPrefix(ConfigVariables.reasonPrefix) {
            return "Nothing to do unless the agent fails too: then set the variable where it runs."
        }
        if head.hasPrefix("Needs authentication") {
            return "The token in the config is old or wrong: sign in again in the agent."
        }
        if head.hasPrefix("Spawn error: Command not found") {
            return head.contains("a relative path")
                ? "Write the full path in the config."
                : "Install it, or write the full path in the config."
        }
        if head.hasPrefix("Spawn error: Not executable") {
            return "Make the file executable, or point the config at the right one."
        }
        if head.hasPrefix("Spawn error") {
            return "Run its command in Terminal to see why."
        }
        if head.hasPrefix("Non-zero exit") {
            return printedError
                ? "Read its error above: usually a missing key or package."
                : "Run its command in Terminal to see why: usually a missing key or package."
        }
        if head.hasPrefix("Exited after start") {
            return "Run its command in Terminal to see why it quits."
        }
        if head.hasPrefix("Timed out") {
            return remote
                ? "Check again. If it stays slow, see whether the server is up."
                : "Check again. If it stays slow, run its command in Terminal."
        }
        if head.hasPrefix("Handshake rejected") {
            return "Read its error above: often the server needs an update."
        }
        if head.hasPrefix("Invalid URL") {
            return "Fix the address in the config."
        }
        if head.hasPrefix("Protocol error") {
            return "Check that this really is an MCP server, and update it if it is."
        }
        if head.hasPrefix("No response from server") {
            return remote
                ? "Check the address, and that the server is up."
                : "Run its command in Terminal to see whether it starts."
        }
        if head.hasPrefix("Header helper") {
            return "Run the config's headersHelper in Terminal to see why it fails."
        }
        if head.hasPrefix("HTTP 5") {
            return "The trouble is on the server's side: check again later."
        }
        if head.hasPrefix("HTTP ") {
            return "Check the address in the config."
        }
        // Anything else is a connection error in the system's words.
        return remote
            ? "Check the address, and that the server is up."
            : "Run its command in Terminal to see why."
    }
}
