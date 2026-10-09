import SwiftUI
import AppKit

/// What a config path can do (round 8): show it in Finder, copy its path, or,
/// last and behind a confirmation, open it in its default app. mcpock never
/// writes the file. Opening a config is risky for someone who doesn't
/// know what they're doing (one accidental save can break an agent), so it is
/// never one easy click: no buttons, no double-click, only the menu item.
@MainActor
enum ConfigFileActions {
    /// Asks first (the menu item's "…"), then opens the file in its default app.
    static func confirmAndOpen(_ path: String) {
        guard confirmOpen(path) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    static func copy(_ path: String) {
        PanelState.copyToPasteboard(path)
    }

    static func showInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// "Open claude_desktop_config.json?" with Cancel as the default button, so
    /// Return or Escape never opens it by accident.
    private static func confirmOpen(_ path: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = MenuText.openConfigQuestion(path: path)
        alert.informativeText = MenuText.openConfigWarning
        let cancel = alert.addButton(withTitle: "Cancel")
        let open = alert.addButton(withTitle: MenuText.openConfigConfirm)
        cancel.keyEquivalent = "\r"
        open.keyEquivalent = ""
        return alert.runModal() == .alertSecondButtonReturn
    }
}

/// The one right-click menu every config path gets (round 8): Show in Finder,
/// Copy Path, a separator, then Open Config… last. `openTitle` nil leaves Open
/// out (the Connect tab's helper, which is a program, not a file to edit);
/// `MenuText.openFileTitle` names a file that isn't a config (the status file).
struct ConfigPathMenuItems: View {
    let path: String
    var openTitle: String? = MenuText.openConfigTitle

    var body: some View {
        Button(MenuText.showInFinderTitle) { ConfigFileActions.showInFinder(path) }
        Button(MenuText.copyPathTitle) { ConfigFileActions.copy(path) }
        if let openTitle {
            Divider()
            Button(openTitle) { ConfigFileActions.confirmAndOpen(path) }
        }
    }
}

extension View {
    /// Right-click for Show in Finder / Copy Path / Open Config…, with the path
    /// and the hint in the tooltip. No double-click (round 8). `help` goes first
    /// in the tooltip (the full path).
    func configPathActions(_ path: String, help: String? = nil,
                           openTitle: String? = MenuText.openConfigTitle) -> some View {
        self
            .contentShape(Rectangle())
            .contextMenu { ConfigPathMenuItems(path: path, openTitle: openTitle) }
            .help(MenuText.configPathHelp(path: help ?? path))
    }
}

/// One path on its own line (round 7, shared since round 8): Settings > Agents,
/// Settings > General's status file. The path alone, no glyph; right-click for
/// the menu; a faint hover fill says the row does something.
struct ConfigPathRow: View {
    let path: String
    let theme: ThemeColors
    var openTitle: String? = MenuText.openConfigTitle
    var font: Font = Theme.mono
    @State private var isHovered = false

    var body: some View {
        Text(CardText.shortPath(path))
            .font(font)
            .foregroundStyle(theme.textSecondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isHovered ? theme.rowHighlight : .clear)
            }
            .onHover { isHovered = $0 }
            .configPathActions(path, openTitle: openTitle)
            .accessibilityAddTraits(.isButton)
            .configPathAccessibilityActions(path, openTitle: openTitle)
    }
}

extension View {
    /// The same three actions for VoiceOver, in the menu's order.
    @ViewBuilder
    func configPathAccessibilityActions(_ path: String, openTitle: String? = MenuText.openConfigTitle) -> some View {
        let base = self
            .accessibilityAction(named: MenuText.showInFinderTitle) { ConfigFileActions.showInFinder(path) }
            .accessibilityAction(named: MenuText.copyPathTitle) { ConfigFileActions.copy(path) }
        if let openTitle {
            base.accessibilityAction(named: openTitle) { ConfigFileActions.confirmAndOpen(path) }
        } else {
            base
        }
    }
}
