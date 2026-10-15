import AppKit
import Darwin
import Foundation
import PluralismCore
import PluralismNet

/// Engine für Windows-11-ARM64-Gäste (und optional Linux) über QEMU mit
/// Hypervisor.framework-Beschleunigung. QEMU läuft als eigener Prozess; Pluralism steuert
/// ihn über QMP und zeigt das Bild über eine lokale VNC-Verbindung an.
///
/// Netzwerk: Pluralism legt ein eigenes vmnet-Netz für die VM an und reicht die Ethernet-Rahmen
/// zwischen QEMU (-netdev dgram) und vmnet durch. Klappt das nicht, nutzt QEMU sein eingebautes
/// Usermode-Netz als Ausweichweg.
@MainActor
final class QEMUEngine: VMEngine {
    let bundle: VMBundle
    private(set) var config: VMConfiguration
    private let toolchainProvider: () -> QEMUToolchain?

    var onStateChange: ((VMRunState) -> Void)?
    var onNotice: ((String) -> Void)?
    var onNetworkChange: (() -> Void)?

    private(set) var state: VMRunState = .stopped {
        didSet {
            if state != oldValue { onStateChange?(state) }
        }
    }

    private var qemuProcess: ManagedProcess?
    private var tpmProcess: ManagedProcess?
    private var qmp: QMPClient?
    private var rfb: RFBConnection?
    private var relay: PacketRelay?
    private weak var displayView: RFBDisplayView?
    private(set) var activeNetwork: ActiveNetwork = .none
    private var runtime: RuntimePaths
    private var launchGeneration = 0
    /// Abbruch für den laufenden Start; Hintergrundschritte lesen ihn beim Warten auf Sockets.
    private var launchFlag = CancellationFlag()
    private var usesIntegratedDisplay = true
    private var stopRequestedByUser = false

    init(bundle: VMBundle, config: VMConfiguration, toolchainProvider: @escaping () -> QEMUToolchain?) {
        self.bundle = bundle
        self.config = config
        self.toolchainProvider = toolchainProvider
        self.runtime = RuntimePaths(config: config, userID: getuid())
    }

    func update(configuration: VMConfiguration) {
        config = configuration
        runtime = RuntimePaths(config: configuration, userID: getuid())
    }

    // MARK: Start

    /// Alles, was ein Start braucht. Unveränderlich und `Sendable`, damit es in die Hintergrundschritte darf.
    private struct Launch: Sendable {
        let generation: Int
        let flag: CancellationFlag
        let config: VMConfiguration
        let bundle: VMBundle
        let runtime: RuntimePaths
        let toolchain: QEMUToolchain
        let media: QEMUMedia
    }

    private struct Prepared: Sendable {
        let network: NetworkSetup
        let plan: QEMULaunchPlan
    }

    private struct Processes: Sendable {
        let qemu: ManagedProcess
        let tpm: ManagedProcess?
    }

    private struct Connections: Sendable {
        let qmp: QMPClient
        let rfb: RFBConnection?
    }

    func start() {
        guard qemuProcess == nil, !state.isActive else { return }
        guard let toolchain = toolchainProvider() else {
            state = .error("QEMU wurde nicht gefunden. Diese Pluralism-Version enthält keine QEMU-Laufzeit. Lade die aktuelle Version oder hinterlege in den Einstellungen einen eigenen Pfad.")
            return
        }
        state = .starting
        stopRequestedByUser = false
        launchGeneration += 1
        let flag = CancellationFlag()
        launchFlag = flag
        let launch = Launch(generation: launchGeneration, flag: flag, config: config, bundle: bundle,
                            runtime: runtime, toolchain: toolchain, media: makeMedia(config: config, bundle: bundle))
        Task {
            await run(launch)
        }
    }

    /// Gilt dieser Start noch? (Nicht abgebrochen, kein neuerer Start.)
    private func isCurrent(_ launch: Launch) -> Bool {
        launchGeneration == launch.generation && !launch.flag.isCancelled
    }

    /// Startablauf in drei blockierenden Schritten im Hintergrund: vorbereiten und Netz aufbauen,
    /// Prozesse starten, Steuerung und Bild verbinden. Dazwischen prüft der Main Actor, ob der Start
    /// noch gilt, und übernimmt die Ergebnisse.
    private func run(_ launch: Launch) async {
        var startedRelay: PacketRelay?
        let generation = launch.generation
        let addressDetected: @MainActor @Sendable (String) -> Void = { [weak self] address in
            self?.guestAddressDetected(address, generation: generation)
        }
        do {
            // 1. Ordner, Platten, Firmware, Netz, Befehlszeile
            let prepared = try await Background.runThrowing {
                try QEMUEngine.prepare(config: launch.config, bundle: launch.bundle, toolchain: launch.toolchain,
                                       runtime: launch.runtime)
                let network = QEMUEngine.setupNetwork(config: launch.config, runtime: launch.runtime) { address in
                    MainQueue.async { addressDetected(address) }
                }
                do {
                    let plan = try QEMUCommandBuilder.makePlan(config: launch.config, bundle: launch.bundle,
                                                               toolchain: launch.toolchain, runtime: launch.runtime,
                                                               media: launch.media, network: network.backend)
                    return Prepared(network: network, plan: plan)
                } catch {
                    network.relay?.stop()
                    throw error
                }
            }
            startedRelay = prepared.network.relay
            guard isCurrent(launch) else {
                if let startedRelay {
                    QEMUEngine.stopInBackground(startedRelay)
                }
                return
            }
            relay = prepared.network.relay
            activeNetwork = prepared.network.active
            if let notice = prepared.network.notice {
                onNotice?(notice)
            }

            // 2. swtpm zuerst, QEMU verbindet sich beim Start mit dessen Socket.
            let plan = prepared.plan
            let processes = try await Background.runThrowing {
                var tpm: ManagedProcess?
                do {
                    if let tpmPlan = plan.swtpm {
                        let process = try ManagedProcess(plan: tpmPlan, logURL: launch.bundle.tpmLogURL)
                        try process.launch()
                        tpm = process
                        try QEMUEngine.waitForFile(launch.runtime.tpmSocket.path, timeout: 5)
                    }
                    let qemu = try ManagedProcess(plan: plan.qemu, logURL: launch.bundle.engineLogURL)
                    try qemu.launch()
                    return Processes(qemu: qemu, tpm: tpm)
                } catch {
                    tpm?.terminate()
                    throw error
                }
            }
            guard isCurrent(launch) else {
                processes.qemu.terminate()
                processes.tpm?.terminate()
                return
            }
            qemuProcess = processes.qemu
            tpmProcess = processes.tpm
            usesIntegratedDisplay = plan.usesIntegratedDisplay
            processes.qemu.onExit = { [weak self] status in
                self?.processDidExit(status: status, generation: generation)
            }
            if !processes.qemu.isRunning {
                processDidExit(status: -1, generation: generation)
                return
            }

            // 3. Steuerverbindung (QMP) und Bildschirm (VNC)
            let connections = try await Background.runThrowing {
                let qmp = QMPClient()
                try qmp.connect(path: launch.runtime.qmpSocket.path, timeout: 20) { launch.flag.isCancelled }
                var rfb: RFBConnection?
                if plan.usesIntegratedDisplay {
                    let connection = RFBConnection()
                    do {
                        try connection.connect(path: launch.runtime.vncSocket.path, timeout: 20) { launch.flag.isCancelled }
                    } catch {
                        qmp.close()
                        throw error
                    }
                    rfb = connection
                }
                return Connections(qmp: qmp, rfb: rfb)
            }
            guard isCurrent(launch), qemuProcess != nil else {
                connections.qmp.close()
                connections.rfb?.close()
                return
            }
            attach(qmp: connections.qmp, rfb: connections.rfb)
            state = .running
        } catch {
            // Wenn der QEMU-Prozess schon beendet ist, hat processDidExit den Fehler gemeldet.
            guard launchGeneration == generation, state == .starting else {
                if let startedRelay {
                    QEMUEngine.stopInBackground(startedRelay)
                }
                return
            }
            let logHint = QEMUEngine.lastLogLines(bundle.engineLogURL)
            teardown()
            var message = error.localizedDescription
            if !logHint.isEmpty {
                message += "\n\nQEMU meldet:\n" + logHint
            }
            state = .error(message)
        }
    }

    /// Bereitet Ordner, Sockets, Hilfsplatte und UEFI-Variablen vor (Hintergrundthread).
    private nonisolated static func prepare(config: VMConfiguration, bundle: VMBundle, toolchain: QEMUToolchain,
                                runtime: RuntimePaths) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: bundle.logsDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: bundle.tpmStateDirectory, withIntermediateDirectories: true)

        // Laufzeitordner mit kurzen Socket-Pfaden, nur für diesen Benutzer lesbar
        try fm.createDirectory(at: runtime.directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runtime.directory.deletingLastPathComponent().path)
        for socket in [runtime.qmpSocket, runtime.vncSocket, runtime.tpmSocket, runtime.netGuestSocket, runtime.netHostSocket] {
            try? fm.removeItem(at: socket)
        }

        guard fm.fileExists(atPath: bundle.diskURL(for: config).path) else {
            throw PluralismError.message("Die Systemplatte fehlt: \(bundle.diskURL(for: config).path)")
        }
        if config.media.attachInstaller, let installer = config.media.installerISOPath, !installer.isEmpty,
           !fm.fileExists(atPath: installer) {
            throw QEMUPlanError.missingInstaller(installer)
        }
        if config.disk.migration == .driverPending, !fm.fileExists(atPath: bundle.virtioHelperDiskURL.path) {
            try DiskImageService.createDisk(at: bundle.virtioHelperDiskURL, sizeGiB: 1, format: .raw, toolchain: nil)
        }

        // UEFI-Variablen aus der Vorlage kopieren (Homebrew-Dateien sind schreibgeschützt,
        // die Kopie muss beschreibbar sein, sonst kann QEMU den pflash nicht ändern).
        let secure = config.guestOS == .windows && config.windows.secureBoot
        let firmware = try toolchain.firmware(secureBoot: secure)
        let varsURL = bundle.qemuEFIVariablesURL
        if !fm.fileExists(atPath: varsURL.path) {
            try fm.copyItem(atPath: firmware.varsTemplate, toPath: varsURL.path)
            try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: varsURL.path)
        }
    }

    struct NetworkSetup: Sendable {
        var backend: QEMUNetworkBackend
        var relay: PacketRelay?
        var active: ActiveNetwork
        var notice: String?
    }

    /// Die Paketbrücke hat die Adresse gesehen, die der Gast benutzt.
    private func guestAddressDetected(_ address: String, generation: Int) {
        guard launchGeneration == generation, case .vmnet(var addressing) = activeNetwork, addressing != nil else { return }
        addressing?.guestAddress = address
        activeNetwork = .vmnet(addressing)
        onNetworkChange?()
    }

    /// Baut das vmnet-Netz und die Paketbrücke auf. Fällt bei Problemen auf das Usermode-Netz zurück.
    private nonisolated static func setupNetwork(config: VMConfiguration, runtime: RuntimePaths,
                                                 onGuestAddress: @escaping @Sendable (String) -> Void) -> NetworkSetup {
        let fallbackForwards = QEMUCommandBuilder.allPortForwards(config)
        switch config.network.mode {
        case .none:
            return NetworkSetup(backend: .none, relay: nil, active: .none, notice: nil)
        case .nat, .hostOnly:
            let mode: VMNetworkMode = config.network.mode == .nat ? .shared : .hostOnly
            do {
                let (network, fixedNotice) = try VMNetworkRegistry.shared.acquire(
                    mode: mode, guestMAC: config.network.macAddress,
                    fixedHostAddress: FixedSubnet.hostAddress(slot: config.network.slot, mode: config.network.mode))
                let relay = PacketRelay(network: network,
                                        hostSocketPath: runtime.netHostSocket.path,
                                        guestSocketPath: runtime.netGuestSocket.path)
                relay.onGuestAddress = onGuestAddress
                try relay.start()
                return NetworkSetup(backend: .vmnetRelay(guestSocket: runtime.netGuestSocket.path,
                                                         hostSocket: runtime.netHostSocket.path),
                                    relay: relay, active: .vmnet(network.addressing), notice: fixedNotice)
            } catch {
                let notice = "Schnelles Netzwerk (vmnet) nicht verfügbar: \(error.localizedDescription) Die VM nutzt das langsamere Ausweich-Netz."
                return NetworkSetup(backend: .user(forwards: fallbackForwards), relay: nil, active: .fallback, notice: notice)
            }
        }
    }

    private func makeMedia(config: VMConfiguration, bundle: VMBundle) -> QEMUMedia {
        let fm = FileManager.default
        var media = QEMUMedia()
        if config.media.attachInstaller {
            if let installer = config.media.installerISOPath, !installer.isEmpty {
                media.installerISO = installer
            }
            if let driver = config.media.driverISOPath, fm.fileExists(atPath: driver) {
                media.driverISO = driver
            }
            if config.media.hasUnattendMedia, fm.fileExists(atPath: bundle.unattendISOURL.path) {
                media.unattendISO = bundle.unattendISOURL.path
            }
        }
        return media
    }

    private func attach(qmp: QMPClient, rfb: RFBConnection?) {
        self.qmp = qmp
        qmp.onEvent = { [weak self] event in
            self?.handle(event: event)
        }
        self.rfb = rfb
        if let rfb {
            rfb.onDisconnect = { [weak self] _ in
                guard let self, self.state.isActive else { return }
                // Bild weg, Prozess läuft noch: QEMU beendet sich gleich oder die VM ist aus.
                self.displayView?.detach()
            }
            displayView?.attach(rfb)
        }
    }

    private func handle(event: String) {
        switch event {
        case "STOP":
            if state == .running { state = .paused }
        case "RESUME":
            if state == .paused || state == .starting { state = .running }
        case "POWERDOWN":
            state = .stopping
        case "SHUTDOWN":
            state = .stopping
        default:
            break
        }
    }

    private func processDidExit(status: Int32, generation: Int) {
        guard generation == launchGeneration else { return }
        let wasStopping = state == .stopping || stopRequestedByUser
        let logHint = QEMUEngine.lastLogLines(bundle.engineLogURL)
        teardown()
        if status == 0 || wasStopping {
            state = .stopped
        } else {
            var message = "QEMU wurde unerwartet beendet (Status \(status))."
            if !logHint.isEmpty {
                message += "\n\n" + logHint
            }
            state = .error(message)
        }
    }

    private func teardown() {
        launchFlag.cancel()
        qmp?.close()
        qmp = nil
        rfb?.close()
        rfb = nil
        displayView?.detach()
        qemuProcess?.terminate()
        qemuProcess = nil
        tpmProcess?.terminate()
        tpmProcess = nil
        if let relay {
            self.relay = nil
            QEMUEngine.stopInBackground(relay)
        }
        activeNetwork = .none
    }

    // MARK: Steuerung

    func requestShutdown() {
        guard let qmp else {
            forceStop()
            return
        }
        stopRequestedByUser = true
        state = .stopping
        qmp.send(.systemPowerdown)
    }

    func forceStop() {
        stopRequestedByUser = true
        guard let qemuProcess else {
            launchGeneration += 1
            teardown()
            state = .stopped
            return
        }
        state = .stopping
        if let qmp {
            qmp.send(.quit)
        } else {
            qemuProcess.terminate()
        }
        // Falls QEMU nicht reagiert: nach 5 Sekunden hart beenden.
        let process = qemuProcess
        Task {
            try? await Task.sleep(for: .seconds(5))
            if process.isRunning {
                process.kill()
            }
        }
    }

    func pause() {
        qmp?.send(.stop)
    }

    func resume() {
        qmp?.send(.cont)
    }

    var supportsSuspend: Bool { false }

    func suspend() {
        onNotice?("Anhalten mit gesichertem Zustand gibt es für QEMU-VMs noch nicht. Nutze Pause oder Snapshots.")
    }

    func sendCtrlAltDelete() {
        qmp?.send(.sendKeys(["ctrl", "alt", "delete"]))
    }

    var supportsHotPlug: Bool { false }

    func hotPlugImage(_ url: URL, completion: @escaping @MainActor (Error?) -> Void) {
        completion(PluralismError.message("Bei QEMU-VMs werden Medien beim nächsten Start angehängt."))
    }

    // MARK: Anzeige

    func makeDisplayView() -> NSView? {
        guard config.display.qemuFrontend == .integrated else { return nil }
        let view = RFBDisplayView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768))
        if let rfb {
            view.attach(rfb)
        }
        displayView = view
        return view
    }

    var displayHint: String? {
        config.display.qemuFrontend == .separateWindow
            ? "Das Bild dieser VM erscheint im eigenen QEMU-Fenster."
            : nil
    }

    /// Hartes Beenden beim Schließen der App.
    func terminateImmediately() {
        launchGeneration += 1
        teardown()
    }

    // MARK: Hilfen

    /// Brücke anhalten, ohne den Main Actor zu blockieren (vmnet wartet bis zu drei Sekunden).
    private nonisolated static func stopInBackground(_ relay: PacketRelay) {
        DispatchQueue.global(qos: .utility).async { relay.stop() }
    }

    private nonisolated static func waitForFile(_ path: String, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !FileManager.default.fileExists(atPath: path) {
            if Date() > deadline {
                throw PluralismError.message("swtpm hat seinen Socket nicht rechtzeitig angelegt (siehe logs/swtpm.log).")
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    /// Letzte Zeilen der QEMU-Logdatei, für verständlichere Fehlermeldungen.
    nonisolated static func lastLogLines(_ url: URL, count: Int = 6) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        let lines = text.split(separator: "\n").suffix(count)
        return lines.joined(separator: "\n")
    }
}
