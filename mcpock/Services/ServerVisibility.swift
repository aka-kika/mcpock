import Foundation

/// Where a server shows in the panel: the three positions of the Preferences
/// "Show as" control. Pinned rows sit at the top, shown rows in the list, hidden
/// rows leave the panel (mcpock still checks them). Exactly one applies at a
/// time — `HealthMonitor.setPinned` and `setHidden` keep the two sets disjoint.
enum ServerVisibility: String, CaseIterable, Identifiable, Sendable {
    case pinned
    case shown
    case hidden

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pinned: return "Pinned"
        case .shown: return "Shown"
        case .hidden: return "Hidden"
        }
    }

    /// Round 8: Settings > Servers shows the three positions as icons (the
    /// title is the tooltip and the accessibility label), so the table and the
    /// window can be narrower.
    var systemImage: String {
        switch self {
        case .pinned: return "pin"
        case .shown: return "eye"
        case .hidden: return "eye.slash"
        }
    }

    /// The position for a pinned/hidden pair. Pinned wins if both are somehow
    /// set (a stale preferences file): the panel shows a pinned row, so the
    /// control should say so.
    nonisolated static func resolve(pinned: Bool, hidden: Bool) -> ServerVisibility {
        if pinned { return .pinned }
        if hidden { return .hidden }
        return .shown
    }

    /// The Preferences footer line: "19 servers · 5 pinned · 1 hidden".
    nonisolated static func summary(total: Int, pinned: Int, hidden: Int) -> String {
        "\(total) server\(total == 1 ? "" : "s") · \(pinned) pinned · \(hidden) hidden"
    }
}

extension HealthMonitor {
    func visibility(of name: String) -> ServerVisibility {
        ServerVisibility.resolve(pinned: isPinned(name), hidden: isHidden(name))
    }

    /// Move a server to one of the three positions. Pinning unhides and hiding
    /// unpins (the monitor's own rules); "Shown" clears whichever flag is set.
    func setVisibility(_ visibility: ServerVisibility, name: String) {
        switch visibility {
        case .pinned:
            setPinned(true, name: name)
        case .hidden:
            setHidden(true, name: name)
        case .shown:
            if isPinned(name) { setPinned(false, name: name) }
            if isHidden(name) { setHidden(false, name: name) }
        }
    }
}
