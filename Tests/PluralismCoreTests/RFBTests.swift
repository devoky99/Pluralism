import Foundation
@testable import PluralismCore
import XCTest

/// Simulierter VNC-Server: liefert vorbereitete Bytes und merkt sich, was der Client schreibt.
final class FakeStream: RFBByteSource, RFBByteSink {
    var input: [UInt8]
    var offset = 0
    var written: [[UInt8]] = []

    init(_ input: [UInt8]) {
        self.input = input
    }

    func read(exactly count: Int) throws -> [UInt8] {
        guard offset + count <= input.count else { throw RFBError.closed }
        defer { offset += count }
        return Array(input[offset..<(offset + count)])
    }

    func write(_ bytes: [UInt8]) throws {
        written.append(bytes)
    }
}

final class RFBTests: XCTestCase {
    /// Begrüßung eines QEMU-VNC-Servers (3.8, Sicherheit "None", 4x2 Pixel, Name "QEMU").
    func serverHello(width: UInt16 = 4, height: UInt16 = 2) -> [UInt8] {
        var bytes = Array("RFB 003.008\n".utf8)
        bytes += [1, 1]                       // ein Sicherheitstyp: None
        bytes += [0, 0, 0, 0]                 // SecurityResult OK
        bytes += RFBBytes.u16(width) + RFBBytes.u16(height)
        bytes += RFBPixelFormat.bgrx32.encoded()
        bytes += RFBBytes.u32(4) + Array("QEMU".utf8)
        return bytes
    }

    func testHandshake() throws {
        let stream = FakeStream(serverHello())
        let client = RFBClientProtocol(source: stream, sink: stream)
        let info = try client.handshake()
        XCTAssertEqual(info.width, 4)
        XCTAssertEqual(info.height, 2)
        XCTAssertEqual(info.name, "QEMU")
        XCTAssertEqual(info.pixelFormat, .bgrx32)

        XCTAssertEqual(stream.written[0], Array("RFB 003.008\n".utf8))
        XCTAssertEqual(stream.written[1], [1])        // None gewählt
        XCTAssertEqual(stream.written[2], [1])        // shared
        XCTAssertEqual(stream.written[3].count, 20)   // SetPixelFormat
        XCTAssertEqual(stream.written[3][0], 0)
        let encodings = stream.written[4]
        XCTAssertEqual(encodings[0], 2)
        XCTAssertEqual(Int(RFBBytes.readU16(encodings, 2)), RFBClientProtocol.preferredEncodings.count)
    }

    func testHandshakeRefused() {
        var bytes = Array("RFB 003.008\n".utf8)
        bytes += [0] + RFBBytes.u32(5) + Array("Nein!".utf8)
        let stream = FakeStream(bytes)
        let client = RFBClientProtocol(source: stream, sink: stream)
        XCTAssertThrowsError(try client.handshake()) { error in
            XCTAssertEqual(error as? RFBError, .connectionRefused("Nein!"))
        }
    }

    func testHandshakeWithoutNoneSecurity() {
        var bytes = Array("RFB 003.008\n".utf8)
        bytes += [1, 2]   // nur VNC-Passwort
        let stream = FakeStream(bytes)
        let client = RFBClientProtocol(source: stream, sink: stream)
        XCTAssertThrowsError(try client.handshake())
    }

    func testOldProtocolVersion() throws {
        var bytes = Array("RFB 003.003\n".utf8)
        bytes += RFBBytes.u32(1)                 // Server wählt None
        bytes += RFBBytes.u16(2) + RFBBytes.u16(2)
        bytes += RFBPixelFormat.bgrx32.encoded()
        bytes += RFBBytes.u32(0)
        let stream = FakeStream(bytes)
        let client = RFBClientProtocol(source: stream, sink: stream)
        let info = try client.handshake()
        XCTAssertEqual(stream.written[0], Array("RFB 003.003\n".utf8))
        XCTAssertEqual(info.width, 2)
    }

    func testFramebufferUpdateParsing() throws {
        var bytes = serverHello()
        bytes += [0, 0] + RFBBytes.u16(4)       // Update mit 4 Rechtecken
        // Raw 1x1 bei (1,0)
        bytes += RFBBytes.u16(1) + RFBBytes.u16(0) + RFBBytes.u16(1) + RFBBytes.u16(1) + RFBBytes.u32(0)
        bytes += [0x11, 0x22, 0x33, 0x00]
        // CopyRect 2x1 von (0,0) nach (2,1)
        bytes += RFBBytes.u16(2) + RFBBytes.u16(1) + RFBBytes.u16(2) + RFBBytes.u16(1) + RFBBytes.u32(1)
        bytes += RFBBytes.u16(0) + RFBBytes.u16(0)
        // QEMU-Tastenerweiterung
        bytes += RFBBytes.u16(0) + RFBBytes.u16(0) + RFBBytes.u16(0) + RFBBytes.u16(0) + RFBBytes.u32(UInt32(bitPattern: -258))
        // Neue Größe 8x6
        bytes += RFBBytes.u16(0) + RFBBytes.u16(0) + RFBBytes.u16(8) + RFBBytes.u16(6) + RFBBytes.u32(UInt32(bitPattern: -223))

        let stream = FakeStream(bytes)
        let client = RFBClientProtocol(source: stream, sink: stream)
        try client.handshake()
        XCTAssertFalse(client.supportsQEMUExtendedKeys)
        let message = try client.readMessage()
        guard case .framebufferUpdate(let rects) = message else {
            return XCTFail("Kein Framebuffer-Update")
        }
        XCTAssertEqual(rects.count, 4)
        XCTAssertEqual(rects[0], RFBRect(x: 1, y: 0, width: 1, height: 1, content: .raw([0x11, 0x22, 0x33, 0x00])))
        XCTAssertEqual(rects[1].content, .copyRect(sourceX: 0, sourceY: 0))
        XCTAssertEqual(rects[2].content, .qemuExtendedKeySupport)
        XCTAssertEqual(rects[3].content, .desktopSize)
        XCTAssertEqual(rects[3].width, 8)
        XCTAssertTrue(client.supportsQEMUExtendedKeys)
    }

    func testCutTextBellAndUnknownMessage() throws {
        var bytes = serverHello()
        bytes += [3, 0, 0, 0] + RFBBytes.u32(4) + [0x48, 0xE4, 0x6C, 0x6C]   // "Häll" in Latin-1
        bytes += [2]
        bytes += [99]
        let stream = FakeStream(bytes)
        let client = RFBClientProtocol(source: stream, sink: stream)
        try client.handshake()
        XCTAssertEqual(try client.readMessage(), .serverCutText("Häll"))
        XCTAssertEqual(try client.readMessage(), .bell)
        XCTAssertThrowsError(try client.readMessage())
    }

    func testClientMessages() {
        XCTAssertEqual(RFBClientProtocol.framebufferUpdateRequest(incremental: true, x: 0, y: 0, width: 1920, height: 1080),
                       [3, 1, 0, 0, 0, 0, 0x07, 0x80, 0x04, 0x38])
        XCTAssertEqual(RFBClientProtocol.pointerEvent(buttonMask: RFBButton.left, x: 300, y: 2),
                       [5, 1, 0x01, 0x2C, 0x00, 0x02])
        XCTAssertEqual(RFBClientProtocol.keyEvent(down: true, keysym: 0xFF0D),
                       [4, 1, 0, 0, 0, 0, 0xFF, 0x0D])
        XCTAssertEqual(RFBClientProtocol.qemuExtendedKeyEvent(down: false, keysym: 0x61, scancode: 0x1E),
                       [255, 0, 0, 0, 0, 0, 0, 0x61, 0, 0, 0, 0x1E])
        XCTAssertEqual(RFBClientProtocol.pointerEvent(buttonMask: 0, x: -5, y: 70000), [5, 0, 0, 0, 0xFF, 0xFF])
    }

    func testSendKeyFallsBackWithoutQEMUExtension() throws {
        let stream = FakeStream([])
        let client = RFBClientProtocol(source: stream, sink: stream)
        try client.sendKey(down: true, keysym: 0x61, scancode: 0x1E)
        XCTAssertEqual(stream.written.last?.first, 4)  // ohne Erweiterung: klassisches KeyEvent
    }

    // MARK: Framebuffer

    func testBlitRawWithClipping() {
        let width = 4, height = 2
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let pixels: [UInt8] = [1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4]  // 2x2
        let rect = RFBRect(x: 3, y: 1, width: 2, height: 2, content: .raw(pixels))
        buffer.withUnsafeMutableBytes { raw in
            RFBFramebufferWriter.blitRaw(pixels, rect: rect, into: raw.baseAddress!, bytesPerRow: width * 4, width: width, height: height)
        }
        // Nur Pixel (3,1) liegt im Bild und bekommt den ersten Quellpixel.
        XCTAssertEqual(Array(buffer[(1 * width + 3) * 4..<(1 * width + 3) * 4 + 4]), [1, 1, 1, 1])
        XCTAssertEqual(buffer.filter { $0 != 0 }.count, 4)
    }

    func testCopyRectOverlapping() {
        let width = 3, height = 3
        // Spalte 0 enthält 1, 2, 3 (je Zeile), Rest 0
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0..<3 {
            for b in 0..<4 { buffer[(row * width) * 4 + b] = UInt8(row + 1) }
        }
        // Spalte 0, Zeilen 0..1 eine Zeile nach unten verschieben (überlappend)
        let rect = RFBRect(x: 0, y: 1, width: 1, height: 2, content: .copyRect(sourceX: 0, sourceY: 0))
        buffer.withUnsafeMutableBytes { raw in
            RFBFramebufferWriter.copyRect(sourceX: 0, sourceY: 0, rect: rect, in: raw.baseAddress!,
                                          bytesPerRow: width * 4, width: width, height: height)
        }
        XCTAssertEqual(buffer[0], 1)
        XCTAssertEqual(buffer[(1 * width) * 4], 1)
        XCTAssertEqual(buffer[(2 * width) * 4], 2)
    }

    // MARK: Tastatur

    func testKeyboardMapping() {
        XCTAssertEqual(KeyboardMapping.scancode(forMacKeyCode: 0x00, layout: .iso), 0x1E)      // A
        XCTAssertEqual(KeyboardMapping.scancode(forMacKeyCode: 0x7E, layout: .ansi), 0xC8)     // Pfeil hoch (E0 48)
        XCTAssertEqual(KeyboardMapping.scancode(forMacKeyCode: 0x3D, layout: .iso), 0xB8)      // AltGr
        XCTAssertEqual(KeyboardMapping.scancode(forMacKeyCode: 0x37, layout: .iso), 0xDB)      // Windows-Taste
        XCTAssertNil(KeyboardMapping.scancode(forMacKeyCode: 0x3F, layout: .iso))              // fn
        // ISO-Tausch: ^ oben links und < neben Shift
        XCTAssertEqual(KeyboardMapping.scancode(forMacKeyCode: 0x0A, layout: .iso), 0x29)
        XCTAssertEqual(KeyboardMapping.scancode(forMacKeyCode: 0x32, layout: .iso), 0x56)
        XCTAssertEqual(KeyboardMapping.scancode(forMacKeyCode: 0x32, layout: .ansi), 0x29)
        XCTAssertEqual(KeyboardMapping.keysym(for: "a"), 0x61)
        XCTAssertEqual(KeyboardMapping.keysym(for: "ä"), 0xE4)
        XCTAssertEqual(KeyboardMapping.keysym(for: "€"), 0x0100_20AC)
    }

    func testEveryModifierHasAScancode() {
        for code in KeyboardMapping.modifierKeyCodes {
            XCTAssertNotNil(KeyboardMapping.scancode(forMacKeyCode: code, layout: .iso), String(code, radix: 16))
        }
    }

    func testLatin1() {
        XCTAssertEqual(RFBText.decodeLatin1([0x47, 0xFC, 0x6C]), "Gül")
        XCTAssertEqual(RFBText.encodeLatin1("Gül ğ"), [0x47, 0xFC, 0x6C, 0x20, UInt8(ascii: "?")])
    }
}
