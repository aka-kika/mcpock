import SwiftUI
import WidgetKit

/// Small: overall status as a ring (premium look, 22 Nov, Kika's pick). The
/// ring is all servers, the slivers are the ones that need her, the number
/// inside says how many; when all is fine it holds the total. Under it the
/// word, then "41 in use · 12 off".
struct StatusWidgetView: View {
    let entry: MCPockWidgetEntry
    @Environment(\.colorScheme) private var colorScheme

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
        VStack(alignment: .leading, spacing: 0) {
            StatusRing(snapshot: snapshot, colorScheme: colorScheme)
            Text(StatusRing.label(snapshot))
                .font(.system(size: 12, weight: .medium))
                .padding(.top, 8)
            Spacer(minLength: 0)
            // A stale snapshot says so here; else the quiet totals.
            if snapshot.isStale(now: entry.date) {
                WidgetCheckedAt(date: snapshot.generated, stale: true)
                    .font(.system(size: 10))
                    .foregroundStyle(WidgetColors.grey(colorScheme))
            } else {
                Text(snapshot.inUseLine)
                    .font(.system(size: 10.5))
                    .foregroundStyle(WidgetColors.grey(colorScheme))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(2)
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
    MCPockWidgetEntry(date: .now, snapshot: .placeholderAllFine)
    MCPockWidgetEntry(date: .now, snapshot: nil)
}
