import SwiftUI
import WidgetKit

/// Medium: up to 4 servers that need attention, each with its state in plain
/// words. When nothing is wrong: "All 48 fine". Footer: how many more are
/// fine, and when mcpock last checked.
struct ProblemsWidgetView: View {
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

    private func content(_ snapshot: MCPockWidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("mcpock")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            if snapshot.problems.isEmpty {
                Spacer(minLength: 0)
                Text(snapshot.firstCheckDone ? "All \(snapshot.totalServers) fine" : "Checking\u{2026}")
                    .font(.system(size: 16, weight: .semibold))
                Spacer(minLength: 0)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(snapshot.problems) { problem in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(WidgetColors.broken(colorScheme))
                                .frame(width: 6, height: 6)
                            Text(problem.name)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(problem.status)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            footer(snapshot)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(2)
    }

    @ViewBuilder
    private func footer(_ s: MCPockWidgetSnapshot) -> some View {
        if s.problems.isEmpty {
            WidgetCheckedAt(date: s.generated)
        } else {
            HStack(spacing: 3) {
                Text("\(s.fineCount) more fine \u{00B7}")
                WidgetCheckedAt(date: s.generated)
            }
        }
    }
}

struct MCPockProblemsWidget: Widget {
    let kind = "MCPockProblemsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MCPockTimelineProvider()) { entry in
            ProblemsWidgetView(entry: entry)
        }
        .configurationDisplayName("mcpock Problems")
        .description("The servers that need you, worst first.")
        .supportedFamilies([.systemMedium])
    }
}

#Preview(as: .systemMedium) {
    MCPockProblemsWidget()
} timeline: {
    MCPockWidgetEntry(date: .now, snapshot: .placeholderSample)
    MCPockWidgetEntry(date: .now, snapshot: MCPockWidgetSnapshot(
        generated: .now, checking: false, firstCheckDone: true,
        totalServers: 48, problemCount: 0, fineCount: 48, problems: [], agents: []
    ))
}
