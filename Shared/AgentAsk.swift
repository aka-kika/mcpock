import Foundation

/// An agent asking the user to hide or show a tool, or to turn a server off
/// or on (1.16, Kika's ask, 10 Nov). The `mcpock_ask` tool of the helper
/// writes one small file per ask into mcpock's own folder; it never touches an
/// agent's config. The app shows the ask, and only the user's yes runs the
/// usual switch (sheet first, backup kept). Compiled into the app and the helper.
struct AgentAsk: Codable, Equatable, Sendable {
    enum Action: String, Codable, CaseIterable, Sendable {
        case hideTool = "hide_tool"
        case showTool = "show_tool"
        case turnOff = "turn_off"
        case turnOn = "turn_on"

        var needsTool: Bool { self == .hideTool || self == .showTool }

        /// "hide delete_repository in github", "turn github off".
        func words(server: String, tool: String?) -> String {
            switch self {
            case .hideTool: return "hide \(tool ?? "a tool") in \(server)"
            case .showTool: return "show \(tool ?? "a tool") in \(server) again"
            case .turnOff: return "turn \(server) off"
            case .turnOn: return "turn \(server) on"
            }
        }
    }

    /// A UUID, also the file's name.
    var id: String
    var server: String
    var tool: String?
    var action: Action
    /// The agent's own words, one line, at most `maxReason` characters.
    var reason: String
    /// The MCP client that asked, as it named itself ("claude-code").
    var agent: String
    var asked: Date

    static let maxReason = 200
    /// Asks waiting at once; more are refused until the user answers some.
    static let maxWaiting = 10
    /// An ask nobody answered goes away after a day.
    static let lifetime: TimeInterval = 24 * 3600
    /// A file larger than this is not an ask.
    static let maxFileBytes = 4096

    /// One line of plain text: line breaks and control characters become
    /// spaces, runs of spaces collapse, cut at `limit`.
    static func oneLine(_ text: String, limit: Int) -> String {
        let flat = String(text.unicodeScalars.map { scalar -> Character in
            scalar.properties.generalCategory == .control || scalar.properties.generalCategory == .lineSeparator
                || scalar.properties.generalCategory == .paragraphSeparator || scalar == "\u{2028}" ? " " : Character(scalar)
        })
        let words = flat.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        return words.count > limit ? String(words.prefix(limit)) : words
    }

    /// "Claude Code" for "claude-code"; the client's own name otherwise,
    /// cleaned to one short line.
    static func agentLabel(_ client: String?) -> String {
        let raw = oneLine(client ?? "", limit: 40)
        let key = raw.lowercased().filter { $0.isLetter || $0.isNumber }
        let known: [String: String] = [
            "claudecode": "Claude Code", "claudeai": "Claude Desktop", "claudedesktop": "Claude Desktop",
            "cursor": "Cursor", "codex": "Codex", "codexmcpclient": "Codex", "grok": "Grok", "grokcli": "Grok",
            "goose": "Goose", "hermes": "Hermes", "opencode": "OpenCode", "vscode": "VS Code",
            "visualstudiocode": "VS Code", "windsurf": "Windsurf", "gemini": "Gemini CLI", "geminicli": "Gemini CLI",
        ]
        if let label = known[key] { return label }
        return raw.isEmpty ? "An agent" : raw
    }
}

/// What became of an ask, as the status file tells agents (1.16).
struct AskRecord: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        /// Shown to the user, no answer yet.
        case waiting
        /// The user said yes and the switch wrote it.
        case done
        /// The user said no (or closed the sheet without writing).
        case no
        /// Nobody answered within a day.
        case expired
    }

    var id: String
    var server: String
    var tool: String?
    var action: AgentAsk.Action
    var agent: String
    var asked: Date
    var state: State
    var answered: Date?
}

/// The folder asks wait in: `~/Library/Application Support/mcpock/asks/`,
/// readable only by the user. One file per ask, named `<uuid>.json`.
enum AskBox {
    static func directory(base: URL = MCPockStatus.defaultDirectory()) -> URL {
        base.appendingPathComponent("asks", isDirectory: true)
    }

    enum Refusal: Error, Equatable {
        case full
        case cannotWrite
    }

    /// Writes `ask` as a new file, readable only by the user from its first
    /// byte. Refused when `maxWaiting` asks already wait.
    static func write(_ ask: AgentAsk, to folder: URL) throws {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // A folder someone else could write into is tightened, like the status folder.
        _ = chmod(folder.path, 0o700)
        let waiting = (try? fm.contentsOfDirectory(atPath: folder.path))?.filter { isAskName($0) }.count ?? 0
        guard waiting < AgentAsk.maxWaiting else { throw Refusal.full }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(ask), data.count <= AgentAsk.maxFileBytes else { throw Refusal.cannotWrite }
        let file = folder.appendingPathComponent(ask.id + ".json")
        let fd = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Refusal.cannotWrite }
        var ok = false
        defer {
            close(fd)
            if !ok { unlink(file.path) }
        }
        let wrote = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard wrote == data.count else { throw Refusal.cannotWrite }
        ok = true
    }

    /// "<uuid>.json", nothing else.
    static func isAskName(_ name: String) -> Bool {
        guard name.hasSuffix(".json") else { return false }
        return UUID(uuidString: String(name.dropLast(5))) != nil
    }

    /// The asks waiting in `folder` that pass every check; the rest are
    /// returned as `rejected` names for the app to remove. Read-only.
    static func read(from folder: URL, now: Date) -> (asks: [AgentAsk], expired: [AgentAsk], rejected: [String]) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return ([], [], []) }
        var asks: [AgentAsk] = []
        var expired: [AgentAsk] = []
        var rejected: [String] = []
        for name in names.sorted() where !name.hasPrefix(".") {
            guard isAskName(name), let ask = readOne(folder.appendingPathComponent(name)),
                  ask.id.lowercased() + ".json" == name.lowercased() else {
                rejected.append(name)
                continue
            }
            if now.timeIntervalSince(ask.asked) > AgentAsk.lifetime {
                expired.append(ask)
            } else if ask.asked.timeIntervalSince(now) > 300 {
                rejected.append(name) // from the future: not a real ask
            } else {
                asks.append(ask)
            }
        }
        return (asks.sorted { $0.asked < $1.asked }, expired, rejected)
    }

    /// One file, only if it is a plain file of this user's, not readable by
    /// others, small, and exactly an ask's keys with sane values.
    static func readOne(_ file: URL) -> AgentAsk? {
        var info = stat()
        guard lstat(file.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(),
              info.st_mode & 0o077 == 0, info.st_size <= AgentAsk.maxFileBytes,
              let data = FileManager.default.contents(atPath: file.path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let allowed: Set<String> = ["id", "server", "tool", "action", "reason", "agent", "asked"]
        guard Set(object.keys).isSubset(of: allowed) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let ask = try? decoder.decode(AgentAsk.self, from: data) else { return nil }
        let clean = AgentAsk.oneLine(ask.reason, limit: AgentAsk.maxReason)
        guard !ask.server.isEmpty, ask.server.count <= 200, clean == ask.reason, !clean.isEmpty,
              (ask.tool ?? "").count <= 200, ask.action.needsTool == (ask.tool != nil),
              ask.agent.count <= 40 else { return nil }
        return ask
    }
}
