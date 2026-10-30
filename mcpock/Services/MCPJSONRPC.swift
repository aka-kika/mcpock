import Foundation

enum MCPJSONRPC {
    static let protocolVersion = "2024-11-05"
    /// Every probe sends `initialize` with this id.
    static let initializeID = 1
    static let clientName = "mcpock"
    /// Reported to servers in `clientInfo`; tracks the app version so it can't drift.
    static let clientVersion =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    static func initializeRequest(id: Int, protocolVersion: String = protocolVersion) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id,
            "method": "initialize",
            "params": [
                "protocolVersion": protocolVersion,
                "capabilities": [String: Any](),
                "clientInfo": [
                    "name": clientName,
                    "version": clientVersion,
                ],
            ] as [String: Any],
        ]
    }

    static func initializedNotification() -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
        ]
    }

    static func toolsListRequest(id: Int) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id,
            "method": "tools/list",
            "params": [String: Any](),
        ]
    }

    static func encode(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [])
    }

    /// Newline-delimited JSON message — the MCP stdio transport framing.
    /// (MCP stdio is NDJSON, not LSP-style Content-Length; real servers ignore the latter.)
    static func encodeLine(_ object: [String: Any]) throws -> Data {
        var message = try encode(object)
        message.append(0x0A) // "\n"
        return message
    }

    /// True when `message` is the JSON-RPC *response* to request `id` — and not a
    /// server-initiated notification or request interleaved before it (e.g. a
    /// `notifications/message` log line, which is valid MCP traffic mid-handshake).
    static func isResponse(_ message: [String: Any], to id: Int) -> Bool {
        guard message["result"] != nil || message["error"] != nil else { return false }
        if let number = message["id"] as? NSNumber { return number.intValue == id }
        if let string = message["id"] as? String { return string == String(id) }
        // An error with a null id is the server's answer to a request it could
        // not read (a parse or version error): the reply, with its real
        // message, not a wait until the timeout (review 2026-10-20, 7243). Only
        // while waiting for initialize: later, a null-id error is a server
        // refusing something else (the initialized notice) and must not stand
        // in for the answer to tools/list (r3 f730).
        return id == initializeID && message["error"] != nil && (message["id"] == nil || message["id"] is NSNull)
    }

    /// The message of an error with a null id: a server's answer to something
    /// it could not read, or nil for anything else.
    static func nullIDError(_ message: [String: Any]) -> String? {
        guard message["id"] == nil || message["id"] is NSNull,
              let error = message["error"] as? [String: Any] else { return nil }
        return error["message"] as? String ?? "Error with no id"
    }

    static func parseJSONObject(_ data: Data) throws -> [String: Any] {
        let obj = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dict = obj as? [String: Any] else {
            throw ProbeError.protocolError("Expected JSON object")
        }
        return dict
    }

    static func parseTools(from response: [String: Any]) throws -> [MCPToolInfo] {
        if let error = response["error"] as? [String: Any] {
            let message = error["message"] as? String ?? String(describing: error)
            throw ProbeError.protocolError(message)
        }
        guard let result = response["result"] as? [String: Any] else {
            throw ProbeError.protocolError("tools/list missing result")
        }
        let toolsArray = (result["tools"] as? [[String: Any]]) ?? []
        return toolsArray.compactMap { tool in
            guard let name = tool["name"] as? String else { return nil }
            let description = tool["description"] as? String ?? ""
            return MCPToolInfo(name: name, description: description)
        }
    }

    /// The protocol version a server that refused `sent` names as one it
    /// speaks, in the error's `data` (`supported`, `supportedVersions`,
    /// `protocolVersion`) or its message; the newest if it names several. The
    /// probe asks once more with it (r3 a1f3). `nil` when the answer is not an
    /// error or names nothing else. A result that names another version is not
    /// retried: the server already answered, and `negotiatedVersion` reads it.
    static func retryVersion(after response: [String: Any], sent: String) -> String? {
        guard let error = response["error"] as? [String: Any] else { return nil }
        var found: [String] = []
        if let data = error["data"] as? [String: Any] {
            for key in ["supported", "supportedVersions", "supported_versions", "protocolVersion", "supportedVersion"] {
                if let one = data[key] as? String { found.append(one) }
                if let many = data[key] as? [String] { found += many }
            }
        }
        // Dates only, so a free-text field cannot send the probe anywhere odd.
        let text = (error["message"] as? String ?? "") + " " + String(describing: error["data"] ?? "")
        if let dates = try? NSRegularExpression(pattern: versionPattern) {
            found += dates.matches(in: text, range: NSRange(text.startIndex..., in: text))
                .compactMap { Range($0.range, in: text).map { String(text[$0]) } }
        }
        return found.filter { $0 != sent && isVersion($0) }.max()
    }

    /// The version the server answered initialize with, else what was asked.
    static func negotiatedVersion(_ response: [String: Any], sent: String) -> String {
        let named = (response["result"] as? [String: Any])?["protocolVersion"] as? String
        return named.flatMap { isVersion($0) ? $0 : nil } ?? sent
    }

    private static let versionPattern = "[0-9]{4}-[0-9]{2}-[0-9]{2}"

    private static func isVersion(_ text: String) -> Bool {
        text.range(of: "^" + versionPattern + "$", options: .regularExpression) != nil
    }

    static func validateInitializeResponse(_ response: [String: Any]) throws {
        if let error = response["error"] as? [String: Any] {
            let message = error["message"] as? String ?? String(describing: error)
            throw ProbeError.handshakeRejected(message)
        }
        guard response["result"] != nil else {
            throw ProbeError.handshakeRejected("Missing result in initialize response")
        }
    }
}
