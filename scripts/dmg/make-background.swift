// Draws the DMG window's background (scripts/dmg/background.png), 1320 x 840
// pixels for a 660 x 420 point window at 2x. Three pastel colors, low noise:
// an arrow from the app to Applications and one line of text.
//
//   swift scripts/dmg/make-background.swift scripts/dmg/background.png
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "background.png"
let size = NSSize(width: 1320, height: 840)
let paper = NSColor(srgbRed: 0.957, green: 0.965, blue: 0.984, alpha: 1)  // #F4F6FB
let arrow = NSColor(srgbRed: 0.690, green: 0.741, blue: 0.851, alpha: 1)  // #B0BDD9
let ink = NSColor(srgbRed: 0.490, green: 0.545, blue: 0.651, alpha: 1)    // #7D8BA6

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

paper.setFill()
NSRect(origin: .zero, size: size).fill()

// Icons sit at x 180 and 480 points, y 190 from the top: the arrow runs
// between them, at the same height (420 - 190 = 230 points from the bottom).
let y: CGFloat = 230 * 2
let path = NSBezierPath()
path.move(to: NSPoint(x: 528, y: y))
path.line(to: NSPoint(x: 792, y: y))
path.move(to: NSPoint(x: 746, y: y + 30))
path.line(to: NSPoint(x: 794, y: y))
path.line(to: NSPoint(x: 746, y: y - 30))
path.lineWidth = 14
path.lineCapStyle = .round
path.lineJoinStyle = .round
arrow.setStroke()
path.stroke()

let text = "Drag mcpock into Applications to install" as NSString
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 30, weight: .medium),
    .foregroundColor: ink,
]
let textSize = text.size(withAttributes: attrs)
text.draw(at: NSPoint(x: (size.width - textSize.width) / 2, y: 196), withAttributes: attrs)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
