import SwiftUI
import WidgetKit

/// Medium: the status ring on the left, and beside it the servers that need
/// her, each with its agents under it and its state in plain words (premium
/// look, 22 Nov, Kika's pick). When nothing is wrong: "All fine" and the totals.
struct ProblemsWidgetView: View {
    let entry: MCPockWidgetEntry
    @Environment(\.colorScheme) private var colorScheme

    /// Rows that fit beside the ring; the rest is "+N more".
    static let rowLimit = 3

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

    private func content(_ snapshot: MCPockWidgetSnapshot) -> some View {
        HStack(spacing: 12) {
            VStack(spacing: 0) {
                StatusRing(snapshot: snapshot, colorScheme: colorScheme)
                Text(StatusRing.label(snapshot))
                    .font(.system(size: 11.5, weight: .medium))
                    .padding(.top, 7)
                Text(snapshot.inUse.map { "of \($0) in use" } ?? "\(snapshot.totalServers) servers")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .padding(.top, 1)
            }
            .frame(width: 78)
            Rectangle()
                .fill(Color.primary.opacity(0.1))
                .frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                if snapshot.problems.isEmpty {
                    Spacer(minLength: 0)
                    Text(snapshot.firstCheckDone ? "All fine" : "Checking\u{2026}")
                        .font(.system(size: 17, weight: .semibold))
                    Text(snapshot.inUseLine)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                    Spacer(minLength: 0)
                } else {
                    ForEach(snapshot.problems.prefix(Self.rowLimit)) { problem in
                        row(problem)
                    }
                    Spacer(minLength: 0)
                }
                footer(snapshot)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .padding(2)
    }

    private func row(_ problem: MCPockWidgetSnapshot.Problem) -> some View {
        HStack(spacing: 8) {
            WidgetMark(isBroken: problem.showsRed, colorScheme: colorScheme)
            VStack(alignment: .leading, spacing: 0) {
                Text(problem.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                if let agents = problem.agents, !agents.isEmpty {
                    Text(agents.joined(separator: ", "))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            // The state keeps its room; a long name or agent line gives way.
            Text(problem.status)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .layoutPriority(1)
        }
        .frame(height: 30)
    }

    @ViewBuilder
    private func footer(_ s: MCPockWidgetSnapshot) -> some View {
        let more = s.problemCount - min(s.problems.count, Self.rowLimit)
        HStack(spacing: 3) {
            // The snapshot keeps only the worst few (r3 b5bc).
            if more > 0 { Text("+\(more) more \u{00B7}") }
            WidgetCheckedAt(date: s.generated, stale: s.isStale(now: entry.date))
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
    MCPockWidgetEntry(date: .now, snapshot: .placeholderAllFine)
}
