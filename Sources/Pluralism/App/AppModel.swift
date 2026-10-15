import AppKit
import Combine
import Foundation
import PluralismCore

struct AlertItem: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// Zentraler Zustand der App: VM-Bibliothek, Sitzungen, QEMU-Werkzeuge, Downloads.
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let host: HostProfile
    let downloads = DownloadService()

    @Published private(set) var library: VMLibrary
    @Published private(set) var configurations: [VMConfiguration] = []
    @Published var selection: UUID?
    @Published var showNewVMWizard = false
    @Published var alert: AlertItem?
    @Published private(set) var toolchainReport: ToolchainReport?
    @Published private(set) var isDetectingToolchain = false

    private var sessions: [UUID: VMSession] = [:]

    var toolchain: QEMUToolchain? { toolchainReport?.toolchain }

    init() {
        host = HostInspector.currentProfile()
        let customPath = UserDefaults.standard.string(forKey: PreferenceKeys.libraryPath)
        if let customPath, !customPath.isEmpty {
            library = VMLibrary(directory: URL(fileURLWithPath: customPath, isDirectory: true))
        } else {
            library = VMLibrary(directory: VMLibrary.defaultDirectory)
        }
        try? library.ensureExists()
        reload()
        refreshToolchain()
    }

    // MARK: Bibliothek

    func reload() {
        configurations = library.loadAll()
        if let selection, !configurations.contains(where: { $0.id == selection }) {
            self.selection = nil
        }
        if selection == nil {
            selection = configurations.first?.id
        }
    }

    func configuration(for id: UUID) -> VMConfiguration? {
        sessions[id]?.configuration ?? configurations.first { $0.id == id }
    }

    /// Liefert die Sitzung einer VM und legt sie bei Bedarf an.
    func session(for id: UUID) -> VMSession? {
        if let existing = sessions[id] { return existing }
        guard let config = configurations.first(where: { $0.id == id }) else { return nil }
        let session = VMSession(configuration: config, bundle: library.bundle(for: id)) { [weak self] in
            self?.toolchain
        }
        session.onConfigurationSaved = { [weak self] saved in
            guard let self, let index = self.configurations.firstIndex(where: { $0.id == saved.id }) else { return }
            self.configurations[index] = saved
        }
        sessions[id] = session
        return session
    }

    var hasActiveVMs: Bool {
        sessions.values.contains { $0.state.isActive }
    }

    func setLibraryDirectory(_ url: URL) {
        guard !hasActiveVMs else {
            alert = AlertItem(title: "Bibliothek nicht gewechselt", message: "Bitte zuerst alle VMs ausschalten.")
            return
        }
        UserDefaults.standard.set(url.path, forKey: PreferenceKeys.libraryPath)
        library = VMLibrary(directory: url)
        try? library.ensureExists()
        sessions.removeAll()
        selection = nil
        reload()
    }

    // MARK: QEMU-Werkzeuge

    func refreshToolchain() {
        isDetectingToolchain = true
        let override = UserDefaults.standard.string(forKey: PreferenceKeys.qemuPathOverride)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let report = ToolchainDetector.detect(qemuOverride: override)
            DispatchQueue.main.async {
                self?.toolchainReport = report
                self?.isDetectingToolchain = false
            }
        }
    }

    // MARK: VMs anlegen, ändern, löschen

    struct NewVMRequest {
        var configuration: VMConfiguration
        var password: String
        var windowsISO: URL?
        var virtioISO: URL?
    }

    func createVM(_ request: NewVMRequest, completion: @escaping (Result<VMConfiguration, Error>) -> Void) {
        let library = self.library
        let toolchain = self.toolchain
        let initialConfig = request.configuration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var config = initialConfig
            let result: Result<VMConfiguration, Error>
            do {
                let bundle = try library.createBundle(for: config)
                do {
                    try DiskImageService.createDisk(at: bundle.diskURL(for: config), sizeGiB: config.disk.sizeGiB,
                                                    format: config.disk.format, toolchain: toolchain)
                    if config.guestOS == .windows {
                        // Schnelle virtio-Platte nur, wenn Setup den Treiber viostor automatisch bekommt.
                        // Bei manueller Installation bleibt NVMe, das Windows ohne Treiber kennt.
                        config.disk.bus = .nvme
                        if config.windows.unattend.enabled {
                            let media = try GuestMediaBuilder.buildWindowsSetupMedia(
                                bundle: bundle,
                                settings: config.windows.unattend,
                                password: request.password,
                                enableRemoteDesktop: config.windows.rdpHostPort != nil,
                                windowsISO: request.windowsISO,
                                virtioISO: request.virtioISO)
                            config.media.hasUnattendMedia = true
                            if media.copiedDrivers.contains("viostor") {
                                config.disk.bus = .virtio
                            }
                        }
                    }
                    try bundle.save(config)
                } catch {
                    try? FileManager.default.removeItem(at: bundle.url)
                    throw error
                }
                result = .success(config)
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async { [weak self] in
                if case .success(let created) = result {
                    self?.reload()
                    self?.selection = created.id
                }
                completion(result)
            }
        }
    }

    func save(_ config: VMConfiguration) throws {
        if let session = sessions[config.id] {
            try session.apply(config)
        } else {
            try library.save(config)
            if let index = configurations.firstIndex(where: { $0.id == config.id }) {
                configurations[index] = config
            }
        }
    }

    func delete(_ id: UUID) {
        if let session = sessions[id], session.state.isActive {
            alert = AlertItem(title: "VM läuft noch", message: "Bitte die VM zuerst ausschalten.")
            return
        }
        do {
            try library.moveToTrash(id)
            sessions[id] = nil
            selection = nil
            reload()
        } catch {
            show(error, title: "Löschen fehlgeschlagen")
        }
    }

    func clone(_ id: UUID) {
        guard let config = configuration(for: id) else { return }
        if let session = sessions[id], session.state.isActive {
            alert = AlertItem(title: "VM läuft noch", message: "Klonen geht nur bei ausgeschalteter VM.")
            return
        }
        let library = self.library
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try library.clone(config, newName: "\(config.name) Kopie") }
            DispatchQueue.main.async { [weak self] in
                switch result {
                case .success(let copy):
                    self?.reload()
                    self?.selection = copy.id
                case .failure(let error):
                    self?.show(error, title: "Klonen fehlgeschlagen")
                }
            }
        }
    }

    // MARK: Beenden

    func terminateAll() {
        for session in sessions.values where session.state.isActive {
            session.engine.terminateImmediately()
        }
    }

    // MARK: Meldungen

    func show(_ error: Error, title: String) {
        alert = AlertItem(title: title, message: error.localizedDescription)
    }
}
