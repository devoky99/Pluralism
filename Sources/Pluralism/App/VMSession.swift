import Combine
import Foundation
import PluralismCore

/// Verbindet eine VM-Konfiguration mit ihrer Engine und stellt den Zustand für die
/// Oberfläche bereit. Eine Sitzung existiert pro VM, solange die App läuft.
@MainActor
final class VMSession: ObservableObject, Identifiable {
    let id: UUID
    let bundle: VMBundle
    @Published private(set) var configuration: VMConfiguration
    @Published private(set) var state: VMRunState = .stopped
    @Published var notice: String?
    @Published private(set) var snapshots: [SnapshotInfo] = []
    private(set) var engine: VMEngine
    private let toolchainProvider: () -> QEMUToolchain?
    private var runningSince: Date?

    /// Meldet gespeicherte Änderungen an das AppModel.
    var onConfigurationSaved: ((VMConfiguration) -> Void)?
    /// Vergibt einen freien Platz für den festen Adressbereich (siehe `FixedSubnet`).
    var slotAllocator: (() -> Int?)?

    /// Mindestlaufzeit mit Hilfsplatte, damit Windows den virtio-Treiber sicher eingebunden hat.
    static let migrationMinimumRuntime: TimeInterval = 120

    init(configuration: VMConfiguration, bundle: VMBundle, toolchainProvider: @escaping () -> QEMUToolchain?) {
        self.id = configuration.id
        self.bundle = bundle
        self.configuration = configuration
        self.toolchainProvider = toolchainProvider
        self.engine = VMSession.makeEngine(configuration: configuration, bundle: bundle, toolchainProvider: toolchainProvider)
        wireEngine()
        reloadSnapshots()
    }

    private static func makeEngine(configuration: VMConfiguration, bundle: VMBundle,
                                   toolchainProvider: @escaping () -> QEMUToolchain?) -> VMEngine {
        switch configuration.engine {
        case .appleVirtualization:
            return AppleVMEngine(bundle: bundle, config: configuration)
        case .qemu:
            return QEMUEngine(bundle: bundle, config: configuration, toolchainProvider: toolchainProvider)
        }
    }

    private func wireEngine() {
        engine.onStateChange = { [weak self] newState in
            self?.handleStateChange(newState)
        }
        engine.onNotice = { [weak self] message in
            self?.notice = message
        }
        engine.onNetworkChange = { [weak self] in
            self?.objectWillChange.send()
        }
        state = engine.state
    }

    // MARK: Steuerung

    func start() {
        guard !state.isActive else { return }
        notice = nil
        var updated = configuration
        updated.lastStartedAt = Date()
        if updated.network.mode != .none, updated.network.slot == nil {
            updated.network.slot = slotAllocator?()
        }
        // Umstellung auf virtio abschließen: vorher Snapshot, dann Systemplatte umschalten.
        if updated.disk.migration == .readyToSwitch {
            do {
                // Der Snapshot soll den NVMe-Stand ohne offene Umstellung enthalten.
                var before = configuration
                before.disk.migration = nil
                try bundle.save(before)
                try SnapshotService.create(bundle: bundle, config: before, name: "Vor der Umstellung auf virtio",
                                           note: "Automatisch angelegt. Falls Windows nicht startet: wiederherstellen.")
                reloadSnapshots()
                updated.disk.bus = .virtio
                updated.disk.migration = nil
                try? FileManager.default.removeItem(at: bundle.virtioHelperDiskURL)
                notice = "Die Systemplatte läuft jetzt über virtio. Ein Snapshot vom Stand davor liegt bereit."
            } catch {
                notice = "Umstellung verschoben, Snapshot fehlgeschlagen: \(error.localizedDescription)"
            }
        }
        try? bundle.save(updated)
        configuration = updated
        onConfigurationSaved?(updated)
        engine.update(configuration: updated)
        engine.start()
    }

    /// Startet die Umstellung einer Windows-VM von NVMe auf die schnellere virtio-Platte.
    /// Schritt 1: Beim nächsten Start hängt eine Hilfsplatte an, Windows bindet den Treiber.
    /// Schritt 2: Nach einem Lauf von mindestens zwei Minuten schaltet der folgende Start um.
    func beginVirtioMigration() throws {
        var updated = configuration
        guard updated.guestOS == .windows, updated.disk.bus == .nvme else { return }
        updated.disk.migration = .driverPending
        try apply(updated)
        notice = "Starte Windows einmal normal, warte etwa zwei Minuten und fahre es herunter. Beim nächsten Start stellt Pluralism auf virtio um."
    }

    func cancelVirtioMigration() throws {
        var updated = configuration
        updated.disk.migration = nil
        try apply(updated)
        try? FileManager.default.removeItem(at: bundle.virtioHelperDiskURL)
    }

    private func handleStateChange(_ newState: VMRunState) {
        let previous = state
        state = newState
        if newState == .running, runningSince == nil {
            runningSince = Date()
        }
        if !newState.isActive, previous.isActive {
            let ranFor = runningSince.map { Date().timeIntervalSince($0) } ?? 0
            runningSince = nil
            if configuration.disk.migration == .driverPending, newState == .stopped,
               ranFor >= VMSession.migrationMinimumRuntime {
                var updated = configuration
                updated.disk.migration = .readyToSwitch
                try? apply(updated)
                notice = "Der Treiber ist vorbereitet. Beim nächsten Start stellt Pluralism die Systemplatte auf virtio um."
            }
        }
    }

    func shutdown() { engine.requestShutdown() }
    func forceStop() { engine.forceStop() }
    func pause() { engine.pause() }
    func resume() { engine.resume() }
    func suspend() { engine.suspend() }

    var hasSavedState: Bool {
        FileManager.default.fileExists(atPath: bundle.savedStateURL.path)
    }

    func discardSavedState() {
        try? FileManager.default.removeItem(at: bundle.savedStateURL)
        objectWillChange.send()
    }

    /// Scrollverhalten ändern, auch während die VM läuft. Wirkt sofort.
    func updateScrolling(speed: Double? = nil, momentum: Bool? = nil, invert: Bool? = nil) {
        var updated = configuration
        if let speed {
            let range = PeripheralSettings.scrollSpeedRange
            updated.peripherals.scrollSpeed = min(max(speed, range.lowerBound), range.upperBound)
        }
        if let momentum { updated.peripherals.scrollMomentum = momentum }
        if let invert { updated.peripherals.invertScroll = invert }
        guard updated != configuration else { return }
        do {
            try bundle.save(updated)
        } catch {
            notice = "Scroll-Einstellung nicht gespeichert: \(error.localizedDescription)"
        }
        configuration = updated
        engine.update(configuration: updated)
        onConfigurationSaved?(updated)
    }

    /// Neue Konfiguration speichern (nur ausgeschaltet).
    func apply(_ newConfiguration: VMConfiguration) throws {
        guard state.isStopped else {
            throw PluralismError.message("Einstellungen lassen sich nur bei ausgeschalteter VM ändern.")
        }
        try bundle.save(newConfiguration)
        let engineChanged = newConfiguration.engine != configuration.engine
        configuration = newConfiguration
        if engineChanged {
            engine = VMSession.makeEngine(configuration: newConfiguration, bundle: bundle, toolchainProvider: toolchainProvider)
            wireEngine()
        } else {
            engine.update(configuration: newConfiguration)
        }
        onConfigurationSaved?(newConfiguration)
    }

    // MARK: Snapshots

    func reloadSnapshots() {
        snapshots = SnapshotService.list(bundle: bundle)
    }

    func createSnapshot(name: String) throws {
        guard state.isStopped else {
            throw PluralismError.message("Snapshots gehen nur bei ausgeschalteter VM.")
        }
        try SnapshotService.create(bundle: bundle, config: configuration, name: name)
        reloadSnapshots()
    }

    func restoreSnapshot(_ snapshot: SnapshotInfo) throws {
        guard state.isStopped else {
            throw PluralismError.message("Zum Wiederherstellen muss die VM ausgeschaltet sein.")
        }
        let restored = try SnapshotService.restore(bundle: bundle, current: configuration, snapshot: snapshot)
        try apply(restored)
        reloadSnapshots()
    }

    func deleteSnapshot(_ snapshot: SnapshotInfo) throws {
        try SnapshotService.delete(bundle: bundle, snapshot: snapshot)
        reloadSnapshots()
    }
}
