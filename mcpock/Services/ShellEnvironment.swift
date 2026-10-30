import Foundation
import os

/// The user's login-shell environment, read once per launch (r3 3c03).
///
/// mcpock starts from launchd, whose PATH has none of nvm, fnm, volta, mise,
/// bun or pyenv, and none of the keys exported in `~/.zshrc`. Agents started
/// from a terminal (Claude Code, Codex) have all of that, so servers that
/// work there read "command not found" or "Not checked" here. Like VS Code,
/// mcpock asks the login shell once (`$SHELL -l -i -c env -0`, 5 s at most)
/// and uses that as the base for starting servers and filling `${VAR}`.
/// Until it is read, or when the shell fails, mcpock's own environment stands in.
enum ShellEnvironment {
    private struct State {
        var loaded: [String: String]?
        var started = false
    }
    private static let state = OSAllocatedUnfairLock(initialState: State())

    /// Keys that describe the shell session that read the environment, not
    /// the user's setup: mcpock keeps its own values for these.
    static let sessionKeys: Set<String> = ["PWD", "OLDPWD", "SHLVL", "_", "TERM", "TERM_PROGRAM",
                                           "TERM_PROGRAM_VERSION", "TERM_SESSION_ID", "TMUX", "TMUX_PANE"]

    /// The environment to start servers with and fill `${VAR}` from.
    static var current: [String: String] {
        state.withLock { $0.loaded } ?? ProcessInfo.processInfo.environment
    }

    /// Reads the login shell once; later calls return at once.
    static func loadOnce(timeout: TimeInterval = 5) async {
        let first = state.withLock { state -> Bool in
            defer { state.started = true }
            return !state.started
        }
        guard first else { return }
        let login = await Task.detached(priority: .utility) { read(timeout: timeout) }.value
        guard let login else { return }
        let merged = merge(process: ProcessInfo.processInfo.environment, login: login)
        state.withLock { $0.loaded = merged }
    }

    /// The process environment with the login shell's values on top, except
    /// the shell-session keys. An empty PATH from the shell never replaces one.
    static func merge(process: [String: String], login: [String: String]) -> [String: String] {
        var env = process
        for (key, value) in login where !sessionKeys.contains(key) {
            if key == "PATH", value.isEmpty { continue }
            env[key] = value
        }
        return env
    }

    /// The marker printed before `env -0`, so anything an rc file prints first
    /// is skipped.
    static let marker = "__MCPOCK_ENV__"

    /// `NAME=value` pairs after the marker, NUL separated (values may hold newlines).
    static func parse(_ data: Data) -> [String: String]? {
        let markerData = Data((marker + "\0").utf8)
        guard let range = data.range(of: markerData) else { return nil }
        var env: [String: String] = [:]
        for chunk in data[range.upperBound...].split(separator: 0) {
            guard let line = String(data: Data(chunk), encoding: .utf8),
                  let equals = line.firstIndex(of: "="), equals != line.startIndex else { continue }
            env[String(line[..<equals])] = String(line[line.index(after: equals)...])
        }
        return env.isEmpty ? nil : env
    }

    /// The user's shell from the account database, then `$SHELL`, then zsh.
    static func loginShell() -> String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        if let shell = ProcessInfo.processInfo.environment["SHELL"],
           FileManager.default.isExecutableFile(atPath: shell) { return shell }
        return "/bin/zsh"
    }

    /// Runs the login shell with its output in a temporary file (a shell rc
    /// that leaves a background job holding a pipe can't hang the read), and
    /// stops it after `timeout`. Nil when it fails or prints nothing usable.
    static func read(shell: String = loginShell(), timeout: TimeInterval) -> [String: String]? {
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcpock-env-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: outURL.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let out = try? FileHandle(forWritingTo: outURL) else { return nil }
        defer {
            try? out.close()
            try? FileManager.default.removeItem(at: outURL)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-i", "-c", "printf '%s\\0' \(marker); /usr/bin/env -0"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            // What the shell's rc started too, or it outlives the check
            // (review 2026-10-30, aa31). Listed first: after the shell goes,
            // its children can't be found from its PID any more.
            let tree = ProcessRunner.treeSnapshot(of: process.processIdentifier)
            process.terminate()
            tree.filter(\.isStillTheSameProcess).forEach { kill($0.pid, SIGTERM) }
            if done.wait(timeout: .now() + 1) == .timedOut { kill(process.processIdentifier, SIGKILL) }
            tree.filter(\.isStillTheSameProcess).forEach { kill($0.pid, SIGKILL) }
            return nil
        }
        guard let data = try? Data(contentsOf: outURL) else { return nil }
        return parse(data)
    }
}
