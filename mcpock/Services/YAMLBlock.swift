import Foundation

/// Small block-YAML reader for the shapes agent configs use: a top-level key whose
/// children are named entries, each a map of fields whose values are a scalar, a
/// list of scalars, or a map of scalars.
///
///     extensions:            ← Goose (lists level with their key)
///       foo:
///         type: stdio
///         args:
///         - mcp
///     mcp_servers:           ← Hermes (lists one level deeper)
///       bar:
///         command: /Applications/Safari Technology
///           Preview.app/Contents/MacOS/safaridriver
///         env:
///           KEY: value
///
/// It builds a real node tree (block maps, block lists, compact `- key: value`
/// items), and reads scalars the way YAML does:
///
/// - **plain** scalars that wrap onto more-indented lines are folded with single
///   spaces (Hermes wraps long paths like the one above; 1.5.0 kept only the
///   first line), and a value may start on the line after its key;
/// - **double-quoted** scalars can span lines, with escapes (`\n`, `\"`, `\uXXXX`,
///   an escaped line break…);
/// - **single-quoted** scalars can span lines, with `''` for a quote;
/// - **block** scalars `|` and `>` with `-` / `+` chomping and an optional
///   indentation digit;
/// - flow `[a, b]` and `{k: v}`, also across lines;
/// - ` #` comments.
///
/// A line only continues a scalar when it is indented deeper than the key (or
/// the `- `) that owns the scalar, so a continuation line is never mistaken for
/// a new key or list item. Still deliberately not a full YAML parser: no anchors,
/// aliases, tags, `?` keys or multi-document files (zero third-party
/// dependencies is a project rule). Lines it can't place are skipped, never fatal.
enum YAMLBlock {
    enum Value: Equatable {
        case scalar(String)
        case list([String])
        case map([String: String])

        var scalar: String? { if case .scalar(let s) = self { return s }; return nil }
        var list: [String]? { if case .list(let l) = self { return l }; return nil }
        var map: [String: String]? { if case .map(let m) = self { return m }; return nil }

        /// Flatten a node to what the config readers use: list items and map
        /// values that are themselves collections are dropped.
        init(_ node: Node) {
            switch node {
            case .scalar(let s):
                self = .scalar(s)
            case .sequence(let items):
                self = .list(items.compactMap(\.scalarValue))
            case .mapping(let pairs):
                var map: [String: String] = [:]
                for pair in pairs { if let s = pair.value.scalarValue { map[pair.key] = s } }
                self = .map(map)
            }
        }
    }

    /// A parsed YAML node. Map keys keep their file order.
    indirect enum Node: Equatable {
        case scalar(String)
        case sequence([Node])
        case mapping([Pair])

        struct Pair: Equatable {
            let key: String
            let value: Node
        }

        var scalarValue: String? { if case .scalar(let s) = self { return s }; return nil }

        /// The value of the first `key` in a mapping.
        subscript(key: String) -> Node? {
            if case .mapping(let pairs) = self { return pairs.first { $0.key == key }?.value }
            return nil
        }
    }

    /// The entries under `topKey:` (a top-level key), keyed by entry name, each
    /// mapping field name → value. Empty when the key is absent or its block is
    /// empty. A repeated entry name or field keeps the last one.
    static func entries(in text: String, under topKey: String) -> [String: [String: Value]] {
        // The scan offers every candidate file (JSON and TOML too) to both YAML
        // shapes: a file without `topKey:` at the start of a line is not parsed.
        let key = topKey + ":"
        guard text.hasPrefix(key) || text.hasPrefix("\u{FEFF}" + key) || text.contains("\n" + key),
              case .mapping(let named)? = parse(text)?[topKey] else { return [:] }
        var result: [String: [String: Value]] = [:]
        for entry in named {
            guard case .mapping(let fields) = entry.value else { continue }
            var out: [String: Value] = [:]
            for field in fields { out[field.key] = Value(field.value) }
            result[entry.key] = out
        }
        return result
    }

    /// Parse a whole document into its root node, or nil when it has no content.
    static func parse(_ text: String) -> Node? {
        var parser = Parser(text)
        return parser.document()
    }

    static func indent(_ s: String) -> Int {
        var n = 0
        for c in s { if c == " " { n += 1 } else { break } }
        return n
    }
}

// MARK: - Parser

private struct Parser {
    typealias Node = YAMLBlock.Node

    private var lines: [String]
    private var pos = 0
    /// How many blocks deep the parse is. Each nesting level is one recursion,
    /// so a pathological file (thousands of `- - - -` on one line) could
    /// overflow the scan thread's small stack; past `maxDepth` the rest of
    /// that block is skipped, like any other part mcpock can't read.
    private var depth = 0
    private static let maxDepth = 64
    /// Whether the last line ends in a line break (block scalars keep it or not).
    private let endsWithNewline: Bool

    init(_ text: String) {
        var t = text.replacingOccurrences(of: "\r\n", with: "\n")
        if t.hasPrefix("\u{FEFF}") { t.removeFirst() }
        endsWithNewline = t.hasSuffix("\n")
        if endsWithNewline { t.removeLast() }
        lines = t.components(separatedBy: "\n").map { line in
            // Directives and document markers carry no data for us.
            let isMarker = line.hasPrefix("%") || line == "---" || line == "..."
                || line.hasPrefix("--- #") || line.hasPrefix("... #")
            return isMarker ? "" : line
        }
    }

    mutating func document() -> Node? {
        guard let i = nextSignificant(from: 0) else { return nil }
        pos = i
        return block(indent: indent(i), parent: -1)
    }

    // MARK: Block structure

    /// The node starting at `pos`, whose first line sits at `n` (deeper than `parent`).
    private mutating func block(indent n: Int, parent: Int) -> Node {
        depth += 1
        defer { depth -= 1 }
        guard depth <= Self.maxDepth else {
            pos += 1
            skip(deeperThan: n)
            return .scalar("")
        }
        let content = String(lines[pos].dropFirst(n))
        if Self.isSequenceItem(content) { return sequence(indent: n) }
        if Self.splitKey(content) != nil { return mapping(indent: n) }
        return inlineValue(content, parent: parent)
    }

    private mutating func mapping(indent n: Int) -> Node {
        var pairs: [Node.Pair] = []
        while let i = nextSignificant(from: pos), indent(i) >= n {
            pos = i
            guard indent(i) == n else { skip(deeperThan: n); continue }
            let content = String(lines[i].dropFirst(n))
            guard !Self.isSequenceItem(content), let (key, rest) = Self.splitKey(content) else {
                pos += 1           // not a key: skip the line and anything under it
                skip(deeperThan: n)
                continue
            }
            // Only leading space goes: a quoted value's trailing `\ ` is content.
            let value = String(rest.drop { $0 == " " || $0 == "\t" })
            if value.trimmingCharacters(in: .whitespaces).isEmpty || value.hasPrefix("#") {
                pos += 1
                pairs.append(.init(key: key, value: nested(parent: n, allowLevelList: true)))
            } else {
                pairs.append(.init(key: key, value: inlineValue(value, parent: n, levelList: true)))
            }
        }
        return .mapping(pairs)
    }

    private mutating func sequence(indent n: Int) -> Node {
        var items: [Node] = []
        while let i = nextSignificant(from: pos), indent(i) == n,
              Self.isSequenceItem(String(lines[i].dropFirst(n))) {
            pos = i
            let afterDash = lines[i].dropFirst(n + 1)
            let gap = afterDash.prefix { $0 == " " }.count
            let rest = String(afterDash.dropFirst(gap).drop { $0 == "\t" })
            if rest.trimmingCharacters(in: .whitespaces).isEmpty || rest.hasPrefix("#") {
                pos += 1
                items.append(nested(parent: n, allowLevelList: false))
            } else if Self.isSequenceItem(rest) || Self.splitKey(rest) != nil {
                // `- key: value` / `- - x`: a compact collection. Re-read the line as
                // if it started at the item's column, so the item's later keys line up.
                let column = n + 1 + gap
                lines[i] = String(repeating: " ", count: column) + rest
                items.append(block(indent: column, parent: n))
            } else {
                items.append(inlineValue(rest, parent: n))
            }
        }
        return .sequence(items)
    }

    /// The value of a key (or `-`) at indent `parent` with nothing after it on its
    /// line: a deeper block, a list level with a map key (Goose writes those), or null.
    private mutating func nested(parent: Int, allowLevelList: Bool) -> Node {
        guard let i = nextSignificant(from: pos) else { return .scalar("") }
        if indent(i) > parent {
            pos = i
            return block(indent: indent(i), parent: parent)
        }
        if allowLevelList, indent(i) == parent, Self.isSequenceItem(String(lines[i].dropFirst(parent))) {
            pos = i
            return sequence(indent: parent)
        }
        return .scalar("")
    }

    // MARK: Scalars

    /// A value that starts on the current line as `text`. Continuation lines must
    /// be indented deeper than `parent`. Leaves `pos` on the next unread line.
    /// `levelList`: a `- ` list level with `parent` may be the value (map keys only).
    private mutating func inlineValue(_ text: String, parent: Int, levelList: Bool = false) -> Node {
        // A tag (`!Ref`) or anchor (`&base`) is dropped; the value after it is read
        // as usual. Aliases (`*base`) are not resolved: they stay plain text.
        if text.first == "!" || text.first == "&" {
            let rest = String(text.drop { $0 != " " && $0 != "\t" }).trimmingCharacters(in: .whitespaces)
            if rest.isEmpty || rest.hasPrefix("#") {
                pos += 1
                return nested(parent: parent, allowLevelList: levelList)
            }
            return inlineValue(rest, parent: parent, levelList: levelList)
        }
        switch text.first {
        case "\"": if let s = quoted(text, double: true) { return .scalar(s) }
        case "'": if let s = quoted(text, double: false) { return .scalar(s) }
        case "|", ">": if let header = BlockHeader(text) { return .scalar(blockScalar(header, parent: parent)) }
        case "[", "{": if let node = flow(text) { return node }
        default: break
        }
        return .scalar(plain(text, parent: parent))
    }

    /// A plain scalar: its first line, then every deeper line folded in with a
    /// space (an empty line in between becomes a line break). A comment ends it.
    private mutating func plain(_ text: String, parent: Int) -> String {
        var (out, ended) = Self.stripComment(text)
        pos += 1
        var blanks = 0
        var j = pos
        while !ended, j < lines.count {
            let trimmed = lines[j].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { blanks += 1; j += 1; continue }
            if indent(j) <= parent || trimmed.hasPrefix("#") { break }
            let (piece, hadComment) = Self.stripComment(trimmed)
            out += blanks == 0 ? " " : String(repeating: "\n", count: blanks)
            out += piece
            blanks = 0
            ended = hadComment
            j += 1
            pos = j
        }
        return out
    }

    /// A quoted scalar that may span lines, or nil when it never closes (then the
    /// caller reads the line as plain text rather than swallowing the file). Like
    /// PyYAML, which writes Hermes' config, a continuation line may sit at any
    /// indent: the closing quote, not the indent, ends the scalar.
    private mutating func quoted(_ text: String, double: Bool) -> String? {
        var raw: [String] = []
        var current = String(text.dropFirst())
        var j = pos
        while true {
            if let close = Self.closingQuote(in: current, double: double) {
                raw.append(String(current[..<close]))
                pos = j + 1
                return Self.foldQuoted(raw, double: double)
            }
            raw.append(current)
            j += 1
            guard j < lines.count else { return nil }
            current = lines[j]
        }
    }

    private struct BlockHeader {
        let literal: Bool
        let chomp: Character?   // "-" strip, "+" keep, nil clip
        let explicitIndent: Int?

        init?(_ text: String) {
            let (header, _) = Parser.stripComment(text)
            var chars = Array(header.trimmingCharacters(in: .whitespaces))
            guard let first = chars.first, first == "|" || first == ">" else { return nil }
            literal = first == "|"
            chars.removeFirst()
            var chomp: Character?
            var explicitIndent: Int?
            for c in chars {
                if (c == "-" || c == "+"), chomp == nil {
                    chomp = c
                } else if let d = c.wholeNumberValue, (1...9).contains(d), explicitIndent == nil {
                    explicitIndent = d
                } else {
                    return nil
                }
            }
            self.chomp = chomp
            self.explicitIndent = explicitIndent
        }
    }

    /// `|` keeps line breaks, `>` folds them; `-` drops the final break, `+` keeps
    /// every trailing one, default keeps exactly one.
    private mutating func blockScalar(_ header: BlockHeader, parent: Int) -> String {
        pos += 1
        let base = max(parent, 0)
        var contentIndent: Int
        if let explicit = header.explicitIndent {
            contentIndent = base + explicit
        } else {
            var k = pos
            while k < lines.count, lines[k].trimmingCharacters(in: .whitespaces).isEmpty { k += 1 }
            contentIndent = k < lines.count ? indent(k) : 0
        }
        if contentIndent <= parent { contentIndent = Int.max }   // no deeper line: empty

        var body: [String] = []
        while pos < lines.count {
            let line = lines[pos]
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                body.append(line.count > contentIndent ? String(line.dropFirst(contentIndent)) : "")
            } else if indent(pos) >= contentIndent {
                body.append(String(line.dropFirst(contentIndent)))
            } else {
                break
            }
            pos += 1
        }

        var trailing = 0
        while let last = body.last, last.isEmpty { body.removeLast(); trailing += 1 }
        // Every collected line ends in a break, except the file's last line when
        // the file has no final newline.
        let breaks = body.count + trailing - (pos == lines.count && !endsWithNewline ? 1 : 0)
        let breaksAfterContent = max(0, breaks - max(0, body.count - 1))
        if body.isEmpty { return header.chomp == "+" ? String(repeating: "\n", count: max(0, breaks)) : "" }
        let text = header.literal ? body.joined(separator: "\n") : Self.foldBlock(body)
        switch header.chomp {
        case "-": return text
        case "+": return text + String(repeating: "\n", count: breaksAfterContent)
        default: return text + (breaksAfterContent > 0 ? "\n" : "")
        }
    }

    // MARK: Flow collections

    /// `[a, b]` / `{k: v}`, gathered across lines (comments dropped) until the
    /// brackets balance; as with quoted scalars, the closing bracket ends it.
    private mutating func flow(_ text: String) -> Node? {
        var balance = FlowBalance()
        var parts = [Self.stripFlowComment(text)]
        var closed = balance.feed(parts[0])
        var j = pos
        while !closed {
            j += 1
            guard j < lines.count else { return nil }
            let part = Self.stripFlowComment(lines[j].trimmingCharacters(in: .whitespaces))
            parts.append(part)
            closed = balance.feed(" " + part)
        }
        var reader = FlowReader(Array(parts.joined(separator: " ")))
        guard let node = reader.value() else { return nil }
        pos = j + 1
        return node
    }

    // MARK: Line helpers

    private func indent(_ i: Int) -> Int { YAMLBlock.indent(lines[i]) }

    /// The next line at or after `i` that is neither blank nor a whole-line comment.
    private func nextSignificant(from i: Int) -> Int? {
        var k = i
        while k < lines.count {
            let t = lines[k].trimmingCharacters(in: .whitespaces)
            if !t.isEmpty, !t.hasPrefix("#") { return k }
            k += 1
        }
        return nil
    }

    private mutating func skip(deeperThan n: Int) {
        while let i = nextSignificant(from: pos), indent(i) > n { pos = i + 1 }
    }

    // MARK: Pure helpers

    static func isSequenceItem(_ content: String) -> Bool {
        content == "-" || content.hasPrefix("- ") || content.hasPrefix("-\t")
    }

    /// `key: rest` → (key, rest). The colon must be followed by a space, a tab or
    /// the end of the line, so `http://x` and `C:\x` are never keys.
    static func splitKey(_ content: String) -> (String, String)? {
        let chars = Array(content)
        guard let first = chars.first, !"#[{|>&*!%@`".contains(first) else { return nil }
        var i = 0
        var key: String
        if first == "\"" || first == "'" {
            let rest = String(chars.dropFirst())
            guard let close = closingQuote(in: rest, double: first == "\"") else { return nil }
            let inner = String(rest[..<close])
            key = foldQuoted([inner], double: first == "\"")
            i = inner.count + 2
            while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }
            guard i < chars.count, chars[i] == ":" else { return nil }
        } else {
            while i < chars.count {
                if chars[i] == "#", i > 0, chars[i - 1] == " " || chars[i - 1] == "\t" { return nil }
                if chars[i] == ":", i + 1 == chars.count || chars[i + 1] == " " || chars[i + 1] == "\t" { break }
                i += 1
            }
            guard i < chars.count else { return nil }
            key = String(chars[..<i]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { return nil }
        }
        let after = i + 1 < chars.count ? String(chars[(i + 1)...]) : ""
        guard after.isEmpty || after.first == " " || after.first == "\t" else { return nil }
        return (key, after)
    }

    /// Cut a ` #` comment off a plain scalar. Returns the trimmed text and
    /// whether a comment was found (which ends a multi-line plain scalar).
    static func stripComment(_ s: String) -> (String, Bool) {
        let chars = Array(s)
        for i in chars.indices where chars[i] == "#" && (i == 0 || chars[i - 1] == " " || chars[i - 1] == "\t") {
            return (String(chars[..<i]).trimmingCharacters(in: .whitespaces), true)
        }
        return (s.trimmingCharacters(in: .whitespaces), false)
    }

    /// Index of the quote that closes a scalar whose opening quote was already
    /// dropped. Double quotes skip `\x` escapes; single quotes skip `''`.
    static func closingQuote(in s: String, double: Bool) -> String.Index? {
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if double {
                if c == "\\" {
                    i = s.index(after: i)
                    if i < s.endIndex { i = s.index(after: i) }
                    continue
                }
                if c == "\"" { return i }
            } else if c == "'" {
                let next = s.index(after: i)
                if next < s.endIndex, s[next] == "'" { i = s.index(after: next); continue }
                return i
            }
            i = s.index(after: i)
        }
        return nil
    }

    /// Fold the raw lines of a quoted scalar: trailing and leading white space
    /// around a break goes, a single break becomes a space, each empty line a
    /// `\n`, and (double quotes) a `\` at the end of a line joins without a space.
    static func foldQuoted(_ raw: [String], double: Bool) -> String {
        var out = ""
        var emptyLines = 0
        var joinTight = false
        for (idx, rawLine) in raw.enumerated() {
            let isFirst = idx == 0, isLast = idx == raw.count - 1
            var line = Substring(rawLine)
            if !isFirst { line = line.drop { $0 == " " || $0 == "\t" } }
            if !isLast { line = trimTrailingWhitespace(line, double: double) }
            if !isFirst, !isLast, line.isEmpty { emptyLines += 1; continue }

            var escapedBreak = false
            if double, !isLast, trailingBackslashes(line) % 2 == 1 {
                line = line.dropLast()
                escapedBreak = true
            }
            if !isFirst {
                if joinTight {
                    out += String(repeating: "\n", count: emptyLines)
                } else {
                    out += emptyLines == 0 ? " " : String(repeating: "\n", count: emptyLines)
                }
            }
            out += double ? unescape(line) : line.replacingOccurrences(of: "''", with: "'")
            emptyLines = 0
            joinTight = escapedBreak
        }
        return out
    }

    private static func trimTrailingWhitespace(_ s: Substring, double: Bool) -> Substring {
        var t = s
        while let last = t.last, last == " " || last == "\t" {
            let rest = t.dropLast()
            if double, trailingBackslashes(rest) % 2 == 1 { break }   // `\ ` is an escaped space
            t = rest
        }
        return t
    }

    private static func trailingBackslashes(_ s: Substring) -> Int {
        s.reversed().prefix { $0 == "\\" }.count
    }

    /// Decode double-quoted escapes. An unknown escape is kept as written.
    static func unescape(_ s: Substring) -> String {
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            i = s.index(after: i)
            guard c == "\\", i < s.endIndex else { out.append(c); continue }
            let e = s[i]
            i = s.index(after: i)
            switch e {
            case "0": out.append("\u{0}")
            case "a": out.append("\u{7}")
            case "b": out.append("\u{8}")
            case "t", "\t": out.append("\t")
            case "n": out.append("\n")
            case "v": out.append("\u{B}")
            case "f": out.append("\u{C}")
            case "r": out.append("\r")
            case "e": out.append("\u{1B}")
            case " ": out.append(" ")
            case "\"": out.append("\"")
            case "/": out.append("/")
            case "\\": out.append("\\")
            case "N": out.append("\u{85}")
            case "_": out.append("\u{A0}")
            case "L": out.append("\u{2028}")
            case "P": out.append("\u{2029}")
            case "x", "u", "U":
                let width = e == "x" ? 2 : (e == "u" ? 4 : 8)
                let end = s.index(i, offsetBy: width, limitedBy: s.endIndex) ?? s.endIndex
                if let code = UInt32(s[i..<end], radix: 16), s.distance(from: i, to: end) == width,
                   let scalar = Unicode.Scalar(code) {
                    out.unicodeScalars.append(scalar)
                    i = end
                } else {
                    out += "\\\(e)"
                }
            default:
                out += "\\\(e)"
            }
        }
        return out
    }

    /// Fold the lines of a `>` block scalar (already stripped of its indent):
    /// neighbouring normal lines join with a space, empty lines become breaks,
    /// and more-indented lines keep their breaks.
    static func foldBlock(_ body: [String]) -> String {
        var out = ""
        var previous: String?
        var emptyLines = 0
        for line in body {
            if line.isEmpty { emptyLines += 1; continue }
            let moreIndented = line.first == " " || line.first == "\t"
            if let prev = previous {
                let prevMore = prev.first == " " || prev.first == "\t"
                if moreIndented || prevMore {
                    out += String(repeating: "\n", count: emptyLines + 1)
                } else {
                    out += emptyLines == 0 ? " " : String(repeating: "\n", count: emptyLines)
                }
            } else {
                out += String(repeating: "\n", count: emptyLines)
            }
            out += line
            previous = line
            emptyLines = 0
        }
        return out
    }

    /// Cut a ` #` comment that sits outside quotes off one line of a flow collection.
    static func stripFlowComment(_ s: String) -> String {
        var quote: Character?
        var escaped = false
        var previous: Character = " "
        for (offset, c) in s.enumerated() {
            defer { previous = c }
            if let q = quote {
                if escaped { escaped = false; continue }
                if q == "\"", c == "\\" { escaped = true; continue }
                if c == q { quote = nil }
                continue
            }
            if c == "\"" || c == "'", "[{,: \t".contains(previous) { quote = c; continue }
            if c == "#", previous == " " || previous == "\t" {
                return String(s.prefix(offset)).trimmingCharacters(in: .whitespaces)
            }
        }
        return s
    }
}

/// Tracks `[` / `{` depth (outside quotes) line by line, so a long multi-line
/// flow collection (a JSON file offered to the YAML shapes) is scanned once, not
/// once per added line. A quote opens a scalar only at the start of a token.
private struct FlowBalance {
    private var depth = 0
    private var quote: Character?
    private var escaped = false
    private var previous: Character = "["

    /// Feed the next piece; true once the outermost bracket has closed.
    mutating func feed(_ s: String) -> Bool {
        for c in s {
            defer { previous = c }
            if let q = quote {
                if escaped { escaped = false; continue }
                if q == "\"", c == "\\" { escaped = true; continue }
                if c == q { quote = nil }
                continue
            }
            switch c {
            case "\"", "'":
                if "[{,: \t".contains(previous) { quote = c }
            case "[", "{": depth += 1
            case "]", "}":
                depth -= 1
                if depth <= 0 { return true }
            default: break
            }
        }
        return depth <= 0
    }
}

// MARK: - Flow reader

/// Reads one flow node (`[…]`, `{…}` or a scalar inside them) from characters.
private struct FlowReader {
    typealias Node = YAMLBlock.Node

    private let chars: [Character]
    private var i = 0

    init(_ chars: [Character]) { self.chars = chars }

    mutating func value() -> Node? {
        skipSpace()
        skipProperties()
        guard i < chars.count else { return nil }
        switch chars[i] {
        case "[": return sequence()
        case "{": return mapping()
        case "\"", "'": return quoted().map(Node.scalar)
        default: return .scalar(plain(stopAtColon: false))
        }
    }

    private mutating func sequence() -> Node? {
        i += 1
        var items: [Node] = []
        var last = -1
        while true {
            skipSpace()
            // No progress since the last turn means malformed input: give up
            // rather than loop (a JSON file offered to the YAML shapes hit this).
            guard i < chars.count, i != last else { return nil }
            last = i
            if chars[i] == "]" { i += 1; return .sequence(items) }
            if chars[i] == "," { i += 1; continue }
            skipProperties()
            guard i < chars.count else { return nil }
            if chars[i] != "[", chars[i] != "{" {
                // A scalar, or `key: value` (a one-pair map inside a list).
                let key: String
                if chars[i] == "\"" || chars[i] == "'" {
                    guard let k = quoted() else { return nil }
                    key = k
                } else {
                    key = plain(stopAtColon: true)
                }
                skipSpace()
                guard i < chars.count, chars[i] == ":" else { items.append(.scalar(key)); continue }
                i += 1
                skipSpace()
                var node: Node = .scalar("")
                if i < chars.count, chars[i] != ",", chars[i] != "]" {
                    guard let v = value() else { return nil }
                    node = v
                }
                items.append(.mapping([.init(key: key, value: node)]))
                continue
            }
            guard let item = value() else { return nil }
            items.append(item)
        }
    }

    private mutating func mapping() -> Node? {
        i += 1
        var pairs: [Node.Pair] = []
        var last = -1
        while true {
            skipSpace()
            guard i < chars.count, i != last else { return nil }   // no progress: malformed
            last = i
            if chars[i] == "}" { i += 1; return .mapping(pairs) }
            if chars[i] == "," { i += 1; continue }
            let key: String
            if chars[i] == "\"" || chars[i] == "'" {
                guard let k = quoted() else { return nil }
                key = k
            } else {
                key = plain(stopAtColon: true)
            }
            skipSpace()
            var node: Node = .scalar("")
            if i < chars.count, chars[i] == ":" {
                i += 1
                skipSpace()
                if i < chars.count, chars[i] != ",", chars[i] != "}" {
                    guard let v = value() else { return nil }
                    node = v
                }
            }
            pairs.append(.init(key: key, value: node))
        }
    }

    /// A quoted flow scalar, scanned in place (copying the rest of the text per
    /// scalar made a large JSON file quadratic).
    private mutating func quoted() -> String? {
        let double = chars[i] == "\""
        var k = i + 1
        while k < chars.count {
            let c = chars[k]
            if double {
                if c == "\\" { k += 2; continue }
                if c == "\"" { break }
            } else if c == "'" {
                if k + 1 < chars.count, chars[k + 1] == "'" { k += 2; continue }
                break
            }
            k += 1
        }
        guard k < chars.count else { return nil }
        let inner = String(chars[(i + 1)..<k])
        i = k + 1
        return Parser.foldQuoted([inner], double: double)
    }

    /// A plain flow scalar: up to `,` `[` `]` `{` `}` (and `: ` for a map key).
    private mutating func plain(stopAtColon: Bool) -> String {
        let start = i
        while i < chars.count {
            let c = chars[i]
            if ",[]{}".contains(c) { break }
            if stopAtColon, c == ":", i + 1 == chars.count || " ,}]".contains(chars[i + 1]) { break }
            i += 1
        }
        return String(chars[start..<i]).trimmingCharacters(in: .whitespaces)
    }

    /// Drop a tag (`!Ref`) or anchor (`&a`) in front of a flow node.
    private mutating func skipProperties() {
        while i < chars.count, chars[i] == "!" || chars[i] == "&" {
            while i < chars.count, !" \t,[]{}".contains(chars[i]) { i += 1 }
            skipSpace()
        }
    }

    private mutating func skipSpace() {
        while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }
    }
}
