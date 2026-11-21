import Foundation

/// A claude.ai connector as Claude Code lists it (premium look, 22 Nov,
/// Kika's pick: its own section on the Agents tab). These are servers of the
/// Claude account, not of a config file, so mcpock cannot check them itself:
/// it shows what Claude Code says. Best effort, and only when she turned it on.
struct ClaudeConnector: Identifiable, Equatable, Sendable {
    enum State: Equatable, Sendable {
        case connected
        /// Claude Code could not reach it.
        case failing
        case needsSignIn
        /// Listed, with a status mcpock does not know.
        case unknown
    }

    /// "Gmail", without Claude Code's "claude.ai " in front.
    let name: String
    /// The host only ("gmail.mcp.claude.com"). A connector's URL can carry a
    /// key in its path, so the path never leaves the parser.
    let host: String
    var state: State
    /// The projects that have it switched off, by folder name.
    var offProjects: [String] = []

    var id: String { name }

    /// The panel's mark: a dot while connected, a diamond when failing, the
    /// ring for a sign-in; the grey ring when mcpock can't tell.
    var mark: HealthState {
        switch state {
        case .connected: return .healthy
        case .failing: return .broken
        case .needsSignIn: return .degraded
        case .unknown: return .unknown
        }
    }

    /// The one word on the right: the problem first, else where it is off.
    var word: String? {
        switch state {
        case .failing: return "Not answering"
        case .needsSignIn: return "Needs sign-in"
        case .connected, .unknown:
            switch offProjects.count {
            case 0: return nil
            case 1: return "Off in \(offProjects[0])"
            default: return "Off in \(offProjects.count) projects"
            }
        }
    }

    var wordIsProblem: Bool { state == .failing }
}

/// Reads the connectors from Claude Code: `claude mcp list` for the names,
/// hosts and states, and `~/.claude.json` for the projects that switched one
/// off. Parsing is pure (`ClaudeConnectorsTests`); only `load` starts a process.
enum ClaudeConnectors {
    /// How Claude Code names a connector of the account.
    static let prefix = "claude.ai "
    /// Asked at most this often: `claude mcp list` makes Claude Code start its
    /// servers to answer, so it is not a thing to do every minute.
    static let refreshEvery: TimeInterval = 30 * 60
    static let timeout: Duration = .seconds(90)

    /// The grey line under the section.
    static let footnote = "Best effort. Needs Claude Code signed in with a claude.ai account."

    /// The lines of `claude mcp list` that are connectors:
    /// `claude.ai Gmail: https://gmail.mcp.claude.com/mcp - ✔ Connected`.
    /// Everything else (its own config servers, plugin servers, the
    /// "Checking…" line) is left out: mcpock checks those itself.
    static func parse(_ output: String) -> [ClaudeConnector] {
        var seen = Set<String>()
        return output.split(whereSeparator: \.isNewline).compactMap { rawLine -> ClaudeConnector? in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(prefix), let colon = line.range(of: ": ") else { return nil }
            let name = String(line[line.index(line.startIndex, offsetBy: prefix.count)..<colon.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { return nil }
            let rest = String(line[colon.upperBound...])
            // The status is after the last " - " (a URL holds no " - ").
            let (target, status): (String, String)
            if let dash = rest.range(of: " - ", options: .backwards) {
                target = String(rest[..<dash.lowerBound])
                status = String(rest[dash.upperBound...])
            } else {
                (target, status) = (rest, "")
            }
            return ClaudeConnector(name: name, host: host(of: target), state: state(of: status))
        }
    }

    /// The host of a listed target; "" when it is not a URL. Never the path,
    /// the query or the user part.
    static func host(of target: String) -> String {
        let first = target.split(separator: " ").first.map(String.init) ?? ""
        guard let url = URL(string: first), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty
        else { return "" }
        return host.lowercased()
    }

    static func state(of status: String) -> ClaudeConnector.State {
        let text = status.lowercased()
        if text.contains("needs auth") || text.contains("sign in") || text.contains("unauthorized") { return .needsSignIn }
        if text.contains("failed") || text.contains("error") || status.contains("\u{2718}") || status.contains("\u{2717}") {
            return .failing
        }
        if text.contains("connected") { return .connected }
        return .unknown
    }

    /// From `~/.claude.json`: for every connector, the projects whose
    /// `disabledMcpServers` name it, by folder name, sorted. Keys are the
    /// connector names without the prefix, lowercased.
    static func offProjects(claudeJSON data: Data) -> [String: [String]] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = root["projects"] as? [String: Any]
        else { return [:] }
        var result: [String: Set<String>] = [:]
        for (path, value) in projects {
            guard let project = value as? [String: Any],
                  let disabled = project["disabledMcpServers"] as? [String]
            else { continue }
            let folder = (path as NSString).lastPathComponent
            for entry in disabled where entry.hasPrefix(prefix) {
                let name = String(entry.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces).lowercased()
                guard !name.isEmpty, !folder.isEmpty else { continue }
                result[name, default: []].insert(folder)
            }
        }
        return result.mapValues { $0.sorted() }
    }

    /// The listed connectors with their off projects filled in, by name.
    static func merged(_ connectors: [ClaudeConnector], off: [String: [String]]) -> [ClaudeConnector] {
        connectors.map { connector in
            var copy = connector
            copy.offProjects = off[connector.name.lowercased()] ?? []
            return copy
        }
        .sorted { a, b in
            let (ra, rb) = (rank(a), rank(b))
            return ra != rb ? ra < rb : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// Problems first, like every list in the panel.
    private static func rank(_ connector: ClaudeConnector) -> Int {
        switch connector.state {
        case .failing: return 0
        case .needsSignIn: return 1
        case .connected, .unknown: return 2
        }
    }

    enum LoadResult: Equatable, Sendable {
        case connectors([ClaudeConnector])
        /// Why there is no list, in words for the section ("Claude Code was not found").
        case unavailable(String)
    }

    /// Asks Claude Code. Runs `claude mcp list` from the home folder (no
    /// project's own switches apply there), waits at most `timeout`, and
    /// always reaps the process tree.
    static func load(
        claudeJSONPath: String = (NSHomeDirectory() as NSString).appendingPathComponent(".claude.json"),
        timeout: Duration = ClaudeConnectors.timeout
    ) async -> LoadResult {
        let runner: ProcessRunner
        do {
            runner = try ProcessRunner(
                command: "claude", args: ["mcp", "list"], env: [:],
                workingDirectory: NSHomeDirectory(),
                capturesRawStdout: true,
                baseEnvironment: HeadersHelper.helperBase(ShellEnvironment.current)
            )
        } catch {
            return .unavailable("Claude Code was not found on this Mac.")
        }

        let deadline = ContinuousClock.now + timeout
        while runner.isRunning, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
        }
        let timedOut = runner.isRunning
        if !timedOut {
            let readDeadline = ContinuousClock.now + .milliseconds(500)
            while !runner.stdoutDidFinish, ContinuousClock.now < readDeadline {
                await ProcessRunner.pause(.milliseconds(10))
            }
        }
        let output = String(decoding: runner.rawStdout, as: UTF8.self)
        let normalExit = !timedOut && runner.exitedNormally && runner.terminationStatus == 0
        await runner.terminateAndReap()

        if timedOut { return .unavailable("Claude Code did not answer in time.") }
        guard normalExit else { return .unavailable("Claude Code could not list its servers.") }

        let off = FileManager.default.contents(atPath: claudeJSONPath).map(offProjects(claudeJSON:)) ?? [:]
        return .connectors(merged(parse(output), off: off))
    }
}
