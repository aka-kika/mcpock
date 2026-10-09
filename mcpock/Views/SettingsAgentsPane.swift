import SwiftUI
import AppKit

/// One agent as the Agents pane lists it: its name, how many servers it
/// declares, and the config file(s) those came from.
struct SettingsAgentEntry: Identifiable, Hashable, Sendable {
    /// The agent part of a source label ("Hermes" for "Hermes · scribe").
    let agent: String
    /// Distinct config paths, sorted. Usually one; a scanned agent may have one
    /// per folder.
    let paths: [String]
    /// Distinct servers (display rows) this agent declares.
    let serverCount: Int

    var id: String { agent }
}

/// The Agents pane (v1.5 spec, Phase 5; a grouped form since round 8): a
/// read-only list of the agents discovery found, with the config path each one
/// reads. Right-click a path for Show in Finder, Copy Path and, last, Open
/// Config…. mcpock never writes to these files.
struct SettingsAgentsPane: View {
    var monitor: HealthMonitor?
    let theme: ThemeColors

    static let intro = "Agents mcpock found on this Mac, with the config file each one reads. "
        + "Right-click a file for options; mcpock only reads it."

    private static let badgeSize: CGFloat = 24

    /// One entry per agent, from every group's sources. Agents are deduplicated
    /// by their label's agent part, so "Hermes" and "Hermes · scribe" are one
    /// row with two paths, and a server declared in three of Cursor's projects
    /// counts once. Pure, so `SettingsPanesTests` covers it without a monitor.
    nonisolated static func entries(from groups: [ServerGroup]) -> [SettingsAgentEntry] {
        var paths: [String: Set<String>] = [:]
        var servers: [String: Set<String>] = [:]
        for group in groups {
            for source in group.sources {
                let agent = AgentBadge.agentName(fromLabel: source.agent)
                guard !agent.isEmpty else { continue }
                servers[agent, default: []].insert(group.name)
                if !source.path.isEmpty {
                    paths[agent, default: []].insert(source.path)
                }
            }
        }
        return servers.keys
            .sorted { a, b in
                // aka last, as on the Agents tab (round 6).
                let (lastA, lastB) = (AgentSections.isAlwaysLast(a), AgentSections.isAlwaysLast(b))
                if lastA != lastB { return lastB }
                return a.localizedStandardCompare(b) == .orderedAscending
            }
            .map { agent in
                SettingsAgentEntry(
                    agent: agent,
                    paths: (paths[agent] ?? []).sorted(),
                    serverCount: servers[agent]?.count ?? 0
                )
            }
    }

    /// "14 agents · 16 config files", the pane's footer and General's Status.
    nonisolated static func countText(_ entries: [SettingsAgentEntry]) -> String {
        let files = Set(entries.flatMap(\.paths)).count
        return "\(entries.count) agent\(entries.count == 1 ? "" : "s") · \(files) config file\(files == 1 ? "" : "s")"
    }

    private var entries: [SettingsAgentEntry] {
        Self.entries(from: monitor?.groups ?? [])
    }

    var body: some View {
        let entries = self.entries
        Form {
            Section {
                if entries.isEmpty {
                    Text(monitor == nil ? "No agents yet." : "Still looking for agents\u{2026}")
                        .foregroundStyle(theme.textTertiary)
                } else {
                    ForEach(entries) { entry in
                        row(entry)
                    }
                }
            } header: {
                SettingsFormHeader(title: "Where servers come from", text: Self.intro, theme: theme)
            } footer: {
                Text(Self.countText(entries))
                    .font(Theme.caption)
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .panelScrollIndicators()
    }

    private func row(_ entry: SettingsAgentEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            // The panel's badge view, so a later logo pass changes both at once.
            AgentBadgeView(badge: AgentBadge.forLabel(entry.agent), theme: theme, size: Self.badgeSize)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(AgentBadge.displayLabel(entry.agent))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    Text("\(entry.serverCount) server\(entry.serverCount == 1 ? "" : "s")")
                        .font(Theme.caption)
                        .foregroundStyle(theme.textTertiary)
                }
                if entry.paths.isEmpty {
                    Text("Config path unknown")
                        .font(Theme.mono)
                        .foregroundStyle(theme.textTertiary)
                } else {
                    ForEach(entry.paths, id: \.self) { path in
                        ConfigPathRow(path: path, theme: theme)
                            .padding(.leading, -5)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// A grouped form's first section header (round 8): the pane's title and one
/// line of what it's for, in place of the old headers above the lists.
struct SettingsFormHeader: View {
    let title: String
    let text: String
    let theme: ThemeColors

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            Text(text)
                .font(Theme.caption)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .textCase(nil)
        .padding(.bottom, 2)
    }
}
