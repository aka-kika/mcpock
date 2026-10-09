import AppKit
import SwiftUI

/// `Servers | Agents`: two segments on a neutral track, the selected one on a
/// neutral fill. Its own small view rather than a system segmented picker, whose
/// selected segment takes the accent colour inside the panel.
struct PanelTabControl: View {
    @Binding var tab: PanelTab
    let theme: ThemeColors

    var body: some View {
        NeutralSegments(
            options: PanelTab.allCases.map { ($0, $0.title) },
            selection: $tab,
            theme: theme,
            accessibilityLabel: "Panel view"
        )
    }
}

/// A segmented control drawn with neutral fills only: a `fieldFill` track and
/// the selected segment on `selectedFill`, never the accent colour. The panel's
/// `Servers | Agents` switch and Preferences' `Pinned | Shown | Hidden` both use
/// it (a system segmented picker painted 40 rows of accent blue down the
/// Servers pane; the mockup has neutral segments).
struct NeutralSegments<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    let theme: ThemeColors
    var height: CGFloat = 24
    var fontSize: CGFloat = 12
    var accessibilityLabel = ""
    /// Round 8: one SF Symbol per option, shown instead of the title; the
    /// title becomes the segment's tooltip and accessibility label.
    var symbols: [String]? = nil
    /// The track behind the segments. nil is `fieldFill`, which in Dark is the
    /// panel surface and vanishes on a grouped form's section; the Settings
    /// forms pass `rowHighlight` (round 8).
    var trackFill: Color? = nil

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let (value, title) = options[index]
                let selected = value == selection
                Button {
                    selection = value
                } label: {
                    segmentLabel(index: index, title: title, selected: selected)
                        .foregroundStyle(selected ? theme.textPrimary : theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: height)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(theme.selectedFill)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(symbols == nil ? "" : title)
                .accessibilityLabel(title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(trackFill ?? theme.fieldFill)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }
}

extension NeutralSegments {
    @ViewBuilder
    fileprivate func segmentLabel(index: Int, title: String, selected: Bool) -> some View {
        if let symbols, symbols.indices.contains(index) {
            Image(systemName: symbols[index])
                .font(.system(size: fontSize, weight: selected ? .semibold : .regular))
                .accessibilityHidden(true)
        } else {
            Text(title)
                .font(.system(size: fontSize, weight: selected ? .medium : .regular))
                .lineLimit(1)
        }
    }
}

/// One footer glyph (round 2, like 1.4.1): attention, search, refresh, settings.
/// All share one size, weight and colour so the row reads as one set of
/// controls; the tap target is 24×24 around a 13pt symbol. `selected` puts the
/// neutral selected fill behind it (never the accent); `tint` overrides the
/// colour, which only the attention toggle uses, to signal quietly.
struct FooterGlyphButton: View {
    let systemImage: String
    let title: String
    let theme: ThemeColors
    var selected = false
    var tint: Color? = nil
    var spinning = false
    var disabled = false
    let action: () -> Void
    @State private var isHovered = false

    nonisolated static let size: CGFloat = 24

    var body: some View {
        Button(action: action) {
            SpinnableIcon(systemName: systemImage, spinning: spinning)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(tint ?? theme.textSecondary)
                .frame(width: Self.size, height: Self.size)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(background)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { isHovered = $0 }
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var background: Color {
        if selected { return theme.selectedFill }
        return isHovered && !disabled ? theme.rowHighlight : .clear
    }
}

/// A plain text button for the footer ("Undo hide").
struct FooterTextButton: View {
    let title: String
    let theme: ThemeColors
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.caption)
                .foregroundStyle(isHovered ? theme.textPrimary : theme.textSecondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

/// Small uppercase section header with its count on the right ("NEEDS YOU   3").
struct SectionHeader: View {
    let title: String
    let count: Int?
    let theme: ThemeColors

    var body: some View {
        HStack {
            Text(title.uppercased())
            Spacer()
            if let count {
                Text("\(count)").monospacedDigit()
            }
        }
        .font(.system(size: 10.5, weight: .semibold))
        .tracking(0.6)
        .foregroundStyle(theme.textTertiary)
    }
}

/// Hands the hosting view's window to `onWindow` once it is in one. The
/// MenuBarExtra window has no SwiftUI handle, and the keyboard handler and the
/// detail card both need it.
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ReaderView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ReaderView: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}

/// Scroll indicators for every scroll view mcpock draws (round 6): hidden while
/// Settings > General "Hide scroll bars" is on (the default), the system's own
/// behaviour when off. `.never`, not `.hidden`: `.hidden` still shows them on
/// macOS whenever a mouse is connected. Trackpad and wheel scrolling still work.
struct PanelScrollIndicators: ViewModifier {
    @AppStorage(AppPreferences.hideScrollBarsKey) private var hide = AppPreferences.defaultHideScrollBars

    func body(content: Content) -> some View {
        content.scrollIndicators(Self.visibility(hide: hide))
    }

    static func visibility(hide: Bool) -> ScrollIndicatorVisibility {
        hide ? .never : .automatic
    }
}

extension View {
    /// See `PanelScrollIndicators`.
    func panelScrollIndicators() -> some View {
        modifier(PanelScrollIndicators())
    }
}
