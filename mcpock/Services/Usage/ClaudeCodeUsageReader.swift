import Foundation

/// Reads `~/.claude/projects/**/*.jsonl` — including subagent transcripts
/// under `<project>/<session>/subagents/` — for MCP tool calls. An MCP call
/// is an assistant `tool_use` block named `mcp__<server>__<tool>`; the line's
/// own `timestamp` is the call's time. Read-only, and it keeps only the
/// agent, the server and that time.
///
/// Checked against real transcripts on this Mac (`grep -m3 '"name":"mcp__'`):
/// a line looks like
/// `{"timestamp":"2026-07-04T02:03:46.616Z","message":{"role":"assistant",
/// "content":[{"type":"tool_use","name":"mcp__skill-librarian__librarian_find",…}]},…}`.
/// Plugin servers show up as `mcp__plugin_<plugin>_<server>__<tool>`, e.g.
/// `mcp__plugin_chrome-devtools-mcp_chrome-devtools__click` — confirmed with
/// the same grep.
struct ClaudeCodeUsageReader: UsageReader {
    let agent = AgentRegistry.claudeCodeLabel

    /// `~/.claude/projects` by default; tests point this at a fixture folder
    /// (the root is an init parameter for exactly that reason).
    let root: URL

    init(root: URL = ClaudeCodeUsageReader.defaultRoot) {
        self.root = root
    }

    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    func read(since cursor: UsageCursor, knownServers: Set<String>) -> (events: [UsageEvent], cursor: UsageCursor) {
        var nextCursor = cursor
        var events: [UsageEvent] = []
        for file in transcriptFiles() {
            let path = file.path
            let size = fileSize(file)
            var offset = cursor.values[path] ?? 0
            // Shrank or was replaced with something shorter: nothing at the
            // old offset can still be valid, so start this file over.
            if size < offset { offset = 0 }
            guard size > offset else { continue }
            let (found, newOffset) = scan(file, from: offset, knownServers: knownServers)
            events.append(contentsOf: found)
            nextCursor.values[path] = newOffset
        }
        return (events, nextCursor)
    }

    // MARK: - Discovery

    /// Every `.jsonl` file under `root`, at any depth (subagent transcripts
    /// live one folder deeper, in `<session>/subagents/`).
    private func transcriptFiles() -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            files.append(url)
        }
        return files
    }

    private func fileSize(_ url: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return 0 }
        return (attrs[.size] as? Int64) ?? 0
    }

    // MARK: - Scanning

    private static let marker = Data("mcp__".utf8)
    private static let newline: UInt8 = 0x0A
    private static let chunkSize = 1 << 20 // 1 MB: never the whole file in memory (some run past a gigabyte)

    /// Reads from `offset` to EOF in fixed chunks, one complete line at a
    /// time. Only a line that ends in a newline advances the returned offset,
    /// so a line still being written (the session is live) is left for next
    /// time, whole. Only a line containing `mcp__` is even decoded as JSON —
    /// most lines in a transcript are plain assistant text or tool results.
    private func scan(
        _ url: URL, from offset: Int64, knownServers: Set<String>
    ) -> (events: [UsageEvent], newOffset: Int64) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return ([], offset) }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(offset))) != nil else { return ([], offset) }

        let decoder = JSONDecoder()
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoFormatterNoFraction = ISO8601DateFormatter()
        isoFormatterNoFraction.formatOptions = [.withInternetDateTime]

        var events: [UsageEvent] = []
        var buffer = Data()
        var consumed = offset

        while let chunk = try? handle.read(upToCount: Self.chunkSize), !chunk.isEmpty {
            buffer.append(chunk)
            while let newlineIndex = buffer.firstIndex(of: Self.newline) {
                let line = buffer.subdata(in: buffer.startIndex..<newlineIndex)
                consumed += Int64(line.count) + 1
                buffer.removeSubrange(buffer.startIndex...newlineIndex)
                guard !line.isEmpty, line.range(of: Self.marker) != nil else { continue }
                events.append(contentsOf: Self.events(
                    in: line, agent: agent, knownServers: knownServers,
                    decoder: decoder, isoFormatter: isoFormatter, isoFormatterNoFraction: isoFormatterNoFraction
                ))
            }
        }
        // A leftover partial last line (no trailing newline yet) is never
        // counted as consumed, so it's read whole once it's complete.
        return (events, consumed)
    }

    // MARK: - One line

    private struct TranscriptLine: Decodable {
        let timestamp: String?
        let message: Message?
        struct Message: Decodable {
            let role: String?
            let content: [ContentBlock]?
        }
        struct ContentBlock: Decodable {
            let type: String
            let name: String?
        }
    }

    private static func events(
        in line: Data, agent: String, knownServers: Set<String>,
        decoder: JSONDecoder, isoFormatter: ISO8601DateFormatter, isoFormatterNoFraction: ISO8601DateFormatter
    ) -> [UsageEvent] {
        guard let parsed = try? decoder.decode(TranscriptLine.self, from: line),
              parsed.message?.role == "assistant",
              let content = parsed.message?.content,
              let timestamp = parsed.timestamp,
              let date = isoFormatter.date(from: timestamp) ?? isoFormatterNoFraction.date(from: timestamp)
        else { return [] }
        return content.compactMap { block -> UsageEvent? in
            guard block.type == "tool_use", let name = block.name,
                  let server = resolveServerName(name, knownServers: knownServers)
            else { return nil }
            return UsageEvent(agent: agent, server: server, date: date)
        }
    }

    // MARK: - Server name

    /// `mcp__<server>__<tool>` -> `<server>`; anything not shaped like that
    /// (no `mcp__` prefix, or no `__` separating a server from a tool) is nil
    /// — a non-MCP tool call (`Read`, `Bash`, …) is ignored.
    ///
    /// Plugin servers, `mcp__plugin_<plugin>_<server>__<tool>`: tries the
    /// longest trailing run of `<plugin>_<server>` (split on `_`) that
    /// normalizes to a name in `knownServers` — the server name always comes
    /// last, so trying suffixes from the end finds it without needing to know
    /// where the plugin's own name ends. Reports that match's un-normalized
    /// text (normalizing happens once, in `UsageStore`, from every reader's
    /// raw name alike). No match: the raw `<plugin>_<server>` text, as the
    /// contract asks for.
    static func resolveServerName(_ toolName: String, knownServers: Set<String>) -> String? {
        guard toolName.hasPrefix("mcp__") else { return nil }
        var parts = toolName.dropFirst(5).components(separatedBy: "__")
        guard parts.count >= 2 else { return nil }
        parts.removeLast() // the tool name; never kept (arguments/results/chat never are either)
        let serverPart = parts.joined(separator: "__")
        guard !serverPart.isEmpty else { return nil }
        guard serverPart.hasPrefix("plugin_") else { return serverPart }

        let combo = String(serverPart.dropFirst("plugin_".count))
        let segments = combo.components(separatedBy: "_")
        guard segments.count > 1 else { return combo }
        for start in stride(from: segments.count - 1, through: 1, by: -1) {
            let candidate = segments[start...].joined(separator: "_")
            if knownServers.contains(HealthMonitor.normalizedName(candidate)) {
                return candidate
            }
        }
        return combo
    }
}
