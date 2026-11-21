import Foundation

/// **The keys of the take-over card, as the protocol names them** (X's keysyms, RFC 6143 7.5.4). A key that writes a
/// character goes as that character's keysym, so a Spanish ñ or an accent that the Mac composed arrives as it is; the
/// other keys go by the Mac's own key code. Esc and every ⌘ shortcut stay in the app (the design's section 3.2): this
/// table has neither.
public enum RFBKeys {
    public static let shift: UInt32 = 0xFFE1
    public static let control: UInt32 = 0xFFE3
    /// The Mac's Option key: Alt, which a Mac's screen and X both read as Option or Alt.
    public static let option: UInt32 = 0xFFE9

    /// The keysym of a Mac key that writes no character (its virtual key code, `kVK_…`), or nil.
    public static func special(macKeyCode code: UInt16) -> UInt32? {
        switch code {
        case 0x24: 0xFF0D       // Return
        case 0x4C: 0xFF8D       // the keypad's Enter
        case 0x30: 0xFF09       // Tab
        case 0x33: 0xFF08       // Delete, which deletes back: BackSpace
        case 0x75: 0xFFFF       // the forward Delete
        case 0x73: 0xFF50       // Home
        case 0x77: 0xFF57       // End
        case 0x74: 0xFF55       // Page Up
        case 0x79: 0xFF56       // Page Down
        case 0x7B: 0xFF51       // ←
        case 0x7E: 0xFF52       // ↑
        case 0x7C: 0xFF53       // →
        case 0x7D: 0xFF54       // ↓
        case 0x7A: 0xFFBE       // F1
        case 0x78: 0xFFBF       // F2
        case 0x63: 0xFFC0       // F3
        case 0x76: 0xFFC1       // F4
        case 0x60: 0xFFC2       // F5
        case 0x61: 0xFFC3       // F6
        case 0x62: 0xFFC4       // F7
        case 0x64: 0xFFC5       // F8
        case 0x65: 0xFFC6       // F9
        case 0x6D: 0xFFC7       // F10
        case 0x67: 0xFFC8       // F11
        case 0x6F: 0xFFC9       // F12
        default: nil
        }
    }

    /// The keysym of one character: Latin-1 as itself, every other one as X's Unicode keysym; nil for a control
    /// character (those keys go by `special`).
    public static func keysym(for scalar: Unicode.Scalar) -> UInt32? {
        let value = scalar.value
        switch value {
        case 0x20...0x7E, 0xA0...0xFF: return value
        case 0..<0x20, 0x7F...0x9F: return nil
        case 0xF700...0xF8FF: return nil        // the Mac's own codes of function keys, which `special` names
        default: return 0x0100_0000 | value
        }
    }
}
