import Foundation

/// Probe for the legacy MCP **SSE** transport (`"type": "sse"`, Goose `type: sse`).
///
/// The client GETs the server URL with `Accept: text/event-stream`; the server
/// answers with an `endpoint` event carrying the URL to POST JSON-RPC to, and
/// every response comes back as a `message` event on that same stream. So a probe
/// is: open the stream, read the endpoint, POST `initialize`, wait for its
/// response on the stream, POST `notifications/initialized`, optionally POST
/// `tools/list` and wait again, then drop the stream.
enum SSEProbe {
    static let probeTimeout: Duration = .seconds(10)
    /// How long the stream may stay silent before its `endpoint` event. A
    /// legacy SSE server sends it at once; a streamable-HTTP server labelled
    /// `sse` may answer the GET with an event stream and never send one, and
    /// then the caller falls back to the streamable probe (Argon 2026-10-17 #3).
    static let endpointTimeout: Duration = .seconds(3)

    /// `nil` when the URL is not a legacy SSE endpoint (no 2xx `text/event-stream`
    /// answer to the GET, or a stream that never announces an endpoint) — the
    /// caller then tries the streamable-HTTP probe instead, because configs
    /// routinely label streamable servers `sse`.
    static func probe(url: URL, headers: [String: String], fetchTools: Bool) async -> ProbeResult? {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await ProbeSession.shared.bytes(for: request)
        } catch {
            return ProbeResult(state: .broken, failureReason: error.localizedDescription, tools: nil,
                               transientFailure: HTTPProbe.isTransient(error))
        }
        // The event stream stays open until cancelled: close it on every way
        // out, the early ones included, so a probe each cycle can't leave
        // half-open connections behind (review, 2026-09-26).
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { return nil }
        if ProbeError.isAuthCode(http.statusCode) {
            let error = ProbeError.httpError(http.statusCode, "")
            return ProbeResult(state: .broken, failureReason: error.localizedDescription, tools: nil,
                               needsAttention: true)
        }
        let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        guard (200...299).contains(http.statusCode), contentType.contains("text/event-stream") else {
            return nil
        }

        let endpoint = EndpointSeen()
        do {
            let result = try await withThrowingTaskGroup(of: ProbeResult.self) { group in
                group.addTask {
                    try await handshake(stream: bytes, base: url, headers: headers, fetchTools: fetchTools, endpoint: endpoint)
                }
                group.addTask {
                    try await Task.sleep(for: endpointTimeout)
                    if !endpoint.seen { throw ProbeError.protocolError("SSE stream sent no endpoint event") }
                    try await Task.sleep(for: probeTimeout - endpointTimeout)
                    throw ProbeError.timeout(probeTimeout)
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
            return result
        } catch {
            // An event stream with no endpoint is not a legacy SSE server, and
            // one that points somewhere else gets the normal HTTP check.
            if !endpoint.seen || error is ForeignEndpoint { return nil }
            return ProbeResult(
                state: .broken,
                failureReason: (error as? ProbeError)?.localizedDescription ?? error.localizedDescription,
                tools: nil,
                transientFailure: HTTPProbe.isTransient(error),
                needsAttention: (error as? ProbeError)?.needsAttention ?? false
            )
        }
    }

    // MARK: - Handshake over the stream

    private typealias Lines = AsyncLineSequence<URLSession.AsyncBytes>.AsyncIterator

    /// Set once the stream announced its POST endpoint.
    private final class EndpointSeen: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var seen: Bool {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    private static func handshake(
        stream: URLSession.AsyncBytes, base: URL, headers: [String: String], fetchTools: Bool, endpoint seen: EndpointSeen
    ) async throws -> ProbeResult {
        var lines = stream.lines.makeAsyncIterator()

        guard let endpointText = try await nextEvent(&lines, named: "endpoint")?.data else {
            throw ProbeError.protocolError("SSE stream sent no endpoint event")
        }
        seen.seen = true
        guard let endpoint = URL(string: endpointText.trimmingCharacters(in: .whitespaces), relativeTo: base)?.absoluteURL
        else { throw ProbeError.invalidURL(endpointText) }
        // The endpoint gets the config's headers (API keys), so it must be the
        // server the config names, not any host the stream mentions (review
        // 2026-10-20, 7676).
        guard isSameOrigin(endpoint, as: base) else { throw ForeignEndpoint() }

        try await post(MCPJSONRPC.initializeRequest(id: 1), to: endpoint, headers: headers)
        try MCPJSONRPC.validateInitializeResponse(try await nextResponse(&lines, id: 1))
        try await post(MCPJSONRPC.initializedNotification(), to: endpoint, headers: headers)

        var tools: [MCPToolInfo]?
        if fetchTools {
            try await post(MCPJSONRPC.toolsListRequest(id: 2), to: endpoint, headers: headers)
            tools = try MCPJSONRPC.parseTools(from: try await nextResponse(&lines, id: 2))
        }
        return ProbeResult(state: .healthy, failureReason: nil, tools: tools)
    }

    /// The stream named an endpoint on another scheme, host or port.
    private struct ForeignEndpoint: Error {}

    /// Same scheme (http or https), host and port as the configured URL.
    static func isSameOrigin(_ endpoint: URL, as base: URL) -> Bool {
        guard let scheme = endpoint.scheme?.lowercased(), ["http", "https"].contains(scheme),
              scheme == base.scheme?.lowercased(),
              let host = endpoint.host, let baseHost = base.host,
              host.caseInsensitiveCompare(baseHost) == .orderedSame
        else { return false }
        let defaultPort = scheme == "https" ? 443 : 80
        return (endpoint.port ?? defaultPort) == (base.port ?? defaultPort)
    }

    /// One parsed SSE event: `event:` name (default `message`) and its `data:` line.
    private struct Event {
        let name: String
        let data: String
    }

    /// Read the next event, or the next one with a given name.
    ///
    /// `AsyncLineSequence` swallows the blank lines that delimit SSE events, so an
    /// event is taken as complete at its `data:` line; the `event:` line before it
    /// names it. A message whose JSON is split over several `data:` lines is
    /// joined with newlines, as SSE says, until it reads as one JSON object
    /// (review 2026-10-20, 8c5b; the HTTP probe's streamed answers do the same).
    private static func nextEvent(_ lines: inout Lines, named wanted: String? = nil) async throws -> Event? {
        var name = "message"
        var pending: String?
        while let line = try await lines.next() {
            if line.isEmpty || line.hasPrefix(":") { continue }   // keep-alive / comment
            guard let colon = line.firstIndex(of: ":") else { continue }
            let field = line[..<colon]
            var value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
            switch field {
            case "event":
                name = String(value)
                pending = nil
            case "data":
                let data = pending.map { $0 + "\n" + value } ?? String(value)
                // The endpoint is plain text on one line; a message is JSON.
                if name != "endpoint", (try? MCPJSONRPC.parseJSONObject(Data(data.utf8))) == nil,
                   data.utf8.count <= MCPMessageBuffer.maxBodyBytes {
                    pending = data
                    continue
                }
                let event = Event(name: name, data: data)
                name = "message"
                pending = nil
                if wanted == nil || event.name == wanted { return event }
            default:
                break
            }
        }
        throw ProbeError.noData
    }

    /// Skip notifications and unrelated events until the response to `id` arrives.
    private static func nextResponse(_ lines: inout Lines, id: Int) async throws -> [String: Any] {
        while let event = try await nextEvent(&lines) {
            guard let data = event.data.data(using: .utf8),
                  let message = try? MCPJSONRPC.parseJSONObject(data) else { continue }
            if MCPJSONRPC.isResponse(message, to: id) { return message }
        }
        throw ProbeError.noData
    }

    /// POST one JSON-RPC message to the announced endpoint; the answer (if any)
    /// comes back on the stream, so only the status code matters here.
    private static func post(_ message: [String: Any], to endpoint: URL, headers: [String: String]) async throws {
        var request = URLRequest(url: endpoint, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.httpBody = try MCPJSONRPC.encode(message)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await ProbeSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProbeError.protocolError("Invalid HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw ProbeError.httpError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }
}
