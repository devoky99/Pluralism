import Darwin
import Foundation
import Synchronization

/// Kleine, blockierende Unix-Domain-Socket-Verbindung (für QMP und VNC).
///
/// Nebenläufigkeit: Ein Thread liest, andere schreiben. `fd` ändert sich nie; geschlossen wird der
/// Deskriptor erst in `deinit`, wenn niemand mehr liest. `close()` weckt einen blockierten Leser nur
/// über `shutdown` auf. So kann der Deskriptor nicht schon wiederverwendet sein, während ein anderer
/// Thread noch darauf liest. Schreiben ist über `writeLock` serialisiert.
final class UnixSocket: @unchecked Sendable {
    let fd: Int32
    private let writeLock = NSLock()
    private let isShutDown = Atomic<Bool>(false)

    private init(fd: Int32) {
        self.fd = fd
    }

    deinit {
        Darwin.close(fd)
    }

    enum SocketError: LocalizedError {
        case create(Int32)
        case pathTooLong(String)
        case connect(String, Int32)
        case closed
        case io(Int32)

        var errorDescription: String? {
            switch self {
            case .create(let e): return "Socket konnte nicht erstellt werden (\(String(cString: strerror(e))))."
            case .pathTooLong(let p): return "Socket-Pfad zu lang: \(p)"
            case .connect(let p, let e): return "Verbindung zu \(p) fehlgeschlagen (\(String(cString: strerror(e))))."
            case .closed: return "Verbindung geschlossen."
            case .io(let e): return "Ein-/Ausgabefehler (\(String(cString: strerror(e))))."
            }
        }
    }

    static func connect(path: String) throws -> UnixSocket {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.create(errno) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else {
            Darwin.close(fd)
            throw SocketError.pathTooLong(path)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (index, byte) in pathBytes.enumerated() {
                raw[index] = byte
            }
            raw[pathBytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let error = errno
            Darwin.close(fd)
            throw SocketError.connect(path, error)
        }

        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return UnixSocket(fd: fd)
    }

    /// Versucht wiederholt zu verbinden, bis der Socket existiert und annimmt.
    static func connect(path: String, timeout: TimeInterval, isCancelled: () -> Bool = { false }) throws -> UnixSocket {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error = SocketError.closed
        while Date() < deadline {
            if isCancelled() { throw SocketError.closed }
            if FileManager.default.fileExists(atPath: path) {
                do {
                    return try connect(path: path)
                } catch {
                    lastError = error
                }
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw lastError
    }

    func readExactly(_ count: Int) throws -> [UInt8] {
        guard count > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: count)
        var offset = 0
        try buffer.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            while offset < count {
                let n = Darwin.recv(fd, base + offset, count - offset, 0)
                if n > 0 {
                    offset += n
                } else if n == 0 {
                    throw SocketError.closed
                } else if errno != EINTR {
                    throw SocketError.io(errno)
                }
            }
        }
        return buffer
    }

    /// Liest, was gerade da ist (mindestens 1 Byte, blockierend).
    func readSome(maxLength: Int = 65536) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: maxLength)
        while true {
            let n = buffer.withUnsafeMutableBytes { raw in
                Darwin.recv(fd, raw.baseAddress, maxLength, 0)
            }
            if n > 0 { return Data(buffer[0..<n]) }
            if n == 0 { throw SocketError.closed }
            if errno != EINTR { throw SocketError.io(errno) }
        }
    }

    func writeAll(_ bytes: [UInt8]) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !isShutDown.load(ordering: .acquiring) else { throw SocketError.closed }
        var offset = 0
        try bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while offset < bytes.count {
                let n = Darwin.send(fd, base + offset, bytes.count - offset, 0)
                if n > 0 {
                    offset += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    throw SocketError.io(errno)
                }
            }
        }
    }

    /// Beendet die Verbindung in beide Richtungen. Blockierte Leser kehren mit „geschlossen“ zurück.
    func close() {
        let (exchanged, _) = isShutDown.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing)
        if exchanged {
            Darwin.shutdown(fd, SHUT_RDWR)
        }
    }
}
