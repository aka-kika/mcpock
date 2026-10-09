import SwiftUI

/// A server's health as **shape plus color** (v1.5 spec), so color is never the
/// only signal: a filled circle is fine, a ring is slow or waiting, a diamond is
/// broken, a dash is not checked by mcpock at all. One view for the panel, the
/// detail card and Preferences, so the three can't drift apart.
///
/// | State | Mark |
/// | --- | --- |
/// | healthy | filled circle, 8pt |
/// | degraded | ring, 8pt, 2pt stroke |
/// | broken | filled diamond (7pt square rotated 45°) |
/// | unknown | ring in `textTertiary` |
/// | selfManaged / paused | small dash in `textTertiary` |
///
/// A row that only differs keeps the healthy circle; its note carries the
/// degraded color instead (see `ShortReason`).
struct HealthMark: View {
    let state: HealthState
    let theme: ThemeColors
    /// Being re-checked on its own (1.5.3): a small spinning arc takes the
    /// mark's place, in the same box, so nothing in the row moves.
    var checking = false

    /// Every mark sits in the same box, so names line up whatever the shape.
    static let boxSize: CGFloat = 10
    static let dotSize: CGFloat = 8
    static let ringStroke: CGFloat = 2
    static let diamondSide: CGFloat = 7

    var body: some View {
        Group {
            if checking {
                CheckingArc(color: theme.textSecondary)
            } else {
                mark
            }
        }
        .frame(width: Self.boxSize, height: Self.boxSize)
        .accessibilityElement()
        .accessibilityLabel(checking ? "Checking again" : Self.word(for: state))
    }

    @ViewBuilder
    private var mark: some View {
        switch state {
        case .healthy:
            Circle()
                .fill(theme.statusHealthy)
                .frame(width: Self.dotSize, height: Self.dotSize)
        case .degraded:
            ring(theme.statusDegraded)
        case .unknown:
            ring(theme.textTertiary)
        case .broken:
            Rectangle()
                .fill(theme.statusBroken)
                .frame(width: Self.diamondSide, height: Self.diamondSide)
                .rotationEffect(.degrees(45))
        case .selfManaged, .paused:
            Capsule()
                .fill(theme.textTertiary)
                .frame(width: 7, height: 2)
        }
    }

    /// The stroke is inset so the ring's outer edge matches the dot's 8pt.
    private func ring(_ color: Color) -> some View {
        Circle()
            .strokeBorder(color, lineWidth: Self.ringStroke)
            .frame(width: Self.dotSize, height: Self.dotSize)
    }

    /// The word the UI uses for a state (the spec's table). Row-level nuance
    /// ("Needs sign-in", "Set up differently") comes from `word(for group:)`.
    static func word(for state: HealthState) -> String {
        switch state {
        case .healthy: return "Healthy"
        case .degraded: return "Slow"
        case .broken: return "Broken"
        case .unknown: return "Checking"
        case .selfManaged: return "Runs inside its app"
        case .paused: return "Paused"
        }
    }

    /// The word for a whole row: an auth failure reads "Needs sign-in" rather than
    /// "Slow", and a healthy row that differs reads "Set up differently".
    static func word(for group: ServerGroup) -> String {
        if group.state == .degraded,
           group.issues.contains(where: { $0.reason.hasPrefix("Needs authentication") }) {
            return "Needs sign-in"
        }
        if group.state == .healthy && group.differsNeedsAttention {
            return "Set up differently"
        }
        return word(for: group.state)
    }
}

/// The health mark while one server is re-checked: a quarter-open arc the size
/// of the dot, turning once a second. Driven by `TimelineView` like
/// `SpinnableIcon`, so when checking ends the arc is simply gone (a
/// `.repeatForever` animation would keep running).
struct CheckingArc: View {
    let color: Color

    private let period: Double = 0.9

    var body: some View {
        TimelineView(.animation) { context in
            let seconds = context.date.timeIntervalSinceReferenceDate
            let turn = seconds.truncatingRemainder(dividingBy: period) / period
            Circle()
                .trim(from: 0, to: 0.72)
                .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .frame(width: HealthMark.dotSize, height: HealthMark.dotSize)
                .rotationEffect(.degrees(turn * 360))
        }
    }
}
