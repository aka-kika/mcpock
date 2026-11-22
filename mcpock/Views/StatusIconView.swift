import AppKit
import SwiftUI

/// What the menu-bar icon adds to the plain glyph (v1.5 spec, Phase 6). The
/// shape carries the meaning, so there is never a count and never a pulse: a
/// ring says "worth a look when you have a minute", a diamond says "broken".
enum StatusBadgeKind: Equatable, Sendable {
    /// All fine: the plain glyph.
    case none
    /// Something slow, needs sign-in, still being checked, or set up differently.
    case ring
    /// Something broken.
    case diamond

    /// The one mapping from the monitor's verdict to a badge. Pure, so
    /// `StatusIconTests` covers every case.
    nonisolated static func forAggregate(_ aggregate: AggregateState) -> StatusBadgeKind {
        switch aggregate {
        case .allHealthy: return .none
        case .attention, .degradedOrUnknown: return .ring
        case .broken: return .diamond
        }
    }
}

/// The menu-bar icon: mcpock's own glyph (three stacked server units, each
/// with a slot and a light; 22 Nov), plus a small badge at its bottom-right
/// corner when something needs attention. The glyph is drawn on a half-point
/// grid for an 18 pt box, so every edge lands on a whole pixel. The badge sits in a knockout (a hole
/// punched through the glyph) so it reads cleanly over the glyph's strokes
/// whatever the menu bar's colour is. Badge colours are the theme's status
/// colours for the menu bar's own look, never the app theme: the deeper ones on
/// a light bar, the pastels on a dark one.
///
/// **Drawn as one `NSImage`, not composed in SwiftUI.** A `MenuBarExtra` label
/// keeps only its `Image`/`Text` and turns it into a template: the first Phase 6
/// build layered SwiftUI shapes over the glyph and the menu bar showed the plain
/// glyph with no badge at all (found in the Phase 7 capture). The badged image
/// is therefore drawn by hand in a drawing handler, which AppKit calls when the
/// status item draws, under the menu bar's own appearance, so the glyph colour
/// (`labelColor`) and the badge palette always match the bar. All fine keeps
/// the plain template glyph, exactly as before.
struct StatusIconView: View {
    let aggregate: AggregateState
    /// An agent's ask waits for her answer (1.16): a small dot at the top right.
    var asksYou = false

    static let ringSize: CGFloat = 7
    static let ringStroke: CGFloat = 2
    static let diamondSide: CGFloat = 6
    /// Clear space between the badge and the glyph.
    static let knockout: CGFloat = 1.5
    /// The glyph's asset (a one-colour template) and the box it is drawn for.
    /// Also the icon of a server that has none of its own (`ServerIconView`).
    static let glyphAsset = "mcpock-glyph"
    static let glyphSize = NSSize(width: 18, height: 18)
    /// The image's size: room for the glyph plus the badge hanging off its corner.
    static let canvas = NSSize(width: 22, height: 18)
    /// The badge's centre, in top-left coordinates on the canvas: on the
    /// bottom unit's right end, where its light is, so the badge takes the
    /// light's place.
    static let badgeCenter = NSPoint(x: 17.5, y: 14)
    /// The ask dot (1.16): top right, the glyph's own colour, no new colour.
    static let askCenter = NSPoint(x: 18.5, y: 3.5)
    static let askSize: CGFloat = 5.5

    private var kind: StatusBadgeKind { StatusBadgeKind.forAggregate(aggregate) }

    var body: some View {
        Image(nsImage: Self.image(for: kind, asksYou: asksYou))
            .accessibilityLabel(Self.accessibilityLabel(for: aggregate, asksYou: asksYou))
    }

    /// The glyph as its own image, a copy (the caller may flag it as a
    /// template); the old system symbol if the asset is ever missing.
    private static func glyph() -> NSImage? {
        if let asset = NSImage(named: glyphAsset)?.copy() as? NSImage {
            asset.size = glyphSize
            return asset
        }
        return NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium))
    }

    static func image(for kind: StatusBadgeKind, asksYou: Bool = false) -> NSImage {
        if kind == .none, !asksYou, let plain = glyph() {
            plain.isTemplate = true
            return plain
        }
        let image = NSImage(size: canvas, flipped: true) { rect in
            let dark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let theme = ThemeColors.resolve(dark ? .dark : .light)
            guard let context = NSGraphicsContext.current else { return false }

            // The glyph in the bar's own text colour: drawn, then coloured
            // through its own shape (the canvas is still empty around it).
            if let symbol = glyph() {
                let size = symbol.size
                let origin = NSPoint(x: 0, y: ((rect.height - size.height) / 2).rounded())
                let box = NSRect(origin: origin, size: size)
                symbol.draw(in: box)
                context.compositingOperation = .sourceIn
                NSColor.labelColor.setFill()
                box.fill()
                context.compositingOperation = .sourceOver
            }

            // Punch the knockout through the glyph, then draw the badge in it.
            context.compositingOperation = .destinationOut
            NSColor.black.setFill()
            if kind != .none { badgePath(kind, grow: knockout).fill() }
            if asksYou { askPath(grow: knockout).fill() }
            context.compositingOperation = .sourceOver
            if asksYou {
                NSColor.labelColor.setFill()
                askPath(grow: 0).fill()
            }

            switch kind {
            case .ring:
                NSColor(theme.statusDegraded).setStroke()
                let path = badgePath(.ring, grow: -ringStroke / 2)
                path.lineWidth = ringStroke
                path.stroke()
            case .diamond:
                NSColor(theme.statusBroken).setFill()
                badgePath(.diamond, grow: 0).fill()
            case .none:
                break
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func askPath(grow: CGFloat) -> NSBezierPath {
        let r = askSize / 2 + grow
        return NSBezierPath(ovalIn: NSRect(x: askCenter.x - r, y: askCenter.y - r, width: r * 2, height: r * 2))
    }

    /// The badge's outline, grown (knockout) or shrunk (stroke inset) by `grow`.
    private static func badgePath(_ kind: StatusBadgeKind, grow: CGFloat) -> NSBezierPath {
        let c = badgeCenter
        switch kind {
        case .diamond:
            // A square of `diamondSide` turned 45°: its half-diagonal is side/√2.
            let r = diamondSide / 2 * 2.squareRoot() + grow * 2.squareRoot()
            let path = NSBezierPath()
            path.move(to: NSPoint(x: c.x, y: c.y - r))
            path.line(to: NSPoint(x: c.x + r, y: c.y))
            path.line(to: NSPoint(x: c.x, y: c.y + r))
            path.line(to: NSPoint(x: c.x - r, y: c.y))
            path.close()
            return path
        case .ring, .none:
            let r = ringSize / 2 + grow
            return NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        }
    }

    /// One label per state, for VoiceOver; the shapes are not readable aloud.
    nonisolated static func accessibilityLabel(for aggregate: AggregateState, asksYou: Bool) -> String {
        let label = accessibilityLabel(for: aggregate)
        return asksYou ? label + ", and an agent asks you something" : label
    }

    nonisolated static func accessibilityLabel(for aggregate: AggregateState) -> String {
        switch aggregate {
        case .allHealthy:
            return "mcpock: all servers fine"
        case .attention:
            return "mcpock: a server is set up differently across agents"
        case .degradedOrUnknown:
            return "mcpock: some servers are slow, need sign-in or are still being checked"
        case .broken:
            return "mcpock: some servers are broken"
        }
    }
}
