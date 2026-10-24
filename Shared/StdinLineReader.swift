import Foundation

/// Splits stdin bytes into newline-delimited messages with a size cap (r3 b1c9):
/// `readLine` grows without limit on a client that never sends a newline. A
/// message over `maxBytes` is reported once, its rest is dropped up to the next
/// newline, and reading goes on with whatever follows.
struct StdinLineReader {
    enum Event: Equatable {
        case line(String)
        case tooLong
    }

    static let defaultMaxBytes = 1_048_576

    private var buffer = Data()
    private var discarding = false
    let maxBytes: Int

    init(maxBytes: Int = StdinLineReader.defaultMaxBytes) {
        self.maxBytes = maxBytes
    }

    /// Feed one piece of input; returns the messages it completed, in order.
    mutating func feed(_ chunk: Data) -> [Event] {
        var events: [Event] = []
        var rest = chunk[...]
        while !rest.isEmpty {
            if let newline = rest.firstIndex(of: 0x0A) {
                let head = rest[rest.startIndex..<newline]
                rest = rest[rest.index(after: newline)...]
                if discarding {
                    discarding = false
                } else if buffer.count + head.count > maxBytes {
                    events.append(.tooLong)
                } else {
                    buffer.append(contentsOf: head)
                    events.append(.line(String(decoding: buffer, as: UTF8.self)))
                }
                buffer.removeAll(keepingCapacity: true)
            } else {
                if !discarding {
                    if buffer.count + rest.count > maxBytes {
                        events.append(.tooLong)
                        discarding = true
                        buffer.removeAll(keepingCapacity: true)
                    } else {
                        buffer.append(contentsOf: rest)
                    }
                }
                rest = rest[rest.endIndex...]
            }
        }
        return events
    }

    /// The last message when input ends without a final newline.
    mutating func finish() -> Event? {
        defer { buffer.removeAll(); discarding = false }
        guard !discarding, !buffer.isEmpty else { return nil }
        return .line(String(decoding: buffer, as: UTF8.self))
    }
}
