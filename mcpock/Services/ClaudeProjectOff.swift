import Foundation

/// The servers a Claude Code project switched off with its own /mcp list
/// (`disabledMcpServers` under that project in `~/.claude.json`). A server
/// of the user scope stays on everywhere else, so the row keeps its state;
/// the card says where it is off (premium look, 22 Nov: "Off in one project").
/// Read only: mcpock never writes that list (Claude Code rewrites the file
/// while it runs).
enum ClaudeProjectOff {
    /// Server name (as written) to the projects that have it off, by folder
    /// name, sorted. The account's connectors are left to `ClaudeConnectors`.
    static func projects(claudeJSON data: Data) -> [String: [String]] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = root["projects"] as? [String: Any]
        else { return [:] }
        var result: [String: Set<String>] = [:]
        for (path, value) in projects {
            guard let project = value as? [String: Any],
                  let disabled = project["disabledMcpServers"] as? [String]
            else { continue }
            let folder = (path as NSString).lastPathComponent
            guard !folder.isEmpty else { continue }
            for name in disabled where !name.isEmpty && !name.hasPrefix(ClaudeConnectors.prefix) {
                result[name, default: []].insert(folder)
            }
        }
        return result.mapValues { $0.sorted() }
    }

    /// "Off in one project: shop", "Off in 3 projects: blog, shop, site";
    /// more than three are counted, not listed. nil with none.
    static func note(_ projects: [String]) -> String? {
        switch projects.count {
        case 0: return nil
        case 1: return "Off in one project: \(projects[0])"
        case 2, 3: return "Off in \(projects.count) projects: \(projects.joined(separator: ", "))"
        default: return "Off in \(projects.count) projects"
        }
    }
}
