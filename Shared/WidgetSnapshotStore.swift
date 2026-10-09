import Foundation

/// Reads and writes `MCPockWidgetSnapshot` as a file inside a container
/// directory (round 8). Pure I/O, no App Group lookup of its own — callers
/// hand it a directory, so tests use a throwaway one and never touch the
/// real App Group container. The app writes here (via `WidgetSnapshotWriter`,
/// app-only); the widget extension only reads.
enum WidgetSnapshotStore {
    static let fileName = "widget-status.json"

    static func url(in containerURL: URL) -> URL {
        containerURL.appendingPathComponent(fileName)
    }

    static func write(_ snapshot: MCPockWidgetSnapshot, to containerURL: URL) throws {
        try FileManager.default.createDirectory(at: containerURL, withIntermediateDirectories: true)
        let data = try MCPockWidgetSnapshot.encoder().encode(snapshot)
        try data.write(to: url(in: containerURL), options: .atomic)
    }

    /// `nil` when there's nothing there yet (first launch) or the file can't
    /// be read — the widgets show "Open mcpock to start checking" either way.
    static func read(from containerURL: URL) -> MCPockWidgetSnapshot? {
        guard let data = try? Data(contentsOf: url(in: containerURL)) else { return nil }
        return try? MCPockWidgetSnapshot.decoder().decode(MCPockWidgetSnapshot.self, from: data)
    }
}
