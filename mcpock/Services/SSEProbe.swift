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
    static func probe(
        url: URL, headers: [String: String], fetchTools: Bool,
        deadline: ContinuousClock.Instant = ContinuousClock.now + probeTimeout
    ) async -> ProbeResult? {
        var request = URLRequest(url: url, timeoutInterval: (try? HTTPProbe.timeoutInterval(until: deadline, cap: 10)) ?? 0.001)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")   // last, as in HTTPProbe (r3 3c71)

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
                    try await handshake(
                        stream: bytes, base: url, headers: headers, fetchTools: fetchTools, endpoint: endpoint,
                        deadline: deadline
                    )
                }
                group.addTask {
                    try await Task.sleep(for: min(endpointTimeout, deadline - ContinuousClock.now))
                    if !endpoint.seen { throw ProbeError.protocolError("SSE stream sent no endpoint event") }
                    try await Task.sleep(until: deadline, clock: .continuous)
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
        stream: URLSession.AsyncBytes, base: URL, headers: [String: String], fetchTools: Bool, endpoint seen: EndpointSeen,
        deadline: ContinuousClock.Instant
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

        try await post(MCPJSONRPC.initializeRequest(id: MCPJSONRPC.initializeID), to: endpoint, headers: headers, deadline: deadline)
        var initResponse = try await nextResponse(&lines, id: MCPJSONRPC.initializeID)
        // A server that refuses our protocol version names the one it speaks:
        // ask once more with it (r3 a1f3).
        if let retry = MCPJSONRPC.retryVersion(after: initResponse, sent: MCPJSONRPC.protocolVersion) {
            try await post(
                MCPJSONRPC.initializeRequest(id: MCPJSONRPC.initializeID, protocolVersion: retry),
                to: endpoint, headers: headers, deadline: deadline)
            initResponse = try await nextResponse(&lines, id: MCPJSONRPC.initializeID)
        }
        try MCPJSONRPC.validateInitializeResponse(initResponse)
        try await post(
            MCPJSONRPC.initializedNotification(), to: endpoint, headers: headers, deadline: deadline,
            timeout: HTTPProbe.notificationTimeout
        )

        var tools: [MCPToolInfo]?
        if fetchTools {
            try await post(MCPJSONRPC.toolsListRequest(id: 2), to: endpoint, headers: headers, deadline: deadline)
            tools = try MCPJSONRPC.parseTools(from: try await nextResponse(&lines, id: 2))
        }
        return ProbeResult(state: .healthy, failureReason: nil, tools: tools)
    }

    /// The stream named an endpoint on another scheme, host or port.
    private struct ForeignEndpoint: Error {}

    /// Same scheme (http or https), host and port as the configured URL.
    /// localhost, 127.0.0.1 and ::1 count as one host: a local server often
    /// announces its endpoint under another name than the config uses (r3 d0d1).
    static func isSameOrigin(_ endpoint: URL, as base: URL) -> Bool {
        guard let scheme = endpoint.scheme?.lowercased(), ["http", "https"].contains(scheme),
              scheme == base.scheme?.lowercased(),
              let host = endpoint.host, let baseHost = base.host,
              canonicalHost(host) == canonicalHost(baseHost)
        else { return false }
        let defaultPort = scheme == "https" ? 443 : 80
        return (endpoint.port ?? defaultPort) == (base.port ?? defaultPort)
    }

    private static func canonicalHost(_ host: String) -> String {
        let lower = host.lowercased()
        return ["localhost", "127.0.0.1", "::1"].contains(lower) ? "localhost" : lower
    }

    /// The most a message split over `data:` lines may grow while waiting for
    /// its closing brace. Past it the text goes out as it is (it will not parse
    /// and is skipped), so a stream that never closes cannot grow without end.
    /// A real tools list, pretty-printed, can be a few hundred KB.
    static let maxJoinedBytes = 1024 * 1024

    /// Follows `{` and `}` (and brackets) through text a line at a time,
    /// ignoring those inside strings, so a split message is known to be
    /// complete without parsing it again.
    struct BraceScanner {
        private var depth = 0
        private var inString = false
        private var escaped = false

        var isOpen: Bool { depth > 0 }

        mutating func feed(_ text: Substring) {
            for byte in text.utf8 {
                if inString {
                    if escaped { escaped = false } else if byte == 0x5C { escaped = true } else if byte == 0x22 { inString = false }
                    continue
                }
                switch byte {
                case 0x22: inString = true
                case 0x7B, 0x5B: depth += 1
                case 0x7D, 0x5D: depth = max(0, depth - 1)
                default: break
                }
            }
            // A raw newline cannot sit inside a JSON string: one still open here is malformed.
            inString = false
            escaped = false
        }
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
    /// joined with newlines, as SSE says, until its braces close (review
    /// 2026-10-20, 8c5b). Each line is scanned once and the pieces are joined
    /// once: re-parsing the growing text on every line burned a core on a
    /// chatty stream (r3 669e).
    private static func nextEvent(_ lines: inout Lines, named wanted: String? = nil) async throws -> Event? {
        var name = "message"
        var pending: [Substring] = []
        var pendingBytes = 0
        var scanner = BraceScanner()
        while let line = try await lines.next() {
            if line.isEmpty || line.hasPrefix(":") { continue }   // keep-alive / comment
            guard let colon = line.firstIndex(of: ":") else { continue }
            let field = line[..<colon]
            var value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
            switch field {
            case "event":
                name = String(value)
                pending = []
                pendingBytes = 0
                scanner = BraceScanner()
            case "data":
                pending.append(value)
                pendingBytes += value.utf8.count + 1
                // The endpoint is plain text on one line; a message is JSON.
                if name != "endpoint" {
                    scanner.feed(value)
                    if scanner.isOpen, pendingBytes <= maxJoinedBytes { continue }
                }
                let event = Event(name: name, data: pending.joined(separator: "\n"))
                name = "message"
                pending = []
                pendingBytes = 0
                scanner = BraceScanner()
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
    private static func post(
        _ message: [String: Any], to endpoint: URL, headers: [String: String],
        deadline: ContinuousClock.Instant, timeout: TimeInterval = 10
    ) async throws {
        var request = URLRequest(url: endpoint, timeoutInterval: try HTTPProbe.timeoutInterval(until: deadline, cap: timeout))
        request.httpMethod = "POST"
        request.httpBody = try MCPJSONRPC.encode(message)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await ProbeSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProbeError.protocolError("Invalid HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw ProbeError.httpError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }
}
