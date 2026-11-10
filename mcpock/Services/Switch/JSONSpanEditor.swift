import Foundation

/// Where one JSON value sits in a text, with its children (the server switch).
/// Indexes count Unicode scalars; `end` is one past the value's last scalar.
struct JSONSpan {
    indirect enum Kind {
        case object([Member])
        case array([JSONSpan])
        case string(String)
        case other
    }

    struct Member {
        let key: String
        /// The key's opening quote.
        let keyStart: Int
        let value: JSONSpan
    }

    let start: Int
    let end: Int
    let kind: Kind

    var members: [Member]? { if case .object(let m) = kind { return m }; return nil }
    var elements: [JSONSpan]? { if case .array(let e) = kind { return e }; return nil }
    var string: String? { if case .string(let s) = kind { return s }; return nil }

    func member(_ key: String) -> Member? { members?.first { $0.key == key } }

    /// The value at `path`, walking object keys from this value.
    func value(at path: [String]) -> JSONSpan? {
        var current = self
        for key in path {
            guard let next = current.member(key) else { return nil }
            current = next.value
        }
        return current
    }
}

/// Changes one small part of a JSON or JSONC file and leaves every other
/// character alone: comments, key order and indentation stay as the agent (or
/// the user) wrote them. The server switch's JSON writers are built on it;
/// nothing here reads or writes a file.
///
/// Every edit returns the whole new text. The callers check the result by
/// parsing it (`ServerSwitch.verify`), so an edit that went wrong is never
/// written.
enum JSONSpanEditor {
    enum EditError: Error, Equatable {
        case notJSON
        case missing(String)
        case alreadyThere(String)
    }

    // MARK: Reading

    static func parse(_ text: String) -> JSONSpan? {
        var parser = Parser(scalars: Array(text.unicodeScalars))
        return parser.document()
    }

    private struct Parser {
        let scalars: [Unicode.Scalar]
        var i = 0
        var depth = 0

        mutating func document() -> JSONSpan? {
            if i < scalars.count, scalars[i] == "\u{FEFF}" { i += 1 }
            skipTrivia()
            guard let root = value() else { return nil }
            skipTrivia()
            return i == scalars.count ? root : nil
        }

        /// Whitespace and JSONC comments.
        mutating func skipTrivia() {
            while i < scalars.count {
                let c = scalars[i]
                if c == " " || c == "\t" || c == "\n" || c == "\r" {
                    i += 1
                } else if c == "/", i + 1 < scalars.count, scalars[i + 1] == "/" {
                    while i < scalars.count, scalars[i] != "\n" { i += 1 }
                } else if c == "/", i + 1 < scalars.count, scalars[i + 1] == "*" {
                    i += 2
                    while i + 1 < scalars.count, !(scalars[i] == "*" && scalars[i + 1] == "/") { i += 1 }
                    i = min(i + 2, scalars.count)
                } else {
                    return
                }
            }
        }

        mutating func value() -> JSONSpan? {
            guard i < scalars.count, depth < 256 else { return nil }
            let start = i
            switch scalars[i] {
            case "{":
                i += 1
                depth += 1
                defer { depth -= 1 }
                var members: [JSONSpan.Member] = []
                while true {
                    skipTrivia()
                    guard i < scalars.count else { return nil }
                    if scalars[i] == "}" { i += 1; break }
                    let keyStart = i
                    guard scalars[i] == "\"", let key = string() else { return nil }
                    skipTrivia()
                    guard i < scalars.count, scalars[i] == ":" else { return nil }
                    i += 1
                    skipTrivia()
                    guard let v = value() else { return nil }
                    members.append(.init(key: key, keyStart: keyStart, value: v))
                    skipTrivia()
                    guard i < scalars.count else { return nil }
                    if scalars[i] == "," { i += 1 } else if scalars[i] != "}" { return nil }
                }
                return JSONSpan(start: start, end: i, kind: .object(members))
            case "[":
                i += 1
                depth += 1
                defer { depth -= 1 }
                var elements: [JSONSpan] = []
                while true {
                    skipTrivia()
                    guard i < scalars.count else { return nil }
                    if scalars[i] == "]" { i += 1; break }
                    guard let v = value() else { return nil }
                    elements.append(v)
                    skipTrivia()
                    guard i < scalars.count else { return nil }
                    if scalars[i] == "," { i += 1 } else if scalars[i] != "]" { return nil }
                }
                return JSONSpan(start: start, end: i, kind: .array(elements))
            case "\"":
                guard let s = string() else { return nil }
                return JSONSpan(start: start, end: i, kind: .string(s))
            default:
                // A number, true, false or null: up to the next structural scalar.
                while i < scalars.count, !",}] \t\r\n/".unicodeScalars.contains(scalars[i]) { i += 1 }
                return i > start ? JSONSpan(start: start, end: i, kind: .other) : nil
            }
        }

        /// Reads the string whose opening quote is at `i`; leaves `i` after its
        /// closing quote. Escapes are decoded by Foundation.
        mutating func string() -> String? {
            let start = i
            i += 1
            while i < scalars.count, scalars[i] != "\"" {
                if scalars[i] == "\\" { i += 1 }
                if i < scalars.count, scalars[i] == "\n" { return nil }
                i += 1
            }
            guard i < scalars.count else { return nil }
            i += 1
            let literal = text(scalars[start..<i])
            let decoded = try? JSONSerialization.jsonObject(with: Data("[\(literal)]".utf8)) as? [String]
            return decoded?.first
        }
    }

    // MARK: Editing

    /// `"key": value` added as the object's last member. An object that is not
    /// there is an error; a key that is already there is too.
    static func insertMember(in text: String, objectPath: [String], key: String, valueText: String) throws -> String {
        let scalars = Array(text.unicodeScalars)
        guard let root = parse(text) else { throw EditError.notJSON }
        guard let object = root.value(at: objectPath), let members = object.members else {
            throw EditError.missing(objectPath.joined(separator: "."))
        }
        guard object.member(key) == nil else { throw EditError.alreadyThere(key) }
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        let member = "\(quoted(key)): \(valueText)"
        if let last = members.last {
            let piece: String
            if let indent = lineIndent(scalars, at: last.keyStart) {
                piece = "," + newline + indent + member
            } else {
                piece = ", " + member
            }
            return splice(scalars, last.value.end..<last.value.end, piece)
        }
        // An empty object: opened up when the file is written on several lines.
        guard text.contains("\n") else { return splice(scalars, object.start..<object.end, "{\(member)}") }
        let outer = leadingWhitespace(scalars, ofLineAt: object.start)
        let piece = "{" + newline + outer + indentUnit(scalars) + member + newline + outer + "}"
        return splice(scalars, object.start..<object.end, piece)
    }

    /// Takes `key` out of the object at `objectPath`, with its comma. Returns
    /// the new text and the removed value exactly as it was written.
    static func removeMember(in text: String, objectPath: [String], key: String) throws -> (text: String, valueText: String) {
        let scalars = Array(text.unicodeScalars)
        guard let root = parse(text) else { throw EditError.notJSON }
        guard let object = root.value(at: objectPath), let members = object.members,
              let index = members.firstIndex(where: { $0.key == key }) else {
            throw EditError.missing((objectPath + [key]).joined(separator: "."))
        }
        let member = members[index]
        let valueText = self.text(scalars[member.value.start..<member.value.end])
        let range = removalRange(
            index: index,
            starts: members.map(\.keyStart),
            ends: members.map(\.value.end),
            container: object.start..<object.end
        )
        return (splice(scalars, range, ""), valueText)
    }

    /// Replaces the value of `key` in the object at `objectPath`, or adds the
    /// member when it is not there.
    static func setMember(in text: String, objectPath: [String], key: String, valueText: String) throws -> String {
        let scalars = Array(text.unicodeScalars)
        guard let root = parse(text) else { throw EditError.notJSON }
        guard let object = root.value(at: objectPath), object.members != nil else {
            throw EditError.missing(objectPath.joined(separator: "."))
        }
        if let existing = object.member(key) {
            return splice(scalars, existing.value.start..<existing.value.end, valueText)
        }
        return try insertMember(in: text, objectPath: objectPath, key: key, valueText: valueText)
    }

    /// Adds an element at the end of the array at `arrayPath`.
    static func appendElement(in text: String, arrayPath: [String], elementText: String) throws -> String {
        let scalars = Array(text.unicodeScalars)
        guard let root = parse(text) else { throw EditError.notJSON }
        guard let array = root.value(at: arrayPath), let elements = array.elements else {
            throw EditError.missing(arrayPath.joined(separator: "."))
        }
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        if let last = elements.last {
            let piece: String
            if let indent = lineIndent(scalars, at: last.start) {
                piece = "," + newline + indent + elementText
            } else {
                piece = ", " + elementText
            }
            return splice(scalars, last.end..<last.end, piece)
        }
        guard text.contains("\n") else { return splice(scalars, array.start..<array.end, "[\(elementText)]") }
        let outer = leadingWhitespace(scalars, ofLineAt: array.start)
        let piece = "[" + newline + outer + indentUnit(scalars) + elementText + newline + outer + "]"
        return splice(scalars, array.start..<array.end, piece)
    }

    /// Takes the element at `index` out of the array at `arrayPath`.
    static func removeElement(in text: String, arrayPath: [String], index: Int) throws -> String {
        let scalars = Array(text.unicodeScalars)
        guard let root = parse(text) else { throw EditError.notJSON }
        guard let array = root.value(at: arrayPath), let elements = array.elements, elements.indices.contains(index) else {
            throw EditError.missing(arrayPath.joined(separator: "."))
        }
        let range = removalRange(index: index, starts: elements.map(\.start), ends: elements.map(\.end),
                                 container: array.start..<array.end)
        return splice(scalars, range, "")
    }

    // MARK: Helpers

    /// What to cut so the neighbours and their commas still read right: a
    /// later item goes with the comma before it, the first one with the comma
    /// after it, an only item with everything between the brackets (`{}`).
    private static func removalRange(index: Int, starts: [Int], ends: [Int], container: Range<Int>) -> Range<Int> {
        if index > 0 { return ends[index - 1]..<ends[index] }
        if starts.count > 1 { return starts[0]..<starts[1] }
        return (container.lowerBound + 1)..<(container.upperBound - 1)
    }

    /// The whitespace before `index` when nothing else is on its line before
    /// it; nil when the value sits further along a line.
    static func lineIndent(_ scalars: [Unicode.Scalar], at index: Int) -> String? {
        var i = index
        while i > 0, scalars[i - 1] == " " || scalars[i - 1] == "\t" { i -= 1 }
        guard i == 0 || scalars[i - 1] == "\n" else { return nil }
        return text(scalars[i..<index])
    }

    /// The whitespace the line holding `index` starts with.
    static func leadingWhitespace(_ scalars: [Unicode.Scalar], ofLineAt index: Int) -> String {
        var lineStart = index
        while lineStart > 0, scalars[lineStart - 1] != "\n" { lineStart -= 1 }
        var i = lineStart
        while i < scalars.count, scalars[i] == " " || scalars[i] == "\t" { i += 1 }
        return text(scalars[lineStart..<i])
    }

    /// One level of indentation as this file writes it: the first indented
    /// line's whitespace, two spaces when there is none.
    static func indentUnit(_ scalars: [Unicode.Scalar]) -> String {
        var i = 0
        while i < scalars.count {
            if scalars[i] == "\n" {
                var j = i + 1
                while j < scalars.count, scalars[j] == " " || scalars[j] == "\t" { j += 1 }
                if j > i + 1, j < scalars.count, scalars[j] != "\n", scalars[j] != "\r" {
                    return text(scalars[(i + 1)..<j])
                }
            }
            i += 1
        }
        return "  "
    }

    /// `key` as a JSON string, quotes and escapes included.
    static func quoted(_ key: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [key], options: [.withoutEscapingSlashes]),
              let array = String(data: data, encoding: .utf8) else { return "\"\(key)\"" }
        return String(array.dropFirst().dropLast())
    }

    private static func splice(_ scalars: [Unicode.Scalar], _ range: Range<Int>, _ piece: String) -> String {
        text(scalars[..<range.lowerBound]) + piece + text(scalars[range.upperBound...])
    }

    static func text(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }
}
