import AppKit
import Carbon.HIToolbox

/// The panel's keyboard shortcut (1.12, her own pick in Settings > General;
/// ⌃⌥M before and by default). Carbon key code and modifiers, as
/// `RegisterEventHotKey` takes them, plus the key as she saw it.
struct PanelShortcut: Equatable, Codable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32
    /// The key's name: "M", "F5", "Space".
    var key: String

    static let standard = PanelShortcut(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(controlKey | optionKey), key: "M")

    /// "⌃⌥M", in the order macOS menus write them.
    var displayText: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "\u{2303}" }
        if modifiers & UInt32(optionKey) != 0 { text += "\u{2325}" }
        if modifiers & UInt32(shiftKey) != 0 { text += "\u{21E7}" }
        if modifiers & UInt32(cmdKey) != 0 { text += "\u{2318}" }
        return text + key
    }

    /// "Control-Option-M", for help text and VoiceOver.
    var spokenText: String {
        var words: [String] = []
        if modifiers & UInt32(controlKey) != 0 { words.append("Control") }
        if modifiers & UInt32(optionKey) != 0 { words.append("Option") }
        if modifiers & UInt32(shiftKey) != 0 { words.append("Shift") }
        if modifiers & UInt32(cmdKey) != 0 { words.append("Command") }
        return (words + [key]).joined(separator: "-")
    }

    /// A key press as a shortcut, or nil when it can't be one: it needs
    /// Control, Option or Command (Shift alone would take a letter from
    /// every app), and a key with a name.
    static func from(keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String?) -> PanelShortcut? {
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        guard modifiers & UInt32(controlKey | optionKey | cmdKey) != 0,
              let key = keyName(keyCode: Int(keyCode), characters: characters) else { return nil }
        return PanelShortcut(keyCode: UInt32(keyCode), modifiers: modifiers, key: key)
    }

    private static let namedKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "\u{21A9}", kVK_Tab: "\u{21E5}", kVK_Delete: "\u{232B}",
        kVK_LeftArrow: "\u{2190}", kVK_RightArrow: "\u{2192}", kVK_UpArrow: "\u{2191}", kVK_DownArrow: "\u{2193}",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    /// Escape is never a shortcut: it cancels the recording.
    static func keyName(keyCode: Int, characters: String?) -> String? {
        if keyCode == kVK_Escape { return nil }
        if let named = namedKeys[keyCode] { return named }
        guard let character = characters?.uppercased(), character.count == 1,
              let scalar = character.unicodeScalars.first,
              !CharacterSet.controlCharacters.contains(scalar),
              !(0xF700...0xF8FF).contains(scalar.value) else { return nil }
        return character
    }
}

extension AppPreferences {
    /// Settings > General: the shortcut that opens the panel (1.12).
    static let panelShortcutKey = "panelShortcut"

    static func loadPanelShortcut(from defaults: UserDefaults = store) -> PanelShortcut {
        guard let data = defaults.data(forKey: panelShortcutKey),
              let shortcut = try? JSONDecoder().decode(PanelShortcut.self, from: data) else { return .standard }
        return shortcut
    }

    static func savePanelShortcut(_ shortcut: PanelShortcut, to defaults: UserDefaults = store) {
        if shortcut == .standard {
            defaults.removeObject(forKey: panelShortcutKey)
        } else if let data = try? JSONEncoder().encode(shortcut) {
            defaults.set(data, forKey: panelShortcutKey)
        }
    }
}
