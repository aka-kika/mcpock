import SwiftUI

/// The ring both widgets draw (premium look, 22 Nov, Kika's picks): all
/// servers as one circle, the fine ones in the healthy colour, a sliver for
/// what needs her, and the bare track for what is off or not checked. The
/// arcs come from `RingArcs` (shared with the app, so the tests cover them).
struct WidgetRing<Center: View>: View {
    let broken: Int
    let attention: Int
    let fine: Int
    var quiet: Int = 0
    var lineWidth: CGFloat = 5.5
    let colorScheme: ColorScheme
    @ViewBuilder var center: () -> Center

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.09), lineWidth: lineWidth)
            ForEach(Array(RingArcs.arcs(broken: broken, attention: attention, fine: fine, off: quiet).enumerated()), id: \.offset) { _, arc in
                Circle()
                    .inset(by: lineWidth / 2)
                    .trim(from: arc.from, to: arc.to)
                    .stroke(color(arc.kind), style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
            center()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(fine) fine, \(broken + attention) need attention")
    }

    private func color(_ kind: RingArcs.Kind) -> Color {
        switch kind {
        case .broken: return WidgetColors.broken(colorScheme)
        case .attention: return WidgetColors.degraded(colorScheme)
        // Softer than the slivers, so the eye lands on what needs her.
        case .fine: return WidgetColors.healthy(colorScheme).opacity(0.75)
        }
    }
}

/// The whole setup's ring with its number inside: how many need her, in the
/// worst one's colour; the total, plain, when all is fine.
struct StatusRing: View {
    let snapshot: MCPockWidgetSnapshot
    var size: CGFloat = 64
    let colorScheme: ColorScheme

    var body: some View {
        let counts = snapshot.ringCounts
        WidgetRing(
            broken: snapshot.firstCheckDone ? counts.broken : 0,
            attention: snapshot.firstCheckDone ? counts.attention : 0,
            fine: snapshot.firstCheckDone ? counts.fine : 0,
            quiet: snapshot.firstCheckDone ? counts.quiet : 1,
            colorScheme: colorScheme
        ) {
            Text(centerText)
                .font(.system(size: size * 0.36, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(centerColor)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .padding(.horizontal, 9)
        }
        .frame(width: size, height: size)
    }

    private var centerText: String {
        if !snapshot.firstCheckDone { return "\u{2026}" }
        return snapshot.problemCount > 0 ? "\(snapshot.problemCount)" : "\(snapshot.totalServers)"
    }

    private var centerColor: Color {
        guard snapshot.firstCheckDone, snapshot.problemCount > 0 else { return .primary }
        return snapshot.markIsRed ? WidgetColors.broken(colorScheme) : WidgetColors.degraded(colorScheme)
    }

    /// The word under the ring.
    static func label(_ s: MCPockWidgetSnapshot) -> String {
        if !s.firstCheckDone { return "Checking\u{2026}" }
        if s.problemCount == 0 { return "All fine" }
        return s.problemCount == 1 ? "needs you" : "need you"
    }
}

/// A problem's mark, the panel's shapes: a diamond for broken, a ring for the rest.
struct WidgetMark: View {
    let isBroken: Bool
    let colorScheme: ColorScheme

    var body: some View {
        Group {
            if isBroken {
                Rectangle()
                    .fill(WidgetColors.broken(colorScheme))
                    .frame(width: 6.5, height: 6.5)
                    .rotationEffect(.degrees(45))
            } else {
                Circle()
                    .strokeBorder(WidgetColors.degraded(colorScheme), lineWidth: 2)
                    .frame(width: 8, height: 8)
            }
        }
        .frame(width: 10, height: 10)
        .accessibilityHidden(true)
    }
}
