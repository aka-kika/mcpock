import Foundation

/// An MCP config found by scanning (not in the registry).
struct ScannedConfig {
    let path: String      // canonical absolute path
    let label: String     // derived source label
    let entries: [DiscoveredEntry]
}

/// Bounded, TCC-safe filesystem sweep for MCP config files. Reads only; never
/// descends into noisy or protected directories.
enum ConfigScanner {
    private static let candidateExtensions: Set<String> = ["json", "jsonc", "toml", "yaml", "yml"]
    /// Compared **case-insensitively** (see `isExcludedDir`) — keep entries lowercase.
    /// Case mattered: the list once held `Caches`/`Cache` but not lowercase `cache`, so
    /// XDG-style dirs slipped through and a 3-month-old Langflow cache artifact
    /// (`~/.langflow/cache/<uuid>/_mcp_servers_<uuid>.json`) was discovered and probed as
    /// a real server — reported broken forever, since Langflow isn't even installed.
    /// `snapshots`/`archive`/`history` joined the list when Hermes's
    /// `state-snapshots/<date>/config.yaml` backups were discovered as a live agent
    /// called "20260718-041744-pre-update" — a copy of a config is not a config.
    private static let excludedDirs: Set<String> = [
        "node_modules", "caches", "cache", ".git", "logs", "log", "backups", "backup", "vendor", "dist", "build",
        "snapshots", "state-snapshots", "archive", "archived", "_archived", "history",
    ]

    /// Dated copy folders: `_archived_2026-08-27`, `backup-20260628`, `snapshot_v3`.
    private static let excludedPrefixes = ["_archived", "archived", "backup", "snapshot"]

    /// Directory names are matched case-insensitively so `Cache`, `cache` and `CACHE`
    /// are all skipped — hand-enumerating spellings is what let `cache` through before.
    private static func isExcludedDir(_ name: String) -> Bool {
        let lower = name.lowercased()
        return excludedDirs.contains(lower) || excludedPrefixes.contains { lower.hasPrefix($0) }
    }
    private static let maxFileBytes = 1_000_000

    /// Files that look like an agent config but that no agent loads. Matched as a
    /// path suffix, so it holds under any home folder.
    /// - `~/.minimax/mcp/mcp.json`: MiniMax loads only `~/.minimax/mcp.json` (its
    ///   own `~/.minimax/mcp-runtime-names.json` lists only that file's servers).
    ///   Reading the other file made its servers look "set up differently" for
    ///   MiniMax (playwright, recall; fixed in 1.5.1).
    private static let excludedFileSuffixes = ["/.minimax/mcp/mcp.json"]

    static func isExcludedFile(_ path: String) -> Bool {
        excludedFileSuffixes.contains { path.hasSuffix($0) }
    }

    /// Default roots: TCC-safe config locations. Never Documents/Desktop/Downloads.
    static var defaultRoots: [String] {
        let home = NSHomeDirectory() as NSString
        return [
            home.appendingPathComponent(".config"),
            home.appendingPathComponent("Library/Application Support"),
        ] + homeDotDirs()
    }

    private static func homeDotDirs() -> [String] {
        let home = NSHomeDirectory()
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: home) else { return [] }
        return items
            .filter { $0.hasPrefix(".") && $0 != "." && $0 != ".." && $0 != ".Trash" }
            .map { (home as NSString).appendingPathComponent($0) }
            // Skip symlinked roots: a dotdir symlinked into iCloud/Documents must not be followed.
            .filter { !isSymlink($0) }
    }

    static func scan(roots: [String], maxDepth: Int = 2) -> [ScannedConfig] {
        var out: [String: ScannedConfig] = [:]   // keyed by canonical path (dedup)
        for root in roots {
            walk(root, depth: 0, maxDepth: maxDepth, into: &out)
        }
        return Array(out.values)
    }

    private static func walk(_ dir: String, depth: Int, maxDepth: Int, into out: inout [String: ScannedConfig]) {
        // Never follow a symlinked directory (root or otherwise) — it can escape the safe roots.
        if isSymlink(dir) { return }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { return }
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }

        for name in names {
            let full = (dir as NSString).appendingPathComponent(name)
            // Skip symlinks entirely: following one could escape the safe roots
            // (e.g. a dotfile dir symlinked into iCloud/Documents) — TCC-unsafe.
            // Known agents are covered by AgentRegistry's exact paths instead.
            if isSymlink(full) { continue }
            var childIsDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &childIsDir) else { continue }

            if childIsDir.boolValue {
                if isExcludedDir(name) || name.hasPrefix(".") && depth > 0 { continue }
                if depth < maxDepth {
                    walk(full, depth: depth + 1, maxDepth: maxDepth, into: &out)
                }
                continue
            }

            let ext = (name as NSString).pathExtension.lowercased()
            guard candidateExtensions.contains(ext), !isExcludedFile(full) else { continue }
            // Regular files only: reading a named pipe (FIFO) or a socket that
            // happens to end in .json would block the scan forever.
            guard let attrs = try? fm.attributesOfItem(atPath: full),
                  attrs[.type] as? FileAttributeType == .typeRegular,
                  let size = attrs[.size] as? Int, size <= maxFileBytes else { continue }
            guard let text = try? String(contentsOfFile: full, encoding: .utf8) else { continue }

            for shape in ConfigShape.all {
                if let entries = shape.parse(text), entries.contains(where: \.hasEndpoint) {
                    let canonical = canonicalPath(full)
                    out[canonical] = ScannedConfig(path: canonical, label: deriveLabel(fromPath: full), entries: entries)
                    break
                }
            }
        }
    }

    /// Source label from a config path: the containing folder, dot stripped.
    static func deriveLabel(fromPath path: String) -> String {
        let parent = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        return parent.hasPrefix(".") ? String(parent.dropFirst()) : parent
    }

    /// True if `path` itself is a symbolic link (does NOT follow it).
    private static func isSymlink(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)[.type]) as? FileAttributeType == .typeSymbolicLink
    }

    /// Canonical absolute path (symlinks resolved + standardized). Shared with
    /// `ConfigDiscovery` as the dedup key so a file found by both the registry and
    /// the scan collapses to one source.
    static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
