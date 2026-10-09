import Foundation

/// The MCP side of the `mcpock-mcp` helper (round 7): one newline-delimited
/// JSON-RPC message in, at most one out. Read-only by design: its three tools
/// only read mcpock's status file, never probe a server, never write anything.
///
/// Lives in `Shared/` (compiled into the app too) so `MCPStatusServerTests`
/// drives it without spawning the helper; `main.swift` is only the stdin loop.
struct MCPStatusServer {
    /// Protocol versions this server can speak; it answers with the client's
    /// if listed, else the newest. The tools use nothing version-specific.
    static let supportedVersions = ["2025-06-18", "2025-03-26", MCPJSONRPC.protocolVersion]
    static let serverName = "mcpock"

    static let instructions = """
        mcpock is a macOS menu bar app that checks the MCP servers the user's agents use. \
        Call mcpock_problems when the user says "check my mcpock" (or asks what is wrong with their \
        MCP servers), then fix what it reports in the config files it names. Everything here is read-only.
        """

    var loadStatus: () -> StatusLoad
    var now: () -> Date = Date.init
    var isRunning: (Int32) -> Bool = MCPStatusServer.processIsAlive
    var version: String = MCPJSONRPC.clientVersion

    /// Handle one line. Returns the response line (no trailing newline), or nil
    /// for notifications and blank lines.
    func handle(line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let message = try? MCPJSONRPC.parseJSONObject(data) else {
            return encode(error: -32700, message: "Parse error", id: NSNull())
        }
        guard let method = message["method"] as? String else {
            // A response to something we never sent; nothing to say.
            return nil
        }
        let id = message["id"]
        // Notifications (no id) never get an answer.
        guard let id, !(id is NSNull) else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String
            let version = asked.flatMap { Self.supportedVersions.contains($0) ? $0 : nil }
                ?? Self.supportedVersions[0]
            return encode(result: [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": Self.serverName, "title": "mcpock", "version": self.version],
                "instructions": Self.instructions,
            ], id: id)
        case "ping":
            return encode(result: [String: Any](), id: id)
        case "tools/list":
            return encode(result: ["tools": Self.tools], id: id)
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            guard let text = callTool(name, arguments: arguments) else {
                return encode(error: -32602, message: "Unknown tool: \(name)", id: id)
            }
            return encode(result: ["content": [["type": "text", "text": text]], "isError": false], id: id)
        case "resources/list":
            return encode(result: ["resources": [Any]()], id: id)
        case "prompts/list":
            return encode(result: ["prompts": [Any]()], id: id)
        default:
            return encode(error: -32601, message: "Method not found: \(method)", id: id)
        }
    }

    /// The tool's text, or nil for a name this server doesn't have.
    func callTool(_ name: String, arguments: [String: Any]) -> String? {
        switch name {
        case "mcpock_status":
            return StatusReport.statusText(loadStatus(), now: now(), isRunning: isRunning)
        case "mcpock_problems":
            return StatusReport.problemsText(loadStatus(), now: now(), isRunning: isRunning)
        case "mcpock_server":
            let server = (arguments["name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !server.isEmpty else { return "Pass the server's name, e.g. {\"name\": \"firecrawl\"}." }
            return StatusReport.serverText(loadStatus(), name: server, now: now(), isRunning: isRunning)
        default:
            return nil
        }
    }

    static let tools: [[String: Any]] = [
        tool("mcpock_status",
             title: "mcpock summary",
             description: "Counts from mcpock: how many MCP servers are fine, broken, slow, waiting for a sign-in "
                + "or set up differently across agents, and when mcpock last checked."),
        tool("mcpock_problems",
             title: "mcpock problems",
             description: "Every MCP server that needs attention (broken, slow, needs sign-in, set up differently) "
                + "with its reasons, the command or URL it runs (secrets masked), its config file paths and the "
                + "agents that use it. Call this when the user says \"check my mcpock\"."),
        tool("mcpock_server",
             title: "mcpock server details",
             description: "Everything mcpock knows about one MCP server: state, every declaration with its config "
                + "file, command or URL (secrets masked), env and header names, errors and tools.",
             properties: ["name": ["type": "string", "description": "The server's name as mcpock shows it, e.g. \"firecrawl\"."]],
             required: ["name"]),
    ]

    private static func tool(
        _ name: String,
        title: String,
        description: String,
        properties: [String: Any] = [:],
        required: [String] = []
    ) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties, "additionalProperties": false]
        if !required.isEmpty { schema["required"] = required }
        return [
            "name": name,
            "title": title,
            "description": description,
            "inputSchema": schema,
            "annotations": ["readOnlyHint": true, "idempotentHint": true, "openWorldHint": false],
        ]
    }

    // MARK: - Encoding

    private func encode(result: [String: Any], id: Any) -> String {
        line(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func encode(error code: Int, message: String, id: Any) -> String {
        line(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private func line(_ object: [String: Any]) -> String {
        // `encodeLine` adds the newline the transport needs; the caller writes it.
        guard let data = try? MCPJSONRPC.encodeLine(object),
              let text = String(data: data, encoding: .utf8) else {
            return #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error"}}"#
        }
        return text.trimmingCharacters(in: .newlines)
    }

    /// True while a process with this id exists (EPERM still means it exists).
    static func processIsAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }
}
