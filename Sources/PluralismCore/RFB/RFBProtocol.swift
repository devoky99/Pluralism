import Foundation

// RFB ("Remote Framebuffer", das Protokoll hinter VNC), Version 3.8.
// Pluralism verbindet sich damit über einen lokalen Unix-Socket mit dem VNC-Server, den
// QEMU für die VM bereitstellt, und zeigt das Bild im eigenen Fenster an.
// Spezifikation: RFC 6143 und die Community-Erweiterungen (rfbproto).

/// Quelle für Bytes (blockierend). In der App ein Socket, in Tests ein Puffer.
public protocol RFBByteSource: AnyObject {
    func read(exactly count: Int) throws -> [UInt8]
}

/// Ziel für Bytes. In der App ein Socket, in Tests ein Puffer.
public protocol RFBByteSink: AnyObject {
    func write(_ bytes: [UInt8]) throws
}

public enum RFBError: Error, LocalizedError, Equatable {
    case badProtocolVersion(String)
    case connectionRefused(String)
    case noSupportedSecurityType([UInt8])
    case securityFailed(String)
    case unsupportedEncoding(Int32)
    case unexpectedMessage(UInt8)
    case closed

    public var errorDescription: String? {
        switch self {
        case .badProtocolVersion(let v): return "Unbekannte VNC-Protokollversion: \(v)"
        case .connectionRefused(let reason): return "Der VNC-Server hat die Verbindung abgelehnt: \(reason)"
        case .noSupportedSecurityType(let types): return "Kein passendes VNC-Sicherheitsverfahren angeboten: \(types)"
        case .securityFailed(let reason): return "VNC-Anmeldung fehlgeschlagen: \(reason)"
        case .unsupportedEncoding(let e): return "Nicht unterstützte VNC-Kodierung: \(e)"
        case .unexpectedMessage(let t): return "Unerwartete VNC-Nachricht vom Typ \(t)"
        case .closed: return "Die VNC-Verbindung wurde geschlossen."
        }
    }
}

/// Pixelformat. Pluralism fordert 32 Bit pro Pixel, Little Endian, Rot bei Bit 16, Grün bei 8,
/// Blau bei 0. Im Speicher liegt das als B, G, R, X und passt direkt zu einem
/// CGImage mit `byteOrder32Little` und `noneSkipFirst`.
public struct RFBPixelFormat: Equatable, Sendable {
    public var bitsPerPixel: UInt8
    public var depth: UInt8
    public var bigEndian: Bool
    public var trueColor: Bool
    public var redMax: UInt16
    public var greenMax: UInt16
    public var blueMax: UInt16
    public var redShift: UInt8
    public var greenShift: UInt8
    public var blueShift: UInt8

    public static let bgrx32 = RFBPixelFormat(bitsPerPixel: 32, depth: 24, bigEndian: false, trueColor: true,
                                              redMax: 255, greenMax: 255, blueMax: 255,
                                              redShift: 16, greenShift: 8, blueShift: 0)

    public var bytesPerPixel: Int { Int(bitsPerPixel) / 8 }

    public func encoded() -> [UInt8] {
        var bytes: [UInt8] = [bitsPerPixel, depth]
        bytes.append(bigEndian ? 1 : 0)
        bytes.append(trueColor ? 1 : 0)
        bytes.append(contentsOf: RFBBytes.u16(redMax))
        bytes.append(contentsOf: RFBBytes.u16(greenMax))
        bytes.append(contentsOf: RFBBytes.u16(blueMax))
        bytes.append(contentsOf: [redShift, greenShift, blueShift, 0, 0, 0])
        return bytes
    }

    public static func decode(_ b: [UInt8]) -> RFBPixelFormat {
        RFBPixelFormat(bitsPerPixel: b[0], depth: b[1], bigEndian: b[2] != 0, trueColor: b[3] != 0,
                       redMax: RFBBytes.readU16(b, 4), greenMax: RFBBytes.readU16(b, 6), blueMax: RFBBytes.readU16(b, 8),
                       redShift: b[10], greenShift: b[11], blueShift: b[12])
    }
}

public enum RFBEncoding {
    public static let raw: Int32 = 0
    public static let copyRect: Int32 = 1
    public static let desktopSize: Int32 = -223
    public static let lastRect: Int32 = -224
    public static let qemuExtendedKeyEvent: Int32 = -258
}

public struct RFBServerInit: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var pixelFormat: RFBPixelFormat
    public var name: String
}

public enum RFBRectContent: Equatable {
    case raw([UInt8])
    case copyRect(sourceX: Int, sourceY: Int)
    /// Neue Bildschirmgröße steht in width/height des Rechtecks.
    case desktopSize
    /// Server versteht QEMUs erweiterte Tastenereignisse (Scancodes).
    case qemuExtendedKeySupport
}

public struct RFBRect: Equatable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
    public var content: RFBRectContent
}

public enum RFBServerMessage: Equatable {
    case framebufferUpdate([RFBRect])
    case colorMapEntries
    case bell
    case serverCutText(String)
}

/// Client-Seite des RFB-Protokolls ohne Netzwerkcode.
public final class RFBClientProtocol {
    public let source: RFBByteSource
    public let sink: RFBByteSink
    public let pixelFormat: RFBPixelFormat
    public private(set) var serverInit: RFBServerInit?
    public private(set) var supportsQEMUExtendedKeys = false

    /// Kodierungen, die Pluralism versteht. Raw reicht lokal völlig aus (Unix-Socket, kein Netz).
    public static let preferredEncodings: [Int32] = [
        RFBEncoding.copyRect,
        RFBEncoding.raw,
        RFBEncoding.desktopSize,
        RFBEncoding.lastRect,
        RFBEncoding.qemuExtendedKeyEvent
    ]

    public init(source: RFBByteSource, sink: RFBByteSink, pixelFormat: RFBPixelFormat = .bgrx32) {
        self.source = source
        self.sink = sink
        self.pixelFormat = pixelFormat
    }

    /// Begrüßung, Sicherheitsabsprache, Initialisierung. Danach sendet der Client sein
    /// Pixelformat und seine Kodierungen.
    @discardableResult
    public func handshake(shared: Bool = true) throws -> RFBServerInit {
        let versionBytes = try source.read(exactly: 12)
        let version = String(decoding: versionBytes, as: UTF8.self)
        guard version.hasPrefix("RFB "), version.count >= 11 else {
            throw RFBError.badProtocolVersion(version)
        }
        let minorText = version.dropFirst(8).prefix(3)
        let minor = Int(minorText) ?? 8

        if minor >= 7 {
            try sink.write(Array("RFB 003.008\n".utf8))
            let count = Int(try source.read(exactly: 1)[0])
            if count == 0 {
                throw RFBError.connectionRefused(try readReason())
            }
            let types = try source.read(exactly: count)
            guard types.contains(1) else {
                throw RFBError.noSupportedSecurityType(types)
            }
            try sink.write([1])
            let result = try readU32()
            if result != 0 {
                var reason = "Code \(result)"
                if minor >= 8 {
                    reason = try readReason()
                }
                throw RFBError.securityFailed(reason)
            }
        } else {
            try sink.write(Array("RFB 003.003\n".utf8))
            let type = try readU32()
            if type == 0 {
                throw RFBError.connectionRefused(try readReason())
            }
            guard type == 1 else {
                throw RFBError.noSupportedSecurityType([UInt8(truncatingIfNeeded: type)])
            }
        }

        try sink.write([shared ? 1 : 0])

        let width = Int(try readU16())
        let height = Int(try readU16())
        let format = RFBPixelFormat.decode(try source.read(exactly: 16))
        let nameLength = Int(try readU32())
        let nameBytes = nameLength > 0 ? try source.read(exactly: min(nameLength, 1 << 16)) : []
        let info = RFBServerInit(width: width, height: height, pixelFormat: format,
                                 name: String(decoding: nameBytes, as: UTF8.self))
        serverInit = info

        try sink.write(RFBClientProtocol.setPixelFormat(pixelFormat))
        try sink.write(RFBClientProtocol.setEncodings(RFBClientProtocol.preferredEncodings))
        return info
    }

    /// Liest die nächste Nachricht des Servers (blockierend).
    public func readMessage() throws -> RFBServerMessage {
        let type = try source.read(exactly: 1)[0]
        switch type {
        case 0:
            _ = try source.read(exactly: 1)
            let count = Int(try readU16())
            var rects: [RFBRect] = []
            rects.reserveCapacity(count == 0xFFFF ? 16 : count)
            var index = 0
            while count == 0xFFFF || index < count {
                index += 1
                let x = Int(try readU16())
                let y = Int(try readU16())
                let w = Int(try readU16())
                let h = Int(try readU16())
                let encoding = Int32(bitPattern: try readU32())
                switch encoding {
                case RFBEncoding.raw:
                    let length = w * h * pixelFormat.bytesPerPixel
                    let pixels = length > 0 ? try source.read(exactly: length) : []
                    rects.append(RFBRect(x: x, y: y, width: w, height: h, content: .raw(pixels)))
                case RFBEncoding.copyRect:
                    let sx = Int(try readU16())
                    let sy = Int(try readU16())
                    rects.append(RFBRect(x: x, y: y, width: w, height: h, content: .copyRect(sourceX: sx, sourceY: sy)))
                case RFBEncoding.desktopSize:
                    rects.append(RFBRect(x: x, y: y, width: w, height: h, content: .desktopSize))
                case RFBEncoding.qemuExtendedKeyEvent:
                    supportsQEMUExtendedKeys = true
                    rects.append(RFBRect(x: x, y: y, width: w, height: h, content: .qemuExtendedKeySupport))
                case RFBEncoding.lastRect:
                    return .framebufferUpdate(rects)
                default:
                    throw RFBError.unsupportedEncoding(encoding)
                }
            }
            return .framebufferUpdate(rects)
        case 1:
            _ = try source.read(exactly: 1)
            _ = try readU16()
            let count = Int(try readU16())
            if count > 0 {
                _ = try source.read(exactly: count * 6)
            }
            return .colorMapEntries
        case 2:
            return .bell
        case 3:
            _ = try source.read(exactly: 3)
            let raw = try readU32()
            // Erweiterte Zwischenablage nutzt negative Längen; die versteht Pluralism noch nicht.
            let length = Int(Int32(bitPattern: raw))
            if length <= 0 {
                let skip = Int(abs(Int64(Int32(bitPattern: raw))))
                if skip > 0 { _ = try source.read(exactly: skip) }
                return .serverCutText("")
            }
            let bytes = try source.read(exactly: length)
            return .serverCutText(RFBText.decodeLatin1(bytes))
        default:
            throw RFBError.unexpectedMessage(type)
        }
    }

    // MARK: Client-Nachrichten

    public func requestUpdate(incremental: Bool, x: Int = 0, y: Int = 0, width: Int, height: Int) throws {
        try sink.write(RFBClientProtocol.framebufferUpdateRequest(incremental: incremental, x: x, y: y, width: width, height: height))
    }

    public func sendKey(down: Bool, keysym: UInt32, scancode: UInt32?) throws {
        if supportsQEMUExtendedKeys, let scancode {
            try sink.write(RFBClientProtocol.qemuExtendedKeyEvent(down: down, keysym: keysym, scancode: scancode))
        } else if keysym != 0 {
            try sink.write(RFBClientProtocol.keyEvent(down: down, keysym: keysym))
        }
    }

    public func sendPointer(buttonMask: UInt8, x: Int, y: Int) throws {
        try sink.write(RFBClientProtocol.pointerEvent(buttonMask: buttonMask, x: x, y: y))
    }

    public static func setPixelFormat(_ format: RFBPixelFormat) -> [UInt8] {
        var bytes: [UInt8] = [0, 0, 0, 0]
        bytes.append(contentsOf: format.encoded())
        return bytes
    }

    public static func setEncodings(_ encodings: [Int32]) -> [UInt8] {
        var bytes: [UInt8] = [2, 0]
        bytes.append(contentsOf: RFBBytes.u16(UInt16(encodings.count)))
        for encoding in encodings {
            bytes.append(contentsOf: RFBBytes.u32(UInt32(bitPattern: encoding)))
        }
        return bytes
    }

    public static func framebufferUpdateRequest(incremental: Bool, x: Int, y: Int, width: Int, height: Int) -> [UInt8] {
        var bytes: [UInt8] = [3]
        bytes.append(incremental ? 1 : 0)
        bytes.append(contentsOf: RFBBytes.u16(clamp16(x)))
        bytes.append(contentsOf: RFBBytes.u16(clamp16(y)))
        bytes.append(contentsOf: RFBBytes.u16(clamp16(width)))
        bytes.append(contentsOf: RFBBytes.u16(clamp16(height)))
        return bytes
    }

    public static func keyEvent(down: Bool, keysym: UInt32) -> [UInt8] {
        var bytes: [UInt8] = [4]
        bytes.append(down ? 1 : 0)
        bytes.append(contentsOf: [0, 0])
        bytes.append(contentsOf: RFBBytes.u32(keysym))
        return bytes
    }

    /// QEMU-Erweiterung: Nachricht 255, Untertyp 0, mit XT-Scancode. So entscheidet das
    /// Tastaturlayout im Gast über das Zeichen, nicht eine Umrechnungstabelle.
    public static func qemuExtendedKeyEvent(down: Bool, keysym: UInt32, scancode: UInt32) -> [UInt8] {
        var bytes: [UInt8] = [255, 0]
        bytes.append(contentsOf: RFBBytes.u16(down ? 1 : 0))
        bytes.append(contentsOf: RFBBytes.u32(keysym))
        bytes.append(contentsOf: RFBBytes.u32(scancode))
        return bytes
    }

    public static func pointerEvent(buttonMask: UInt8, x: Int, y: Int) -> [UInt8] {
        var bytes: [UInt8] = [5, buttonMask]
        bytes.append(contentsOf: RFBBytes.u16(clamp16(x)))
        bytes.append(contentsOf: RFBBytes.u16(clamp16(y)))
        return bytes
    }

    // Bewusst keine ClientCutText-Nachricht: Pluralism teilt keine Zwischenablage mit dem Gast.

    // MARK: Lesen

    private func readU16() throws -> UInt16 {
        RFBBytes.readU16(try source.read(exactly: 2), 0)
    }

    private func readU32() throws -> UInt32 {
        RFBBytes.readU32(try source.read(exactly: 4), 0)
    }

    private func readReason() throws -> String {
        let length = Int(try readU32())
        guard length > 0 else { return "" }
        return String(decoding: try source.read(exactly: min(length, 4096)), as: UTF8.self)
    }

    private static func clamp16(_ value: Int) -> UInt16 {
        UInt16(clamping: max(0, value))
    }
}

/// Maustasten-Bits im RFB-Protokoll.
public enum RFBButton {
    public static let left: UInt8 = 1
    public static let middle: UInt8 = 2
    public static let right: UInt8 = 4
    public static let wheelUp: UInt8 = 8
    public static let wheelDown: UInt8 = 16
    public static let wheelLeft: UInt8 = 32
    public static let wheelRight: UInt8 = 64
}

public enum RFBBytes {
    public static func u16(_ v: UInt16) -> [UInt8] {
        [UInt8(v >> 8), UInt8(v & 0xFF)]
    }

    public static func u32(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    public static func readU16(_ b: [UInt8], _ offset: Int) -> UInt16 {
        (UInt16(b[offset]) << 8) | UInt16(b[offset + 1])
    }

    public static func readU32(_ b: [UInt8], _ offset: Int) -> UInt32 {
        (UInt32(b[offset]) << 24) | (UInt32(b[offset + 1]) << 16) | (UInt32(b[offset + 2]) << 8) | UInt32(b[offset + 3])
    }
}

/// RFB überträgt Text klassisch als ISO 8859-1 (Latin-1). Pluralism liest solche Nachrichten
/// nur, um den Datenstrom korrekt zu verarbeiten, und verwirft den Inhalt.
public enum RFBText {
    public static func encodeLatin1(_ text: String) -> [UInt8] {
        text.unicodeScalars.map { $0.value <= 0xFF ? UInt8($0.value) : UInt8(ascii: "?") }
    }

    public static func decodeLatin1(_ bytes: [UInt8]) -> String {
        String(String.UnicodeScalarView(bytes.map { Unicode.Scalar($0) }))
    }
}
