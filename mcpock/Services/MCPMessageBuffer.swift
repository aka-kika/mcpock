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
                guard let bodyStart = findHeaderEnd() else { return nil }
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

            // Unknown leading bytes — skip forward to the next `{` and retry.
            if let brace = buffer.firstIndex(of: UInt8(ascii: "{")) {
                buffer.removeSubrange(0..<brace)
                continue
            }

            // No `{` anywhere. Keep the buffer only if it might still become a
            // Content-Length header once more bytes arrive; otherwise the whole
            // buffer is non-JSON noise — drop it in one shot (not byte-by-byte) and
            // wait for real data.
            // Bytes that aren't text can't be a header either: an empty preview
            // made `"content-length".hasPrefix("")` true, so binary noise was
            // kept and grew until the probe timed out (review, 2026-09-26).
            if let preview = String(bytes: buffer.prefix(32), encoding: .utf8)?.lowercased(), !preview.isEmpty,
               "content-length".hasPrefix(preview) || preview.hasPrefix("content") {
                return nil
            }
            buffer.removeAll(keepingCapacity: true)
            return nil
        }
    }

    /// The largest message body accepted: far above any real `initialize` or
    /// `tools/list` reply, and small enough that the arithmetic can't overflow.
    static let maxBodyBytes = 64 * 1024 * 1024

    private func startsWithContentLengthHeader() -> Bool {
        let prefix = buffer.prefix(14)
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
