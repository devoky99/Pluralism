/// Rahmenformat von QEMUs `-netdev stream` (und `-netdev socket`): vor jedem Ethernet-Rahmen stehen
/// 4 Byte mit seiner Länge (Big Endian).
///
/// Ein Stream-Socket verliert keine Rahmen: Ist der Empfänger gerade beschäftigt, wartet der Sender.
/// Bei Datagramm-Sockets verwirft macOS Rahmen, sobald der kleine Empfangspuffer (4 KB) voll ist.
public enum StreamFraming {
    public static let headerSize = 4
    /// Obergrenze für einen Rahmen. Größere Längen bedeuten einen kaputten Datenstrom.
    public static let maxFrameSize = 65_536

    /// Längenfeld für einen Rahmen.
    public static func header(length: Int) -> [UInt8] {
        let value = UInt32(length)
        return [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    /// Rahmen samt Längenfeld.
    public static func encode(_ frame: [UInt8]) -> [UInt8] {
        header(length: frame.count) + frame
    }
}

/// Setzt Rahmen aus einem Bytestrom wieder zusammen (Teilstücke dürfen beliebig geschnitten sein).
public struct StreamFrameDecoder: Sendable {
    public enum DecodeError: Error, Equatable, Sendable {
        case frameTooLarge(Int)
    }

    private var buffer: [UInt8] = []
    private var start = 0

    public init() {}

    /// Bytes, die zu einem noch unvollständigen Rahmen gehören.
    public var pendingByteCount: Int { buffer.count - start }

    /// Hängt `bytes` an und ruft `onFrame` für jeden vollständigen Rahmen auf.
    /// Der übergebene Speicher gilt nur während des Aufrufs.
    public mutating func append(_ bytes: UnsafeRawBufferPointer, onFrame: (UnsafeRawBufferPointer) -> Void) throws {
        buffer.append(contentsOf: bytes)
        while buffer.count - start >= StreamFraming.headerSize {
            let high = Int(buffer[start]) << 24 | Int(buffer[start + 1]) << 16
            let length = high | Int(buffer[start + 2]) << 8 | Int(buffer[start + 3])
            guard length <= StreamFraming.maxFrameSize else {
                throw DecodeError.frameTooLarge(length)
            }
            let frameStart = start + StreamFraming.headerSize
            guard buffer.count - frameStart >= length else { break }
            buffer.withUnsafeBytes { raw in
                onFrame(UnsafeRawBufferPointer(rebasing: raw[frameStart..<(frameStart + length)]))
            }
            start = frameStart + length
        }
        if start == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            start = 0
        } else if start >= 65_536 {
            buffer.removeFirst(start)
            start = 0
        }
    }

    public mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
        start = 0
    }
}
