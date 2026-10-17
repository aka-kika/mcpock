import Foundation

/// Builds a shareable report of the servers that need attention, for the
/// Settings "Copy All" and "Export…" actions. It is the report the agents
/// read (`StatusReport.problemLines`, from the same snapshot as
/// `status.json`): config paths, servers set up differently, hidden ones
/// left out, agents by their full names (Argon 2026-10-17 #12). Pure string
/// builders so they're unit-testable; the file write + save panel live in
/// the view.
enum ErrorExport {
    enum Format {
        case markdown
        case json
    }

    /// The servers the report lists: needing attention, not hidden.
    static func failing(_ status: MCPockStatus) -> [MCPockStatus.Server] {
        StatusReport.problems(in: status)
    }

    /// Pick the format implied by a chosen filename's extension (defaults to Markdown).
    static func format(forExtension ext: String) -> Format {
        ext.lowercased() == "json" ? .json : .markdown
    }

    static func string(_ format: Format, from status: MCPockStatus, now: Date) -> String {
        switch format {
        case .markdown: return markdown(from: status, now: now)
        case .json: return json(from: status, now: now)
        }
    }

    // MARK: - Markdown

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

    // MARK: - JSON

    private struct Payload: Encodable {
        let generated: Date
        let failingCount: Int
        let totalCount: Int
        let summary: String
        let servers: [MCPockStatus.Server]
    }

    static func json(from status: MCPockStatus, now: Date) -> String {
        let failing = failing(status)
        let payload = Payload(
            generated: now,
            failingCount: failing.count,
            totalCount: status.counts.total,
            summary: status.summary,
            servers: failing
        )
        guard let data = try? MCPockStatus.encoder().encode(payload),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string + "\n"
    }

    // MARK: - Helpers

    /// A filesystem-safe timestamp for the default filename, e.g. `2026-07-11-0830`.
    static func fileStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmm"
        return f.string(from: date)
    }

    private static var displayFormatter: DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }
}
