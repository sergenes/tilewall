import Foundation

/// A global hotkey: a virtual key code plus Carbon modifier flags.
public struct KeyCombo: Equatable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    /// The key as written in the config, lowercased: "t", "tab", "left".
    public var key: String

    /// Human readable form with the standard macOS modifier symbols, for example "⌃⌥T".
    public var display: String {
        var text = ""
        if modifiers & KeyCombo.control != 0 { text += "⌃" }
        if modifiers & KeyCombo.option != 0 { text += "⌥" }
        if modifiers & KeyCombo.shift != 0 { text += "⇧" }
        if modifiers & KeyCombo.cmd != 0 { text += "⌘" }
        let names = ["return": "↩", "tab": "⇥", "space": "Space", "escape": "⎋", "left": "←", "right": "→", "down": "↓", "up": "↑"]
        return text + (names[key] ?? key.uppercased())
    }

    public static let cmd: UInt32 = 1 << 8
    public static let shift: UInt32 = 1 << 9
    public static let option: UInt32 = 1 << 11
    public static let control: UInt32 = 1 << 12

    static let keyCodes: [String: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
        "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21,
        "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31,
        "u": 32, "[": 33, "i": 34, "p": 35, "return": 36, "l": 37, "j": 38, "'": 39, "k": 40,
        ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49,
        "`": 50, "escape": 53, "left": 123, "right": 124, "down": 125, "up": 126,
    ]

    /// Parses strings like "ctrl+alt+m". Returns nil when the key or a modifier is unknown, or no modifier is given.
    public init?(_ text: String) {
        var mods: UInt32 = 0
        var key: UInt32?
        var name = ""
        for raw in text.lowercased().split(separator: "+", omittingEmptySubsequences: false) {
            let part = raw.trimmingCharacters(in: .whitespaces)
            switch part {
            case "cmd", "command": mods |= KeyCombo.cmd
            case "shift": mods |= KeyCombo.shift
            case "alt", "opt", "option": mods |= KeyCombo.option
            case "ctrl", "control": mods |= KeyCombo.control
            default:
                guard key == nil, let code = KeyCombo.keyCodes[part] else { return nil }
                key = code
                name = part
            }
        }
        guard let key, mods != 0 else { return nil }
        keyCode = key
        self.key = name
        modifiers = mods
    }
}
