import Foundation

/// Ordner einer VM auf der Platte (`<UUID>.pluralismvm`). Enthält Konfiguration, Platte,
/// UEFI-Variablen, TPM-Zustand, Logs und Snapshots. Alles, was zur VM gehört, liegt hier,
/// damit man eine VM einfach kopieren oder sichern kann.
public struct VMBundle: Equatable, Hashable, Sendable {
    public static let fileExtension = "pluralismvm"

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static func url(for id: UUID, in libraryDirectory: URL) -> URL {
        libraryDirectory.appendingPathComponent("\(id.uuidString).\(fileExtension)", isDirectory: true)
    }

    public var configURL: URL { url.appendingPathComponent("config.json") }

    public func diskURL(for config: VMConfiguration) -> URL {
        url.appendingPathComponent(config.disk.fileName)
    }

    /// UEFI-Variablenspeicher der Apple-Engine.
    public var appleEFIVariablesURL: URL { url.appendingPathComponent("efi-variables.bin") }
    /// UEFI-Variablen (pflash) der QEMU-Engine.
    public var qemuEFIVariablesURL: URL { url.appendingPathComponent("qemu-efi-vars.fd") }
    /// Maschinenkennung der Apple-Engine.
    public var machineIdentifierURL: URL { url.appendingPathComponent("machine-identifier.bin") }
    /// Gesicherter Laufzeitzustand (Apple-Engine, "Anhalten").
    public var savedStateURL: URL { url.appendingPathComponent("saved-state.vzvmsave") }
    public var tpmStateDirectory: URL { url.appendingPathComponent("tpm", isDirectory: true) }
    public var logsDirectory: URL { url.appendingPathComponent("logs", isDirectory: true) }
    public var snapshotsDirectory: URL { url.appendingPathComponent("snapshots", isDirectory: true) }
    public var unattendISOURL: URL { url.appendingPathComponent("unattend.iso") }
    /// Kleine leere Platte für die Umstellung einer Windows-VM von NVMe auf virtio.
    public var virtioHelperDiskURL: URL { url.appendingPathComponent("virtio-helper.img") }

    public var serialLogURL: URL { logsDirectory.appendingPathComponent("serial.log") }
    public var engineLogURL: URL { logsDirectory.appendingPathComponent("engine.log") }
    public var tpmLogURL: URL { logsDirectory.appendingPathComponent("swtpm.log") }

    /// Dateien, die ein Snapshot sichern muss (sofern vorhanden).
    public func snapshotPayload(for config: VMConfiguration) -> [URL] {
        [diskURL(for: config), appleEFIVariablesURL, qemuEFIVariablesURL, machineIdentifierURL, tpmStateDirectory, configURL]
    }

    public func loadConfiguration() throws -> VMConfiguration {
        let data = try Data(contentsOf: configURL)
        return try PluralismJSON.decoder().decode(VMConfiguration.self, from: data)
    }

    public func save(_ configuration: VMConfiguration) throws {
        let data = try PluralismJSON.encoder().encode(configuration)
        try data.write(to: configURL, options: .atomic)
    }
}

/// Kurze Pfade für Unix-Sockets. macOS erlaubt höchstens 104 Bytes pro Socket-Pfad,
/// der Pfad im VM-Bundle unter ~/Library/Application Support wäre dafür zu lang.
public struct RuntimePaths: Equatable, Sendable {
    public let directory: URL

    public init(config: VMConfiguration, userID: UInt32, root: String = "/tmp") {
        directory = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent("pluralism-\(userID)", isDirectory: true)
            .appendingPathComponent(config.shortID, isDirectory: true)
    }

    public var qmpSocket: URL { directory.appendingPathComponent("qmp.sock") }
    public var vncSocket: URL { directory.appendingPathComponent("vnc.sock") }
    public var tpmSocket: URL { directory.appendingPathComponent("tpm.sock") }
    /// Netzwerk-Paketbrücke: Pluralism lauscht, QEMU verbindet sich (`-netdev stream`).
    public var netSocket: URL { directory.appendingPathComponent("net.sock") }

    /// Alle Socket-Pfade sind kurz genug für sockaddr_un.
    public var allSocketPathsFit: Bool {
        [qmpSocket, vncSocket, tpmSocket, netSocket].allSatisfy { $0.path.utf8.count < 104 }
    }
}

/// Metadaten eines Snapshots (`snapshots/<id>/snapshot.json`).
public struct SnapshotInfo: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var note: String

    public init(id: UUID = UUID(), name: String, createdAt: Date = Date(), note: String = "") {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.note = note
    }
}
