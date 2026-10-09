import AppKit
import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case dark
    case light
    /// Apple's own Liquid Glass (macOS 26.1+), added after the first three.
    /// Its raw value is stored in `AppPreferences`, so "glass" must never
    /// change once someone has it saved.
    case glass

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .dark: return "Dark"
        case .light: return "Light"
        case .glass: return "Glass"
        }
    }

    /// Glyph for the segmented Appearance picker. The names still travel as the
    /// accessibility label and tooltip — a segmented control of three icons is only
    /// readable because these are the conventional macOS ones.
    var systemImage: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .dark: return "moon.fill"
        case .light: return "sun.max.fill"
        case .glass: return "cube.transparent"
        }
    }

    /// `nil` means follow system. Glass follows it too — it's a surface
    /// treatment, not a light/dark choice, and the system's own Liquid Glass
    /// already adapts to light/dark and to the person's Clear/Tinted setting
    /// on its own.
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system, .glass: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }

    /// Concrete scheme for painting custom colors.
    func resolvedScheme(systemFallback: ColorScheme) -> ColorScheme {
        preferredColorScheme ?? systemFallback
    }

    func resolvedColors(systemFallback: ColorScheme) -> ThemeColors {
        ThemeColors.resolve(resolvedScheme(systemFallback: systemFallback), forGlass: self == .glass)
    }

    /// AppKit appearance for MenuBarExtra / NSWindow (preferredColorScheme alone is ignored there).
    var nsAppearance: NSAppearance? {
        switch self {
        case .system, .glass: return nil
        case .dark: return NSAppearance(named: .darkAqua)
        case .light: return NSAppearance(named: .aqua)
        }
    }
}

struct ThemeColors: Equatable {
    let background: Color
    let elevated: Color
    let divider: Color
    let textPrimary: Color
    let textSecondary: Color
    let textTertiary: Color
    let statusHealthy: Color
    let statusDegraded: Color
    let statusBroken: Color
    /// Hover fill for a row. **Neutral, not accent**: an accent-tinted block behind a
    /// two-line row reads as a heavy selection slab rather than a hover hint.
    let rowHighlight: Color
    /// Fill for the panel's own bars (the footer today; the header in v1.5). Dark:
    /// the soft-dark `surface`, a step up from the background. Light: clear, so
    /// the one menu material shows through edge to edge. The reverted translucent
    /// panel (44f2e73) tinted the footer differently from the list and the two
    /// read as mismatched "old theme" sections; one treatment avoids that.
    let chromeFill: Color
    /// Selected row in the server list (v1.5). A step stronger than the hover fill
    /// and just as neutral: no accent inside the panel.
    let rowSelected: Color
    /// Resting fill for the panel's controls: the search field, the segment track,
    /// the agent badges' ground. Dark: the soft-dark `surface`. Light: a system
    /// fill, so the menu material stays one sheet instead of growing solid cards.
    let fieldFill: Color
    /// The selected segment and a pressed footer glyph. Neutral, never accent.
    let selectedFill: Color
    /// Outline of an unselected control: the search field, the
    /// card's buttons and tool chips. Light needs more than `divider` here: on the
    /// frosted menu material a separator-weight outline all but disappeared
    /// (Phase 7). Still a neutral label grey, never accent.
    let controlStroke: Color

    /// Text/­surface tokens come from **AppKit semantic colors**, not fixed hex:
    /// they already track light/dark, increased-contrast, and reduced-transparency,
    /// and they match the system menus mcpock sits beside. Only the three status
    /// hues stay hand-picked — the system greens/reds are louder than a 7pt dot wants.
    ///
    /// `forGlass`: the Glass theme paints its own surface (`PanelBackdrop`'s
    /// `.glassEffect`), so the header/footer chrome must stop laying a second,
    /// opaque fill on top of it — the same reason Light already leaves
    /// `chromeFill` clear for its menu material. Defaults to false so every
    /// existing `resolve(.dark)` / `resolve(.light)` call (including the
    /// System and Dark/Light themes, and the tests that pin their exact
    /// colors) is unchanged.
    static func resolve(_ scheme: ColorScheme, forGlass: Bool = false) -> ThemeColors {
        let statusHealthy: Color
        let statusDegraded: Color
        let statusBroken: Color
        switch scheme {
        case .light:
            statusHealthy = Color(hex: 0x3D8B55)
            statusDegraded = Color(hex: 0xB8860B)
            statusBroken = Color(hex: 0xB54545)
        case .dark:
            fallthrough
        @unknown default:
            // Pastel, not saturated: the dots are the only colour on the soft
            // ground, so they are the first thing to shout if they're loud.
            statusHealthy = Color(hex: 0x93C9A6)
            statusDegraded = Color(hex: 0xDCC27A)
            statusBroken = Color(hex: 0xDF9C9C)
        }

        // Surfaces: semantic in Light (it matches system menus well), but a
        // hand-picked **soft dark** ramp in Dark. `windowBackgroundColor` in Dark
        // is near-black, and the previous charcoal (#1F1F22) still read as a hard
        // void next to the desktop. This ramp is lifted to a warm graphite, with
        // dividers and hover fills kept faint so the panel has almost no edges of
        // its own. Text stays semantic in both, so contrast tracks the system.
        let background: Color
        let surface: Color
        let elevated: Color
        let divider: Color
        let rowHighlight: Color
        let chromeFill: Color
        let rowSelected: Color
        let fieldFill: Color
        let selectedFill: Color
        let controlStroke: Color
        switch scheme {
        case .light:
            background = Color(nsColor: .windowBackgroundColor)
            surface = Color(nsColor: .controlBackgroundColor)
            elevated = Color(nsColor: .quaternaryLabelColor).opacity(0.5)
            divider = Color(nsColor: .separatorColor)
            rowHighlight = Color.black.opacity(0.05)
            chromeFill = .clear
            rowSelected = Color.black.opacity(0.08)
            // One step stronger than the first pass (quaternary / tertiary),
            // which washed out on the menu material.
            fieldFill = Color(nsColor: .secondarySystemFill)
            selectedFill = Color(nsColor: .systemFill)
            controlStroke = Color(nsColor: .tertiaryLabelColor).opacity(0.55)
        case .dark:
            fallthrough
        @unknown default:
            background = Color(hex: 0x2B2B30)
            surface = Color(hex: 0x323238)
            elevated = Color(hex: 0x3D3D45)
            divider = Color.white.opacity(0.07)
            rowHighlight = Color.white.opacity(0.06)
            chromeFill = forGlass ? .clear : surface
            rowSelected = Color.white.opacity(0.09)
            // On Glass the solid graphite track read as a dark slab on top of
            // the glass (2026-09-26): the switch and search field get a
            // faint white tint instead, so the glass shows through them.
            fieldFill = forGlass ? Color.white.opacity(0.08) : surface
            selectedFill = forGlass ? Color.white.opacity(0.16) : elevated
            controlStroke = Color.white.opacity(0.10)
        }

        return ThemeColors(
            background: background,
            elevated: elevated,
            divider: divider,
            textPrimary: Color(nsColor: .labelColor),
            textSecondary: Color(nsColor: .secondaryLabelColor),
            textTertiary: Color(nsColor: .tertiaryLabelColor),
            statusHealthy: statusHealthy,
            statusDegraded: statusDegraded,
            statusBroken: statusBroken,
            rowHighlight: rowHighlight,
            chromeFill: chromeFill,
            rowSelected: rowSelected,
            fieldFill: fieldFill,
            selectedFill: selectedFill,
            controlStroke: controlStroke
        )
    }
}

enum Theme {
    static let mono = Font.system(size: 11, weight: .regular, design: .monospaced)
    /// Row text uses the **menu font**, not the generic system font — it's what
    /// AppKit menus beside us draw with, and the mismatch was a big part of why
    /// the panel read as "not quite a macOS menu". There is deliberately **no
    /// semibold variant**: system menus set item titles in regular, and bold rows
    /// were a large part of why the panel read as a document popup.
    static let body = Font(NSFont.menuFont(ofSize: 13))
    static let caption = Font(NSFont.menuFont(ofSize: 11))
    /// Counts and other digits, so they don't jitter as values change.
    static let numeric = Font.system(size: 11, weight: .medium, design: .rounded).monospacedDigit()

    /// Claude orange for the "Copied" state of Copy for Claude (round 9).
    /// Brand #D97757 gives white text only 3.1:1, so this is the same hue and
    /// chroma (OKLCH) with the lightness lowered until white reads 4.5:1.
    static let claudeOrangeHex: UInt32 = 0xBA5B3C
    static let claudeOrange = Color(hex: claudeOrangeHex)
}

/// Applies the chosen appearance to mcpock's own windows (panel + settings) —
/// and ONLY those. Never force `NSApp.appearance` or the status-item window:
/// that freezes the menu-bar icon in the theme's color instead of the system's
/// (a Light theme on a dark menu bar rendered the icon black the moment the
/// panel first opened). The icon always follows the system menu bar.
@MainActor
enum AppearanceApplier {
    static func apply(_ theme: AppTheme) {
        NSApp.appearance = nil
        for window in NSApp.windows where shouldStamp(windowClassName: window.className) {
            window.appearance = theme.nsAppearance
        }
    }

    /// Every app window except the status item's own window (the menu-bar icon).
    nonisolated static func shouldStamp(windowClassName: String) -> Bool {
        !windowClassName.contains("NSStatusBarWindow")
    }
}

extension View {
    /// Force the chosen color scheme (SwiftUI + AppKit). Palette colors travel as a
    /// plain `ThemeColors` value passed to child views — no environment indirection.
    func applyAppTheme(_ theme: AppTheme, systemFallback: ColorScheme) -> some View {
        self
            .preferredColorScheme(theme.preferredColorScheme)
            .onAppear { AppearanceApplier.apply(theme) }
            .onChange(of: theme) { _, newValue in
                AppearanceApplier.apply(newValue)
            }
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}
