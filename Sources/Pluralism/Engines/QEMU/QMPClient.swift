import Foundation
import PluralismCore

/// Steuerverbindung zu QEMU (QMP). Liest Ereignisse in einem eigenen Thread und meldet
/// sie auf dem Hauptthread.
final class QMPClient {
    private var socket: UnixSocket?
    private var lineBuffer = LineBuffer()
    private var pendingLines: [Data] = []
    private let sendQueue = DispatchQueue(label: "pluralism.qmp.send")
    private var nextID = 1
    private var running = false

    /// Name des Ereignisses, z. B. "SHUTDOWN", "STOP", "RESUME", "POWERDOWN".
    var onEvent: ((String) -> Void)?
    var onDisconnect: (() -> Void)?
    /// Status aus query-status ("running", "paused", ...).
    var onStatus: ((String) -> Void)?
    private(set) var qemuVersion: String?

    /// Verbindet (mit Wiederholungen) und schaltet den Befehlsmodus frei. Blockiert.
    func connect(path: String, timeout: TimeInterval, isCancelled: () -> Bool) throws {
        let socket = try UnixSocket.connect(path: path, timeout: timeout, isCancelled: isCancelled)
        self.socket = socket

        // Begrüßung
        let greetingLine = try nextLine()
        guard case .greeting(let version)? = QMPMessage.parse(greetingLine) else {
            throw PluralismError.message("QEMU hat sich nicht wie erwartet gemeldet (QMP).")
        }
        qemuVersion = version

        try socket.writeAll(Array(QMPCommand.capabilities.encoded()))
        // Antwort auf qmp_capabilities abwarten (Ereignisse dazwischen ignorieren)
        while true {
            let line = try nextLine()
            let message = QMPMessage.parse(line)
            if case .success? = message { break }
            if case .failure(_, let description)? = message {
                throw PluralismError.message("QMP-Freischaltung fehlgeschlagen: \(description)")
            }
        }

        running = true
        let thread = Thread { [weak self] in
            self?.readLoop()
        }
        thread.name = "pluralism.qmp.read"
        thread.start()
    }

    private func nextLine() throws -> Data {
        while pendingLines.isEmpty {
            guard let socket else { throw UnixSocket.SocketError.closed }
            let chunk = try socket.readSome()
            pendingLines.append(contentsOf: lineBuffer.append(chunk))
        }
        return pendingLines.removeFirst()
    }

    private func readLoop() {
        while running {
            do {
                let line = try nextLine()
                guard let message = QMPMessage.parse(line) else { continue }
                switch message {
                case .event(let name):
                    DispatchQueue.main.async { [weak self] in self?.onEvent?(name) }
                case .success(_, let status?):
                    DispatchQueue.main.async { [weak self] in self?.onStatus?(status) }
                default:
                    break
                }
            } catch {
                break
            }
        }
        running = false
        DispatchQueue.main.async { [weak self] in self?.onDisconnect?() }
    }

    func send(_ command: QMPCommand) {
        sendQueue.async { [weak self] in
            guard let self, let socket = self.socket else { return }
            let id = self.nextID
            self.nextID += 1
            try? socket.writeAll(Array(command.encoded(id: id)))
        }
    }

    func close() {
        running = false
        socket?.close()
        socket = nil
    }
}
