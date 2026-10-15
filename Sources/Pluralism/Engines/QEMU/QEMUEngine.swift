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
final class QEMUEngine: VMEngine {
    let bundle: VMBundle
    private(set) var config: VMConfiguration
    private let toolchainProvider: () -> QEMUToolchain?

    var onStateChange: ((VMRunState) -> Void)?
    var onNotice: ((String) -> Void)?

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
    private var cancelled = false
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

    func start() {
        guard qemuProcess == nil, !state.isActive else { return }
        guard let toolchain = toolchainProvider() else {
            state = .error("QEMU wurde nicht gefunden. Diese Pluralism-Version enthält keine QEMU-Laufzeit. Lade die aktuelle Version oder hinterlege in den Einstellungen einen eigenen Pfad.")
            return
        }
        state = .starting
        cancelled = false
        stopRequestedByUser = false
        launchGeneration += 1
        let generation = launchGeneration
        let config = self.config
        let bundle = self.bundle
        let runtime = self.runtime
        let media = makeMedia(config: config, bundle: bundle)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var startedRelay: PacketRelay?
            do {
                try QEMUEngine.prepare(config: config, bundle: bundle, toolchain: toolchain, runtime: runtime)
                let network = QEMUEngine.setupNetwork(config: config, runtime: runtime)
                startedRelay = network.relay
                let plan = try QEMUCommandBuilder.makePlan(config: config, bundle: bundle, toolchain: toolchain,
                                                           runtime: runtime, media: media, network: network.backend)
                DispatchQueue.main.async {
                    guard let self, self.launchGeneration == generation else { return }
                    self.relay = network.relay
                    self.activeNetwork = network.active
                    if let notice = network.notice {
                        self.onNotice?(notice)
                    }
                }
                // swtpm zuerst, QEMU verbindet sich beim Start mit dessen Socket.
                var tpm: ManagedProcess?
                if let tpmPlan = plan.swtpm {
                    let process = try ManagedProcess(plan: tpmPlan, logURL: bundle.tpmLogURL)
                    try process.launch()
                    tpm = process
                    try QEMUEngine.waitForFile(runtime.tpmSocket.path, timeout: 5)
                }
                let qemu = try ManagedProcess(plan: plan.qemu, logURL: bundle.engineLogURL)
                try qemu.launch()

                DispatchQueue.main.async {
                    guard let self, self.launchGeneration == generation else {
                        qemu.terminate()
                        tpm?.terminate()
                        return
                    }
                    self.qemuProcess = qemu
                    self.tpmProcess = tpm
                    self.usesIntegratedDisplay = plan.usesIntegratedDisplay
                    qemu.onExit = { [weak self] status in
                        self?.processDidExit(status: status, generation: generation)
                    }
                    if !qemu.isRunning {
                        self.processDidExit(status: -1, generation: generation)
                    }
                }

                // Steuerverbindung
                let qmp = QMPClient()
                try qmp.connect(path: runtime.qmpSocket.path, timeout: 20) { [weak self] in
                    self?.isLaunchCancelled(generation) ?? true
                }

                // Bildschirm
                var rfb: RFBConnection?
                if plan.usesIntegratedDisplay {
                    let connection = RFBConnection()
                    try connection.connect(path: runtime.vncSocket.path, timeout: 20) { [weak self] in
                        self?.isLaunchCancelled(generation) ?? true
                    }
                    rfb = connection
                }

                DispatchQueue.main.async {
                    guard let self, self.launchGeneration == generation, self.qemuProcess != nil else {
                        qmp.close()
                        rfb?.close()
                        return
                    }
                    self.attach(qmp: qmp, rfb: rfb)
                    self.state = .running
                }
            } catch {
                DispatchQueue.main.async {
                    // Wenn der QEMU-Prozess schon beendet ist, hat processDidExit den Fehler gemeldet.
                    guard let self, self.launchGeneration == generation, self.state == .starting else {
                        if let startedRelay {
                            DispatchQueue.global().async { startedRelay.stop() }
                        }
                        return
                    }
                    let logHint = QEMUEngine.lastLogLines(self.bundle.engineLogURL)
                    self.teardown()
                    var message = error.localizedDescription
                    if !logHint.isEmpty {
                        message += "\n\nQEMU meldet:\n" + logHint
                    }
                    self.state = .error(message)
                }
            }
        }
    }

    private func isLaunchCancelled(_ generation: Int) -> Bool {
        // Wird aus einem Hintergrundthread gelesen; ein veralteter Wert verzögert höchstens kurz.
        cancelled || launchGeneration != generation
    }

    /// Bereitet Ordner, Sockets, Hilfsplatte und UEFI-Variablen vor (Hintergrundthread).
    private static func prepare(config: VMConfiguration, bundle: VMBundle, toolchain: QEMUToolchain,
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

    struct NetworkSetup {
        var backend: QEMUNetworkBackend
        var relay: PacketRelay?
        var active: ActiveNetwork
        var notice: String?
    }

    /// Baut das vmnet-Netz und die Paketbrücke auf. Fällt bei Problemen auf das Usermode-Netz zurück.
    private static func setupNetwork(config: VMConfiguration, runtime: RuntimePaths) -> NetworkSetup {
        let fallbackForwards = QEMUCommandBuilder.allPortForwards(config)
        switch config.network.mode {
        case .none:
            return NetworkSetup(backend: .none, relay: nil, active: .none, notice: nil)
        case .nat, .hostOnly:
            let mode: VMNetworkMode = config.network.mode == .nat ? .shared : .hostOnly
            do {
                let network = try VMNetwork(mode: mode, guestMAC: config.network.macAddress)
                let relay = PacketRelay(network: network,
                                        hostSocketPath: runtime.netHostSocket.path,
                                        guestSocketPath: runtime.netGuestSocket.path)
                try relay.start()
                return NetworkSetup(backend: .vmnetRelay(guestSocket: runtime.netGuestSocket.path,
                                                         hostSocket: runtime.netHostSocket.path),
                                    relay: relay, active: .vmnet(network.addressing), notice: nil)
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
        cancelled = true
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
            DispatchQueue.global(qos: .utility).async { relay.stop() }
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
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

    func hotPlugImage(_ url: URL, completion: @escaping (Error?) -> Void) {
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

    private static func waitForFile(_ path: String, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !FileManager.default.fileExists(atPath: path) {
            if Date() > deadline {
                throw PluralismError.message("swtpm hat seinen Socket nicht rechtzeitig angelegt (siehe logs/swtpm.log).")
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    /// Letzte Zeilen der QEMU-Logdatei, für verständlichere Fehlermeldungen.
    static func lastLogLines(_ url: URL, count: Int = 6) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        let lines = text.split(separator: "\n").suffix(count)
        return lines.joined(separator: "\n")
    }
}
