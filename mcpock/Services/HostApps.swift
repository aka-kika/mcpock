import AppKit
import Foundation

/// Finds a server's app, honestly: only a command inside an `.app` bundle
/// (symbolic links followed; not a developer tool), a launcher script that names one,
/// or a local port an app was seen listening on. Anything else stays a normal
/// check.
/// What a probe found out about a server's app (`HostApps.lookUp`).
struct HostLookup: Sendable {
    /// The app the config belongs to, or nil.
    var app: HostApp?
    /// Ports looked up with lsof this time.
    var lookedUp: Set<Int> = []
    /// Of those, the ones an app listens on: port -> bundle path.
    var learned: [Int: String] = [:]
    /// Learned before, but a working server there is not that app's any
    /// more: forget them.
    var forgotten: Set<Int> = []
}

enum HostApps {
    // MARK: - Pure parts (tests pin them)

    /// The app a server's own program sits in, or nil. Developer tools that
    /// only ship inside an app (Xcode's `python3`, `git`) run without it, so
    /// they never make a server wait for that app (Argon 2026-10-17 #9).
    nonisolated static func bundlePath(ofExecutable path: String) -> String? {
        guard !path.contains(".app/Contents/Developer/") else { return nil }
        return bundlePath(inPath: path)
    }

    /// "/Applications/Wake.app" for any path inside it, or nil.
    nonisolated static func bundlePath(inPath path: String) -> String? {
        guard path.hasPrefix("/"), let range = path.range(of: ".app/") ?? (path.hasSuffix(".app") ? path.range(of: ".app", options: .backwards) : nil)
        else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    /// The port of a local address (`localhost`, `127.0.0.1`, `[::1]`), or nil.
    nonisolated static func localPort(inURL text: String) -> Int? {
        guard let parts = URLComponents(string: text), let host = parts.host?.lowercased(),
              ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) else { return nil }
        if let port = parts.port { return port }
        return parts.scheme == "https" ? 443 : 80
    }

    /// What a launcher script points at: the `.app` bundles of the programs
    /// it runs and local ports it talks to. Only a line's program counts, not
    /// any `.app` the script mentions (a comment, an argument, a script inside
    /// an app run by `node`): otherwise a real error read "Needs <App> open"
    /// (review 2026-10-20, 5345).
    nonisolated static func scriptHints(_ text: String) -> (bundles: [String], ports: [Int]) {
        var bundles: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            // `exec`, `nohup` and `VAR=value` before the program are not it.
            let words = AkaSource.splitCommandLine(trimmed)
                .drop { $0 == "exec" || $0 == "nohup" || $0 == "command" || ($0.contains("=") && !$0.hasPrefix("/")) }
            guard let program = words.first, let path = bundlePath(ofExecutable: program) else { continue }
            if !bundles.contains(path) { bundles.append(path) }
        }
        var ports: [Int] = []
        for match in localPortRegex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range(at: 1), in: text), let port = Int(text[range]) else { continue }
            if !ports.contains(port) { ports.append(port) }
        }
        return (bundles, ports)
    }

    private static let localPortRegex = try! NSRegularExpression(pattern: #"(?:localhost|127\.0\.0\.1|\[::1\]):(\d{2,5})"#)

    // MARK: - This Mac

    /// What a probe learns about a config's app, off the main thread (Argon
    /// 2026-10-17 #7: lsof and file reads on the main thread froze the panel).
    /// A healthy server's local ports are looked up first (once per port per
    /// session), so a port learned now already names the app.
    nonisolated static func lookUp(
        _ config: ServerConfig, healthy: Bool, learned: [Int: String], skip: Set<Int>,
        hostAppOf: (ServerConfig, [Int: String]) -> HostApp?, listeningApp: (Int) -> HostApp?
    ) -> HostLookup {
        var lookup = HostLookup()
        if healthy {
            // Learned ports are checked again once per session too: a port an
            // app once served may now belong to a plain server, which must
            // read broken when it fails, not "Needs <App> open" (Argon
            // 2026-10-17 #9).
            for port in localPorts(of: config) where !skip.contains(port) {
                lookup.lookedUp.insert(port)
                if let app = listeningApp(port) {
                    lookup.learned[port] = app.bundlePath
                } else if learned[port] != nil {
                    lookup.forgotten.insert(port)
                }
            }
        }
        let known = learned.merging(lookup.learned) { _, new in new }.filter { !lookup.forgotten.contains($0.key) }
        lookup.app = hostAppOf(config, known)
        return lookup
    }

    /// The app `config` belongs to, or nil. `learnedPorts`: port -> bundle
    /// path, from apps seen listening (`listeningApp`).
    nonisolated static func app(for config: ServerConfig, learnedPorts: [Int: String]) -> HostApp? {
        var ports: [Int] = []
        switch config.transport {
        case .stdio:
            let env = PathResolver.processEnvironment(configEnv: config.env)
            let command = PathResolver.resolveCommand(config.command ?? "", env: env)
            // The program itself only: a file an argument names inside an app
            // (a script, a data file) works without the app running.
            if command.hasPrefix("/") {
                let real = URL(fileURLWithPath: command).resolvingSymlinksInPath().path
                if let bundle = bundlePath(ofExecutable: real), let app = hostApp(atBundlePath: bundle) { return app }
            }
            if let script = launcherScript(atPath: command) {
                let hints = scriptHints(script)
                for bundle in hints.bundles where !bundle.contains(".app/Contents/Developer/") {
                    if let app = hostApp(atBundlePath: bundle) { return app }
                }
                ports = hints.ports
            }
            ports += config.args.compactMap(localPort(inURL:))
        case .http, .sse:
            if let port = config.url.flatMap(localPort(inURL:)) { ports = [port] }
        }
        for port in ports {
            // Only a port an app was seen listening on; no built-in guesses.
            if let path = learnedPorts[port], let app = hostApp(atBundlePath: path) { return app }
        }
        return nil
    }

    /// True while the app runs.
    @MainActor
    static func isRunning(_ app: HostApp) -> Bool {
        let path = URL(fileURLWithPath: app.bundlePath).standardizedFileURL.path
        return NSWorkspace.shared.runningApplications.contains { running in
            if let id = app.bundleID, running.bundleIdentifier == id { return true }
            return running.bundleURL?.standardizedFileURL.path == path
        }
    }

    /// The `.app` listening on a local port right now, or nil (a command-line
    /// server, or nothing listening).
    nonisolated static func listeningApp(port: Int) -> HostApp? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]
        let out = Pipe()
        task.standardOutput = out
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return nil }
        task.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        for pid in text.split(whereSeparator: \.isNewline).compactMap({ Int32($0) }) {
            guard let path = NSRunningApplication(processIdentifier: pid)?.bundleURL?.path,
                  path.hasSuffix(".app"), let app = hostApp(atBundlePath: path) else { continue }
            return app
        }
        return nil
    }

    /// The local ports a config talks to (for learning which app serves them).
    nonisolated static func localPorts(of config: ServerConfig) -> [Int] {
        switch config.transport {
        case .http, .sse:
            return config.url.flatMap(localPort(inURL:)).map { [$0] } ?? []
        case .stdio:
            let env = PathResolver.processEnvironment(configEnv: config.env)
            let command = PathResolver.resolveCommand(config.command ?? "", env: env)
            return (launcherScript(atPath: command).map { scriptHints($0).ports } ?? [])
                + config.args.compactMap(localPort(inURL:))
        }
    }

    nonisolated private static func hostApp(atBundlePath path: String) -> HostApp? {
        guard FileManager.default.fileExists(atPath: path), let bundle = Bundle(path: path) else { return nil }
        // mcpock's own helper: mcpock is always running when it checks.
        if bundle.bundleIdentifier?.hasPrefix("com.mcpock.app") == true { return nil }
        let info = bundle.infoDictionary ?? [:]
        let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
            ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return HostApp(name: name, bundlePath: path, bundleID: bundle.bundleIdentifier)
    }

    /// A small text launcher (`#!`), read only to find what it points at.
    nonisolated private static func launcherScript(atPath path: String) -> String? {
        guard path.hasPrefix("/"),
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              let size = attrs[.size] as? Int, size <= 64 * 1024,
              let text = try? String(contentsOfFile: path, encoding: .utf8),
              text.hasPrefix("#!")
        else { return nil }
        return text
    }
}
