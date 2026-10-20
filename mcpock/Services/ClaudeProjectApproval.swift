import Foundation

/// Which servers in a project's `.mcp.json` Claude Code was told to run.
///
/// Claude Code starts a project's `.mcp.json` servers only after the user
/// approves them, and mcpock does the same (review 2026-10-20, db0c): a
/// scanned `.mcp.json` server is started, and its `headersHelper` run, only
/// when Claude Code lists it as approved for that folder. Anything else (a
/// file from a cloned repo, a server still waiting for its prompt) is left
/// alone.
///
/// Where Claude Code keeps the answer:
/// - `~/.claude.json` `projects.<folder>`: `enabledMcpjsonServers`,
///   `disabledMcpjsonServers`, `enableAllProjectMcpServers`;
/// - the same three keys in the user's `~/.claude/settings.json`;
/// - and in the project's own `.claude/settings.local.json` and
///   `.claude/settings.json`, read only once the folder is trusted
///   (`hasTrustDialogAccepted`): before that, a repo could approve itself.
///
/// A server named as disabled anywhere stays off, whatever else says.
struct ClaudeProjectApproval: Equatable {
    var enabled: Set<String> = []
    var disabled: Set<String> = []
    var enableAll = false
    var trusted = false

    func allows(_ name: String) -> Bool {
        !disabled.contains(name) && (enableAll || enabled.contains(name))
    }

    mutating func add(_ object: [String: Any]) {
        enabled.formUnion(object["enabledMcpjsonServers"] as? [String] ?? [])
        disabled.formUnion(object["disabledMcpjsonServers"] as? [String] ?? [])
        if (object["enableAllProjectMcpServers"] as? Bool) == true { enableAll = true }
    }

    /// `~/.claude.json`'s per-project answers, keyed by canonical folder path.
    static func projects(claudeJSON text: String) -> [String: ClaudeProjectApproval] {
        guard let projects = object(text)?["projects"] as? [String: Any] else { return [:] }
        var result: [String: ClaudeProjectApproval] = [:]
        for (path, value) in projects {
            guard let project = value as? [String: Any] else { continue }
            var approval = ClaudeProjectApproval()
            approval.add(project)
            approval.trusted = (project["hasTrustDialogAccepted"] as? Bool) == true
            result[ConfigScanner.canonicalPath(path), default: ClaudeProjectApproval()].merge(approval)
        }
        return result
    }

    /// The answer for one project folder: `~/.claude.json`, the user's
    /// settings, then the project's own settings when the folder is trusted.
    static func forFolder(
        _ folder: String,
        projects: [String: ClaudeProjectApproval],
        userSettings: [String: Any]?,
        readFile: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }
    ) -> ClaudeProjectApproval {
        var approval = projects[ConfigScanner.canonicalPath(folder)] ?? ClaudeProjectApproval()
        if let userSettings { approval.add(userSettings) }
        if approval.trusted {
            for name in ["settings.local.json", "settings.json"] {
                let path = ((folder as NSString).appendingPathComponent(".claude") as NSString).appendingPathComponent(name)
                if let settings = readFile(path).flatMap(object) { approval.add(settings) }
            }
        }
        return approval
    }

    static func object(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data))
            .flatMap { $0 as? [String: Any] }
            ?? (try? JSONSerialization.jsonObject(with: Data(JSONC.plainJSON(text).utf8))) as? [String: Any]
    }

    private mutating func merge(_ other: ClaudeProjectApproval) {
        enabled.formUnion(other.enabled)
        disabled.formUnion(other.disabled)
        enableAll = enableAll || other.enableAll
        trusted = trusted || other.trusted
    }
}
