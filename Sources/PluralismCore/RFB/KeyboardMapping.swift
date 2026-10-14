import Foundation

/// Physische Mac-Tastenposition (virtueller Keycode aus NSEvent.keyCode) zu
/// PC-Scancode (XT, Satz 1). QEMU nimmt den Scancode über die RFB-Erweiterung entgegen.
/// Weil Positionen statt Zeichen übertragen werden, gilt im Gast dessen eigenes
/// Tastaturlayout (z. B. Deutsch), genau wie bei einer echten PC-Tastatur.
///
/// Kodierung laut rfbproto: einbytige Scancodes unverändert, Codes mit Präfix 0xE0
/// als (0x80 | zweites Byte).
public enum KeyboardMapping {
    /// Bauart der Mac-Tastatur. ISO-Tastaturen (z. B. Deutsch) melden die Taste links oben (^)
    /// und die Taste neben dem linken Shift (<) mit vertauschten Keycodes.
    public enum PhysicalLayout: String, Codable, CaseIterable, Sendable {
        case iso
        case ansi
    }

    public static func scancode(forMacKeyCode keyCode: UInt16, layout: PhysicalLayout) -> UInt32? {
        if layout == .iso {
            if keyCode == 0x0A { return 0x29 }   // Taste links oben (^ / °)
            if keyCode == 0x32 { return 0x56 }   // Taste neben Shift links (< / >)
        }
        return table[keyCode]
    }

    /// Mac-Keycodes (Carbon kVK_*) zu XT-Scancodes.
    public static let table: [UInt16: UInt32] = [
        // Buchstaben
        0x00: 0x1E, // A
        0x0B: 0x30, // B
        0x08: 0x2E, // C
        0x02: 0x20, // D
        0x0E: 0x12, // E
        0x03: 0x21, // F
        0x05: 0x22, // G
        0x04: 0x23, // H
        0x22: 0x17, // I
        0x26: 0x24, // J
        0x28: 0x25, // K
        0x25: 0x26, // L
        0x2E: 0x32, // M
        0x2D: 0x31, // N
        0x1F: 0x18, // O
        0x23: 0x19, // P
        0x0C: 0x10, // Q
        0x0F: 0x13, // R
        0x01: 0x1F, // S
        0x11: 0x14, // T
        0x20: 0x16, // U
        0x09: 0x2F, // V
        0x0D: 0x11, // W
        0x07: 0x2D, // X
        0x10: 0x15, // Y (US-Position; im deutschen Layout Z)
        0x06: 0x2C, // Z (US-Position; im deutschen Layout Y)
        // Ziffernreihe
        0x12: 0x02, // 1
        0x13: 0x03, // 2
        0x14: 0x04, // 3
        0x15: 0x05, // 4
        0x17: 0x06, // 5
        0x16: 0x07, // 6
        0x1A: 0x08, // 7
        0x1C: 0x09, // 8
        0x19: 0x0A, // 9
        0x1D: 0x0B, // 0
        0x1B: 0x0C, // - (ß)
        0x18: 0x0D, // = (´)
        // Satzzeichen
        0x21: 0x1A, // [ (Ü)
        0x1E: 0x1B, // ] (+)
        0x2A: 0x2B, // \ (#)
        0x29: 0x27, // ; (Ö)
        0x27: 0x28, // ' (Ä)
        0x2B: 0x33, // ,
        0x2F: 0x34, // .
        0x2C: 0x35, // / (-)
        0x32: 0x29, // ` (ANSI links oben)
        0x0A: 0x56, // § (ISO-Zusatztaste, ANSI-Fallback)
        // Steuertasten
        0x24: 0x1C, // Return
        0x30: 0x0F, // Tab
        0x31: 0x39, // Leertaste
        0x33: 0x0E, // Rückschritt
        0x35: 0x01, // Escape
        0x39: 0x3A, // Feststelltaste
        0x75: 0xD3, // Entfernen (E0 53)
        0x72: 0xD2, // Hilfe/Einfügen (E0 52)
        0x73: 0xC7, // Pos1 (E0 47)
        0x77: 0xCF, // Ende (E0 4F)
        0x74: 0xC9, // Bild auf (E0 49)
        0x79: 0xD1, // Bild ab (E0 51)
        0x7B: 0xCB, // Pfeil links (E0 4B)
        0x7C: 0xCD, // Pfeil rechts (E0 4D)
        0x7D: 0xD0, // Pfeil runter (E0 50)
        0x7E: 0xC8, // Pfeil hoch (E0 48)
        // Modifikatoren
        0x38: 0x2A, // Shift links
        0x3C: 0x36, // Shift rechts
        0x3B: 0x1D, // Control links
        0x3E: 0x9D, // Control rechts (E0 1D)
        0x3A: 0x38, // Option links = Alt
        0x3D: 0xB8, // Option rechts = AltGr (E0 38)
        0x37: 0xDB, // Command links = Windows-Taste (E0 5B)
        0x36: 0xDC, // Command rechts = Windows-Taste rechts (E0 5C)
        // Funktionstasten
        0x7A: 0x3B, // F1
        0x78: 0x3C, // F2
        0x63: 0x3D, // F3
        0x76: 0x3E, // F4
        0x60: 0x3F, // F5
        0x61: 0x40, // F6
        0x62: 0x41, // F7
        0x64: 0x42, // F8
        0x65: 0x43, // F9
        0x6D: 0x44, // F10
        0x67: 0x57, // F11
        0x6F: 0x58, // F12
        0x69: 0xB7, // F13 = Druck (E0 37)
        0x6B: 0x46, // F14 = Rollen
        // Ziffernblock
        0x52: 0x52, // 0
        0x53: 0x4F, // 1
        0x54: 0x50, // 2
        0x55: 0x51, // 3
        0x56: 0x4B, // 4
        0x57: 0x4C, // 5
        0x58: 0x4D, // 6
        0x59: 0x47, // 7
        0x5B: 0x48, // 8
        0x5C: 0x49, // 9
        0x41: 0x53, // ,
        0x43: 0x37, // *
        0x45: 0x4E, // +
        0x4E: 0x4A, // -
        0x4B: 0xB5, // / (E0 35)
        0x4C: 0x9C, // Enter (E0 1C)
        0x47: 0x45, // Clear = Num
        // Medientasten
        0x4A: 0xA0, // Stumm (E0 20)
        0x49: 0xAE, // Leiser (E0 2E)
        0x48: 0xB0  // Lauter (E0 30)
    ]

    /// Modifikator-Keycodes, die über flagsChanged statt keyDown/keyUp kommen.
    public static let modifierKeyCodes: Set<UInt16> = [0x38, 0x3C, 0x3B, 0x3E, 0x3A, 0x3D, 0x37, 0x36, 0x39]

    /// X11-Keysym für ein getipptes Zeichen. Nur nötig, wenn der Server keine Scancodes
    /// versteht; QEMU versteht sie immer.
    public static func keysym(for character: Character) -> UInt32 {
        guard let scalar = character.unicodeScalars.first else { return 0 }
        let value = scalar.value
        if (0x20...0x7E).contains(value) || (0xA0...0xFF).contains(value) {
            return value
        }
        return 0x0100_0000 | value
    }

    /// Keysyms für Steuertasten (Fallback ohne Scancodes).
    public static let specialKeysyms: [UInt16: UInt32] = [
        0x24: 0xFF0D, // Return
        0x30: 0xFF09, // Tab
        0x33: 0xFF08, // BackSpace
        0x35: 0xFF1B, // Escape
        0x75: 0xFFFF, // Delete
        0x73: 0xFF50, // Home
        0x77: 0xFF57, // End
        0x74: 0xFF55, // Page_Up
        0x79: 0xFF56, // Page_Down
        0x7B: 0xFF51, // Left
        0x7E: 0xFF52, // Up
        0x7C: 0xFF53, // Right
        0x7D: 0xFF54, // Down
        0x38: 0xFFE1, // Shift_L
        0x3C: 0xFFE2, // Shift_R
        0x3B: 0xFFE3, // Control_L
        0x3E: 0xFFE4, // Control_R
        0x3A: 0xFFE9, // Alt_L
        0x3D: 0xFE03, // ISO_Level3_Shift (AltGr)
        0x37: 0xFFEB, // Super_L
        0x36: 0xFFEC, // Super_R
        0x39: 0xFFE5, // Caps_Lock
        0x7A: 0xFFBE, 0x78: 0xFFBF, 0x63: 0xFFC0, 0x76: 0xFFC1, 0x60: 0xFFC2, 0x61: 0xFFC3,
        0x62: 0xFFC4, 0x64: 0xFFC5, 0x65: 0xFFC6, 0x6D: 0xFFC7, 0x67: 0xFFC8, 0x6F: 0xFFC9
    ]
}
