import SwiftUI
import WidgetKit

/// Medium: one row per agent (top 4-5, worst first), each with a small
/// health bar and its server count — the widget's version of the app's
/// Agents tab.
struct AgentsWidgetView: View {
    let entry: MCPockWidgetEntry
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                content(snapshot)
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
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("mcpock \u{00B7} Agents")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(snapshot.agents) { agent in
                        AgentRow(agent: agent, colorScheme: colorScheme)
                    }
                }
                Spacer(minLength: 0)
                WidgetCheckedAt(date: snapshot.generated)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(2)
        }
    }
}

private struct AgentRow: View {
    let agent: MCPockWidgetSnapshot.Agent
    let colorScheme: ColorScheme

    var body: some View {
        HStack(spacing: 8) {
            AgentLogo(logo: agent.logo)
            Text(agent.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .frame(width: 96, alignment: .leading)
            HealthBarMark(fine: agent.fineCount, problems: agent.problemCount, colorScheme: colorScheme)
            Spacer(minLength: 4)
            Text("\(agent.serverCount)")
                .font(.system(size: 11, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

/// The agent's logo, as in the app's Agents tab: a vector template, so it
/// takes the text color (and the system's tint on a tinted desktop). An agent
/// without one keeps a small dot in the same slot, so the names line up.
private struct AgentLogo: View {
    let logo: String?

    var body: some View {
        Group {
            if let logo {
                Image(logo)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
            } else {
                Circle().frame(width: 5, height: 5)
            }
        }
        .frame(width: 13, height: 13)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
}

/// A tiny two-segment bar: fine in the healthy color, problems in the broken
/// color — the widget's version of the Agents tab's `HealthBar`, without its
/// grow-in animation (widgets don't animate between refreshes).
private struct HealthBarMark: View {
    let fine: Int
    let problems: Int
    let colorScheme: ColorScheme

    var body: some View {
        GeometryReader { geo in
            let total = max(fine + problems, 1)
            let problemWidth = geo.size.width * CGFloat(problems) / CGFloat(total)
            ZStack(alignment: .leading) {
                Capsule().fill(WidgetColors.healthy(colorScheme).opacity(0.35))
                if problems > 0 {
                    Capsule().fill(WidgetColors.broken(colorScheme)).frame(width: problemWidth)
                }
            }
        }
        .frame(height: 4)
        .frame(maxWidth: 44)
        .accessibilityLabel("\(fine) fine, \(problems) need attention")
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
        .supportedFamilies([.systemMedium])
    }
}

#Preview(as: .systemMedium) {
    MCPockAgentsWidget()
} timeline: {
    MCPockWidgetEntry(date: .now, snapshot: .placeholderSample)
}
