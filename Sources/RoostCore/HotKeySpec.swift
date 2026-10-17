import Foundation

/// A system-wide shortcut a plugin item asks for, written the way people say it:
/// `"ctrl+opt+cmd+g"`, `"cmd+shift+9"`, `"ctrl+opt+left"`. Parsed here, without AppKit,
/// so it can be tested; the app registers it with Carbon.
public struct HotKeySpec: Hashable {
    public let keyCode: UInt32
    /// Carbon modifier flags: cmdKey, shiftKey, optionKey, controlKey.
    public let modifiers: UInt32
    /// The key's character for NSMenuItem.keyEquivalent ("g", "9", or a function-key character).
    public let keyEquivalent: String
    /// How the menu shows it: ⌃⌥⌘G.
    public let display: String

    public static let command: UInt32 = 1 << 8
    public static let shift: UInt32 = 1 << 9
    public static let option: UInt32 = 1 << 11
    public static let control: UInt32 = 1 << 12

    public init?(_ text: String) {
        let parts = text.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let key = parts.last, !key.isEmpty else { return nil }
        var modifiers: UInt32 = 0
        for name in parts.dropLast() {
            switch name {
            case "cmd", "command", "⌘": modifiers |= Self.command
            case "shift", "⇧": modifiers |= Self.shift
            case "opt", "option", "alt", "⌥": modifiers |= Self.option
            case "ctrl", "control", "⌃": modifiers |= Self.control
            default: return nil
            }
        }
        // A bare letter would fire whenever anyone typed it.
        guard modifiers != 0, let code = Self.keyCodes[key] else { return nil }
        self.keyCode = code
        self.modifiers = modifiers
        self.keyEquivalent = Self.equivalents[key] ?? key
        let symbols = [(Self.control, "⌃"), (Self.option, "⌥"), (Self.shift, "⇧"), (Self.command, "⌘")]
        self.display = symbols.filter { modifiers & $0.0 != 0 }.map(\.1).joined() + (Self.names[key] ?? key.uppercased())
    }

    /// macOS virtual key codes (kVK_ANSI_* and friends): fixed by the hardware layout, not the keyboard language.
    static let keyCodes: [String: UInt32] = {
        var codes: [String: UInt32] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
            "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
            "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
            "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
            ".": 47, "`": 50, "return": 36, "tab": 48, "space": 49, "escape": 53,
            "left": 123, "right": 124, "down": 125, "up": 126,
        ]
        for (number, code) in [(1, 122), (2, 120), (3, 99), (4, 118), (5, 96), (6, 97), (7, 98), (8, 100),
                               (9, 101), (10, 109), (11, 103), (12, 111)] {
            codes["f\(number)"] = UInt32(code)
        }
        return codes
    }()

    static let names: [String: String] = [
        "return": "↩", "tab": "⇥", "space": "Space", "escape": "⎋", "left": "←", "right": "→", "down": "↓", "up": "↑",
    ]

    /// NSMenuItem wants the character a key produces; these are AppKit's function-key characters.
    static let equivalents: [String: String] = {
        var map: [String: String] = ["return": "\r", "tab": "\t", "space": " ", "escape": "\u{1b}",
                                     "left": "\u{F702}", "right": "\u{F703}", "down": "\u{F701}", "up": "\u{F700}"]
        for number in 1...12 { map["f\(number)"] = String(UnicodeScalar(0xF703 + number)!) }
        return map
    }()
}
