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

            let initResponse = try await readResponse(from: process, id: 1, deadline: deadline, limit: timeout)
            try MCPJSONRPC.validateInitializeResponse(initResponse)

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
                failureReason: failureReason(for: error, runner: runner),
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
        while true {
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else { throw ProbeError.timeout(limit) }
            let data = try await process.readMessage(timeout: remaining)
            let message = try MCPJSONRPC.parseJSONObject(data)
            if MCPJSONRPC.isResponse(message, to: id) {
                return message
            }
        }
    }

    /// Build a human-readable failure reason: prefer a non-zero exit code when the
    /// server died on its own, and append its stderr reason when present — the
    /// first line that looks like the real error (if the tail alone wouldn't
    /// show it), then the tail.
    private static func failureReason(for error: Error, runner: ProcessRunner?) -> String {
        var head = (error as? ProbeError)?.localizedDescription ?? error.localizedDescription

        // If the process exited on its own (not killed by a signal — ours or anyone
        // else's), surface its exit code. `terminationReason` distinguishes a real
        // `exit(15)` from a SIGTERM, which raw status-code comparison cannot.
        if let runner, !runner.isRunning, runner.exitedNormally {
            let status = runner.terminationStatus
            if status != 0 {
                head = ProbeError.nonZeroExit(status).localizedDescription
            }
        }

        let reason = runner?.stderrReason() ?? ""
        return reason.isEmpty ? head : "\(head) — \(reason)"
    }
}
