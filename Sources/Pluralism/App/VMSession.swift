import Combine
import Foundation
import PluralismCore

/// Verbindet eine VM-Konfiguration mit ihrer Engine und stellt den Zustand für die
/// Oberfläche bereit. Eine Sitzung existiert pro VM, solange die App läuft.
final class VMSession: ObservableObject, Identifiable {
    let id: UUID
    let bundle: VMBundle
    @Published private(set) var configuration: VMConfiguration
    @Published private(set) var state: VMRunState = .stopped
    @Published var notice: String?
    @Published private(set) var snapshots: [SnapshotInfo] = []
    private(set) var engine: VMEngine
    private let toolchainProvider: () -> QEMUToolchain?

    /// Meldet gespeicherte Änderungen an das AppModel.
    var onConfigurationSaved: ((VMConfiguration) -> Void)?

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
            self?.state = newState
        }
        engine.onNotice = { [weak self] message in
            self?.notice = message
        }
        state = engine.state
    }

    // MARK: Steuerung

    func start() {
        guard !state.isActive else { return }
        notice = nil
        var updated = configuration
        updated.lastStartedAt = Date()
        try? bundle.save(updated)
        configuration = updated
        engine.update(configuration: updated)
        engine.start()
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
