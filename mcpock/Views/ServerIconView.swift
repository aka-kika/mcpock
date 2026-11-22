import SwiftUI

/// A server's mono icon, and on it the server's state (premium look, 22 Nov,
/// Kika's pick "the icon carries the state"): a fine server shows the icon
/// alone; any other state is a small `HealthMark` on the icon's corner, in a
/// hole cut through the glyph so it reads on any backdrop (glass included).
/// A server with no icon of its own shows the menu bar's mcpock glyph.
struct ServerIconView: View {
    let icon: ServerIcon
    let theme: ThemeColors
    /// The state to badge; nil for a fine server (no badge at all).
    var badge: HealthState? = nil
    /// Being re-checked on its own: the badge is the spinning arc.
    var checking = false
    /// The accessibility word for the badge ("Needs sign-in").
    var word: String? = nil
    var size: CGFloat = 18

    /// The fallback: the menu bar's own glyph (`StatusIconView`), the three
    /// stacked server units. Drawn for an 18 pt box, so it fills the frame.
    static let fallbackAsset = StatusIconView.glyphAsset
    /// The badge's centre, from the icon's bottom right corner.
    private static let badgeOffset = CGSize(width: 4, height: 3)
    private static let cutout: CGFloat = 12

    private var showsBadge: Bool { badge != nil || checking }

    /// What a row's icon wears: nothing while fine, else the row's mark.
    static func badgeState(for state: HealthState) -> HealthState? {
        state == .healthy ? nil : state
    }

    var body: some View {
        glyph
            .frame(width: size, height: size)
            // The hole for the badge: an inverted mask, so whatever is behind
            // the row (glass included) shows through, not a painted disc.
            .mask {
                ZStack(alignment: .bottomTrailing) {
                    Rectangle()
                    if showsBadge {
                        Circle()
                            .frame(width: Self.cutout, height: Self.cutout)
                            .offset(x: Self.badgeOffset.width + 1, y: Self.badgeOffset.height + 1)
                            .blendMode(.destinationOut)
                    }
                }
                .compositingGroup()
            }
            .overlay(alignment: .bottomTrailing) {
                if showsBadge {
                    HealthMark(state: badge ?? .unknown, theme: theme, checking: checking, word: word)
                        .offset(Self.badgeOffset)
                }
            }
            .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var glyph: some View {
        switch icon {
        case .asset(let name):
            Image(name)
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size * 0.84, height: size * 0.84)
                .foregroundStyle(theme.textSecondary)
                .accessibilityHidden(true)
        case .file(let path):
            if let image = OwnIconCache.image(path) {
                Image(nsImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: size * 0.84, height: size * 0.84)
                    .foregroundStyle(theme.textSecondary)
                    .accessibilityHidden(true)
            } else {
                fallbackGlyph
            }
        case .symbol(let name):
            symbol(name)
        case .fallback:
            fallbackGlyph
        }
    }

    private var fallbackGlyph: some View {
        Image(Self.fallbackAsset)
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(theme.textSecondary)
            .accessibilityHidden(true)
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: size * 0.72, weight: .regular))
            .foregroundStyle(theme.textSecondary)
            .accessibilityHidden(true)
    }
}

/// Her own icon files (`ServerIcons.userDirectory`), read once per file and
/// change date: a row is drawn many times, the file is small.
@MainActor
enum OwnIconCache {
    private static var images: [String: (stamp: Date?, image: NSImage?)] = [:]
    /// Bigger than this and the file is not a row icon.
    static let maxBytes = 2 * 1024 * 1024

    static func image(_ path: String) -> NSImage? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let stamp = attributes?[.modificationDate] as? Date
        if let cached = images[path], cached.stamp == stamp { return cached.image }
        var image: NSImage?
        if let size = (attributes?[.size] as? NSNumber)?.intValue, size <= maxBytes {
            image = NSImage(contentsOfFile: path)
            image?.isTemplate = true
        }
        if images.count > 200 { images.removeAll() }
        images[path] = (stamp, image)
        return image
    }
}
