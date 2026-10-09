import Foundation

enum HTTPProbe {
    static let probeTimeout: TimeInterval = 10

    /// Probe an HTTP/SSE MCP server via JSON-RPC POST.
    static func probe(config: ServerConfig, fetchTools: Bool) async -> ProbeResult {
        guard let helper = config.headersHelper, !helper.isEmpty else {
            return await probeResolved(config: config, fetchTools: fetchTools)
        }
        // Claude Code's headersHelper: fetch fresh headers first. A failing helper
        // is the server's error, not a misleading 401 from probing without them.
        let fetched = await HeadersHelper.run(
            helper: helper, serverName: config.name, serverURL: config.url ?? ""
        )
        switch fetched {
        case .failure(let error):
            return ProbeResult(
                state: .broken, failureReason: error.localizedDescription, tools: nil,
                transientFailure: false
            )
        case .success(let helperHeaders):
            let merged = config.withHeaders(HeadersHelper.merge(static: config.headers, helper: helperHeaders))
            let result = await probeResolved(config: merged, fetchTools: fetchTools)
            // A server may echo a header back in an error: the helper's values
            // never leave the probe, so scrub them from the reason here.
            let known = SecretMask.knownSecrets(env: [:], headers: helperHeaders)
            return ProbeResult(
                state: result.state,
                failureReason: result.failureReason.map { SecretMask.scrub($0, known: known) },
                tools: result.tools,
                transientFailure: result.transientFailure,
                needsAttention: result.needsAttention
            )
        }
    }

    private static func probeResolved(config: ServerConfig, fetchTools: Bool) async -> ProbeResult {
        guard let urlString = config.url, let url = URL(string: urlString) else {
            return ProbeResult(
                state: .broken,
                failureReason: ProbeError.invalidURL(config.url ?? "").localizedDescription,
                tools: nil
            )
        }

        // Legacy SSE transport: a GET opens the event stream and announces a POST
        // endpoint; responses arrive on the stream. Posting JSON-RPC straight to the
        // stream URL (what the streamable path does) answers 405 or hangs, so every
        // real SSE server used to probe as broken. Configs also mislabel streamable
        // servers as `sse`, so a URL that doesn't serve an event stream falls
        // through to the streamable probe below.
        if config.transport == .sse,
           let sse = await SSEProbe.probe(url: url, headers: config.headers, fetchTools: fetchTools) {
            return sse
        }

        // Headers for the session opened by initialize, kept for the final cleanup
        // DELETE even when a later step throws.
        var sessionHeaders: [String: String]?

        let result: ProbeResult
        do {
            let initBody = try MCPJSONRPC.encode(MCPJSONRPC.initializeRequest(id: 1))
            let (initResponse, sessionId) = try await postJSON(url: url, body: initBody, headers: config.headers)
            try MCPJSONRPC.validateInitializeResponse(initResponse)

            // Streamable-HTTP servers assign an Mcp-Session-Id on initialize and reject
            // follow-up requests that omit it. Replay it plus the negotiated protocol version.
            var headers = config.headers
            if headers["MCP-Protocol-Version"] == nil {
                headers["MCP-Protocol-Version"] = MCPJSONRPC.protocolVersion
            }
            if let sessionId {
                headers["Mcp-Session-Id"] = sessionId
                sessionHeaders = headers
            }

            // Best-effort initialized notification (some servers require it)
            if let notifyBody = try? MCPJSONRPC.encode(MCPJSONRPC.initializedNotification()) {
                _ = try? await postJSON(url: url, body: notifyBody, headers: headers, expectResponse: false)
            }

            var tools: [MCPToolInfo]?
            if fetchTools {
                let toolsBody = try MCPJSONRPC.encode(MCPJSONRPC.toolsListRequest(id: 2))
                let (toolsResponse, _) = try await postJSON(url: url, body: toolsBody, headers: headers)
                tools = try MCPJSONRPC.parseTools(from: toolsResponse)
            }

            result = ProbeResult(state: .healthy, failureReason: nil, tools: tools)
        } catch {
            result = ProbeResult(
                state: .broken,
                failureReason: (error as? ProbeError)?.localizedDescription ?? error.localizedDescription,
                tools: nil,
                transientFailure: isTransient(error),
                needsAttention: (error as? ProbeError)?.needsAttention ?? false
            )
        }

        // End the session the probe opened (streamable HTTP: DELETE with the session
        // id) so a probe every minute doesn't accumulate server-side sessions.
        // Best-effort — servers without session teardown answer 405 and that's fine.
        if let sessionHeaders {
            await closeSession(url: url, headers: sessionHeaders)
        }
        return result
    }

    /// Best-effort session teardown; errors are irrelevant to the probe verdict.
    private static func closeSession(url: URL, headers: [String: String]) async {
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "DELETE"
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        _ = try? await URLSession.shared.data(for: request)
    }

    /// A slow-starting or momentarily-unreachable HTTP server is transient (smoothed to amber);
    /// an explicit protocol/HTTP error is definitive.
    static func isTransient(_ error: Error) -> Bool {
        if let probeError = error as? ProbeError { return probeError.isTransient }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet:
                return true
            default:
                return false
            }
        }
        return false
    }

    /// POST a JSON-RPC body and return the parsed response plus any Mcp-Session-Id header.
    private static func postJSON(
        url: URL,
        body: Data,
        headers: [String: String],
        expectResponse: Bool = true
    ) async throws -> (json: [String: Any], sessionId: String?) {
        var request = URLRequest(url: url, timeoutInterval: probeTimeout)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProbeError.protocolError("Invalid HTTP response")
        }

        let sessionId = http.value(forHTTPHeaderField: "Mcp-Session-Id")

        if !(200...299).contains(http.statusCode) {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw ProbeError.httpError(http.statusCode, bodyText)
        }

        if !expectResponse {
            return ([:], sessionId)
        }

        if data.isEmpty {
            throw ProbeError.noData
        }

        // SSE-style response: extract data: lines
        if let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
           contentType.contains("text/event-stream") {
            return (try parseSSEJSON(data), sessionId)
        }

        // Some servers return SSE without the content type; detect "data:" prefix.
        if let text = String(data: data, encoding: .utf8), text.contains("data:") {
            if let parsed = try? parseSSEJSON(data) {
                return (parsed, sessionId)
            }
        }

        return (try MCPJSONRPC.parseJSONObject(data), sessionId)
    }

    static func parseSSEJSON(_ data: Data) throws -> [String: Any] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw ProbeError.protocolError("Invalid SSE encoding")
        }
        var lastJSON: [String: Any]?
        // Split on any line ending, not the Character "\n": Swift treats "\r\n" as one
        // Character, so servers that end SSE lines with CRLF (sse-starlette, e.g.
        // The Board) came through as a single line and probed as broken.
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("data:") else { continue }
            let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload.isEmpty || payload == "[DONE]" { continue }
            if let payloadData = payload.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] {
                lastJSON = obj
                // Prefer responses with id/result/error
                if obj["result"] != nil || obj["error"] != nil {
                    return obj
                }
            }
        }
        if let lastJSON { return lastJSON }
        throw ProbeError.protocolError("No JSON in SSE stream")
    }
}
