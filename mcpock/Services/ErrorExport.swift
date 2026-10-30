import Foundation

/// Builds a shareable report of the servers that need attention, for Copy All
/// Problems on the panel's footer. It is the report the agents read
/// (`StatusReport.problemLines`, from the same snapshot as `status.json`):
/// config paths, servers set up differently, hidden ones left out, agents by
/// their full names (Argon 2026-10-17 #12). Pure, so it's unit-testable.
enum ErrorExport {
    /// The servers the report lists: needing attention, not hidden.
    static func failing(_ status: MCPockStatus) -> [MCPockStatus.Server] {
        StatusReport.problems(in: status)
    }

    static func markdown(from status: MCPockStatus, now: Date) -> String {
        var lines: [String] = ["# mcpock error report", ""]
        lines.append("Generated: \(displayFormatter.string(from: now))")
        let count = failing(status).count
        if count > 0 {
            lines.append("")
            lines.append(ServerGroup.reportPreamble(plural: count > 1))
        }
        lines.append("")
        lines.append(contentsOf: StatusReport.problemLines(status, now: now))
        return lines.joined(separator: "\n") + "\n"
    }

    private static var displayFormatter: DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }
}
