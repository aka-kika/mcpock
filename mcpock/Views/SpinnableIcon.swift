import SwiftUI

/// An SF Symbol that rotates continuously while `spinning` is true.
///
/// The footer already dimmed its buttons during a refresh pass, but a dimmed icon
/// reads as "disabled", not "working" — it was hard to tell a slow probe cycle from
/// a hung app. Continuous motion answers that at a glance.
///
/// **Why `TimelineView` and not `withAnimation(.repeatForever)`:** a repeating
/// animation attaches to the view and keeps running; clearing the flag and setting
/// the angle back — even inside `withAnimation(.none)` — does not detach it, so the
/// icon span forever after the first refresh (observed 2026-08-03). Driving the
/// angle from the timeline's clock instead means "stopped" is *structural*: when
/// `spinning` is false the animated branch is gone from the hierarchy entirely,
/// so there is no animation left to leak. It also costs nothing while idle —
/// `.animation` only ticks in the branch that's actually on screen.
struct SpinnableIcon: View {
    let systemName: String
    let spinning: Bool

    /// Seconds per full turn.
    private let period: Double = 1.1

    var body: some View {
        if spinning {
            TimelineView(.animation) { context in
                let seconds = context.date.timeIntervalSinceReferenceDate
                let turn = (seconds.truncatingRemainder(dividingBy: period)) / period
                Image(systemName: systemName)
                    .rotationEffect(.degrees(turn * 360))
            }
        } else {
            Image(systemName: systemName)
        }
    }
}
