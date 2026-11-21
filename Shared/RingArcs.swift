import Foundation

/// The arcs of a status ring (premium look, 22 Nov, Kika's picks: the status
/// widget is a ring, the Agents widget a ring per agent). The whole circle is
/// all servers: broken first, then the other problems, then the fine ones;
/// what is turned off or not checked stays the bare track. Pure, shared by the
/// app (tests) and the widget extension (drawing).
enum RingArcs {
    enum Kind: Equatable, Sendable {
        case broken, attention, fine
    }

    struct Arc: Equatable, Sendable {
        let kind: Kind
        /// Shares of the circle, 0...1, clockwise from the top.
        let from: Double
        let to: Double
    }

    /// - `minShare`: a problem sliver is never thinner than this, so one broken
    ///   server among forty can still be seen. The fine arc gives up the room.
    /// - `gap`: clear space between two arcs.
    static func arcs(
        broken: Int, attention: Int, fine: Int, off: Int = 0,
        minShare: Double = 0.045, gap: Double = 0.014
    ) -> [Arc] {
        let (broken, attention, fine, off) = (max(broken, 0), max(attention, 0), max(fine, 0), max(off, 0))
        let total = Double(broken + attention + fine + off)
        guard total > 0 else { return [] }

        // The whole ring in one colour: no gap, no seam.
        if off == 0 {
            if broken == 0 && attention == 0 { return [Arc(kind: .fine, from: 0, to: 1)] }
            if fine == 0 && attention == 0 { return [Arc(kind: .broken, from: 0, to: 1)] }
            if fine == 0 && broken == 0 { return [Arc(kind: .attention, from: 0, to: 1)] }
        }

        func share(_ count: Int) -> Double {
            count > 0 ? max(Double(count) / total, minShare) : 0
        }
        let offShare = Double(off) / total
        var shares: [(Kind, Double)] = [(.broken, share(broken)), (.attention, share(attention))]
        let left = max(0, 1 - offShare - shares.reduce(0) { $0 + $1.1 })
        shares.append((.fine, fine > 0 ? left : 0))

        var arcs: [Arc] = []
        var start = 0.0
        for (kind, width) in shares where width > 0 {
            let end = min(start + width, 1)
            // Half a gap off each end; an arc too thin for that keeps a hair.
            let inset = min(gap / 2, (end - start) / 4)
            arcs.append(Arc(kind: kind, from: start + inset, to: end - inset))
            start = end
        }
        return arcs
    }
}
