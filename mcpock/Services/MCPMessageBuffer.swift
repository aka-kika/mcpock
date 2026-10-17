import Foundation

/// Incremental reader for MCP stdio (Content-Length frames and newline-delimited JSON).
///
/// Internal storage is `[UInt8]` rather than `Data`. `Data` does NOT re-base its
/// indices to 0 after front removal (`removeFirst()` / `removeSubrange`) — its
/// `startIndex` can drift to any positive value, so code that mixes a literal `0`
/// with an absolute index (e.g. `subdata(in: 0..<newlineIndex)` after a preceding
/// `removeFirst()`) goes out of range and crashes. Arrays are always 0-indexed,
/// which eliminates that entire bug class.
final class MCPMessageBuffer: @unchecked Sendable {
    private var buffer = [UInt8]()

    func append(_ data: Data) {
        buffer.append(contentsOf: data)
    }

    /// Returns the next complete JSON message body, or nil if incomplete.
    ///
    /// Iterative, not recursive: a chatty server can print a large amount of
    /// non-JSON stdout (npm/node warnings, banners) before its first MCP message,
    /// and a per-byte recursion over that would overflow the stack. The loop keeps
    /// consuming leading noise until it finds a framed message or runs out of input.
    func nextMessage() throws -> Data? {
        while true {
            // Strip leading ASCII whitespace (space, LF, CR, tab).
            while let first = buffer.first, first == 0x20 || first == 0x0A || first == 0x0D || first == 0x09 {
                buffer.removeFirst()
            }
            if buffer.isEmpty { return nil }

            // Content-Length framing
            if startsWithContentLengthHeader() {
                guard let bodyStart = findHeaderEnd() else {
                    // A header that never ends would be kept forever.
                    if buffer.count > Self.maxHeaderBytes {
                        throw ProbeError.protocolError("Content-Length header never ends")
                    }
                    return nil
                }
                let headerBytes = buffer[0..<bodyStart]
                guard let headerString = String(bytes: headerBytes, encoding: .utf8),
                      let length = parseContentLength(headerString), length >= 0,
                      length <= Self.maxBodyBytes
                else {
                    // Missing/negative length would make body slicing crash, and
                    // a huge one would overflow `bodyStart + length` and trap the
                    // whole app (review, 2026-09-26) — reject the frame.
                    throw ProbeError.protocolError("Invalid Content-Length header")
                }
                let bodyEnd = bodyStart + length
                guard buffer.count >= bodyEnd else { return nil }
                let body = Data(buffer[bodyStart..<bodyEnd])
                buffer.removeSubrange(0..<bodyEnd)
                return body
            }

            // Newline-delimited JSON
            if buffer.first == UInt8(ascii: "{") {
                guard let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) else {
                    // A line that never ends would grow memory until the app
                    // crashed (Argon 2026-10-16 #4): same cap as a framed body.
                    if buffer.count > Self.maxBodyBytes {
                        throw ProbeError.protocolError("Message too large (no line end)")
                    }
                    return nil
                }
                var line = Array(buffer[0..<newlineIndex])
                buffer.removeSubrange(0...newlineIndex)
                if line.last == UInt8(ascii: "\r") {
                    line.removeLast()
                }
                if line.isEmpty { continue }
                return Data(line)
            }

            // Unknown leading bytes (a banner, a log line): skip them a line at a
            // time. Jumping to the first `{` used to cut a `Content-Length:`
            // header off its body (which has no line end, so the probe hung) or
            // land inside a banner like `[dotenv] {path: …}` (Argon 2026-10-17 #1).
            // A carriage return ends a line too: spinners redraw with `\r` only.
            // All whole noise lines go in one cut: removing them one by one
            // moved the rest of a large banner once per line.
            var start = 0
            while start < buffer.count, buffer[start] != UInt8(ascii: "{"), !startsWithContentLengthHeader(at: start),
                  let lineEnd = buffer[start...].firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                // Noise glued to a real message on the same line still yields
                // the message, but only when the rest really is a JSON object.
                if let brace = buffer[start..<lineEnd].firstIndex(of: UInt8(ascii: "{")) {
                    let tail = Data(buffer[brace..<lineEnd])
                    if (try? JSONSerialization.jsonObject(with: tail)) is [String: Any] {
                        buffer.removeSubrange(0...lineEnd)
                        return tail
                    }
                }
                start = lineEnd + 1
            }
            if start > 0 {
                buffer.removeSubrange(0..<start)
                continue
            }

            // A noise line that hasn't ended yet (or a header still arriving):
            // wait for more, but never past the cap. Text starting "Content…"
            // used to be kept forever and grew until the app crashed
            // (Argon 2026-10-17 #2).
            if buffer.count > Self.maxNoiseLineBytes {
                buffer.removeAll(keepingCapacity: true)
            }
            return nil
        }
    }

    /// The longest unfinished non-JSON line kept while waiting for its end.
    static let maxNoiseLineBytes = 64 * 1024

    /// The largest message body accepted: far above any real `initialize` or
    /// `tools/list` reply, and small enough that the arithmetic can't overflow.
    static let maxBodyBytes = 64 * 1024 * 1024
    /// Real headers are a few dozen bytes.
    static let maxHeaderBytes = 8 * 1024

    private func startsWithContentLengthHeader(at start: Int = 0) -> Bool {
        let prefix = buffer[start...].prefix(14)
        guard let s = String(bytes: prefix, encoding: .utf8) else { return false }
        return s.lowercased().hasPrefix("content-length")
    }

    /// Index of first body byte (after blank line).
    private func findHeaderEnd() -> Int? {
        let patternCRLF: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
        if let i = indexOf(pattern: patternCRLF) {
            return i + 4
        }
        let patternLF: [UInt8] = [0x0A, 0x0A]
        if let i = indexOf(pattern: patternLF) {
            return i + 2
        }
        return nil
    }

    private func indexOf(pattern: [UInt8]) -> Int? {
        guard !pattern.isEmpty, buffer.count >= pattern.count else { return nil }
        let end = buffer.count - pattern.count
        for i in 0...end {
            var match = true
            for j in 0..<pattern.count where buffer[i + j] != pattern[j] {
                match = false
                break
            }
            if match { return i }
        }
        return nil
    }

    private func parseContentLength(_ header: String) -> Int? {
        for line in header.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            if key == "content-length" {
                return Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return nil
    }
}
