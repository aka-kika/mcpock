import Foundation

/// The status snapshot mcpock writes to `~/Library/Application Support/mcpock/status.json`
/// whenever its results change (round 7), and the only thing the bundled
/// `mcpock-mcp` helper reads. Compiled into both the app and the helper.
///
/// **Never holds a secret.** Env and header entries are names only; command
/// lines, URLs and failure texts go through `SecretMask` in the app before they
/// land here (`StatusSnapshotTests` pins that down).
struct MCPockStatus: Codable, Equatable, Sendable {
    /// Bumped when a field changes meaning; the helper reads older files as is.
    static let currentSchema = 1

    var schema: Int
    /// When the app wrote this file.
    var generated: Date
    var appVersion: String
    /// The app's process id, so the helper can tell a live snapshot from one
    /// left behind by an mcpock that has quit.
    var pid: Int32
    /// A check is running right now.
    var checking: Bool
    /// The first check after launch has finished.
    var firstCheckDone: Bool
    /// Seconds between automatic checks; 0 = only when asked ("Manual").
    var checkEverySeconds: Int
    /// The panel's summary sentence ("44 servers · 2 broken · 1 needs sign-in").
    var summary: String
    var counts: Counts
    var servers: [Server]
    /// One row per agent, worst-first, aka last — the Agents tab's own order
    /// (round 8, widgets). Optional: files written before 1.8 decode fine
    /// without it, and the field is simply absent from their JSON.
    var perAgent: [AgentStatus]? = nil

    struct Counts: Codable, Equatable, Sendable {
        var total: Int
        var broken: Int
        var slow: Int
        var needsSignIn: Int
        var differs: Int
        var checking: Int
        var fine: Int
        var paused: Int
        var selfManaged: Int
        var hidden: Int
    }

    struct Server: Codable, Equatable, Sendable {
        var name: String
        /// mcpock's raw state: unknown, healthy, degraded, broken, selfManaged, paused.
        var state: String
        /// In plain words: broken, slow, needs sign-in, set up differently, fine,
        /// checking, paused, managed by its app.
        var status: String
        /// True for broken, slow, needs sign-in and set up differently.
        var needsAttention: Bool
        /// The panel's one-line reason, when there is one.
        var reason: String?
        var hidden: Bool
        var pinned: Bool
        var transports: [String]
        var toolCount: Int
        var tools: [String]
        var lastChecked: Date?
        /// Agents that declare it, as people read them ("Claude Code", "Cursor").
        var agents: [String]
        /// Every config file that declares it, full paths.
        var configPaths: [String]
        /// "Grok points at a different address than Claude Code and Cursor."
        var differs: String?
        /// Set up differently, marked as intended (1.5.2): she acknowledged
        /// that the agents launch different things, so it isn't a problem. The
        /// key keeps its 1.5.2 name so older files and helpers still decode. The same kind
        /// of sentence as `differs`; absent in files from before 1.5.2.
        var differsOnPurpose: String? = nil
        /// An info note on a fine row, e.g. "Slow to start (over 20 s)". Never a
        /// problem and never counted. Optional: absent in older files.
        var note: String? = nil
        var sources: [Source]
    }

    /// One agent as the Agents tab sees it (round 8): how many servers it
    /// declares, and how many of those need attention. `name` is already the
    /// display label ("Claude Code", "Hermes · scribe"), same as `Server.agents`.
    struct AgentStatus: Codable, Equatable, Sendable {
        var name: String
        var serverCount: Int
        var problemCount: Int
        var fineCount: Int
        /// How many of `problemCount` are broken (1.9.1), so the widgets can
        /// color red only what the panel colors red. Optional: a status file
        /// from 1.9.0 or earlier has none.
        var brokenCount: Int? = nil
    }

    /// One declaration of a server in one agent's config.
    struct Source: Codable, Equatable, Sendable {
        /// "Cursor", "Claude Code (MyProject)", "Hermes · scribe".
        var agent: String
        var configPath: String
        var transport: String
        /// The command line (stdio) or URL (http/sse), secrets masked.
        var target: String
        /// Env variable names only, never values.
        var envNames: [String]
        /// Header names only, never values.
        var headerNames: [String]
        var state: String
        /// The full failure text for this declaration, secrets masked.
        var failure: String?
        /// This declaration is the odd one out of a server set up differently.
        var differs: Bool
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// `~/Library/Application Support/mcpock`.
    static func defaultDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/mcpock", isDirectory: true)
    }

    static let fileName = "status.json"
    static let markdownFileName = "status.md"
}

/// "just now", "4 min ago", "3 h ago", "2 days ago". Shared by the panel's
/// footer and the helper's replies so both say it the same way.
enum RelativeAge {
    static func text(since date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) h ago" }
        let days = hours / 24
        return days == 1 ? "1 day ago" : "\(days) days ago"
    }
}
