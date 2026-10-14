import Foundation
import PluralismCore

/// Snapshots einer ausgeschalteten VM. Platte, UEFI-Variablen, TPM-Zustand und
/// Konfiguration werden per APFS-Klon kopiert: das geht sofort und belegt nur den
/// Platz, der sich danach ändert.
enum SnapshotService {
    private static let infoFileName = "snapshot.json"

    static func list(bundle: VMBundle) -> [SnapshotInfo] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: bundle.snapshotsDirectory, includingPropertiesForKeys: nil) else {
            return []
        }
        let decoder = PluralismJSON.decoder()
        return entries.compactMap { dir -> SnapshotInfo? in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(infoFileName)) else { return nil }
            return try? decoder.decode(SnapshotInfo.self, from: data)
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    static func create(bundle: VMBundle, config: VMConfiguration, name: String, note: String = "") throws -> SnapshotInfo {
        let fm = FileManager.default
        let info = SnapshotInfo(name: name.isEmpty ? defaultName() : name, note: note)
        let dir = directory(for: info.id, bundle: bundle)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            for item in bundle.snapshotPayload(for: config) where fm.fileExists(atPath: item.path) {
                // copyItem klont auf APFS (clonefile), statt Daten zu duplizieren.
                try fm.copyItem(at: item, to: dir.appendingPathComponent(item.lastPathComponent))
            }
            let data = try PluralismJSON.encoder().encode(info)
            try data.write(to: dir.appendingPathComponent(infoFileName), options: .atomic)
        } catch {
            try? fm.removeItem(at: dir)
            throw error
        }
        return info
    }

    /// Stellt einen Snapshot wieder her und liefert die dabei geladene Konfiguration.
    /// Name und Notizen bleiben auf dem aktuellen Stand.
    static func restore(bundle: VMBundle, current: VMConfiguration, snapshot: SnapshotInfo) throws -> VMConfiguration {
        let fm = FileManager.default
        let dir = directory(for: snapshot.id, bundle: bundle)
        let items = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent != infoFileName }

        // Aktuelle Zustandsdateien entfernen, die der Snapshot ersetzt
        for path in [bundle.savedStateURL, bundle.tpmStateDirectory, bundle.qemuEFIVariablesURL, bundle.appleEFIVariablesURL] {
            try? fm.removeItem(at: path)
        }
        for item in items {
            let target = bundle.url.appendingPathComponent(item.lastPathComponent)
            if fm.fileExists(atPath: target.path) {
                try fm.removeItem(at: target)
            }
            try fm.copyItem(at: item, to: target)
        }

        var restored = (try? bundle.loadConfiguration()) ?? current
        restored.name = current.name
        restored.notes = current.notes
        try bundle.save(restored)
        return restored
    }

    static func delete(bundle: VMBundle, snapshot: SnapshotInfo) throws {
        try FileManager.default.removeItem(at: directory(for: snapshot.id, bundle: bundle))
    }

    private static func directory(for id: UUID, bundle: VMBundle) -> URL {
        bundle.snapshotsDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private static func defaultName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Snapshot vom \(formatter.string(from: Date()))"
    }
}
