import Foundation

/// The MCP side of the `mcpock-mcp` helper (round 7): one newline-delimited
/// JSON-RPC message in, at most one out. Its tools read mcpock's status file
/// and never probe a server. The one that writes, `mcpock_ask` (1.16), only
/// leaves a request in mcpock's own `asks` folder for the user to answer; it
/// never touches an agent's config.
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
        MCP servers), then tell the user what it reports and ask before changing any config file. \
        mcpock changes a config only when the user flips a switch in the app. Only the user turns servers on or \
        off, or hides single tools, there; do not edit a config unless the user says yes. To suggest hiding or \
        showing a tool, or turning a server off or on, call mcpock_ask with a short reason: it changes nothing, \
        mcpock asks the user, and only their Yes runs the switch. Then tell the user you asked and that they \
        answer in mcpock. Read the answer later with mcpock_switches. The other tools only read.
        """

    /// Who is asking: the MCP client's own name from `initialize`.
    final class Session: @unchecked Sendable {
        var client: String?
    }

    var loadStatus: () -> StatusLoad
    var now: () -> Date = Date.init
    var isRunning: (MCPockStatus) -> Bool = { MCPStatusServer.mcpockIsRunning($0) }
    var version: String = MCPJSONRPC.clientVersion
    /// Where `mcpock_ask` leaves requests; tests point it at a temp folder.
    var askFolder: URL = AskBox.directory()
    var newID: () -> String = { UUID().uuidString }
    let session = Session()

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
            session.client = (params["clientInfo"] as? [String: Any])?["name"] as? String
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
        case "mcpock_switches":
            return StatusReport.switchesText(loadStatus(), now: now(), isRunning: isRunning)
        case "mcpock_server":
            let server = (arguments["name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !server.isEmpty else { return "Pass the server's name, e.g. {\"name\": \"firecrawl\"}." }
            return StatusReport.serverText(loadStatus(), name: server, now: now(), isRunning: isRunning)
        case "mcpock_ask":
            return ask(arguments)
        default:
            return nil
        }
    }

    /// `mcpock_ask`: checks the request, then leaves it for the user. Never
    /// changes a config.
    private func ask(_ arguments: [String: Any]) -> String {
        guard let actionName = arguments["action"] as? String, let action = AgentAsk.Action(rawValue: actionName) else {
            return "Pass an action: hide_tool, show_tool, turn_off or turn_on."
        }
        let server = (arguments["server"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let tool = (arguments["tool"] as? String)?.trimmingCharacters(in: .whitespaces)
        let reason = AgentAsk.oneLine(arguments["reason"] as? String ?? "", limit: AgentAsk.maxReason)
        guard !server.isEmpty else { return "Pass the server's name, e.g. {\"server\": \"github\"}." }
        guard !reason.isEmpty else { return "Pass a short reason the user will read, e.g. \"never used in 30 days\"." }
        guard case .loaded(let status) = loadStatus() else { return StatusReport.notRunningYet }
        let checked = StatusReport.checkAsk(status, server: server, tool: tool.flatMap { $0.isEmpty ? nil : $0 }, action: action)
        guard case .ok(let name, let match) = checked else {
            if case .refused(let why) = checked { return why }
            return StatusReport.notRunningYet
        }
        let waiting = AskBox.read(from: askFolder, now: now()).asks
        if let same = waiting.first(where: { $0.server == name && $0.tool == match && $0.action == action }) {
            return "Already asked: the user hasn't answered request \(same.id) yet. Read the answer later with mcpock_switches."
        }
        let ask = AgentAsk(id: newID(), server: name, tool: match, action: action, reason: reason,
                           agent: AgentAsk.agentLabel(session.client), asked: now())
        do {
            try AskBox.write(ask, to: askFolder)
        } catch AskBox.Refusal.full {
            return "\(AgentAsk.maxWaiting) requests already wait for the user. Ask again once they have answered some."
        } catch {
            return "mcpock couldn't save the request (its folder \(askFolder.path) can't be written). Nothing changed."
        }
        return StatusReport.askedText(ask, running: isRunning(status))
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
                + "file, command or URL (secrets masked), env and header names, errors and tools, and each tool's "
                + "calls in the last 30 days with its last use (when Usage counts are on in mcpock).",
             properties: ["name": ["type": "string", "description": "The server's name as mcpock shows it, e.g. \"firecrawl\"."]],
             required: ["name"]),
        tool("mcpock_switches",
             title: "mcpock on and off",
             description: "Which MCP servers are turned off, and in which agents, which single tools are hidden, and "
                + "what became of requests made with mcpock_ask (waiting, yes, no, or ended after a day). Read-only: "
                + "only the user turns a server on or off or hides a tool, in the mcpock app."),
        tool("mcpock_ask",
             title: "Ask the user in mcpock",
             description: "Ask the user to hide or show one tool of an MCP server, or to turn a server off or on. "
                + "Changes nothing: mcpock shows the user your request with your reason, and only their Yes runs "
                + "the switch (they see every file first). Then tell the user you asked and that they answer in "
                + "mcpock. A request with no answer ends after one day. Read the answer with mcpock_switches.",
             properties: [
                "server": ["type": "string", "description": "The server's name as mcpock shows it, e.g. \"github\"."],
                "tool": ["type": "string", "description": "The tool's name, for hide_tool and show_tool only."],
                "action": ["type": "string", "enum": AgentAsk.Action.allCases.map(\.rawValue),
                           "description": "hide_tool, show_tool, turn_off or turn_on."],
                "reason": ["type": "string", "maxLength": AgentAsk.maxReason,
                           "description": "One short line the user reads, e.g. \"never used in 30 days\"."],
             ],
             required: ["server", "action", "reason"],
             readOnly: false),
    ]

    private static func tool(
        _ name: String,
        title: String,
        description: String,
        properties: [String: Any] = [:],
        required: [String] = [],
        readOnly: Bool = true
    ) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties, "additionalProperties": false]
        if !required.isEmpty { schema["required"] = required }
        return [
            "name": name,
            "title": title,
            "description": description,
            "inputSchema": schema,
            // mcpock_ask leaves a request and nothing else: not read-only, never destructive.
            "annotations": readOnly
                ? ["readOnlyHint": true, "idempotentHint": true, "openWorldHint": false]
                : ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false],
        ]
    }

    // MARK: - Encoding

    private func encode(result: [String: Any], id: Any) -> String {
        line(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func encode(error code: Int, message: String, id: Any) -> String {
        line(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    /// The answer to a message over the size cap: JSON-RPC "Invalid Request", id unknown (r3 b1c9).
    func tooLongReply() -> String {
        encode(error: -32600, message: "Message too long (over 1 MB)", id: NSNull())
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

    /// True only if the pid in the status file is still the mcpock that wrote
    /// it. A pid alone is not enough: after a crash the system can give the
    /// number to another program (review 2026-10-20, 7b1a). So the process must
    /// also be named mcpock and must not have started after the file was written.
    /// The three lookups come in as values so tests need no real process.
    /// A lookup that fails (nil) is skipped, never counted against mcpock.
    static func mcpockIsRunning(
        _ status: MCPockStatus,
        isAlive: (Int32) -> Bool = MCPStatusServer.processIsAlive,
        executablePath: (Int32) -> String? = MCPStatusServer.executablePath,
        startTime: (Int32) -> Date? = MCPStatusServer.startTime
    ) -> Bool {
        guard isAlive(status.pid) else { return false }
        if let path = executablePath(status.pid),
           (path as NSString).lastPathComponent != "mcpock" {
            return false
        }
        // The app starts before it writes its first file; a few seconds of
        // slack covers clock rounding (the kernel keeps whole seconds).
        if let started = startTime(status.pid),
           started > status.generated.addingTimeInterval(5) {
            return false
        }
        return true
    }

    /// The path of the program behind a pid, or nil if the system won't say.
    static func executablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    /// When the process behind a pid started, or nil if the system won't say.
    static func startTime(_ pid: Int32) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec))
    }
}
