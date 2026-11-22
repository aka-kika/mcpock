import Foundation

/// The servers a Claude Code project switched off with its own /mcp list
/// (`disabledMcpServers` under that project in `~/.claude.json`). A server
/// of the user scope stays on everywhere else, so the row keeps its state;
/// the card says where it is off (premium look, 22 Nov: "Off in one project").
/// Read only: mcpock never writes that list (Claude Code rewrites the file
/// while it runs).
enum ClaudeProjectOff {
    /// Every name in a project's off list (as written, the account's
    /// "claude.ai …" connectors included) to the full paths of the projects
    /// that list it, sorted. By full path: two projects with the same folder
    /// name are two projects (review 22 Nov).
    static func byPath(claudeJSON data: Data) -> [String: [String]] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = root["projects"] as? [String: Any]
        else { return [:] }
        var result: [String: Set<String>] = [:]
        for (path, value) in projects where !path.isEmpty {
            guard let project = value as? [String: Any],
                  let disabled = project["disabledMcpServers"] as? [String]
            else { continue }
            for name in disabled where !name.isEmpty { result[name, default: []].insert(path) }
        }
        return result.mapValues { $0.sorted() }
    }

    /// Bigger than this and the file is not read for this line at all (the
    /// config reader's own cap).
    static let maxBytes = 64 * 1024 * 1024

    private static let cacheLock = NSLock()
    private static var cache: (path: String, modified: Date, size: Int, value: [String: [String]])?

    /// `byPath` of the file, read again only when the file changed: Claude
    /// Code's file can be many megabytes, and this is asked every time the
    /// panel opens (review 22 Nov).
    static func byPath(file path: String) -> [String: [String]] {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attributes[.modificationDate] as? Date,
              let size = (attributes[.size] as? NSNumber)?.intValue, size <= maxBytes
        else { return [:] }
        cacheLock.lock()
        if let cache, cache.path == path, cache.modified == modified, cache.size == size {
            cacheLock.unlock()
            return cache.value
        }
        cacheLock.unlock()
        guard let data = FileManager.default.contents(atPath: path) else { return [:] }
        let value = byPath(claudeJSON: data)
        cacheLock.lock()
        cache = (path, modified, size, value)
        cacheLock.unlock()
        return value
    }

    /// Folder names for a list of project paths; two projects with the same
    /// folder name show their parent folder too ("code/shop", "work/shop").
    static func displayNames(_ paths: [String]) -> [String] {
        let leaves = paths.map { ($0 as NSString).lastPathComponent }
        let repeated = Set(leaves.filter { leaf in leaves.filter { $0 == leaf }.count > 1 })
        return zip(paths, leaves).map { path, leaf in
            guard repeated.contains(leaf) else { return leaf }
            let parent = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
            return parent.isEmpty ? leaf : parent + "/" + leaf
        }.sorted()
    }

    /// Server name (as written) to the projects that have it off, as shown.
    /// The account's connectors are left to `ClaudeConnectors`.
    static func projects(byPath: [String: [String]]) -> [String: [String]] {
        byPath.filter { !$0.key.hasPrefix(ClaudeConnectors.prefix) }.mapValues(displayNames)
    }

    static func projects(claudeJSON data: Data) -> [String: [String]] {
        projects(byPath: byPath(claudeJSON: data))
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
