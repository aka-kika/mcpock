import Foundation

/// The panel's filter (v1.5 round 2): the footer's attention toggle. Pressed is
/// Needs you, unpressed is All. The raw value is what the panel remembers between
/// opens and launches. The round-1 `pinned` chip is gone (pinned servers keep their
/// own section at the top); a saved "pinned" reads back as `.all`.
enum PanelFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case problems

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .problems: return "Needs you"
        }
    }
}

/// One titled block of rows in the server list.
struct PanelSection: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable, Hashable {
        case needsYou
        case pinned
        case everythingElse
    }

    let kind: Kind
    let groups: [ServerGroup]

    var id: Kind { kind }
    var count: Int { groups.count }

    /// Header text. The view sets it in small uppercase with the count beside it.
    var title: String {
        switch kind {
        case .needsYou: return "Needs you"
        case .pinned: return "Pinned"
        case .everythingElse: return "Everything else"
        }
    }
}

/// Turns the visible rows into the panel's sections (v1.5 spec, Phase 1 item 4).
/// The panel works "like a dashboard you scan": problems first, then
/// what is pinned, then the rest. Pure, and nonisolated like every static on a
/// plain enum, so `PanelSectionsTests` covers it without a view.
enum PanelSections {
    /// Rank inside "Needs you": broken, then degraded, then differs. `nil` means
    /// the row doesn't need you. A broken row that also differs ranks as broken,
    /// the louder problem. Paused and self-managed rows never need you: the first
    /// is the user's own choice, the second lives inside its host app.
    ///
    /// **Unknown never needs you** (Phase 7): for the first ~20 s after launch every
    /// server is unknown, and ranking them here piled the whole list into Needs
    /// you as "Checking". A row that hasn't been checked yet stays in its normal
    /// section with the unknown ring, and the summary line starts with "Checking…".
    static func needsYouRank(_ group: ServerGroup) -> Int? {
        switch group.state {
        case .broken: return 0
        case .degraded: return 1
        case .healthy: return group.differsNeedsAttention ? 2 : nil
        case .unknown, .selfManaged, .paused: return nil
        }
    }

    static func needsYou(_ group: ServerGroup) -> Bool {
        needsYouRank(group) != nil
    }

    /// The worst rank among the rows that need you (0 broken, 1 degraded, 2
    /// differs), or nil when nothing does. Tints the footer's attention toggle.
    static func worstNeedsYouRank(_ groups: [ServerGroup]) -> Int? {
        groups.compactMap(needsYouRank).min()
    }

    /// Build the sections, in order: **Needs you**, **Pinned**, **Everything else**.
    /// Empty sections are left out.
    ///
    /// - `groups`: the rows to show (the caller passes the visible, un-hidden ones;
    ///   pinning unhides, so pinned rows are always among them).
    /// - `pinned`: normalized names (`HealthMonitor.normalizedName`), as stored.
    /// - `filter`: `.problems` keeps only Needs you. A pinned row that needs you
    ///   shows under Needs you, so problems stay on top in every view.
    /// - `query`: narrows by server name, source labels and tool names.
    static func build(
        groups: [ServerGroup],
        pinned: Set<String>,
        filter: PanelFilter,
        query: String
    ) -> [PanelSection] {
        let isPinned: (ServerGroup) -> Bool = { pinned.contains(HealthMonitor.normalizedName($0.name)) }
        let candidates = groups.filter { matches($0, query: query) }

        var needs: [ServerGroup] = []
        var pins: [ServerGroup] = []
        var rest: [ServerGroup] = []
        for group in candidates {
            if needsYou(group) { needs.append(group) }
            else if isPinned(group) { pins.append(group) }
            else { rest.append(group) }
        }

        needs.sort {
            let (a, b) = (needsYouRank($0) ?? .max, needsYouRank($1) ?? .max)
            return a != b ? a < b : byName($0, $1)
        }
        pins.sort(by: byName)
        // selfManaged and paused go last: neither is being checked by mcpock, so
        // they are the least interesting rows in the list.
        rest.sort {
            let (a, b) = (isQuiet($0), isQuiet($1))
            return a != b ? !a : byName($0, $1)
        }

        var sections = [PanelSection(kind: .needsYou, groups: needs)]
        if filter != .problems {
            sections.append(PanelSection(kind: .pinned, groups: pins))
            sections.append(PanelSection(kind: .everythingElse, groups: rest))
        }
        return sections.filter { $0.count > 0 }
    }

    /// Search: case- and diacritic-insensitive substring match on the server name,
    /// any source label (typing "cursor" finds everything Cursor declares) or any
    /// tool name (the field says "Search servers or tools"). Blank matches all.
    static func matches(_ group: ServerGroup, query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        if group.name.localizedStandardContains(needle) { return true }
        if group.sourceLabels.contains(where: { $0.localizedStandardContains(needle) }) { return true }
        return group.tools.contains { $0.name.localizedStandardContains(needle) }
    }

    private static func isQuiet(_ group: ServerGroup) -> Bool {
        group.state == .selfManaged || group.state == .paused
    }

    private static func byName(_ a: ServerGroup, _ b: ServerGroup) -> Bool {
        a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }
}
