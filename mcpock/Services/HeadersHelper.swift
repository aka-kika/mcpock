import Foundation

/// Runs Claude Code's `headersHelper` for an http/sse MCP entry: a shell command
/// whose stdout is a JSON object of HTTP headers (usually a fresh bearer token).
///
/// Secrets: what the helper prints is returned to the probe and nowhere else.
/// It is never logged, stored or put in an error; a failure is one of the fixed
/// phrases below, and its stderr is never read.
enum HeadersHelper {
    /// Claude Code gives a helper 10 seconds.
    static let timeout: Duration = .seconds(10)

    /// Run `helper` through `/bin/sh -c`, as Claude Code does, with the server's
    /// name and URL in the same two environment variables. Always reaps the
    /// process tree (a helper that shells out to `security`, `op`, `curl`...).
    static func run(
        helper: String, serverName: String, serverURL: String, timeout: Duration = HeadersHelper.timeout
    ) async -> Result<[String: String], ProbeError> {
        let runner: ProcessRunner
        do {
            runner = try ProcessRunner(
                command: "/bin/sh", args: ["-c", helper],
                env: ["CLAUDE_CODE_MCP_SERVER_NAME": serverName, "CLAUDE_CODE_MCP_SERVER_URL": serverURL],
                capturesRawStdout: true
            )
        } catch {
            return .failure(.headerHelper("failed: could not start"))
        }

        let deadline = ContinuousClock.now + timeout
        while runner.isRunning, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let timedOut = runner.isRunning
        if !timedOut {
            // Exited: let the stdout reader deliver the last bytes (bounded, a
            // grandchild could hold the pipe open).
            let readDeadline = ContinuousClock.now + .milliseconds(500)
            while !runner.stdoutDidFinish, ContinuousClock.now < readDeadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        let output = runner.rawStdout
        // terminationStatus traps on a running process: read it only after an exit.
        let status: Int32 = timedOut ? -1 : runner.terminationStatus
        let normalExit = !timedOut && runner.exitedNormally
        await runner.terminateAndReap()

        if timedOut {
            let seconds = Int(timeout.components.seconds)
            return .failure(.headerHelper("timed out after \(seconds) s"))
        }
        guard normalExit, status == 0 else {
            return .failure(.headerHelper("failed: exit \(status)"))
        }
        guard let headers = parse(output) else {
            return .failure(.headerHelper("did not return JSON"))
        }
        return .success(headers)
    }

    /// A JSON object whose values are all strings, or nil.
    static func parse(_ data: Data) -> [String: String]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var result: [String: String] = [:]
        for (name, value) in object {
            guard let text = value as? String else { return nil }
            result[name] = text
        }
        return result
    }

    /// Static headers with the helper's on top. Header names are
    /// case-insensitive, so a helper `authorization` replaces a static `Authorization`.
    static func merge(static staticHeaders: [String: String], helper: [String: String]) -> [String: String] {
        var merged = staticHeaders
        for name in helper.keys {
            for existing in merged.keys where existing.caseInsensitiveCompare(name) == .orderedSame {
                merged[existing] = nil
            }
        }
        for (name, value) in helper { merged[name] = value }
        return merged
    }
}
