import Foundation

enum StdioProbe {
    /// 20 s, up from 10: `hermes mcp serve` needs about 9 s to answer, and
    /// `npx -y mcp-remote@latest` goes past 10 s while it renews a login. Total
    /// budget for one attempt (initialize and tools/list together).
    static let probeTimeout: Duration = .seconds(20)

    /// Probe a stdio MCP server. A timeout is retried once, at once, with a fresh
    /// process: a cold npx cache or a login renewal usually answers the second
    /// time. If the retry answers, the server is healthy and the result carries
    /// `slowStartSeconds` (how long the first attempt waited) for an info note,
    /// never a problem. Two timeouts report the retry's failure, transient, so
    /// health smoothing still shows amber first and red on a repeat.
    ///
    /// The first attempt's process is fully reaped (`terminateAndReap`, whole
    /// tree) before the retry spawns, so a retry never leaves an orphan.
    /// Worst case for one server: 2 x `timeout`.
    static func probe(
        config: ServerConfig,
        fetchTools: Bool,
        timeout: Duration = probeTimeout
    ) async -> ProbeResult {
        let clock = ContinuousClock()
        let start = clock.now
        let first = await attempt(config: config, fetchTools: fetchTools, timeout: timeout)
        guard first.state == .broken, first.transientFailure, !Task.isCancelled else { return first }

        let waited = clock.now - start
        let second = await attempt(config: config, fetchTools: fetchTools, timeout: timeout)
        guard second.state == .healthy else { return second }
        return ProbeResult(
            state: .healthy,
            failureReason: nil,
            tools: second.tools,
            slowStartSeconds: Double(waited.components.seconds)
                + Double(waited.components.attoseconds) / 1e18
        )
    }

    /// One try: spawn → initialize → (optional tools/list) → terminate.
    private static func attempt(
        config: ServerConfig,
        fetchTools: Bool,
        timeout: Duration
    ) async -> ProbeResult {
        guard let command = config.command, !command.isEmpty else {
            return ProbeResult(
                state: .broken,
                failureReason: ProbeError.spawnFailed("Missing command").localizedDescription,
                tools: nil
            )
        }

        let deadline = ContinuousClock.now + timeout
        var runner: ProcessRunner?
        var initialized = false
        do {
            let process = try ProcessRunner(
                command: command,
                args: config.args,
                env: config.env,
                workingDirectory: config.projectPath
            )
            runner = process

            // initialize
            let initMsg = try MCPJSONRPC.encodeLine(MCPJSONRPC.initializeRequest(id: 1))
            try process.write(initMsg)

            var initResponse = try await readResponse(from: process, id: 1, deadline: deadline, limit: timeout)
            // A server that refuses our protocol version names the one it speaks:
            // ask once more with it (r3 a1f3).
            if let retry = MCPJSONRPC.retryVersion(after: initResponse, sent: MCPJSONRPC.protocolVersion) {
                try process.write(MCPJSONRPC.encodeLine(MCPJSONRPC.initializeRequest(id: 1, protocolVersion: retry)))
                initResponse = try await readResponse(from: process, id: 1, deadline: deadline, limit: timeout)
            }
            try MCPJSONRPC.validateInitializeResponse(initResponse)
            initialized = true

            // notifications/initialized
            let notified = try MCPJSONRPC.encodeLine(MCPJSONRPC.initializedNotification())
            try process.write(notified)

            var tools: [MCPToolInfo]?
            if fetchTools {
                let toolsMsg = try MCPJSONRPC.encodeLine(MCPJSONRPC.toolsListRequest(id: 2))
                try process.write(toolsMsg)
                let toolsResponse = try await readResponse(from: process, id: 2, deadline: deadline, limit: timeout)
                tools = try MCPJSONRPC.parseTools(from: toolsResponse)
            }

            await process.terminateAndReap()
            runner = nil

            return ProbeResult(state: .healthy, failureReason: nil, tools: tools)
        } catch {
            await runner?.terminateAndReap()
            // A timeout on a still-running process (e.g. a slow cold-start) is transient;
            // spawn errors / non-zero exits are definitive.
            let transient = (error as? ProbeError)?.isTransient ?? false
            return ProbeResult(
                state: .broken,
                failureReason: failureReason(for: error, runner: runner, initialized: initialized),
                tools: nil,
                transientFailure: transient
            )
        }
    }

    /// Read messages until the response to request `id` arrives, skipping any
    /// server-initiated notifications/requests in between. `deadline` is a total
    /// budget for the whole attempt, however many messages precede the response.
    private static func readResponse(
        from process: ProcessRunner,
        id: Int,
        deadline: ContinuousClock.Instant,
        limit: Duration
    ) async throws -> [String: Any] {
        // A null-id error can't stand in for the answer to tools/list (r3 f730),
        // but if the answer never comes it is what the server had to say: better
        // than "Timed out" (review 2026-10-30, 1266).
        var refusal: String?
        while true {
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else {
                throw refusal.map(ProbeError.protocolError) ?? ProbeError.timeout(limit)
            }
            let data: Data
            do {
                data = try await process.readMessage(timeout: remaining)
            } catch ProbeError.timeout {
                // The whole attempt's budget, not what was left of it: a slow
                // initialize used to read "No answer in 12 s" (review 2026-10-30, 2cbb).
                throw refusal.map(ProbeError.protocolError) ?? ProbeError.timeout(limit)
            }
            // A line that only looks like JSON (a banner such as
            // `{path: .env}`) is noise, not a broken server (Argon 2026-10-17 #1).
            guard let message = try? MCPJSONRPC.parseJSONObject(data) else { continue }
            if MCPJSONRPC.isResponse(message, to: id) {
                return message
            }
            refusal = MCPJSONRPC.nullIDError(message) ?? refusal
        }
    }

    /// Build a human-readable failure reason: prefer a non-zero exit code when the
    /// server died on its own, and append its stderr reason when present — the
    /// first line that looks like the real error (if the tail alone wouldn't
    /// show it), then the tail.
    private static func failureReason(for error: Error, runner: ProcessRunner?, initialized: Bool) -> String {
        var head = (error as? ProbeError)?.localizedDescription ?? error.localizedDescription

        // If the process exited on its own (not killed by a signal — ours or anyone
        // else's), surface its exit code. `terminationReason` distinguishes a real
        // `exit(15)` from a SIGTERM, which raw status-code comparison cannot.
        if let runner, (error as? ProbeError)?.isTransient != true, !runner.isRunning, runner.exitedNormally {
            let status = runner.terminationStatus
            if status != 0 {
                let exit: ProbeError = initialized ? .exitedAfterStart(status) : .nonZeroExit(status)
                head = exit.localizedDescription
            }
        }

        let reason = runner?.stderrReason() ?? ""
        return reason.isEmpty ? head : "\(head) — \(reason)"
    }
}
