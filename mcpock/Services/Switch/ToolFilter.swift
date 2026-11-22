import Foundation

/// Setting up and removing mcpock's tool filter in an agent's own config
/// (premium look, 22 Nov, Kika's pick: a notice in the card, with Set up).
/// For the agents that have no setting for hiding single tools: the server's
/// entry is changed to start mcpock's helper first, with the server's own
/// command and arguments inside it, in order and untouched (`ToolFilterCore`).
/// Its `env` and every other key stay where they are. Removing the filter
/// puts the command and arguments back.
///
/// Only stdio servers (a command), and only the agents' own known files.
enum ToolFilter {
    enum FilterError: Error, Equatable {
        /// The entry is not laid out in a way mcpock can change safely.
        case cannotEdit
        /// The edit did not check out, so nothing was written.
        case failedCheck
    }

    /// The object the servers of a filterable agent sit in, or nil when the
    /// agent hides tools its own way, or mcpock offers no filter there.
    static func serversKey(agent: String, configID: String, builtin: Bool) -> String? {
        guard !builtin, configID.hasPrefix("reg:") else { return nil }
        switch agent {
        case "Cursor", "Claude Desktop", "Windsurf", "Cline": return "mcpServers"
        case "VS Code": return "servers"
        default: return nil
        }
    }

    /// True when a filter can be set up for this declaration: a filterable
    /// agent, a server that runs as a command, on, and not filtered yet.
    static func canSetUp(_ config: ServerConfig) -> Bool {
        config.filterFile == nil && !config.turnedOff && config.transport == .stdio && config.command != nil
            && serversKey(agent: config.source.label, configID: config.id, builtin: config.builtin) != nil
    }

    /// mcpock's helper inside the running app.
    static var helperPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(ToolFilterCore.helperName)").path
    }

    /// `~/Library/Application Support/mcpock/filter/`
    static var defaultDirectory: URL {
        MCPockStatus.defaultDirectory().appendingPathComponent("filter", isDirectory: true)
    }

    /// The hide file of one server in one agent: "cursor--github-1a2b3c4d.json".
    /// The short hash keeps "a.b" and "a-b" apart.
    static func hideFile(agent: String, server: String, directory: URL = defaultDirectory) -> String {
        func slug(_ text: String) -> String {
            String(text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
        }
        var hash: UInt32 = 2_166_136_261
        for byte in (agent + "\u{1F}" + server).utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        let name = "\(slug(agent))--\(slug(server))-\(String(hash, radix: 16)).json"
        return directory.appendingPathComponent(name).path
    }

    /// The filter invocation an entry carries, when it is filtered.
    static func invocation(command: String?, arguments: [String]) -> ToolFilterCore.Invocation? {
        guard let command, ToolFilterCore.isHelper(command) else { return nil }
        return ToolFilterCore.invocation(arguments: arguments)
    }

    // MARK: The edit

    /// `text` with `server`'s entry under `key` starting the filter first.
    static func wrapped(_ text: String, key: String, server: String, helper: String, hideFile: String) throws -> String {
        let (command, arguments) = try launch(in: text, key: key, server: server)
        guard invocation(command: command, arguments: arguments) == nil else { throw FilterError.cannotEdit }
        let wrappedArguments = ToolFilterCore.wrappedArguments(hideFile: hideFile, command: command, arguments: arguments)
        return try setting(text, key: key, server: server, command: helper, arguments: wrappedArguments)
    }

    /// `text` with `server`'s entry starting the server itself again.
    static func unwrapped(_ text: String, key: String, server: String) throws -> String {
        let (command, arguments) = try launch(in: text, key: key, server: server)
        guard let inner = invocation(command: command, arguments: arguments) else { throw FilterError.cannotEdit }
        return try setting(text, key: key, server: server, command: inner.command, arguments: inner.arguments)
    }

    /// The entry's command and arguments, only when both are plain: a
    /// command given as a list, or arguments that are not all strings, are
    /// left alone.
    private static func launch(in text: String, key: String, server: String) throws -> (String, [String]) {
        guard let root = ServerSwitch.jsonObject(text) as? [String: Any],
              let entry = (root[key] as? [String: Any])?[server] as? [String: Any],
              let command = entry["command"] as? String, !command.isEmpty
        else { throw FilterError.cannotEdit }
        let raw = entry["args"]
        guard raw == nil || raw is [String] else { throw FilterError.cannotEdit }
        return (command, raw as? [String] ?? [])
    }

    private static func setting(_ text: String, key: String, server: String, command: String, arguments: [String]) throws -> String {
        let path = [key, server]
        // One line, a space after each comma: how these files are usually
        // written, so removing the filter mostly leaves the text as it was.
        // (The check below compares the data, whatever the spacing.)
        let argumentsText = "[" + arguments.map(JSONSpanEditor.quoted).joined(separator: ", ") + "]"
        let after: String
        do {
            let withCommand = try JSONSpanEditor.setMember(in: text, objectPath: path, key: "command",
                                                           valueText: JSONSpanEditor.quoted(command))
            after = try JSONSpanEditor.setMember(in: withCommand, objectPath: path, key: "args",
                                                 valueText: argumentsText)
        } catch {
            throw FilterError.cannotEdit
        }
        guard verify(before: text, after: after, key: key, server: server, command: command, arguments: arguments) else {
            throw FilterError.failedCheck
        }
        return after
    }

    /// True when `after` is `before` with only this entry's command and
    /// arguments changed to the given ones: compared as data.
    static func verify(before: String, after: String, key: String, server: String, command: String, arguments: [String]) -> Bool {
        guard var expected = ServerSwitch.jsonObject(before) as? [String: Any],
              let actual = ServerSwitch.jsonObject(after) as? [String: Any],
              var servers = expected[key] as? [String: Any], var entry = servers[server] as? [String: Any]
        else { return false }
        entry["command"] = command
        entry["args"] = arguments
        servers[server] = entry
        expected[key] = servers
        return NSDictionary(dictionary: expected).isEqual(to: actual)
    }
}

/// Plans for setting up or removing the filter: the same sheet, writer,
/// backups and checks as the server switch. Building one reads files and
/// changes nothing.
enum FilterPlanner {
    static func plan(
        server: String,
        configs: [ServerConfig],
        setUp: Bool,
        helper: String = ToolFilter.helperPath,
        directory: URL = ToolFilter.defaultDirectory,
        running: (String) -> Bool = { _ in false },
        read: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }
    ) -> SwitchPlan {
        var changes: [SwitchChange] = []
        var problems: [String] = []
        for config in configs {
            guard let key = ToolFilter.serversKey(agent: config.source.label, configID: config.id, builtin: config.builtin),
                  setUp ? ToolFilter.canSetUp(config) : config.filterFile != nil
            else { continue }
            let agent = AgentBadge.displayLabel(config.source.label)
            let path = config.source.path
            guard let before = read(path) else {
                problems.append("\(agent): mcpock can't read its file, so it is left alone.")
                continue
            }
            do {
                let after = setUp
                    ? try ToolFilter.wrapped(before, key: key, server: config.name, helper: helper,
                                             hideFile: ToolFilter.hideFile(agent: config.source.label, server: config.name,
                                                                           directory: directory))
                    : try ToolFilter.unwrapped(before, key: key, server: config.name)
                guard after != before else { continue }
                changes.append(SwitchChange(
                    agents: [agent],
                    path: path,
                    before: before,
                    after: after,
                    what: setUp
                        ? "\(server)'s entry starts mcpock's filter first. Its own command, arguments and keys stay inside, word for word."
                        : "\(server)'s entry starts \(server) itself again, as it did before the filter.",
                    when: SwitchPlanner.when(agent: config.source.label, turnOn: true, running: running(config.source.label))
                        .replacingOccurrences(of: "On ", with: setUp ? "Filtered " : "Unfiltered ")
                        .replacingOccurrences(of: ": on ", with: setUp ? ": filtered " : ": unfiltered "),
                    diff: SwitchPlanner.diff(before: before, after: after, mechanism: .claudeDeny, server: config.name, turnOn: false)
                ))
            } catch {
                problems.append("\(agent): mcpock can't change its file safely, so it is left alone.")
            }
        }
        return SwitchPlan(server: server, turnOn: false, changes: changes, skipped: [], problems: problems, filter: setUp)
    }
}
