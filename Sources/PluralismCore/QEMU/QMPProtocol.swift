import Foundation

/// Befehle für das QEMU Machine Protocol (QMP), JSON über einen Unix-Socket.
public enum QMPCommand: Equatable, Sendable {
    case capabilities
    /// ACPI-Ausschaltknopf drücken (Gast fährt sauber herunter).
    case systemPowerdown
    case systemReset
    /// QEMU sofort beenden (wie Stecker ziehen).
    case quit
    /// VM anhalten (pausieren).
    case stop
    /// VM fortsetzen.
    case cont
    case queryStatus
    /// Tasten gleichzeitig drücken, z. B. ["ctrl", "alt", "delete"] (QEMU-qcodes).
    case sendKeys([String])

    public var name: String {
        switch self {
        case .capabilities: return "qmp_capabilities"
        case .systemPowerdown: return "system_powerdown"
        case .systemReset: return "system_reset"
        case .quit: return "quit"
        case .stop: return "stop"
        case .cont: return "cont"
        case .queryStatus: return "query-status"
        case .sendKeys: return "send-key"
        }
    }

    /// Eine Zeile JSON inklusive Zeilenumbruch, bereit zum Senden.
    public func encoded(id: Int? = nil) -> Data {
        var object: [String: Any] = ["execute": name]
        if case .sendKeys(let keys) = self {
            object["arguments"] = ["keys": keys.map { ["type": "qcode", "data": $0] }]
        }
        if let id {
            object["id"] = id
        }
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        data.append(0x0A)
        return data
    }
}

/// Eine Nachricht von QEMU.
public enum QMPMessage: Equatable, Sendable {
    case greeting(version: String?)
    case success(id: Int?, status: String?)
    case failure(id: Int?, description: String)
    case event(name: String)

    /// Wertet eine JSON-Zeile aus. Unbekanntes liefert nil.
    public static func parse(_ line: Data) -> QMPMessage? {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            return nil
        }
        if let qmp = object["QMP"] as? [String: Any] {
            var version: String?
            if let v = qmp["version"] as? [String: Any], let q = v["qemu"] as? [String: Any],
               let major = q["major"] as? Int, let minor = q["minor"] as? Int, let micro = q["micro"] as? Int {
                version = "\(major).\(minor).\(micro)"
            }
            return .greeting(version: version)
        }
        let id = object["id"] as? Int
        if let ret = object["return"] {
            var status: String?
            if let dict = ret as? [String: Any] {
                status = dict["status"] as? String
            }
            return .success(id: id, status: status)
        }
        if let error = object["error"] as? [String: Any] {
            let description = error["desc"] as? String ?? "Unbekannter QMP-Fehler"
            return .failure(id: id, description: description)
        }
        if let event = object["event"] as? String {
            return .event(name: event)
        }
        return nil
    }
}

/// Zerlegt einen Byte-Strom in Zeilen (QMP schickt eine JSON-Nachricht pro Zeile).
public struct LineBuffer: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            if !line.isEmpty {
                lines.append(Data(line))
            }
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        return lines
    }
}
