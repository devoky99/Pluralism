import Foundation
import PluralismCore

/// Der Ordner mit allen VMs (`<UUID>.pluralismvm`).
final class VMLibrary {
    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Pluralism/VMs", isDirectory: true)
    }

    func ensureExists() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func bundle(for id: UUID) -> VMBundle {
        VMBundle(url: VMBundle.url(for: id, in: directory))
    }

    /// Lädt alle lesbaren Konfigurationen. Defekte Bundles werden übersprungen.
    func loadAll() -> [VMConfiguration] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return entries
            .filter { $0.pathExtension == VMBundle.fileExtension }
            .compactMap { try? VMBundle(url: $0).loadConfiguration() }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Legt das Bundle an und schreibt die Konfiguration. Die Platte entsteht separat.
    func createBundle(for config: VMConfiguration) throws -> VMBundle {
        try ensureExists()
        let bundle = self.bundle(for: config.id)
        let fm = FileManager.default
        try fm.createDirectory(at: bundle.url, withIntermediateDirectories: false)
        try fm.createDirectory(at: bundle.logsDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: bundle.snapshotsDirectory, withIntermediateDirectories: true)
        try bundle.save(config)
        return bundle
    }

    func save(_ config: VMConfiguration) throws {
        try bundle(for: config.id).save(config)
    }

    /// Verschiebt die VM in den Papierkorb (wiederherstellbar).
    func moveToTrash(_ id: UUID) throws {
        try FileManager.default.trashItem(at: bundle(for: id).url, resultingItemURL: nil)
    }

    /// Klont eine ausgeschaltete VM. Die Kopie bekommt eine neue ID, MAC-Adresse, Maschinenkennung
    /// und einen eigenen Adressbereich; Snapshots und gesicherte Zustände werden nicht übernommen.
    func clone(_ source: VMConfiguration, newName: String) throws -> VMConfiguration {
        let fm = FileManager.default
        let sourceBundle = bundle(for: source.id)
        var copy = source
        copy.id = UUID()
        copy.name = newName
        copy.network.macAddress = MACAddress.random()
        copy.network.slot = nil   // bekommt beim ersten Start einen eigenen Adressbereich
        copy.createdAt = Date()
        copy.lastStartedAt = nil
        let target = try createBundle(for: copy)

        let items = [sourceBundle.diskURL(for: source), sourceBundle.appleEFIVariablesURL,
                     sourceBundle.qemuEFIVariablesURL, sourceBundle.tpmStateDirectory]
        for item in items where fm.fileExists(atPath: item.path) {
            try fm.copyItem(at: item, to: target.url.appendingPathComponent(item.lastPathComponent))
        }
        try target.save(copy)
        return copy
    }
}
