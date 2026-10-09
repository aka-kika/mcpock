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

/// The menu-bar icon: `server.rack`, plus a small badge at its bottom-right
/// corner when something needs attention. The badge sits in a knockout (a hole
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

    static let ringSize: CGFloat = 7
    static let ringStroke: CGFloat = 2
    static let diamondSide: CGFloat = 6
    /// Clear space between the badge and the glyph.
    static let knockout: CGFloat = 1.5
    /// The image's size: room for the glyph plus the badge hanging off its corner.
    static let canvas = NSSize(width: 22, height: 18)
    /// The badge's centre, in top-left coordinates on the canvas: on the glyph's
    /// bottom-right corner.
    static let badgeCenter = NSPoint(x: 17.5, y: 13.5)

    private var kind: StatusBadgeKind { StatusBadgeKind.forAggregate(aggregate) }

    var body: some View {
        Image(nsImage: Self.image(for: kind))
            .accessibilityLabel(Self.accessibilityLabel(for: aggregate))
    }

    private static func glyph(color: NSColor? = nil) -> NSImage? {
        var config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        if let color {
            config = config.applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        }
        return NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    static func image(for kind: StatusBadgeKind) -> NSImage {
        if kind == .none, let plain = glyph() {
            plain.isTemplate = true
            return plain
        }
        let image = NSImage(size: canvas, flipped: true) { rect in
            let dark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let theme = ThemeColors.resolve(dark ? .dark : .light)
            guard let context = NSGraphicsContext.current else { return false }

            if let symbol = glyph(color: .labelColor) {
                let size = symbol.size
                let origin = NSPoint(x: (rect.width - size.width) / 2 - 1, y: (rect.height - size.height) / 2)
                symbol.draw(in: NSRect(origin: origin, size: size))
            }

            // Punch the knockout through the glyph, then draw the badge in it.
            context.compositingOperation = .destinationOut
            NSColor.black.setFill()
            badgePath(kind, grow: knockout).fill()
            context.compositingOperation = .sourceOver

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
