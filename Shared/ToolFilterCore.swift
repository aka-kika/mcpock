import Foundation

/// mcpock's tool filter (premium look, 22 Nov, Kika's pick): for agents that
/// cannot hide single tools on their own (Cursor, Claude Desktop, VS Code,
/// Cline, Windsurf). The agent starts mcpock's helper in `filter` mode, the
/// helper starts the real server and passes every message through, word for
/// word, except two: the server's tool list loses the tools she turned off,
/// and a call to one of them is answered "turned off" without reaching the
/// server.
///
/// This file is the part both sides share: how the helper is invoked, the
/// small file that names the hidden tools, and what happens to one message.
/// Pure, so the tests cover it without a process.
enum ToolFilterCore {
    /// `mcpock-mcp filter --hide-file <path> -- <command> <args…>`
    static let mode = "filter"
    static let hideFileFlag = "--hide-file"
    static let separator = "--"
    static let helperName = "mcpock-mcp"

    /// The arguments an agent's entry carries once it is filtered: the
    /// server's own command and arguments stay inside, in order, untouched.
    static func wrappedArguments(hideFile: String, command: String, arguments: [String]) -> [String] {
        [mode, hideFileFlag, hideFile, separator, command] + arguments
    }

    struct Invocation: Equatable {
        let hideFile: String
        let command: String
        let arguments: [String]
    }

    /// The inverse of `wrappedArguments`; nil for anything else, so an entry
    /// that only looks similar is never taken apart.
    static func invocation(arguments: [String]) -> Invocation? {
        guard arguments.count >= 5, arguments[0] == mode, arguments[1] == hideFileFlag,
              !arguments[2].isEmpty, arguments[3] == separator, !arguments[4].isEmpty
        else { return nil }
        return Invocation(hideFile: arguments[2], command: arguments[4], arguments: Array(arguments.dropFirst(5)))
    }

    /// True for a command that is mcpock's helper, wherever the app sits.
    static func isHelper(_ command: String) -> Bool {
        (command as NSString).lastPathComponent == helperName
    }

    // MARK: - The hide file

    /// `{"hide": ["delete_repository", "fork_repository"]}`; nil when the
    /// text is not that (no file, not JSON, another shape).
    static func parsedHidden(fromFileText text: String?) -> Set<String>? {
        guard let text, let root = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let names = root["hide"] as? [Any]
        else { return nil }
        return Set(names.compactMap { $0 as? String }.filter { !$0.isEmpty })
    }

    /// The same, with nothing hidden for a file that can't be read: what the
    /// app shows, and what a filter starts with.
    static func hidden(fromFileText text: String?) -> Set<String> {
        parsedHidden(fromFileText: text) ?? []
    }

    /// The hidden tools of a running filter. It starts with what the file
    /// says (nothing, when there is no file yet: nothing was hidden). After
    /// that a file that goes missing or breaks changes nothing: the last
    /// good list stays, so deleting mcpock's folder never brings a hidden
    /// tool back into a running agent (review 22 Nov).
    struct HideList: Equatable {
        private(set) var names: Set<String> = []

        mutating func update(fileText: String?) {
            if let parsed = ToolFilterCore.parsedHidden(fromFileText: fileText) { names = parsed }
        }
    }

    /// The file's text for a set of names: sorted, one per line, so a change
    /// reads as one added or removed line.
    static func fileText(hidden: Set<String>) -> String {
        guard !hidden.isEmpty else { return "{\n  \"hide\": []\n}\n" }
        let lines = hidden.sorted().map { "    " + quoted($0) }
        return "{\n  \"hide\": [\n" + lines.joined(separator: ",\n") + "\n  ]\n}\n"
    }

    private static func quoted(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes])) ?? Data("[\"\"]".utf8)
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }

    // MARK: - One message

    enum ClientAction: Equatable {
        /// Pass it to the server as it is.
        case forward
        /// Do not pass it on; answer the agent with this line.
        case answer(String)
        /// Do not pass it on and say nothing (a notification about a hidden tool).
        case drop
    }

    /// A line from the agent. Only a call to a hidden tool is stopped. While
    /// something is hidden every line is parsed (an agent may write the
    /// method as `tools\/call`), and a batch that holds a call to a hidden
    /// tool is answered whole, not passed on in part (review 22 Nov).
    static func fromClient(_ line: String, hidden: Set<String>) -> ClientAction {
        guard !hidden.isEmpty, let data = Optional(Data(line.utf8)),
              let json = try? JSONSerialization.jsonObject(with: data)
        else { return .forward }
        if let message = json as? [String: Any] {
            guard let name = hiddenCall(message, hidden: hidden) else { return .forward }
            guard let reply = refusal(of: message, tool: name) else { return .drop }
            return encoded(reply).map(ClientAction.answer) ?? .drop
        }
        guard let batch = json as? [Any] else { return .forward }
        let messages = batch.compactMap { $0 as? [String: Any] }
        guard let name = messages.lazy.compactMap({ hiddenCall($0, hidden: hidden) }).first else { return .forward }
        // Every request of the batch gets an answer, so the agent is not left waiting for any of them.
        let replies = messages.compactMap { refusal(of: $0, tool: name) }
        guard !replies.isEmpty, let data = try? JSONSerialization.data(withJSONObject: replies, options: [.withoutEscapingSlashes])
        else { return .drop }
        return .answer(String(decoding: data, as: UTF8.self))
    }

    /// The hidden tool a message calls, or nil.
    private static func hiddenCall(_ message: [String: Any], hidden: Set<String>) -> String? {
        guard message["method"] as? String == "tools/call",
              let name = (message["params"] as? [String: Any])?["name"] as? String, hidden.contains(name)
        else { return nil }
        return name
    }

    /// The filter's own answer to a request; nil for a notification (no id).
    private static func refusal(of message: [String: Any], tool: String) -> [String: Any]? {
        guard let id = message["id"], !(id is NSNull) else { return nil }
        return ["jsonrpc": "2.0", "id": id,
                "error": ["code": -32602, "message": "The tool \(tool) is turned off in mcpock."]]
    }

    /// A line from the server. A tool list loses the hidden tools, also
    /// inside a batch; everything else comes back exactly as it was sent,
    /// byte for byte.
    static func fromServer(_ line: String, hidden: Set<String>) -> String {
        guard !hidden.isEmpty, line.contains("\"tools\""),
              let json = try? JSONSerialization.jsonObject(with: Data(line.utf8))
        else { return line }
        if let message = json as? [String: Any] {
            guard let filtered = withoutHidden(message, hidden: hidden) else { return line }
            return encoded(filtered) ?? line
        }
        guard let batch = json as? [Any] else { return line }
        var changed = false
        let result: [Any] = batch.map { item in
            guard let message = item as? [String: Any], let filtered = withoutHidden(message, hidden: hidden) else { return item }
            changed = true
            return filtered
        }
        guard changed, let data = try? JSONSerialization.data(withJSONObject: result, options: [.withoutEscapingSlashes]) else { return line }
        return String(decoding: data, as: UTF8.self)
    }

    /// A tool-list answer without its hidden tools; nil when nothing changes.
    private static func withoutHidden(_ message: [String: Any], hidden: Set<String>) -> [String: Any]? {
        guard var result = message["result"] as? [String: Any], let tools = result["tools"] as? [[String: Any]] else { return nil }
        let kept = tools.filter { tool in
            guard let name = tool["name"] as? String else { return true }
            return !hidden.contains(name)
        }
        guard kept.count != tools.count else { return nil }
        result["tools"] = kept
        var copy = message
        copy["result"] = result
        return copy
    }

    private static func object(_ line: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    }

    /// One line of JSON, never with a newline inside (MCP's stdio framing).
    private static func encoded(_ message: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Splits a byte stream into lines with no size limit: a filter must pass a
/// large tool result through whole (the helper's own reader caps a message at
/// 1 MB, which is right for its own small protocol and wrong here).
struct FilterLineSplitter {
    private var buffer = Data()
    /// How much of `buffer` was already searched and holds no newline, so a
    /// large result arriving in small pieces is scanned once, not once per
    /// piece (review 22 Nov).
    private var searched = 0

    /// The complete lines in `chunk` (without their newline), in order.
    mutating func feed(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var lines: [Data] = []
        var start = buffer.startIndex
        var from = buffer.startIndex + searched
        while let newline = buffer[from...].firstIndex(of: 0x0A) {
            lines.append(buffer.subdata(in: start..<newline))
            start = newline + 1
            from = start
        }
        if start > buffer.startIndex { buffer = buffer.subdata(in: start..<buffer.endIndex) }
        searched = buffer.count
        return lines
    }

    /// What is left when the stream ends without a last newline.
    mutating func finish() -> Data? {
        defer { buffer.removeAll(); searched = 0 }
        return buffer.isEmpty ? nil : buffer
    }
}
