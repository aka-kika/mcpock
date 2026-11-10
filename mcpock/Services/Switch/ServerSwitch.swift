import Foundation

/// How one agent says "do not start this server" (the server switch, 1.14).
/// mcpock uses the agent's own way where it has one, and parks the entry in
/// the same file where it has none. A stopped server is never deleted: on
/// puts it back.
enum SwitchMechanism: Equatable, Sendable {
    /// Claude Code: the server's name in `deniedMcpServers` of
    /// `~/.claude/settings.json`. Covers every project and scope at once, and
    /// leaves `~/.claude.json` alone (Claude Code rewrites that file itself
    /// while it runs, so an outside edit there can be lost).
    case claudeDeny
    /// OpenCode: `"disabled": true` under `mcp.servers.<name>`, or the older
    /// `"enabled": false` under `mcp.<name>`.
    case openCode
    /// Codex and Grok: `enabled = false` under `[mcp_servers.<name>]`.
    case toml
    /// Goose (`extensions`) and Hermes (`mcp_servers`): `enabled: false`.
    case yaml(section: String)
    /// The entry moves from `mcpServers` to `_mcpock_disabled` in the same
    /// file. No agent is switched this way since 2026-11-10 (an app that
    /// rewrites its file can drop the key); the reader still lists such
    /// entries as turned off, and this turns them back on.
    case park
    /// Claude Desktop and Cursor have no flag. Claude Desktop rewrites its
    /// config at launch and drops keys it does not know (seen with the real
    /// app), and a logged-in Cursor may rewrite `mcp.json` too: the entry
    /// moves out of the file into mcpock's own folder (`ParkedStore`), where
    /// no app can lose it.
    case parkOutside
}

enum ServerSwitch {
    /// The sibling key parked servers wait under. The agent ignores it.
    static let parkedKey = "_mcpock_disabled"
    /// Marks a discovered entry as turned off (never a key an agent writes).
    static let offKey = "\u{1F}off"

    enum SwitchError: Error, Equatable {
        /// The file is not laid out in a way mcpock can change safely.
        case cannotEdit
        /// The edit did not check out, so nothing was written.
        case failedCheck
    }

    /// The way to switch a server of `agent` (a `ServerSource.label`), or nil
    /// when mcpock offers no switch there. Only the agents' own known files:
    /// never a file the scan found, except Claude Code's, whose blocked list
    /// goes by name.
    static func mechanism(agent: String, configID: String, builtin: Bool) -> SwitchMechanism? {
        guard !builtin else { return nil }
        if agent == AgentRegistry.claudeCodeLabel { return .claudeDeny }
        guard configID.hasPrefix("reg:") else { return nil }
        switch agent {
        case "Codex", "Grok": return .toml
        case "Goose": return .yaml(section: "extensions")
        case "Hermes": return .yaml(section: "mcp_servers")
        case "OpenCode": return .openCode
        case "Claude Desktop", "Cursor": return .parkOutside
        default: return nil
        }
    }

    /// Claude Code's user settings, beside its `~/.claude.json`.
    static func claudeSettingsPath(claudeJSON: String) -> String {
        ((claudeJSON as NSString).deletingLastPathComponent as NSString).appendingPathComponent(".claude/settings.json")
    }

    /// The names in `deniedMcpServers` of Claude Code's settings text.
    static func deniedNames(inClaudeSettings text: String) -> Set<String> {
        guard let root = jsonObject(text) as? [String: Any],
              let denied = root["deniedMcpServers"] as? [[String: Any]] else { return [] }
        return Set(denied.compactMap { $0["serverName"] as? String })
    }

    // MARK: The edit

    /// `text` with `server` turned on or off the agent's way. `text` nil is a
    /// file that is not there yet (only Claude Code's settings may be made).
    /// The result is checked before it is returned.
    /// `parkedValue`: the entry's JSON text from `ParkedStore`, needed to turn
    /// a `.parkOutside` server on.
    static func edited(_ text: String?, mechanism: SwitchMechanism, server: String, turnOn: Bool,
                       parkedValue: String? = nil) throws -> String {
        let before: String
        if let text {
            before = text
        } else {
            guard mechanism == .claudeDeny else { throw SwitchError.cannotEdit }
            before = "{}\n"
        }
        let after: String
        do {
            switch mechanism {
            case .claudeDeny: after = try claudeDeny(before, server: server, turnOn: turnOn)
            case .openCode: after = try openCode(before, server: server, turnOn: turnOn)
            case .park: after = try park(before, server: server, turnOn: turnOn)
            case .parkOutside:
                if turnOn {
                    guard let parkedValue, jsonObject(parkedValue) is [String: Any],
                          let root = JSONSpanEditor.parse(before), root.members != nil else { throw SwitchError.cannotEdit }
                    if root.member("mcpServers")?.value.members != nil {
                        after = try JSONSpanEditor.insertMember(in: before, objectPath: ["mcpServers"], key: server, valueText: parkedValue)
                    } else {
                        guard root.member("mcpServers") == nil else { throw SwitchError.cannotEdit }
                        let entry = "{\(JSONSpanEditor.quoted(server)): \(parkedValue)}"
                        after = try JSONSpanEditor.insertMember(in: before, objectPath: [], key: "mcpServers", valueText: entry)
                    }
                } else {
                    after = try JSONSpanEditor.removeMember(in: before, objectPath: ["mcpServers"], key: server).text
                }
            case .toml:
                guard let edited = TOMLSwitch.setEnabled(turnOn, server: server, in: before) else { throw SwitchError.cannotEdit }
                after = edited
            case .yaml(let section):
                guard let edited = YAMLSwitch.setEnabled(turnOn, entry: server, section: section, in: before) else {
                    throw SwitchError.cannotEdit
                }
                after = edited
            }
        } catch is JSONSpanEditor.EditError {
            throw SwitchError.cannotEdit
        }
        guard verify(before: before, after: after, mechanism: mechanism, server: server, turnOn: turnOn,
                     parkedValue: parkedValue) else {
            throw SwitchError.failedCheck
        }
        return after
    }

    /// True when `server` waits under `_mcpock_disabled` in this file.
    static func isParkedInFile(_ text: String, server: String) -> Bool {
        JSONSpanEditor.parse(text)?.value(at: [parkedKey, server])?.members != nil
    }

    /// The entry of `server` under `mcpServers`, exactly as the file writes
    /// it: what `ParkedStore` keeps while it is off.
    static func entryText(in text: String, server: String) -> String? {
        guard let value = JSONSpanEditor.parse(text)?.value(at: ["mcpServers", server]), value.members != nil else { return nil }
        return JSONSpanEditor.text(Array(text.unicodeScalars)[value.start..<value.end])
    }

    private static func claudeDeny(_ text: String, server: String, turnOn: Bool) throws -> String {
        guard let root = JSONSpanEditor.parse(text), let members = root.members else { throw SwitchError.cannotEdit }
        let scalars = Array(text.unicodeScalars)
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        let unit = JSONSpanEditor.indentUnit(scalars)
        let array = root.member("deniedMcpServers")?.value

        if turnOn {
            guard let elements = array?.elements else { return text }
            var result = text
            for index in elements.indices.reversed()
            where elements[index].member("serverName")?.value.string == server {
                result = try JSONSpanEditor.removeElement(in: result, arrayPath: ["deniedMcpServers"], index: index)
            }
            return result
        }

        if deniedNames(inClaudeSettings: text).contains(server) { return text }
        let name = JSONSpanEditor.quoted(server)
        func element(indent: String?, multiline: Bool) -> String {
            guard multiline, let indent else { return "{ \"serverName\": \(name) }" }
            return "{" + newline + indent + unit + "\"serverName\": \(name)" + newline + indent + "}"
        }
        if let array {
            guard let elements = array.elements else { throw SwitchError.cannotEdit }
            if let last = elements.last {
                let lastText = JSONSpanEditor.text(scalars[last.start..<last.end])
                let piece = element(indent: JSONSpanEditor.lineIndent(scalars, at: last.start), multiline: lastText.contains("\n"))
                return try JSONSpanEditor.appendElement(in: text, arrayPath: ["deniedMcpServers"], elementText: piece)
            }
            let inner = JSONSpanEditor.leadingWhitespace(scalars, ofLineAt: array.start) + unit
            return try JSONSpanEditor.appendElement(in: text, arrayPath: ["deniedMcpServers"],
                                                    elementText: element(indent: inner, multiline: text.contains("\n")))
        }
        // No list yet: one is added at the end of the settings.
        let keyIndent = members.first.flatMap { JSONSpanEditor.lineIndent(scalars, at: $0.keyStart) } ?? unit
        let value = "[" + newline + keyIndent + unit + element(indent: keyIndent + unit, multiline: true)
            + newline + keyIndent + "]"
        return try JSONSpanEditor.insertMember(in: text, objectPath: [], key: "deniedMcpServers", valueText: value)
    }

    /// The entry's place in an OpenCode file: the current shape first.
    private static func openCodePath(_ root: JSONSpan, server: String) -> [String]? {
        for path in [["mcp", "servers", server], ["mcp", server]] where root.value(at: path)?.members != nil {
            return path
        }
        return nil
    }

    private static func openCode(_ text: String, server: String, turnOn: Bool) throws -> String {
        guard let root = JSONSpanEditor.parse(text), let path = openCodePath(root, server: server),
              let entry = root.value(at: path) else { throw SwitchError.cannotEdit }
        var result = text
        let hasEnabled = entry.member("enabled") != nil
        let hasDisabled = entry.member("disabled") != nil
        if hasEnabled {
            result = try JSONSpanEditor.setMember(in: result, objectPath: path, key: "enabled", valueText: turnOn ? "true" : "false")
        }
        if hasDisabled {
            result = try JSONSpanEditor.setMember(in: result, objectPath: path, key: "disabled", valueText: turnOn ? "false" : "true")
        }
        if !turnOn, !hasEnabled, !hasDisabled {
            let current = path.count == 3
            result = try JSONSpanEditor.setMember(in: result, objectPath: path, key: current ? "disabled" : "enabled",
                                                  valueText: current ? "true" : "false")
        }
        return result
    }

    private static func park(_ text: String, server: String, turnOn: Bool) throws -> String {
        let from = turnOn ? parkedKey : "mcpServers"
        let to = turnOn ? "mcpServers" : parkedKey
        guard let root = JSONSpanEditor.parse(text), let members = root.members,
              let member = root.value(at: [from])?.member(server) else { throw SwitchError.cannotEdit }
        let scalars = Array(text.unicodeScalars)
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        let keyIndent = members.first.flatMap { JSONSpanEditor.lineIndent(scalars, at: $0.keyStart) }
        let memberIndent = JSONSpanEditor.lineIndent(scalars, at: member.keyStart)

        var (result, value) = try JSONSpanEditor.removeMember(in: text, objectPath: [from], key: server)
        if root.member(to)?.value.members != nil {
            result = try JSONSpanEditor.insertMember(in: result, objectPath: [to], key: server, valueText: value)
        } else {
            guard root.member(to) == nil else { throw SwitchError.cannotEdit }
            let entry = "\(JSONSpanEditor.quoted(server)): \(value)"
            let object: String
            if let keyIndent, let memberIndent {
                object = "{" + newline + memberIndent + entry + newline + keyIndent + "}"
            } else {
                object = "{" + entry + "}"
            }
            result = try JSONSpanEditor.insertMember(in: result, objectPath: [], key: to, valueText: object)
        }
        // The last parked server came back: the empty key goes too.
        if turnOn, JSONSpanEditor.parse(result)?.member(parkedKey)?.value.members?.isEmpty == true {
            result = try JSONSpanEditor.removeMember(in: result, objectPath: [], key: parkedKey).text
        }
        return result
    }

    // MARK: The check

    /// True when `after` is `before` with exactly the intended change: the
    /// JSON files are compared as data, the TOML and YAML ones line by line.
    static func verify(before: String, after: String, mechanism: SwitchMechanism, server: String, turnOn: Bool,
                       parkedValue: String? = nil) -> Bool {
        switch mechanism {
        case .claudeDeny, .openCode, .park, .parkOutside:
            guard var expected = jsonObject(before) as? [String: Any],
                  let actual = jsonObject(after) as? [String: Any] else { return false }
            guard applyExpected(&expected, mechanism: mechanism, server: server, turnOn: turnOn,
                                parkedValue: parkedValue) else { return false }
            return NSDictionary(dictionary: expected).isEqual(to: actual)
        case .toml:
            guard changesAtMostOneLine(before: before, after: after) else { return false }
            let off = MCPServersTOML.servers(fromTOML: after, includingOff: true)[server]?[offKey] as? Bool ?? false
            let names = { (text: String) in Set(MCPServersTOML.servers(fromTOML: text, includingOff: true).keys) }
            return off == !turnOn && names(before) == names(after)
        case .yaml(let section):
            guard changesAtMostOneLine(before: before, after: after),
                  let old = YAMLBlock.parse(before), let new = YAMLBlock.parse(after),
                  droppingEnabled(old, section: section, entry: server) == droppingEnabled(new, section: section, entry: server),
                  let entry = new[section]?[server] else { return false }
            let value = entry["enabled"]?.scalarValue?.lowercased()
            return turnOn ? (value == nil || value == "true") : value == "false"
        }
    }

    private static func applyExpected(_ root: inout [String: Any], mechanism: SwitchMechanism, server: String, turnOn: Bool,
                                      parkedValue: String? = nil) -> Bool {
        switch mechanism {
        case .parkOutside:
            var servers = root["mcpServers"] as? [String: Any] ?? [:]
            if turnOn {
                guard servers[server] == nil, let entry = parkedValue.flatMap(jsonObject) as? [String: Any] else { return false }
                servers[server] = entry
            } else {
                guard servers.removeValue(forKey: server) != nil else { return false }
            }
            root["mcpServers"] = servers
            return true
        case .claudeDeny:
            var denied = root["deniedMcpServers"] as? [Any] ?? []
            let isIt: (Any) -> Bool = { ($0 as? [String: Any])?["serverName"] as? String == server }
            if turnOn {
                denied.removeAll(where: isIt)
                guard root["deniedMcpServers"] != nil else { return true }
            } else if !denied.contains(where: isIt) {
                denied.append(["serverName": server])
            }
            root["deniedMcpServers"] = denied
            return true
        case .openCode:
            guard var mcp = root["mcp"] as? [String: Any] else { return false }
            let nested = (mcp["servers"] as? [String: Any])?[server] is [String: Any]
            var servers = nested ? (mcp["servers"] as? [String: Any] ?? [:]) : mcp
            guard var entry = servers[server] as? [String: Any] else { return false }
            let hasEnabled = entry["enabled"] != nil, hasDisabled = entry["disabled"] != nil
            if hasEnabled { entry["enabled"] = turnOn }
            if hasDisabled { entry["disabled"] = !turnOn }
            if !turnOn, !hasEnabled, !hasDisabled { entry[nested ? "disabled" : "enabled"] = nested }
            servers[server] = entry
            if nested { mcp["servers"] = servers } else { mcp = servers }
            root["mcp"] = mcp
            return true
        case .park:
            let from = turnOn ? parkedKey : "mcpServers", to = turnOn ? "mcpServers" : parkedKey
            guard var source = root[from] as? [String: Any], let entry = source[server] else { return false }
            var target = root[to] as? [String: Any] ?? [:]
            guard target[server] == nil else { return false }
            source[server] = nil
            target[server] = entry
            root[from] = source
            root[to] = target
            if turnOn, source.isEmpty { root[parkedKey] = nil }
            return true
        case .toml, .yaml:
            return false
        }
    }

    /// The two texts are the same lines, but for one changed or one added.
    static func changesAtMostOneLine(before: String, after: String) -> Bool {
        let old = before.components(separatedBy: "\n"), new = after.components(separatedBy: "\n")
        guard new.count == old.count || new.count == old.count + 1 else { return false }
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        return new.count - prefix - suffix <= 1 && old.count - prefix - suffix <= 1
    }

    private static func droppingEnabled(_ node: YAMLBlock.Node, section: String, entry: String) -> YAMLBlock.Node {
        guard case .mapping(let top) = node else { return node }
        return .mapping(top.map { pair in
            guard pair.key == section, case .mapping(let entries) = pair.value else { return pair }
            return .init(key: pair.key, value: .mapping(entries.map { item in
                guard item.key == entry, case .mapping(let fields) = item.value else { return item }
                return .init(key: item.key, value: .mapping(fields.filter { $0.key != "enabled" }))
            }))
        })
    }

    static func jsonObject(_ text: String) -> Any? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8)))
            ?? (try? JSONSerialization.jsonObject(with: Data(JSONC.plainJSON(text).utf8)))
    }
}
