import SwiftUI
import WidgetKit

/// Small: overall status. The mcpock mark and name, "All fine" or "N need
/// you", the server count, and when it last checked.
struct StatusWidgetView: View {
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
            HStack(spacing: 5) {
                Circle()
                    .fill(markColor(snapshot))
                    .frame(width: 8, height: 8)
                Text("mcpock")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(headline(snapshot))
                .font(.system(size: 18, weight: .semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.75)
            Text("\(snapshot.totalServers) server\(snapshot.totalServers == 1 ? "" : "s")")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            WidgetCheckedAt(date: snapshot.generated)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(2)
    }

    private func headline(_ s: MCPockWidgetSnapshot) -> String {
        if !s.firstCheckDone { return "Checking\u{2026}" }
        if s.problemCount == 0 { return "All fine" }
        return "\(s.problemCount) need\(s.problemCount == 1 ? "s" : "") you"
    }

    private func markColor(_ s: MCPockWidgetSnapshot) -> Color {
        if !s.firstCheckDone { return Color.secondary }
        if s.problemCount == 0 { return WidgetColors.healthy(colorScheme) }
        return s.markIsRed ? WidgetColors.broken(colorScheme) : WidgetColors.degraded(colorScheme)
    }
}

struct MCPockStatusWidget: Widget {
    let kind = "MCPockStatusWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MCPockTimelineProvider()) { entry in
            StatusWidgetView(entry: entry)
        }
        .configurationDisplayName("mcpock Status")
        .description("Overall server health at a glance.")
        .supportedFamilies([.systemSmall])
    }
}

#Preview(as: .systemSmall) {
    MCPockStatusWidget()
} timeline: {
    MCPockWidgetEntry(date: .now, snapshot: .placeholderSample)
    MCPockWidgetEntry(date: .now, snapshot: nil)
}
