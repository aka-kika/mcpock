import SwiftUI

/// The three pastel health colors, copied from `Theme.ThemeColors.resolve`
/// (`mcpock/Theme/Theme.swift`) rather than importing that file: the widget
/// extension has no reason to pull in the app's whole theme system (and
/// nothing else there is in flux), just these three hues so the widgets read
/// as the same app. If the app's hex values change, update these to match.
enum WidgetColors {
    static func healthy(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x93C9A6) : Color(hex: 0x3D8B55)
    }

    static func degraded(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0xDCC27A) : Color(hex: 0xB8860B)
    }

    /// The widgets' grey text (22 Nov, Runway 6332). The system's
    /// `.secondary` measured 3.95:1 on a light widget (#808080 on white, VM
    /// pictures), under the 4.5 bar; this one reads about 6:1 in both looks,
    /// like the panel's own grey.
    static func grey(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.58) : Color.black.opacity(0.62)
    }

    static func broken(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0xDF9C9C) : Color(hex: 0xB54545)
    }
}

private extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1.0)
    }
}
