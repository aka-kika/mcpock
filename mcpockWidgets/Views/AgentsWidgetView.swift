import SwiftUI
import WidgetKit

/// A ring per agent with its logo inside (premium look, 22 Nov, Kika's pick):
/// green is on and fine, the gap is turned off or not checked, the sliver
/// needs her. Medium: up to five, worst first, each with "21 of 29" under it.
/// Small: the first four, two by two.
struct AgentsWidgetView: View {
    let entry: MCPockWidgetEntry
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                content(snapshot)
                    .widgetStale(snapshot.isStale(now: entry.date))
            } else {
                WidgetEmptyState()
            }
        }
        .containerBackground(for: .widget) { Color.clear }
    }

    @ViewBuilder
    private func content(_ snapshot: MCPockWidgetSnapshot) -> some View {
        if snapshot.agents.isEmpty {
            WidgetEmptyState()
        } else if family == .systemSmall {
            small(snapshot)
        } else {
            medium(snapshot)
        }
    }

    private func headline(_ s: MCPockWidgetSnapshot) -> String {
        if !s.firstCheckDone { return "Checking\u{2026}" }
        if s.problemCount == 0 { return "All fine" }
        return "\(s.problemCount) need\(s.problemCount == 1 ? "s" : "") you"
    }

    private func medium(_ snapshot: MCPockWidgetSnapshot) -> some View {
        let shown = Array(snapshot.agents.prefix(5))
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(headline(snapshot))
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 6)
                Group {
                    if let count = snapshot.agentCount { Text("\(count) agent\(count == 1 ? "" : "s") \u{00B7}") }
                    WidgetCheckedAt(date: snapshot.generated, stale: snapshot.isStale(now: entry.date))
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            HStack(alignment: .top, spacing: 0) {
                ForEach(shown) { agent in
                    VStack(spacing: 5) {
                        AgentRing(agent: agent, size: 44, colorScheme: colorScheme)
                        Text(agent.countWords)
                            .font(.system(size: 10, design: .rounded).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(agent.name), \(agent.countWords) servers, \(agent.problemCount) need attention")
                }
                // Fewer than five: keep the rings their size, on the left.
                ForEach(0..<max(0, 5 - shown.count), id: \.self) { _ in
                    Color.clear.frame(maxWidth: .infinity).frame(height: 1)
                }
            }
            .padding(.top, 11)
            Spacer(minLength: 0)
            if let line = Self.moreLine(snapshot, shown: shown) {
                Text(line)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(2)
    }

    private func small(_ snapshot: MCPockWidgetSnapshot) -> some View {
        let shown = Array(snapshot.agents.prefix(4))
        return VStack(alignment: .leading, spacing: 0) {
            Text(headline(snapshot))
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 0)
            Grid(horizontalSpacing: 20, verticalSpacing: 9) {
                ForEach(Array(stride(from: 0, to: shown.count, by: 2)), id: \.self) { start in
                    GridRow {
                        ForEach(shown[start..<min(start + 2, shown.count)]) { agent in
                            AgentRing(agent: agent, size: 42, colorScheme: colorScheme)
                                .accessibilityLabel("\(agent.name), \(agent.problemCount) need attention")
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
        }
        .padding(2)
    }

    /// "4 more agents, all fine": the list is worst first, so when the last
    /// ring shown is fine, so is everything after it.
    static func moreLine(_ s: MCPockWidgetSnapshot, shown: [MCPockWidgetSnapshot.Agent]) -> String? {
        guard let total = s.agentCount, total > shown.count else { return nil }
        let more = total - shown.count
        let words = "\(more) more agent\(more == 1 ? "" : "s")"
        return (shown.last?.problemCount ?? 1) == 0 ? words + ", all fine" : words
    }
}

/// One agent: its ring, and inside it the logo (a vector template, so it
/// takes the text colour and the system's tint on a tinted desktop). An agent
/// without a logo shows its first letter.
private struct AgentRing: View {
    let agent: MCPockWidgetSnapshot.Agent
    let size: CGFloat
    let colorScheme: ColorScheme

    var body: some View {
        WidgetRing(
            broken: agent.redCount,
            attention: agent.problemCount - agent.redCount,
            fine: agent.fineCount,
            quiet: agent.quietCount,
            lineWidth: 4,
            colorScheme: colorScheme
        ) {
            Group {
                if let logo = agent.logo {
                    Image(logo)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                } else {
                    Text(agent.name.prefix(1).uppercased())
                        .font(.system(size: size * 0.34, weight: .semibold))
                }
            }
            .frame(width: size * 0.42, height: size * 0.42)
            .foregroundStyle(.primary.opacity(0.85))
        }
        .frame(width: size, height: size)
    }
}

struct MCPockAgentsWidget: Widget {
    let kind = "MCPockAgentsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MCPockTimelineProvider()) { entry in
            AgentsWidgetView(entry: entry)
        }
        .configurationDisplayName("mcpock Agents")
        .description("Each agent's servers, at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

#Preview(as: .systemMedium) {
    MCPockAgentsWidget()
} timeline: {
    MCPockWidgetEntry(date: .now, snapshot: .placeholderSample)
}
