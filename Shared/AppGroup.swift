import Foundation

/// The App Group shared between mcpock and its widget extension (round 8):
/// the sandboxed extension can't reach `~/Library/Application Support/mcpock`
/// at all, so the app also writes a small widget snapshot into this
/// container, and the widget only ever reads from here.
///
/// Team-prefixed (`P5RB3W3D58.com.mcpock`, mcpock's own team id) so macOS
/// accepts the group without a provisioning profile — the same trick
/// other menu bar apps use, just with a fixed identifier instead of one read
/// from Info.plist: mcpock only ever ships as this one app, never a fork.
enum AppGroup {
    static let identifier = "P5RB3W3D58.com.mcpock"

    /// Shared container directory for files exchanged with the widget. `nil`
    /// when the entitlement isn't present (an unsigned or ad-hoc build), so
    /// callers degrade to "no widget data" instead of crashing.
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}
