import AppKit
import SwiftUI

/// The one backdrop behind mcpock's surfaces: the menu-bar panel now, and in v1.5
/// the detail card and the Settings window too (2026-09-24: every view must
/// look right in both looks, and users switch between them).
///
/// - **Dark = soft dark, always.** The solid `#2B2B30` background token. No
///   translucency in dark.
/// - **Light = RepoBar's texture.** The native `.menu` material, blending behind
///   the window and always active: frosted and a little translucent, the look of
///   a real `NSMenu`.
/// - **Glass (1.8) = Apple's own Liquid Glass**, `isGlass: true`, ignoring
///   `scheme` entirely: `.glassEffect(.regular, in: …)`, never a hand-made
///   blur. macOS 26.1+ lets the person pick System Settings > Appearance >
///   Liquid Glass: Clear or Tinted, and Accessibility > Reduce Transparency;
///   the system glass follows both on its own, so nothing here sets a
///   clarity value.
///
/// One treatment, no tint split. The translucent panel shipped once (44f2e73) with
/// a 0.55 tint on the list and 0.6 on the footer, and was reverted the same
/// evening because the two read as different themes. Light is the material alone;
/// bars on top of it use `ThemeColors.chromeFill` (clear in light, and in Glass —
/// see `ThemeColors.resolve(_:forGlass:)`).
///
/// Use it as `.background { PanelBackdrop(scheme: …) }` on the window's root view.
struct PanelBackdrop: View {
    /// The resolved look (`AppTheme.resolvedScheme(systemFallback:)`), so System
    /// follows macOS and picks one of the two. Ignored when `isGlass` is true.
    let scheme: ColorScheme
    /// The Glass theme: paint Liquid Glass instead of `scheme`'s dark/light
    /// treatment. A separate flag rather than a third `scheme` case, because
    /// `scheme` is a plain `ColorScheme` from SwiftUI's environment and Glass
    /// isn't one — it still tracks light/dark underneath, glass is a surface
    /// choice layered on top of that.
    var isGlass: Bool = false
    /// Only the detail card is rounded; the menu-bar panel and Settings fill
    /// the window's own edges (a system-drawn shape already), so this stays 0
    /// there. Ignored unless `isGlass`.
    var cornerRadius: CGFloat = 0
    /// Clear the host window's opaque backing so the material — menu or glass
    /// — can see through it. Right for the MenuBarExtra window and a
    /// borderless card panel; a titled window (Settings) may want to decide
    /// this itself.
    var clearsHostWindow: Bool = true

    var body: some View {
        if isGlass {
            GlassMaterialView(cornerRadius: cornerRadius, clearsHostWindow: clearsHostWindow)
        } else if scheme == .dark {
            ThemeColors.resolve(.dark).background
        } else {
            MenuMaterialView(clearsHostWindow: clearsHostWindow)
        }
    }
}

/// `NSVisualEffectView` with the system menu material. The MenuBarExtra window
/// draws an opaque background by default, so `.behindWindow` blending would only
/// blend against that backing and nothing would show through; the view clears its
/// window (`isOpaque = false`, clear background) when it is attached. This is the
/// working part of 44f2e73, kept.
private struct MenuMaterialView: NSViewRepresentable {
    let clearsHostWindow: Bool

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = WindowClearingVisualEffectView()
        view.clearsHostWindow = clearsHostWindow
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private final class WindowClearingVisualEffectView: NSVisualEffectView {
    var clearsHostWindow = true

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard clearsHostWindow, let window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
    }
}

/// The Glass theme's surface: Apple's own Liquid Glass, not a hand-made blur.
/// `GlassEffectContainer` wraps the one shape per Apple's guidance for
/// multiple glass elements (batches the blend and specular highlight into one
/// pass) — there's only one shape here, but it costs nothing and keeps the
/// pattern ready if a second glass element joins it later.
///
/// The glass sits on an otherwise-empty, clear rectangle **behind** the real
/// content (the panel/card content is layered on top in a `ZStack` or another
/// `.background`, never wrapped in `.glassEffect` itself): content placed
/// inside `.glassEffect` gets a vibrancy pass along with it, which washes out
/// secondary text — most visible in Light. This is the same reason Syrtis's
/// `GlassPanelSurface` keeps glass and content apart.
private struct GlassMaterialView: View {
    let cornerRadius: CGFloat
    let clearsHostWindow: Bool

    var body: some View {
        GlassEffectContainer {
            Rectangle()
                .fill(.clear)
                .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        }
        .background {
            if clearsHostWindow {
                HostWindowClearer()
            }
        }
    }
}

/// Clears the host window's opaque backing (`isOpaque = false`, a clear
/// background) with no material of its own — `GlassMaterialView`'s
/// `.glassEffect` above does the actual rendering, and without this the
/// window's own opaque backing paints behind it and the glass has nothing to
/// show through. Same fix as `WindowClearingVisualEffectView`, factored out
/// because the glass surface isn't an `NSVisualEffectView` to hang the
/// clearing logic off of.
private struct HostWindowClearer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ClearingProbeView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class ClearingProbeView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
    }
}
