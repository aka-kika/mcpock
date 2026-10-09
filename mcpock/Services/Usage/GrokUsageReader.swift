import Foundation

// Usage counts (1.7): Grok Build CLI reader.
//
// A Grok session lives at `~/.grok/sessions/<url-encoded cwd>/<session id>/`.
// Every MCP call it makes is logged twice in `events.jsonl`: once as
// `mcp_tool_call_started` and once as `mcp_tool_call_completed`, each already
// carrying separate `server_name` and `tool_name` fields (checked against
// a real `~/.grok/sessions` on 2026-09-26 — the wrapper tool `use_tool`
// that shows up in `chat_history.jsonl` bundles them into one
// `"tool_name":"<server>__<tool>"` string, but `events.jsonl` has already
// split them out, so there is no string-splitting to get wrong). We read
// only `mcp_tool_call_started`: it fires exactly once per call attempt (a
// session killed mid-call never gets a `_completed` line, so counting on
// `_completed` would silently drop it), its own `ts` is the call's start
// time, and reading a single event type from a single file means a call can
// never be counted twice.
enum GrokUsageReaderConstants {
    static let eventFileName = "events.jsonl"
}

struct GrokUsageReader: UsageReader {
    let agent = "Grok"

    private let root: URL

    /// `root` defaults to `~/.grok/sessions`; tests pass a temp directory.
    /// `FileManager.default` is not `Sendable`, so unlike `root` it is read
    /// fresh each call rather than stored.
    init(root: URL? = nil) {
        self.root = root ?? GrokUsageReader.defaultRoot
    }

    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    func read(since cursor: UsageCursor, knownServers: Set<String>) -> (events: [UsageEvent], cursor: UsageCursor) {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            // Missing folder is not an error: no events, same cursor.
            return ([], cursor)
        }

        let files = eventFiles(fileManager: fileManager)
        var values = cursor.values
        var events: [UsageEvent] = []

        for path in files {
            let key = GrokUsageReader.cursorKey(for: path)
            guard let attributes = try? fileManager.attributesOfItem(atPath: path) else { continue }
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let inode = (attributes[.systemFileNumber] as? NSNumber)?.int64Value ?? -1

            let offsetKey = key
            let inodeKey = key + ".ino"
            var startOffset = values[offsetKey] ?? 0
            let storedInode = values[inodeKey]

            // The file shrank or was swapped for a different one: start over.
            if let storedInode, storedInode != inode {
                startOffset = 0
            }
            if startOffset > size {
                startOffset = 0
            }

            if startOffset < size {
                let (newEvents, consumedOffset) = GrokUsageReader.readNewLines(
                    atPath: path,
                    from: startOffset
                )
                events.append(contentsOf: newEvents)
                values[offsetKey] = consumedOffset
            } else {
                values[offsetKey] = startOffset
            }
            values[inodeKey] = inode
        }

        return (events, UsageCursor(values: values))
    }

    // MARK: - Discovery

    private func eventFiles(fileManager: FileManager) -> [String] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var paths: [String] = []
        for case let url as URL in enumerator {
            if url.lastPathComponent == GrokUsageReaderConstants.eventFileName {
                paths.append(url.path)
            }
        }
        // Deterministic order; the store only cares about the set of events.
        return paths.sorted()
    }

    // MARK: - Incremental, streamed reading

    /// Reads only the complete (newline-terminated) lines after `startOffset`,
    /// streaming in fixed-size chunks so a huge file is never loaded whole.
    /// A trailing partial line (still being written) is left for next time.
    private static func readNewLines(
        atPath path: String,
        from startOffset: Int64
    ) -> (events: [UsageEvent], consumedOffset: Int64) {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return ([], startOffset)
        }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: UInt64(startOffset))
        } catch {
            return ([], startOffset)
        }

        var events: [UsageEvent] = []
        var consumed = startOffset
        var leftover = Data()
        let newline = UInt8(ascii: "\n")
        let chunkSize = 64 * 1024

        while true {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: chunkSize)
            } catch {
                break
            }
            guard let chunk, !chunk.isEmpty else { break }
            leftover.append(chunk)

            while let newlineIndex = leftover.firstIndex(of: newline) {
                let lineData = leftover.subdata(in: leftover.startIndex..<newlineIndex)
                let lineByteCount = Int64(newlineIndex - leftover.startIndex) + 1
                leftover.removeSubrange(leftover.startIndex...newlineIndex)
                consumed += lineByteCount
                if let event = parseEvent(lineData) {
                    events.append(event)
                }
            }
        }

        return (events, consumed)
    }

    /// Never throws: a bad or unrelated line just yields `nil`.
    private static func parseEvent(_ lineData: Data) -> UsageEvent? {
        guard !lineData.isEmpty else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
            return nil
        }
        guard object["type"] as? String == "mcp_tool_call_started" else { return nil }
        guard let server = object["server_name"] as? String, !server.isEmpty else { return nil }
        guard let timestamp = object["ts"] as? String, let date = parseTimestamp(timestamp) else { return nil }
        return UsageEvent(agent: "Grok", server: server, date: date)
    }

    private static let isoFormatterWithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func parseTimestamp(_ value: String) -> Date? {
        isoFormatterWithFractionalSeconds.date(from: value) ?? isoFormatter.date(from: value)
    }

    // MARK: - Cursor keys

    /// A stable (non-randomized) hash of the path, so the cursor survives
    /// across launches. Swift's `Hashable` is seeded per-process and would
    /// not round-trip through `UsageCursor`'s persisted `[String: Int64]`.
    static func cursorKey(for path: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let prime: UInt64 = 0x0000_0100_0000_01b3
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return "grok:" + String(hash, radix: 16)
    }
}
