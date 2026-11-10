import Foundation

/// How one agent hides single tools of a server (Part 2, 2026-11-10). Each
/// agent's own setting, checked against its docs or source on 10 Nov:
/// the tool is never deleted, the agent just stops offering it.
enum ToolMechanism: Equatable, Sendable {
    /// Claude Code: `mcp__<server>__<tool>` in `permissions.deny` of
    /// `~/.claude/settings.json` (a deny rule with no arguments takes the tool
    /// out of the model's context; settings reload live).
    case claudeDeny
    /// Codex: `disabled_tools = [...]` under `[mcp_servers.<name>]` (it wins
    /// over `enabled_tools`).
    case codex
    /// Grok CLI: `<server> = [...]` in the `[disabled_mcp_tools]` table.
    case grok
    /// Hermes: `tools: exclude: [...]` in the server's entry.
    case hermes
    /// Goose: `available_tools: [...]`, a list of the tools it MAY use (empty
    /// is all). Hiding writes every other tool, so a tool the server adds
    /// later stays hidden in Goose until it is shown.
    case goose
    /// OpenCode (v2): a `{"action": "<server>_<tool>", "resource": "*",
    /// "effect": "deny"}` rule in the `permissions` list.
    case openCode
}

enum ToolSwitch {
    enum ToolError: Error, Equatable {
        /// The file is not laid out in a way mcpock can change safely.
        case cannotEdit
        /// The edit did not check out, so nothing was written.
        case failedCheck
        /// An OpenCode file in the older layout (servers right under `mcp`):
        /// the deny rules are a v2 setting, so it is left alone (review
        /// 10 Nov, fable-3; OpenCode's docs: "V2 does not place server names
        /// directly under mcp").
        case olderOpenCode
    }

    /// True when `server` sits right under `mcp` (OpenCode before v2) and
    /// not under `mcp.servers`.
    static func isOlderOpenCode(_ text: String, server: String) -> Bool {
        guard let root = JSONSpanEditor.parse(text) else { return false }
        return root.value(at: ["mcp", "servers", server])?.members == nil && root.value(at: ["mcp", server])?.members != nil
    }

    /// The way `agent` (a `ServerSource.label`) hides a tool, or nil when it
    /// has none mcpock can write. Only the agents' own known files, like the
    /// server switch; Claude Code's rules go by name, from any of its files.
    static func mechanism(agent: String, configID: String, builtin: Bool) -> ToolMechanism? {
        guard !builtin else { return nil }
        if agent == AgentRegistry.claudeCodeLabel { return .claudeDeny }
        guard configID.hasPrefix("reg:") else { return nil }
        switch agent {
        case "Codex": return .codex
        case "Grok": return .grok
        case "Hermes": return .hermes
        case "Goose": return .goose
        case "OpenCode": return .openCode
        default: return nil
        }
    }

    /// A name the way Claude Code and OpenCode write it inside a tool's
    /// full name: anything but letters, digits, `_` and `-` becomes `_`.
    static func safeName(_ name: String) -> String {
        String(name.unicodeScalars.map { scalar -> Character in
            let ok = (scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar))) || scalar == "_" || scalar == "-"
            return ok ? Character(scalar) : "_"
        })
    }

    static func claudeRule(server: String, tool: String) -> String {
        "mcp__\(safeName(server))__\(safeName(tool))"
    }

    static func openCodeAction(server: String, tool: String) -> String {
        "\(safeName(server))_\(safeName(tool))"
    }

    // MARK: Reading

    /// The tools of `server` hidden in `text`, or nil when the file can't be
    /// read that way. `allTools` is the server's own list (Goose's list names
    /// the tools it may use, so the hidden ones are the rest).
    static func hidden(in text: String?, mechanism: ToolMechanism, server: String, allTools: [String]) -> Set<String>? {
        guard let text else { return mechanism == .claudeDeny ? [] : nil }
        switch mechanism {
        case .claudeDeny:
            guard let root = ServerSwitch.jsonObject(text) as? [String: Any] else { return nil }
            let deny = (root["permissions"] as? [String: Any])?["deny"] as? [Any] ?? []
            let rules = Set(deny.compactMap { $0 as? String })
            return Set(allTools.filter { rules.contains(claudeRule(server: server, tool: $0)) })
        case .openCode:
            guard !isOlderOpenCode(text, server: server),
                  let root = ServerSwitch.jsonObject(text) as? [String: Any] else { return nil }
            let rules = root["permissions"] as? [Any] ?? []
            let denied = Set(rules.compactMap { item -> String? in
                guard let rule = item as? [String: Any], rule["effect"] as? String == "deny",
                      rule["resource"] as? String == "*" else { return nil }
                return rule["action"] as? String
            })
            return Set(allTools.filter { denied.contains(openCodeAction(server: server, tool: $0)) })
        case .codex:
            guard let found = TOMLList.find(in: text, table: ["mcp_servers", server], key: "disabled_tools") else { return nil }
            return Set(found.items)
        case .grok:
            guard let found = TOMLList.find(in: text, table: ["disabled_mcp_tools"], key: server, tableMayBeMissing: true) else {
                return nil
            }
            return Set(found.items)
        case .hermes:
            guard let entry = YAMLEntry(text: text, section: "mcp_servers", entry: server),
                  let tools = entry.toolsField() else { return nil }
            if tools.include != nil { return Set(allTools).subtracting(tools.include ?? []) }
            return Set(tools.exclude?.items ?? [])
        case .goose:
            guard let entry = YAMLEntry(text: text, section: "extensions", entry: server),
                  let list = entry.flowListField("available_tools") else { return nil }
            guard let items = list.items, !items.isEmpty else { return [] }
            return Set(allTools).subtracting(items)
        }
    }

    // MARK: The edit

    /// `text` with `hide` hidden and `show` shown for `server`, the agent's
    /// way. `text` nil is a file that is not there yet (only Claude Code's
    /// settings may be made). The result is checked before it is returned.
    static func edited(_ text: String?, mechanism: ToolMechanism, server: String,
                       hide: Set<String>, show: Set<String>, allTools: [String]) throws -> String {
        let before: String
        if let text {
            before = text
        } else {
            guard mechanism == .claudeDeny else { throw ToolError.cannotEdit }
            before = "{}\n"
        }
        if mechanism == .openCode, isOlderOpenCode(before, server: server) { throw ToolError.olderOpenCode }
        // Tools named in the edit count as the server's even when its list
        // (from the last check) does not have them.
        let known = allTools + Array(hide.union(show).subtracting(allTools)).sorted()
        guard let current = hidden(in: before, mechanism: mechanism, server: server, allTools: known) else {
            throw ToolError.cannotEdit
        }
        let wanted = current.union(hide).subtracting(show)
        let order = ordered(wanted, by: allTools)
        let after: String
        do {
            switch mechanism {
            case .claudeDeny: after = try claudeDeny(before, server: server, hide: hide, show: show)
            case .openCode: after = try openCode(before, server: server, hide: hide, show: show)
            case .codex:
                guard let edited = TOMLList.set(order, in: before, table: ["mcp_servers", server], key: "disabled_tools") else {
                    throw ToolError.cannotEdit
                }
                after = edited
            case .grok:
                guard let edited = TOMLList.set(order, in: before, table: ["disabled_mcp_tools"], key: server,
                                                tableMayBeMissing: true) else { throw ToolError.cannotEdit }
                after = edited
            case .hermes:
                guard let edited = YAMLEntry(text: before, section: "mcp_servers", entry: server)?.settingExclude(order) else {
                    throw ToolError.cannotEdit
                }
                after = edited
            case .goose:
                guard let entry = YAMLEntry(text: before, section: "extensions", entry: server),
                      let list = entry.flowListField("available_tools") else { throw ToolError.cannotEdit }
                let allowed: [String]
                if wanted.isEmpty {
                    allowed = []
                } else {
                    // Hiding needs the server's full list: the rest is written out.
                    guard !allTools.isEmpty else { throw ToolError.cannotEdit }
                    let base = (list.items ?? []).isEmpty ? allTools : (list.items ?? [])
                    var kept = base.filter { !wanted.contains($0) }
                    for tool in allTools where show.contains(tool) && !kept.contains(tool) { kept.append(tool) }
                    allowed = Set(allTools).isSubset(of: kept) ? [] : kept
                }
                guard let edited = entry.settingFlowList("available_tools", allowed) else { throw ToolError.cannotEdit }
                after = edited
            }
        } catch is JSONSpanEditor.EditError {
            throw ToolError.cannotEdit
        }
        guard verify(before: before, after: after, mechanism: mechanism, server: server, wanted: wanted,
                     allTools: known) else {
            throw ToolError.failedCheck
        }
        return after
    }

    /// `tools` in the server's own order, then any others sorted.
    static func ordered(_ tools: Set<String>, by allTools: [String]) -> [String] {
        var seen = Set<String>()
        let known = allTools.filter { tools.contains($0) && seen.insert($0).inserted }
        return known + tools.subtracting(known).sorted()
    }

    private static func claudeDeny(_ text: String, server: String, hide: Set<String>, show: Set<String>) throws -> String {
        guard let root = JSONSpanEditor.parse(text), let members = root.members else { throw ToolError.cannotEdit }
        var result = text
        let showRules = Set(show.map { claudeRule(server: server, tool: $0) })
        if let elements = root.value(at: ["permissions", "deny"])?.elements {
            for index in elements.indices.reversed() where elements[index].string.map(showRules.contains) == true {
                result = try JSONSpanEditor.removeElement(in: result, arrayPath: ["permissions", "deny"], index: index)
            }
        }
        let existing = Set(JSONSpanEditor.parse(result)?.value(at: ["permissions", "deny"])?.elements?.compactMap(\.string) ?? [])
        let add = hide.subtracting(show).sorted().map { claudeRule(server: server, tool: $0) }.filter { !existing.contains($0) }
        guard !add.isEmpty else {
            // The last rule went: an empty list (and then an empty
            // "permissions") goes too, so showing everything again leaves
            // the file as it was.
            guard result != text, JSONSpanEditor.parse(result)?.value(at: ["permissions", "deny"])?.elements?.isEmpty == true else {
                return result
            }
            result = try JSONSpanEditor.removeMember(in: result, objectPath: ["permissions"], key: "deny").text
            if JSONSpanEditor.parse(result)?.member("permissions")?.value.members?.isEmpty == true {
                result = try JSONSpanEditor.removeMember(in: result, objectPath: [], key: "permissions").text
            }
            return result
        }

        let scalars = Array(result.unicodeScalars)
        let newline = result.contains("\r\n") ? "\r\n" : "\n"
        let unit = JSONSpanEditor.indentUnit(scalars)
        let current = JSONSpanEditor.parse(result)
        if let permissions = current?.member("permissions")?.value {
            guard permissions.members != nil else { throw ToolError.cannotEdit }
            if let deny = permissions.member("deny")?.value {
                guard deny.elements != nil else { throw ToolError.cannotEdit }
                for rule in add {
                    result = try JSONSpanEditor.appendElement(in: result, arrayPath: ["permissions", "deny"],
                                                              elementText: JSONSpanEditor.quoted(rule))
                }
                return result
            }
            let keyIndent = permissions.members?.first.flatMap {
                JSONSpanEditor.lineIndent(Array(result.unicodeScalars), at: $0.keyStart)
            }
            return try JSONSpanEditor.insertMember(in: result, objectPath: ["permissions"], key: "deny",
                                                   valueText: list(add, indent: keyIndent, unit: unit, newline: newline))
        }
        let keyIndent = members.first.flatMap { JSONSpanEditor.lineIndent(scalars, at: $0.keyStart) } ?? unit
        let deny = "\"deny\": " + list(add, indent: keyIndent + unit, unit: unit, newline: newline)
        let value = "{" + newline + keyIndent + unit + deny + newline + keyIndent + "}"
        return try JSONSpanEditor.insertMember(in: result, objectPath: [], key: "permissions", valueText: value)
    }

    /// A JSON list of strings, one per line when `indent` is known.
    private static func list(_ items: [String], indent: String?, unit: String, newline: String) -> String {
        guard let indent else { return "[" + items.map(JSONSpanEditor.quoted).joined(separator: ", ") + "]" }
        return "[" + newline + items.map { indent + unit + JSONSpanEditor.quoted($0) }.joined(separator: "," + newline)
            + newline + indent + "]"
    }

    private static func openCode(_ text: String, server: String, hide: Set<String>, show: Set<String>) throws -> String {
        guard let root = JSONSpanEditor.parse(text), let members = root.members else { throw ToolError.cannotEdit }
        let showActions = Set(show.map { openCodeAction(server: server, tool: $0) })
        func isRule(_ span: JSONSpan, in actions: Set<String>) -> Bool {
            span.member("effect")?.value.string == "deny" && span.member("resource")?.value.string == "*"
                && span.member("action")?.value.string.map(actions.contains) == true && span.members?.count == 3
        }
        var result = text
        if let elements = root.member("permissions")?.value.elements {
            for index in elements.indices.reversed() where isRule(elements[index], in: showActions) {
                result = try JSONSpanEditor.removeElement(in: result, arrayPath: ["permissions"], index: index)
            }
        }
        let parsed = JSONSpanEditor.parse(result)
        let existing = Set((parsed?.member("permissions")?.value.elements ?? []).compactMap { span -> String? in
            span.member("effect")?.value.string == "deny" && span.member("resource")?.value.string == "*"
                ? span.member("action")?.value.string : nil
        })
        let add = hide.subtracting(show).sorted().map { openCodeAction(server: server, tool: $0) }.filter { !existing.contains($0) }
        guard !add.isEmpty else {
            // The last rule went: the empty list goes too.
            if result != text, parsed?.member("permissions")?.value.elements?.isEmpty == true {
                result = try JSONSpanEditor.removeMember(in: result, objectPath: [], key: "permissions").text
            }
            return result
        }
        func rule(_ action: String) -> String {
            "{ \"action\": \(JSONSpanEditor.quoted(action)), \"resource\": \"*\", \"effect\": \"deny\" }"
        }
        if let permissions = parsed?.member("permissions")?.value {
            guard permissions.elements != nil else { throw ToolError.cannotEdit }
            for action in add {
                result = try JSONSpanEditor.appendElement(in: result, arrayPath: ["permissions"], elementText: rule(action))
            }
            return result
        }
        let scalars = Array(result.unicodeScalars)
        let newline = result.contains("\r\n") ? "\r\n" : "\n"
        let unit = JSONSpanEditor.indentUnit(scalars)
        let keyIndent = members.first.flatMap { JSONSpanEditor.lineIndent(scalars, at: $0.keyStart) } ?? unit
        let value = "[" + newline + add.map { keyIndent + unit + rule($0) }.joined(separator: "," + newline) + newline + keyIndent + "]"
        return try JSONSpanEditor.insertMember(in: result, objectPath: [], key: "permissions", valueText: value)
    }

    // MARK: The check

    /// True when `after` hides exactly `wanted` and nothing else changed: the
    /// JSON files compared as data, the TOML and YAML ones line by line.
    static func verify(before: String, after: String, mechanism: ToolMechanism, server: String,
                       wanted: Set<String>, allTools: [String]) -> Bool {
        guard hidden(in: after, mechanism: mechanism, server: server, allTools: allTools) == wanted else { return false }
        switch mechanism {
        case .claudeDeny:
            guard var old = ServerSwitch.jsonObject(before) as? [String: Any],
                  var new = ServerSwitch.jsonObject(after) as? [String: Any] else { return false }
            let ours = Set(allTools.map { claudeRule(server: server, tool: $0) })
            func strip(_ root: inout [String: Any]) -> [String] {
                guard var permissions = root["permissions"] as? [String: Any] else { return [] }
                let deny = permissions["deny"] as? [Any] ?? []
                let others = deny.filter { !(($0 as? String).map(ours.contains) ?? false) }
                permissions["deny"] = nil
                root["permissions"] = permissions.isEmpty ? nil : permissions
                return others.map { "\($0)" }
            }
            let oldOthers = strip(&old), newOthers = strip(&new)
            return oldOthers == newOthers && NSDictionary(dictionary: old).isEqual(to: new)
        case .openCode:
            guard var old = ServerSwitch.jsonObject(before) as? [String: Any],
                  var new = ServerSwitch.jsonObject(after) as? [String: Any] else { return false }
            let ours = Set(allTools.map { openCodeAction(server: server, tool: $0) })
            func strip(_ root: inout [String: Any]) -> [Any] {
                let rules = root["permissions"] as? [Any] ?? []
                root["permissions"] = nil
                return rules.filter { item in
                    guard let rule = item as? [String: Any], rule.count == 3, rule["effect"] as? String == "deny",
                          rule["resource"] as? String == "*", let action = rule["action"] as? String else { return true }
                    return !ours.contains(action)
                }
            }
            let oldOthers = strip(&old), newOthers = strip(&new)
            return NSArray(array: oldOthers).isEqual(to: newOthers) && NSDictionary(dictionary: old).isEqual(to: new)
        case .codex, .grok:
            // A new table at the end: a blank line, its header, the list.
            return changedLines(before: before, after: after, maxOld: 1, maxNew: 4)
        case .hermes, .goose:
            let section = mechanism == .hermes ? "mcp_servers" : "extensions"
            let key = mechanism == .hermes ? "tools" : "available_tools"
            guard changedLines(before: before, after: after, maxOld: 2, maxNew: 2),
                  let old = YAMLBlock.parse(before), let new = YAMLBlock.parse(after) else { return false }
            return dropping(key, old, section: section, entry: server) == dropping(key, new, section: section, entry: server)
        }
    }

    /// The texts are the same lines, but for one run of at most `maxOld`
    /// lines replaced by at most `maxNew`.
    static func changedLines(before: String, after: String, maxOld: Int, maxNew: Int) -> Bool {
        let old = before.components(separatedBy: "\n"), new = after.components(separatedBy: "\n")
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        return old.count - prefix - suffix <= maxOld && new.count - prefix - suffix <= maxNew
    }

    private static func dropping(_ key: String, _ node: YAMLBlock.Node, section: String, entry: String) -> YAMLBlock.Node {
        guard case .mapping(let top) = node else { return node }
        return .mapping(top.map { pair in
            guard pair.key == section, case .mapping(let entries) = pair.value else { return pair }
            return .init(key: pair.key, value: .mapping(entries.map { item in
                guard item.key == entry, case .mapping(let fields) = item.value else { return item }
                return .init(key: item.key, value: .mapping(fields.filter { $0.key != key }))
            }))
        })
    }
}

// MARK: - TOML: one list on one line

/// `key = ["a", "b"]` inside a TOML table, changed as one line. A list that
/// runs over several lines, or a table written another way, is left alone
/// (nil: no switch, never a guess).
enum TOMLList {
    struct Found {
        /// The items, or empty when the key is not there.
        let items: [String]
        /// The key's line, when it is there.
        let line: Int?
        /// The table's header line, when the table is there.
        let header: Int?
        /// The table's last line with content.
        let lastLine: Int?
    }

    static func find(in text: String, table: [String], key: String, tableMayBeMissing: Bool = false) -> Found? {
        let lines = text.components(separatedBy: "\n")
        var header: Int?
        var lastLine: Int?
        var keyLine: Int?
        var items: [String] = []
        var arrayDepth = 0
        var inTable = false

        for (index, raw) in lines.enumerated() {
            let line = MCPServersTOML.stripComment(raw.hasSuffix("\r") ? String(raw.dropLast()) : raw)
            if arrayDepth > 0 {
                arrayDepth += MCPServersTOML.bracketDepth(line)
                if inTable { lastLine = index }
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                guard let close = trimmed.firstIndex(of: "]") else { return nil }
                let inner = trimmed.hasPrefix("[[") ? String(trimmed.dropFirst(2).prefix(while: { $0 != "]" }))
                    : String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
                let path = MCPServersTOML.splitKey(inner)
                if path == table {
                    guard header == nil, !trimmed.hasPrefix("[[") else { return nil }
                    header = index
                    lastLine = index
                    inTable = true
                } else {
                    // `[disabled_mcp_tools.x]` is the key itself written as a table:
                    // left alone. Another sub-table (Codex's `[mcp_servers.x.env]`,
                    // `.http_headers`) is a different key and is fine (fable-4).
                    if path.count > table.count, Array(path.prefix(table.count)) == table, path[table.count] == key {
                        return nil
                    }
                    inTable = false
                }
                continue
            }
            guard !trimmed.isEmpty else { continue }
            if inTable { lastLine = index }
            guard let eq = MCPServersTOML.firstUnquotedIndex(of: "=", in: line) else { continue }
            let keyPath = MCPServersTOML.splitKey(String(line[..<eq]))
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            // Outside any table: a dotted key or inline table for the same thing.
            if header == nil, !inTable, !lines[..<index].contains(where: { isHeader($0) }), keyPath.first == table.first {
                return nil
            }
            if inTable, keyPath == [key] {
                guard value.hasPrefix("["), MCPServersTOML.bracketDepth(value) == 0 else { return nil }
                guard keyLine == nil else { return nil }
                keyLine = index
                items = MCPServersTOML.parseInlineArray(value)
            } else if value.hasPrefix("[") {
                arrayDepth = max(0, MCPServersTOML.bracketDepth(value))
            }
        }
        guard header != nil || tableMayBeMissing else { return nil }
        return Found(items: items, line: keyLine, header: header, lastLine: lastLine)
    }

    private static func isHeader(_ raw: String) -> Bool {
        MCPServersTOML.stripComment(raw).trimmingCharacters(in: .whitespaces).hasPrefix("[")
    }

    /// `text` with the list set to `items`; an empty list takes the line out.
    static func set(_ items: [String], in text: String, table: [String], key: String, tableMayBeMissing: Bool = false) -> String? {
        guard let found = find(in: text, table: table, key: key, tableMayBeMissing: tableMayBeMissing) else { return nil }
        var lines = text.components(separatedBy: "\n")
        let crlf = text.contains("\r\n") ? "\r" : ""
        let keyText = isBare(key) ? key : quoted(key)
        let newLine = keyText + " = [" + items.map(quoted).joined(separator: ", ") + "]"
        if let line = found.line {
            if items.isEmpty {
                lines.remove(at: line)
            } else {
                let raw = lines[line]
                let indent = String(raw.prefix(while: { $0 == " " || $0 == "\t" }))
                let code = MCPServersTOML.stripComment(raw.hasSuffix("\r") ? String(raw.dropLast()) : raw)
                let rest = String((raw.hasSuffix("\r") ? String(raw.dropLast()) : raw).dropFirst(code.count))
                    .trimmingCharacters(in: .whitespaces)
                lines[line] = indent + newLine + (rest.isEmpty ? "" : "  " + rest) + (raw.hasSuffix("\r") ? "\r" : "")
            }
            return lines.joined(separator: "\n")
        }
        guard !items.isEmpty else { return text }
        if let last = found.lastLine {
            lines.insert(newLine + crlf, at: last + 1)
            return lines.joined(separator: "\n")
        }
        // No table yet: added at the end of the file.
        var body = text
        if !body.isEmpty, !body.hasSuffix("\n") { body += crlf + "\n" }
        let header = "[" + table.map { isBare($0) ? $0 : quoted($0) }.joined(separator: ".") + "]"
        return body + (body.isEmpty ? "" : crlf + "\n") + header + crlf + "\n" + newLine + crlf + "\n"
    }

    static func isBare(_ key: String) -> Bool {
        !key.isEmpty && key.unicodeScalars.allSatisfy { ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "_" || $0 == "-" }
    }

    static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

// MARK: - YAML: one entry's fields

/// One named entry of a top-level YAML section (`mcp_servers:` in Hermes,
/// `extensions:` in Goose), found the same way the server switch finds it.
/// Lists are read and written only in flow form on one line (`[a, b]`).
struct YAMLEntry {
    private var lines: [String]
    private let entryLine: Int
    private let entryIndent: Int
    private let fieldIndent: Int

    struct FlowList {
        /// nil when the field is not there.
        let items: [String]?
        let line: Int?
    }

    init?(text: String, section: String, entry: String) {
        lines = text.components(separatedBy: "\n")
        let all = lines
        func body(_ index: Int) -> String {
            let raw = all[index]
            return raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
        }
        func hasContent(_ index: Int) -> Bool {
            let trimmed = body(index).trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !trimmed.hasPrefix("#")
        }
        func blockKey(_ index: Int) -> String? {
            let line = YAMLSwitch.stripComment(body(index)).trimmingCharacters(in: .whitespaces)
            guard line.hasSuffix(":") else { return nil }
            return YAMLEntry.unquote(String(line.dropLast()))
        }
        guard let sectionLine = all.indices.first(where: {
            hasContent($0) && YAMLBlock.indent(body($0)) == 0 && blockKey($0) == section
        }) else { return nil }
        var found: Int?
        var foundIndent = 0
        var childIndent: Int?
        var index = sectionLine + 1
        while index < all.count {
            defer { index += 1 }
            guard hasContent(index) else { continue }
            guard !body(index).contains("\t") else { return nil }
            let indent = YAMLBlock.indent(body(index))
            if indent == 0 { break }
            if childIndent == nil { childIndent = indent }
            if indent == childIndent, blockKey(index) == entry {
                found = index
                foundIndent = indent
                break
            }
        }
        guard let found else { return nil }
        var fields: Int?
        index = found + 1
        while index < all.count {
            defer { index += 1 }
            guard hasContent(index) else { continue }
            guard !body(index).contains("\t") else { return nil }
            let indent = YAMLBlock.indent(body(index))
            if indent <= foundIndent { break }
            if fields == nil { fields = indent }
        }
        guard let fields else { return nil }
        entryLine = found
        entryIndent = foundIndent
        fieldIndent = fields
    }

    private func body(_ index: Int) -> String {
        let raw = lines[index]
        return raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
    }

    private func hasContent(_ index: Int) -> Bool {
        let trimmed = body(index).trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && !trimmed.hasPrefix("#")
    }

    private var ending: String { lines[entryLine].hasSuffix("\r") ? "\r" : "" }

    /// The lines with content directly under `parent` (a line index) at the
    /// first deeper indent, up to the next line as shallow as `parentIndent`.
    private func children(of parent: Int, parentIndent: Int) -> (lines: [Int], indent: Int?)? {
        var result: [Int] = []
        var childIndent: Int?
        var index = parent + 1
        while index < lines.count {
            defer { index += 1 }
            guard hasContent(index) else { continue }
            let indent = YAMLBlock.indent(body(index))
            if indent <= parentIndent { break }
            if childIndent == nil { childIndent = indent }
            if indent == childIndent { result.append(index) } else if indent < childIndent ?? 0 { return nil }
        }
        return (result, childIndent)
    }

    /// `key:` and what follows it on the same line, for a field line.
    private func split(_ index: Int) -> (key: String, value: String)? {
        let line = YAMLSwitch.stripComment(body(index)).trimmingCharacters(in: .whitespaces)
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = YAMLEntry.unquote(String(line[..<colon]))
        return (key, String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
    }

    /// A field whose value is a flow list on its own line: its items, or nil
    /// items when the field is not there. Nil when it is written another way.
    func flowListField(_ key: String) -> FlowList? {
        guard let (fields, _) = children(of: entryLine, parentIndent: entryIndent) else { return nil }
        guard let line = fields.first(where: { split($0)?.key == key }) else { return FlowList(items: nil, line: nil) }
        guard let value = split(line)?.value, let items = YAMLEntry.flowItems(value) else { return nil }
        return FlowList(items: items, line: line)
    }

    /// Hermes' `tools:` block: its `include` and `exclude` lists. Nil when it
    /// is written in a way mcpock does not change.
    func toolsField() -> (include: [String]?, exclude: FlowList?)? {
        guard let (fields, _) = children(of: entryLine, parentIndent: entryIndent) else { return nil }
        guard let tools = fields.first(where: { split($0)?.key == "tools" }) else { return (nil, nil) }
        guard split(tools)?.value.isEmpty == true,
              let (inner, _) = children(of: tools, parentIndent: fieldIndent) else { return nil }
        var include: [String]?
        var exclude: FlowList?
        for line in inner {
            guard let (key, value) = split(line) else { continue }
            if key == "include" {
                guard let items = YAMLEntry.flowItems(value) else { return nil }
                include = items
            } else if key == "exclude" {
                guard let items = YAMLEntry.flowItems(value) else { return nil }
                exclude = FlowList(items: items, line: line)
            }
        }
        return (include, exclude)
    }

    /// The text with `key: [items]` set on the entry.
    func settingFlowList(_ key: String, _ items: [String]) -> String? {
        guard let list = flowListField(key) else { return nil }
        var out = lines
        let text = String(repeating: " ", count: fieldIndent) + key + ": " + YAMLEntry.flow(items)
        if let line = list.line {
            out[line] = YAMLEntry.keepingComment(of: out[line], text)
        } else {
            guard !items.isEmpty else { return lines.joined(separator: "\n") }
            out.insert(text + ending, at: entryLine + 1)
        }
        return out.joined(separator: "\n")
    }

    /// Hermes: `tools: exclude: [items]`. Refuses when `include` is set
    /// (it would win over the exclude list).
    func settingExclude(_ items: [String]) -> String? {
        guard let tools = toolsField(), tools.include == nil else { return nil }
        var out = lines
        if let line = tools.exclude?.line, items.isEmpty {
            // Nothing hidden any more: the line goes, and `tools:` with it
            // when it held nothing else.
            out.remove(at: line)
            if let (fields, _) = children(of: entryLine, parentIndent: entryIndent),
               let toolsLine = fields.first(where: { split($0)?.key == "tools" }),
               children(of: toolsLine, parentIndent: fieldIndent)?.lines == [line] {
                out.remove(at: toolsLine)
            }
            return out.joined(separator: "\n")
        }
        if let line = tools.exclude?.line {
            let indent = YAMLBlock.indent(body(line))
            out[line] = YAMLEntry.keepingComment(of: out[line],
                                                 String(repeating: " ", count: indent) + "exclude: " + YAMLEntry.flow(items))
            return out.joined(separator: "\n")
        }
        guard !items.isEmpty else { return lines.joined(separator: "\n") }
        guard let (fields, _) = children(of: entryLine, parentIndent: entryIndent) else { return nil }
        let step = max(2, fieldIndent - entryIndent)
        if let toolsLine = fields.first(where: { split($0)?.key == "tools" }) {
            let inner = children(of: toolsLine, parentIndent: fieldIndent)?.indent ?? fieldIndent + step
            out.insert(String(repeating: " ", count: inner) + "exclude: " + YAMLEntry.flow(items) + ending, at: toolsLine + 1)
        } else {
            out.insert(String(repeating: " ", count: fieldIndent + step) + "exclude: " + YAMLEntry.flow(items) + ending,
                       at: entryLine + 1)
            out.insert(String(repeating: " ", count: fieldIndent) + "tools:" + ending, at: entryLine + 1)
        }
        return out.joined(separator: "\n")
    }

    // MARK: Small pieces

    /// The items of a one-line flow list of plain or quoted scalars.
    static func flowItems(_ value: String) -> [String]? {
        let v = value.trimmingCharacters(in: .whitespaces)
        guard v.hasPrefix("["), v.hasSuffix("]") else { return nil }
        let inner = v.dropFirst().dropLast()
        guard !inner.contains("[") && !inner.contains("{") else { return nil }
        var items: [String] = []
        var current = ""
        var quote: Character?
        for c in inner {
            if let q = quote {
                if c == q { quote = nil } else { current.append(c) }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == "," {
                items.append(current.trimmingCharacters(in: .whitespaces)); current = ""
            } else {
                current.append(c)
            }
        }
        guard quote == nil else { return nil }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty || !items.isEmpty { items.append(last) }
        return items.filter { !$0.isEmpty }
    }

    static func flow(_ items: [String]) -> String {
        "[" + items.map { item in
            let plain = !item.isEmpty && item.unicodeScalars.allSatisfy {
                ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "_" || $0 == "-" || $0 == "."
            } && !["true", "false", "null", "yes", "no", "on", "off"].contains(item.lowercased())
            return plain ? item : TOMLList.quoted(item)
        }.joined(separator: ", ") + "]"
    }

    private static func keepingComment(of raw: String, _ text: String) -> String {
        let ending = raw.hasSuffix("\r") ? "\r" : ""
        let line = ending.isEmpty ? raw : String(raw.dropLast())
        let comment = String(line.dropFirst(YAMLSwitch.stripComment(line).count)).trimmingCharacters(in: .whitespaces)
        return text + (comment.isEmpty ? "" : "  " + comment) + ending
    }

    private static func unquote(_ s: String) -> String {
        let v = s.trimmingCharacters(in: .whitespaces)
        guard v.count >= 2, let first = v.first, first == "\"" || first == "'", v.last == first else { return v }
        return String(v.dropFirst().dropLast())
    }
}
