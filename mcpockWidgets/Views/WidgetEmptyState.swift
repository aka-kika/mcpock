import SwiftUI

/// Nothing to show yet — first install, or the app hasn't finished its first
/// check. Every widget falls back to this instead of a blank or crashed view.
struct WidgetEmptyState: View {
    var body: some View {
        VStack(spacing: 4) {
            Text("mcpock")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Open mcpock to start checking.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// "checked 2 minutes ago" — a live relative time, drawn once and then kept
/// current by the system itself, not by a new timeline entry (`Text(_:style:)`
/// refreshes on its own; `.relative` already reads "N minutes ago" / "in N
/// minutes", so nothing more is added to it).
struct WidgetCheckedAt: View {
    let date: Date

    var body: some View {
        HStack(spacing: 3) {
            Text("checked")
            Text(date, style: .relative)
        }
    }
}
