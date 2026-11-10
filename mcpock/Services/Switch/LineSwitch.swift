import Foundation

/// The server switch's TOML and YAML writers. Both change one line (or add
/// one) and leave every other byte alone, so comments, order and spacing stay
/// as written. Pure text in, text out; nothing here touches a file.
///
/// `nil` means "this file is not laid out in a way mcpock can change safely":
/// the caller offers no switch, it never guesses.

/// `enabled = false` under `[mcp_servers.<name>]` (Codex, Grok).
enum TOMLSwitch {
    static func setEnabled(_ on: Bool, server: String, in text: String) -> String? {
        var lines = text.components(separatedBy: "\n")
        var header: Int?
        var arrayDepth = 0
        var enabledLine: Int?

        for (index, raw) in lines.enumerated() {
            let line = MCPServersTOML.stripComment(raw.hasSuffix("\r") ? String(raw.dropLast()) : raw)
            // Inside an array that runs over several lines nothing is a header.
            if arrayDepth > 0 {
                arrayDepth += MCPServersTOML.bracketDepth(line)
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                if header != nil { break }
                guard !trimmed.hasPrefix("[["), let close = trimmed.firstIndex(of: "]") else { continue }
                let path = MCPServersTOML.splitKey(String(trimmed[trimmed.index(after: trimmed.startIndex)..<close]))
                if path == ["mcp_servers", server] { header = index }
                continue
            }
            guard header != nil, let eq = MCPServersTOML.firstUnquotedIndex(of: "=", in: line) else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if key == "enabled" {
                enabledLine = index
            } else if value.hasPrefix("[") {
                arrayDepth = max(0, MCPServersTOML.bracketDepth(value))
            }
        }

        guard let header else { return nil }
        let word = on ? "true" : "false"
        if let enabledLine {
            lines[enabledLine] = replacingValue(in: lines[enabledLine], separator: "=", with: word,
                                                strip: MCPServersTOML.stripComment)
        } else if on {
            return text
        } else {
            let ending = lines[header].hasSuffix("\r") ? "\r" : ""
            lines.insert("enabled = false" + ending, at: header + 1)
        }
        return lines.joined(separator: "\n")
    }
}

/// `enabled: false` in an entry of a top-level YAML section (Goose's
/// `extensions:`, Hermes' `mcp_servers:`), written as plain block YAML.
enum YAMLSwitch {
    static func setEnabled(_ on: Bool, entry: String, section: String, in text: String) -> String? {
        var lines = text.components(separatedBy: "\n")

        func body(_ index: Int) -> String {
            let raw = lines[index]
            return raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
        }
        /// A line with content: not blank, not a comment.
        func hasContent(_ index: Int) -> Bool {
            let trimmed = body(index).trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !trimmed.hasPrefix("#")
        }
        /// `key` when the line is `key:` with nothing (or a comment) after it.
        func blockKey(_ index: Int) -> String? {
            let line = stripComment(body(index)).trimmingCharacters(in: .whitespaces)
            guard line.hasSuffix(":") else { return nil }
            return unquote(String(line.dropLast()))
        }

        guard let sectionLine = lines.indices.first(where: {
            hasContent($0) && YAMLBlock.indent(body($0)) == 0 && blockKey($0) == section
        }) else { return nil }

        // The entries sit one level in; the section ends at the next top-level line.
        var entryLine: Int?
        var entryIndent = 0
        var index = sectionLine + 1
        var childIndent: Int?
        while index < lines.count {
            defer { index += 1 }
            guard hasContent(index) else { continue }
            guard !body(index).contains("\t") else { return nil }
            let indent = YAMLBlock.indent(body(index))
            if indent == 0 { break }
            if childIndent == nil { childIndent = indent }
            if indent == childIndent, blockKey(index) == entry {
                entryLine = index
                entryIndent = indent
                break
            }
        }
        guard let entryLine else { return nil }

        // The entry's own lines are deeper than its name.
        var fieldIndent: Int?
        var enabledLine: Int?
        index = entryLine + 1
        while index < lines.count {
            defer { index += 1 }
            guard hasContent(index) else { continue }
            guard !body(index).contains("\t") else { return nil }
            let indent = YAMLBlock.indent(body(index))
            if indent <= entryIndent { break }
            if fieldIndent == nil { fieldIndent = indent }
            if indent == fieldIndent {
                let line = stripComment(body(index)).trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("enabled:") { enabledLine = index }
            }
        }
        guard let fieldIndent else { return nil }

        let word = on ? "true" : "false"
        if let enabledLine {
            lines[enabledLine] = replacingValue(in: lines[enabledLine], separator: ":", with: word, strip: stripComment)
        } else if on {
            return text
        } else {
            let ending = lines[entryLine].hasSuffix("\r") ? "\r" : ""
            lines.insert(String(repeating: " ", count: fieldIndent) + "enabled: false" + ending, at: entryLine + 1)
        }
        return lines.joined(separator: "\n")
    }

    /// Drops a `#` comment that starts the line or follows a space, outside quotes.
    static func stripComment(_ line: String) -> String {
        var quote: Character?
        var previous: Character = " "
        for index in line.indices {
            let c = line[index]
            if let q = quote {
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == "#", previous == " " {
                return String(line[..<index])
            }
            previous = c
        }
        return line
    }

    private static func unquote(_ s: String) -> String {
        let v = s.trimmingCharacters(in: .whitespaces)
        guard v.count >= 2, let first = v.first, first == "\"" || first == "'", v.last == first else { return v }
        return String(v.dropFirst().dropLast())
    }
}

/// `key<separator> old   # note` becomes `key<separator> word  # note`: the
/// key, its indentation, the comment and the line ending stay.
private func replacingValue(in raw: String, separator: Character, with word: String, strip: (String) -> String) -> String {
    let ending = raw.hasSuffix("\r") ? "\r" : ""
    let line = ending.isEmpty ? raw : String(raw.dropLast())
    let code = strip(line)
    let comment = String(line.dropFirst(code.count))
    guard let at = code.firstIndex(of: separator) else { return raw }
    let head = String(code[...at])
    return head + " " + word + (comment.isEmpty ? "" : "  " + comment) + ending
}
