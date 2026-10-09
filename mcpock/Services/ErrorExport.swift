import Foundation

/// Builds a shareable report of all failing MCP servers, for the Settings
/// "Export errors…" action. Pure string builders so they're unit-testable;
/// the file write + save panel live in the view.
enum ErrorExport {
    enum Format {
        case markdown
        case json
    }

    /// Groups that currently have a failure worth reporting (broken/degraded with a reason).
    static func failing(_ groups: [ServerGroup]) -> [ServerGroup] {
        groups.filter { !$0.issues.isEmpty }
    }

    /// Pick the format implied by a chosen filename's extension (defaults to Markdown).
    static func format(forExtension ext: String) -> Format {
        ext.lowercased() == "json" ? .json : .markdown
    }

    static func string(_ format: Format, from groups: [ServerGroup], totalCount: Int, generated: Date) -> String {
        switch format {
        case .markdown: return markdown(from: groups, totalCount: totalCount, generated: generated)
        case .json: return json(from: groups, totalCount: totalCount, generated: generated)
        }
    }

    // MARK: - Markdown

    static func markdown(from groups: [ServerGroup], totalCount: Int, generated: Date) -> String {
        let failing = failing(groups)
        var lines: [String] = ["# mcpock error report", ""]
        lines.append("Generated: \(displayFormatter.string(from: generated))")
        lines.append("Failing servers: \(failing.count) of \(totalCount)")

        guard !failing.isEmpty else {
            lines.append("")
            lines.append("No failing servers.")
            return lines.joined(separator: "\n") + "\n"
        }

        lines.append("")
        lines.append(ServerGroup.reportPreamble(plural: true))

        for group in failing {
            lines.append("")
            lines.append("## \(group.name) — \(group.state.rawValue)")
            lines.append("Sources: \(group.sourceSummary)")
            lines.append("")
            for issue in group.issues {
                lines.append("- **\(issue.label)**: \(issue.reason)")
                if !issue.command.isEmpty {
                    lines.append("  `\(issue.command)`")
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - JSON

    private struct Payload: Encodable {
        let generated: String
        let failingCount: Int
        let totalCount: Int
        let servers: [Server]

        struct Server: Encodable {
            let name: String
            let state: String
            let sources: [String]
            let errors: [Issue]
        }
        struct Issue: Encodable {
            let source: String
            let reason: String
            let command: String
        }
    }

    static func json(from groups: [ServerGroup], totalCount: Int, generated: Date) -> String {
        let failing = failing(groups)
        let payload = Payload(
            generated: ISO8601DateFormatter().string(from: generated),
            failingCount: failing.count,
            totalCount: totalCount,
            servers: failing.map { group in
                Payload.Server(
                    name: group.name,
                    state: group.state.rawValue,
                    sources: group.sourceLabels,
                    errors: group.issues.map {
                        Payload.Issue(source: $0.label, reason: $0.reason, command: $0.command)
                    }
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(payload),
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
