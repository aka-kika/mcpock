import Foundation

enum PathResolver {
    static let commonBinPaths = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "\(NSHomeDirectory())/.local/bin",
        "/usr/bin",
        "/bin",
    ]

    /// Expand `~` and resolve a command against env PATH + common bin directories.
    static func resolveCommand(_ command: String, env: [String: String]) -> String {
        let expanded = expandTilde(command)

        // Absolute or relative path with separator — use as-is after tilde expand.
        if expanded.contains("/") {
            return expanded
        }

        var searchPaths: [String] = []
        if let pathValue = env["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] {
            searchPaths.append(contentsOf: pathValue.split(separator: ":").map(String.init))
        }
        for p in commonBinPaths where !searchPaths.contains(p) {
            searchPaths.append(p)
        }

        let fm = FileManager.default
        for dir in searchPaths {
            let candidate = (expandTilde(dir) as NSString).appendingPathComponent(expanded)
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        return expanded
    }

    /// True when `path` points at an executable inside a macOS app bundle
    /// (`…/Something.app/Contents/MacOS/…`) — i.e. a GUI app binary, not a CLI.
    /// Electron-based agent apps (e.g. MiniMax Code's builtin `matrix` server)
    /// expose MCP servers as `<app binary> <script.js>` and rely on
    /// `ELECTRON_RUN_AS_NODE=1` to run the script headlessly; spawning the same
    /// command without it boots the full app instead.
    static func isAppBundleExecutable(_ path: String) -> Bool {
        path.contains(".app/Contents/MacOS/")
    }

    /// Pure spelling normalisation of a launch command, for comparing two configs
    /// ("do these agents launch the same thing?") — not for spawning. `~` is
    /// expanded, and an absolute path that sits directly in one of the common bin
    /// directories collapses to its bare name, so `npx` and `/opt/homebrew/bin/npx`
    /// compare equal. Deliberately no filesystem lookup (unlike `resolveCommand`):
    /// this runs inside `HealthMonitor.groupByName`, which recomputes on every
    /// panel render, and a stat per directory per server there would be real work
    /// on the main thread for nothing.
    static func normalizedLaunchCommand(_ command: String) -> String {
        let expanded = expandTilde(command.trimmingCharacters(in: .whitespaces))
        guard expanded.hasPrefix("/") else { return expanded }
        let dir = (expanded as NSString).deletingLastPathComponent
        if commonBinPaths.contains(dir) {
            return (expanded as NSString).lastPathComponent
        }
        return expanded
    }

    static func expandTilde(_ path: String) -> String {
        if path == "~" {
            return NSHomeDirectory()
        }
        if path.hasPrefix("~/") {
            return (NSHomeDirectory() as NSString).appendingPathComponent(String(path.dropFirst(2)))
        }
        return path
    }

    /// Build environment for a child process: base process env, common PATH prepend, then config env.
    /// A PATH from the config comes first as written (`~` expanded in each
    /// entry), with the common bins only appended as fallbacks: a server set
    /// to a specific nvm Node or Python venv keeps it (Argon 2026-10-17 #5).
    static func processEnvironment(configEnv: [String: String], base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        env["PATH"] = prependingCommonBins(to: env["PATH"] ?? "")

        for (key, value) in configEnv {
            env[key] = expandTilde(value)
        }

        if let path = configEnv["PATH"] {
            env["PATH"] = appendingCommonBins(to: path)
        }

        return env
    }

    /// Prepend any missing `commonBinPaths` to a colon-joined PATH, preserving order.
    private static func prependingCommonBins(to path: String) -> String {
        var parts = path.split(separator: ":").map(String.init)
        for p in commonBinPaths.reversed() where !parts.contains(p) {
            parts.insert(p, at: 0)
        }
        return parts.joined(separator: ":")
    }

    /// `path` with `~` expanded in each entry, then any missing `commonBinPaths` after it.
    static func appendingCommonBins(to path: String) -> String {
        var parts = path.split(separator: ":").map { expandTilde(String($0)) }
        for p in commonBinPaths where !parts.contains(p) {
            parts.append(p)
        }
        return parts.joined(separator: ":")
    }
}
