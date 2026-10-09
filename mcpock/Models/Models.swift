import Foundation

/// Where a server was declared: the agent's display label ("Cursor", "Hermes")
/// and the config file it came from.
struct ServerSource: Hashable, Sendable {
    let label: String
    /// Absolute path of the config file that declared the server, filled in by
    /// `ConfigDiscovery` (the registry path, or the scanned file's canonical path).
    /// The v1.5 detail card's "Used by" list shows it and opens it. Empty only in
    /// test fixtures that don't care where a source lives.
    let path: String

    init(label: String, path: String = "") {
        self.label = label
        self.path = path
    }
}

enum TransportKind: String, Sendable, Hashable {
    case stdio
    case http
    case sse
}

enum HealthState: String, Sendable, Hashable {
    case unknown
    case healthy
    case degraded
    case broken
    /// The entry belongs to its host app's internal runtime (e.g. MiniMax Code's
    /// `"builtin": true` servers) — it only exists inside that app, so mcpock
    /// never probes it and shows a neutral badge instead of red.
    case selfManaged
    /// The user paused probing for this server — mcpock never launches it until
    /// resumed. The off-switch for servers whose launch has side effects (e.g. an
    /// unauthenticated OAuth server that opens a browser login page every spawn).
    case paused

    var sortRank: Int {
        switch self {
        case .broken: return 0
        case .degraded: return 1
        case .unknown: return 2
        case .healthy: return 3
        case .selfManaged: return 4
        case .paused: return 5
        }
    }
}

enum AggregateState: Sendable, Hashable {
    case allHealthy
    /// Every server is healthy, but at least one is set up differently across its
    /// agents (see `ServerGroup.differs`). Worth a quiet ring in the menu bar,
    /// never the broken diamond: nothing is failing, the setups just disagree.
    case attention
    case degradedOrUnknown
    case broken
}

struct MCPToolInfo: Identifiable, Sendable, Hashable {
    var id: String { name }
    let name: String
    let description: String

    var firstLineDescription: String {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return trimmed.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? trimmed
    }
}

struct ServerConfig: Identifiable, Sendable, Hashable {
    let id: String
    let name: String
    let source: ServerSource
    let projectPath: String?
    let transport: TransportKind
    let command: String?
    let args: [String]
    let env: [String: String]
    let url: String?
    let headers: [String: String]
    /// True when the config marks this entry as its host app's builtin server
    /// (`"builtin": true`, e.g. MiniMax Code's cu/trash/matrix). These run inside
    /// the host app's own runtime — probing them from outside always fails, so
    /// mcpock reports them as `.selfManaged` instead of probing.
    var builtin: Bool = false
    /// Claude Code's `headersHelper` on an http/sse entry: a shell command whose
    /// stdout is a JSON object of HTTP headers (usually a fresh token). Only the
    /// command lives here; what it prints is run per probe and never stored.
    var headersHelper: String?

    /// The same config with other static headers (the helper's output merged in
    /// for one probe). Never stored back into the monitor.
    func withHeaders(_ newHeaders: [String: String]) -> ServerConfig {
        var copy = ServerConfig(
            id: id, name: name, source: source, projectPath: projectPath, transport: transport,
            command: command, args: args, env: env, url: url, headers: newHeaders, builtin: builtin
        )
        copy.headersHelper = headersHelper
        return copy
    }

    /// "Code (WeeklyContentCalendar)" for a project-scoped entry. Parentheses, not
    /// the " · " the source list is joined with — "Code · Code · WeeklyContent…"
    /// read as three sources.
    var displaySource: String {
        if let projectPath, !projectPath.isEmpty {
            let leaf = (projectPath as NSString).lastPathComponent
            return "\(source.label) (\(leaf))"
        }
        return source.label
    }

    /// Human-readable command line (stdio) or URL (http/sse) — for copy/debug context.
    var commandLine: String {
        switch transport {
        case .stdio:
            return ([command].compactMap { $0 } + args).joined(separator: " ")
        case .http, .sse:
            return url ?? ""
        }
    }
}

struct ServerSnapshot: Identifiable, Sendable, Hashable {
    var id: String { config.id }
    var config: ServerConfig
    var state: HealthState
    var failureReason: String?
    var tools: [MCPToolInfo]
    var lastChecked: Date?
    /// Count of consecutive transient failures, used for health smoothing.
    var consecutiveFailures: Int
    /// Seconds the last check waited before the retry answered (see
    /// `ProbeResult.slowStartSeconds`); nil when it answered first time.
    var slowStartSeconds: Double?

    init(
        config: ServerConfig,
        state: HealthState = .unknown,
        failureReason: String? = nil,
        tools: [MCPToolInfo] = [],
        lastChecked: Date? = nil,
        consecutiveFailures: Int = 0,
        slowStartSeconds: Double? = nil
    ) {
        self.config = config
        self.state = state
        self.failureReason = failureReason
        self.tools = tools
        self.lastChecked = lastChecked
        self.consecutiveFailures = consecutiveFailures
        self.slowStartSeconds = slowStartSeconds
    }
}

/// Everything that determines HOW a server is probed — and nothing about how it's
/// displayed. Two configs with equal specs are the same probe target, so one probe
/// answers for all of them (see `HealthMonitor.probeSpec`).
struct ProbeSpec: Hashable, Sendable {
    let transport: TransportKind
    let command: String?
    let args: [String]
    let env: [String: String]
    let projectPath: String?
    let url: String?
    let headers: [String: String]
    let builtin: Bool
    let headersHelper: String?
}

/// A failing instance of a grouped server (which source, why, and its command).
struct ServerIssue: Sendable, Hashable {
    let label: String
    let reason: String
    let command: String
}

/// One source whose launch target disagrees with the rest of its group: the
/// "odd one out" behind "Set up differently in Grok".
struct DiffNote: Sendable, Hashable {
    /// The source's display label (`ServerConfig.displaySource`), e.g. "Grok".
    let label: String
    /// What that source launches: its command line (stdio) or URL (http/sse).
    /// Never includes env or header values, so it is safe to show and copy.
    let target: String
}

/// One declaration behind a display row, as the detail card's "Used by" list
/// and Compare view need it. Env and header **names** only: the values are
/// often API keys, and nothing in the UI shows them.
struct GroupSource: Sendable, Hashable, Identifiable {
    var id: String { configID }
    let configID: String
    /// Display label ("Code (MyProject)", "Hermes · scribe").
    let label: String
    /// The agent part of the label (`ServerSource.label`), for the badge.
    let agent: String
    /// Config file that declared it (may be empty in test fixtures).
    let path: String
    let transport: TransportKind
    /// Command line (stdio) or URL (http/sse), as written in the config.
    let target: String
    let envKeys: [String]
    let headerKeys: [String]
    let state: HealthState
    let failureReason: String?
}

/// A display row: all instances that share a server **name**, collapsed into one.
/// Its `state` is the worst across instances, so it shows broken if any instance is.
struct ServerGroup: Identifiable, Sendable, Hashable {
    let name: String
    let state: HealthState
    let sourceLabels: [String]
    let tools: [MCPToolInfo]
    let issues: [ServerIssue]
    let variantCount: Int
    /// Sources whose launch target differs from the majority (`Differs.detect`).
    /// Empty when every declaration launches the same thing. Defaulted so fixtures
    /// that don't care can keep using the short initializer.
    var differs: [DiffNote] = []
    /// The notes `Differs.detect` found, when she marked the setups "Mark as
    /// intended" and they still match what she acknowledged (1.5.2). `differs`
    /// is empty then, so nothing downstream counts the row as set up differently;
    /// the card shows a quiet "Marked as intended · Undo" line instead.
    var acknowledgedDiffers: [DiffNote] = []
    /// Every declaration behind this row, in discovery order.
    var sources: [GroupSource] = []
    /// Newest probe time across the row's declarations (nil until first checked).
    /// Feeds "Checked 1 min ago" in the footer and the detail card.
    var lastChecked: Date? = nil
    /// Longest first-try wait among the healthy declarations that only answered
    /// on a retry. Nil when none did. Informational: not a problem.
    var slowStartSeconds: Double? = nil

    var id: String { name }

    /// True when the row's agents disagree about what to launch.
    var isDiffering: Bool { !differs.isEmpty }

    /// True when the agents disagree and she marked that as intended.
    var isDifferentOnPurpose: Bool { !acknowledgedDiffers.isEmpty }

    /// A mismatch only matters for servers mcpock actually probes: a paused or
    /// self-managed row is the user's (or its host app's) business, so it never
    /// lands in "Needs you" or rings the menu-bar icon for differing.
    var differsNeedsAttention: Bool {
        isDiffering && state != .paused && state != .selfManaged
    }
    var sourceSummary: String { sourceLabels.joined(separator: " · ") }

    /// Framing so a pasted report is self-explanatory to an LLM (provenance + the ask).
    /// Single source for both the one-server "Copy errors" text and the multi-server
    /// export report, so the two explanations can't drift apart.
    static func reportPreamble(plural: Bool) -> String {
        let failing = plural
            ? "The servers below are failing their startup checks — please help me diagnose and fix them."
            : "The server below is failing its startup check — please help me diagnose and fix it."
        return """
        This is an automated health report from mcpock, a macOS menu-bar app that \
        periodically launches my configured MCP servers to check they start correctly. \
        \(failing)
        """
    }

    /// Paste-ready error report: the menu's "Copy Errors", the card's "Copy
    /// errors" and ⌘C on a failing row.
    var copyText: String {
        var lines = [Self.reportPreamble(plural: false), "", "MCP server: \(name)"]
        lines.append("Status: \(state.rawValue)")
        lines.append("Sources: \(sourceSummary)")
        if !issues.isEmpty {
            lines.append("")
            lines.append(issues.count == 1 ? "Error:" : "Errors:")
            for issue in issues {
                lines.append("- \(issue.label): \(issue.reason)")
                if !issue.command.isEmpty {
                    lines.append("  command: \(issue.command)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }
}

struct ProbeResult: Sendable {
    let state: HealthState
    let failureReason: String?
    let tools: [MCPToolInfo]?
    /// True when a failure might resolve on its own (e.g. a slow cold-start timeout),
    /// so health smoothing shows amber before red. Ignored unless `state == .broken`.
    var transientFailure: Bool = false
    /// True when the failure needs the user's attention rather than a fix in the
    /// server (e.g. an unauthenticated HTTP 401/403). It's a stable amber
    /// `degraded` — not red `broken` — and never escalates: retrying won't help,
    /// but nothing is crashing. Takes precedence over `transientFailure`.
    var needsAttention: Bool = false
    /// Set on a healthy result that only answered on the second try: how long
    /// the first attempt waited, in seconds. An info note, never a problem.
    var slowStartSeconds: Double? = nil
}

enum ProbeError: Error, LocalizedError, Sendable {
    case spawnFailed(String)
    case timeout(Duration)
    case handshakeRejected(String)
    case nonZeroExit(Int32)
    case invalidURL(String)
    case httpError(Int, String)
    case protocolError(String)
    case noData
    /// Claude Code's `headersHelper` failed; the detail is a fixed phrase
    /// ("failed: exit 1", "timed out after 10 s", "did not return JSON"), never output.
    case headerHelper(String)

    var errorDescription: String? {
        switch self {
        case .spawnFailed(let detail):
            return "Spawn error: \(detail)"
        case .timeout(let limit):
            let seconds = Double(limit.components.seconds)
                + Double(limit.components.attoseconds) / 1e18
            let text = seconds == seconds.rounded()
                ? String(Int(seconds))
                : String(format: "%.1f", seconds)
            return "Timed out after \(text)s"
        case .handshakeRejected(let detail):
            return "Handshake rejected: \(detail)"
        case .nonZeroExit(let code):
            return "Non-zero exit (\(code))"
        case .invalidURL(let url):
            return "Invalid URL: \(url)"
        case .httpError(let code, let body):
            if Self.isAuthCode(code) {
                return "Needs authentication (HTTP \(code))"
            }
            let snippet = body.prefix(120)
            return "HTTP \(code)\(snippet.isEmpty ? "" : ": \(snippet)")"
        case .protocolError(let detail):
            return "Protocol error: \(detail)"
        case .noData:
            return "No response from server"
        case .headerHelper(let detail):
            return "Header helper \(detail)"
        }
    }

    /// HTTP status codes that mean "the server is up but rejected us for lack of
    /// credentials" — i.e. the user needs to authenticate, not fix a crash.
    static func isAuthCode(_ code: Int) -> Bool {
        code == 401 || code == 403
    }

    /// Whether this failure needs the user's attention (auth) rather than being a
    /// crash. Drives the stable amber `degraded` state instead of red `broken`.
    var needsAttention: Bool {
        if case .httpError(let code, _) = self { return Self.isAuthCode(code) }
        return false
    }

    /// Whether this failure might resolve on its own (a slow cold start / transient hiccup)
    /// rather than being definitive. Drives health smoothing (amber before red).
    var isTransient: Bool {
        switch self {
        case .timeout:
            return true
        case .spawnFailed, .handshakeRejected, .nonZeroExit,
             .invalidURL, .httpError, .protocolError, .noData, .headerHelper:
            return false
        }
    }
}
