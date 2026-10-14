import Foundation

// MARK: - Grundtypen

/// Betriebssystem des Gasts. Pluralism unterstützt bewusst nur ARM64-Gäste.
public enum GuestOS: String, Codable, CaseIterable, Identifiable, Sendable {
    case linux
    case windows

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .linux: return "Linux (ARM64)"
        case .windows: return "Windows 11 (ARM64)"
        }
    }

    /// Standard-Engine für dieses Gastsystem.
    public var defaultEngine: VMEngineKind {
        switch self {
        case .linux: return .appleVirtualization
        case .windows: return .qemu
        }
    }
}

/// Welche Technik die VM ausführt.
public enum VMEngineKind: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Apples Virtualization.framework (Linux-Gäste).
    case appleVirtualization
    /// QEMU als eigener Prozess, beschleunigt über Apples Hypervisor.framework (Windows-Gäste).
    case qemu

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .appleVirtualization: return "Apple Virtualization"
        case .qemu: return "QEMU + Hypervisor.framework"
        }
    }
}

/// Dateiformat der Systemplatte.
public enum DiskFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Rohes, dünn belegtes Abbild (APFS-sparse). Funktioniert mit beiden Engines.
    case raw
    /// Apple Sparse Image Format (ab macOS 26, nur Apple-Engine).
    case asif
    /// QEMU-Format mit Copy-on-Write (nur QEMU-Engine).
    case qcow2

    public var id: String { rawValue }

    public var fileExtension: String {
        switch self {
        case .raw: return "img"
        case .asif: return "asif"
        case .qcow2: return "qcow2"
        }
    }

    public var displayName: String {
        switch self {
        case .raw: return "RAW (dünn belegt)"
        case .asif: return "ASIF (ab macOS 26)"
        case .qcow2: return "qcow2"
        }
    }

    public func isSupported(by engine: VMEngineKind) -> Bool {
        switch (self, engine) {
        case (.raw, _): return true
        case (.asif, .appleVirtualization): return true
        case (.qcow2, .qemu): return true
        default: return false
        }
    }
}

/// Wie streng Schreibzugriffe auf die Platte des Hosts durchgeschrieben werden.
public enum DiskSyncMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case full
    case fsync
    case none

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .full: return "Vollständig (am sichersten, langsamer)"
        case .fsync: return "fsync (empfohlen)"
        case .none: return "Aus (am schnellsten, Risiko bei Absturz)"
        }
    }
}

// MARK: - Einstellungsgruppen

public struct DiskSettings: Codable, Equatable, Sendable {
    public var sizeGiB: Int
    public var format: DiskFormat
    public var fileName: String
    public var syncMode: DiskSyncMode

    public init(sizeGiB: Int = 64, format: DiskFormat = .raw, fileName: String? = nil, syncMode: DiskSyncMode = .fsync) {
        self.sizeGiB = sizeGiB
        self.format = format
        self.fileName = fileName ?? "disk.\(format.fileExtension)"
        self.syncMode = syncMode
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = DiskSettings()
        sizeGiB = try c.decode(.sizeGiB, default: fallback.sizeGiB)
        format = try c.decode(.format, default: fallback.format)
        fileName = try c.decode(.fileName, default: "disk.\(format.fileExtension)")
        syncMode = try c.decode(.syncMode, default: fallback.syncMode)
    }
}

public struct MediaSettings: Codable, Equatable, Sendable {
    /// Pfad zum Installations-ISO.
    public var installerISOPath: String?
    /// Ob das Installationsmedium beim Start angehängt wird.
    public var attachInstaller: Bool
    /// Pfad zum Treiber-ISO (virtio-win) für Windows.
    public var driverISOPath: String?
    /// Ob im Bundle ein Antwortdatei-ISO (unattend.iso) liegt.
    public var hasUnattendMedia: Bool
    /// Ob das Medium mit den Pluralism Tools (pluralism-tools.iso) angehängt wird.
    public var attachGuestTools: Bool

    public init(installerISOPath: String? = nil, attachInstaller: Bool = true, driverISOPath: String? = nil,
                hasUnattendMedia: Bool = false, attachGuestTools: Bool = false) {
        self.installerISOPath = installerISOPath
        self.attachInstaller = attachInstaller
        self.driverISOPath = driverISOPath
        self.hasUnattendMedia = hasUnattendMedia
        self.attachGuestTools = attachGuestTools
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        installerISOPath = try c.decodeIfPresent(String.self, forKey: .installerISOPath)
        attachInstaller = try c.decode(.attachInstaller, default: true)
        driverISOPath = try c.decodeIfPresent(String.self, forKey: .driverISOPath)
        hasUnattendMedia = try c.decode(.hasUnattendMedia, default: false)
        attachGuestTools = try c.decode(.attachGuestTools, default: false)
    }
}

/// Grafikgerät für QEMU-VMs.
public enum QEMUDisplayDevice: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Einfacher Framebuffer. Funktioniert in Windows ohne Treiber, feste Auflösung.
    case ramfb
    /// virtio-gpu. Braucht unter Windows den viogpudo-Treiber, erlaubt dann andere Auflösungen.
    case virtioGPU

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .ramfb: return "ramfb (ohne Treiber, für die Installation)"
        case .virtioGPU: return "virtio-gpu (nach Treiberinstallation)"
        }
    }
}

/// Wo das Bild einer QEMU-VM angezeigt wird.
public enum QEMUDisplayFrontend: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Im Pluralism-Fenster über eine lokale VNC-Verbindung.
    case integrated
    /// In QEMUs eigenem Cocoa-Fenster (inklusive QEMU-Zwischenablage).
    case separateWindow

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .integrated: return "Im Pluralism-Fenster"
        case .separateWindow: return "Eigenes QEMU-Fenster"
        }
    }
}

public struct DisplaySettings: Codable, Equatable, Sendable {
    public var widthPixels: Int
    public var heightPixels: Int
    /// Auflösung folgt der Fenstergröße (Apple-Engine).
    public var autoResize: Bool
    public var qemuDevice: QEMUDisplayDevice
    public var qemuFrontend: QEMUDisplayFrontend

    public init(widthPixels: Int = 1920, heightPixels: Int = 1200, autoResize: Bool = true,
                qemuDevice: QEMUDisplayDevice = .ramfb, qemuFrontend: QEMUDisplayFrontend = .integrated) {
        self.widthPixels = widthPixels
        self.heightPixels = heightPixels
        self.autoResize = autoResize
        self.qemuDevice = qemuDevice
        self.qemuFrontend = qemuFrontend
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DisplaySettings()
        widthPixels = try c.decode(.widthPixels, default: d.widthPixels)
        heightPixels = try c.decode(.heightPixels, default: d.heightPixels)
        autoResize = try c.decode(.autoResize, default: d.autoResize)
        qemuDevice = try c.decode(.qemuDevice, default: d.qemuDevice)
        qemuFrontend = try c.decode(.qemuFrontend, default: d.qemuFrontend)
    }
}

public enum NetworkMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Gemeinsames Netz mit dem Mac (NAT). Kein Root und keine besonderen Rechte nötig.
    case nat
    /// Keine Netzwerkkarte.
    case none

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .nat: return "Gemeinsames Netzwerk (NAT)"
        case .none: return "Kein Netzwerk"
        }
    }
}

public enum PortProtocol: String, Codable, CaseIterable, Identifiable, Sendable {
    case tcp
    case udp
    public var id: String { rawValue }
}

/// Weiterleitung eines Ports vom Mac (127.0.0.1) in den Gast. Nur QEMU-Engine.
public struct PortForward: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var proto: PortProtocol
    public var hostPort: Int
    public var guestPort: Int
    public var label: String

    public init(id: UUID = UUID(), proto: PortProtocol = .tcp, hostPort: Int, guestPort: Int, label: String = "") {
        self.id = id
        self.proto = proto
        self.hostPort = hostPort
        self.guestPort = guestPort
        self.label = label
    }
}

public struct NetworkSettings: Codable, Equatable, Sendable {
    public var mode: NetworkMode
    public var macAddress: String
    public var portForwards: [PortForward]

    public init(mode: NetworkMode = .nat, macAddress: String = MACAddress.random(), portForwards: [PortForward] = []) {
        self.mode = mode
        self.macAddress = macAddress
        self.portForwards = portForwards
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decode(.mode, default: .nat)
        macAddress = try c.decode(.macAddress, default: MACAddress.random())
        portForwards = try c.decode(.portForwards, default: [])
    }
}

/// Ein Ordner des Macs, der im Gast sichtbar ist.
public struct SharedFolder: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// Name im Gast (Unterordner der Freigabe "pluralism").
    public var name: String
    public var hostPath: String
    public var readOnly: Bool

    public init(id: UUID = UUID(), name: String, hostPath: String, readOnly: Bool = false) {
        self.id = id
        self.name = SharedFolder.sanitizedName(name)
        self.hostPath = hostPath
        self.readOnly = readOnly
    }

    /// Erlaubt nur Zeichen, die in Linux und Windows als Ordnername unproblematisch sind.
    public static func sanitizedName(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let mapped = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let result = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "._"))
        return result.isEmpty ? "Ordner" : String(result.prefix(64))
    }
}

public struct IntegrationSettings: Codable, Equatable, Sendable {
    /// Gemeinsame Zwischenablage (SPICE-Agent im Gast nötig).
    public var clipboard: Bool
    public var audioOutput: Bool
    public var audioInput: Bool
    /// Tastenkürzel wie Cmd+Tab an den Gast weiterreichen (Apple-Engine).
    public var captureSystemKeys: Bool

    public init(clipboard: Bool = true, audioOutput: Bool = true, audioInput: Bool = false, captureSystemKeys: Bool = false) {
        self.clipboard = clipboard
        self.audioOutput = audioOutput
        self.audioInput = audioInput
        self.captureSystemKeys = captureSystemKeys
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = IntegrationSettings()
        clipboard = try c.decode(.clipboard, default: d.clipboard)
        audioOutput = try c.decode(.audioOutput, default: d.audioOutput)
        audioInput = try c.decode(.audioInput, default: d.audioInput)
        captureSystemKeys = try c.decode(.captureSystemKeys, default: d.captureSystemKeys)
    }
}

public struct AdvancedSettings: Codable, Equatable, Sendable {
    /// Verschachtelte Virtualisierung (M3 oder neuer, macOS 15 oder neuer).
    public var nestedVirtualization: Bool
    public var memoryBalloon: Bool
    public var entropyDevice: Bool
    /// Ausgabe der seriellen Konsole in logs/serial.log schreiben.
    public var serialLog: Bool
    /// Geräte weglassen, die das Sichern des VM-Zustands verhindern (Ton, Zufallsgenerator).
    public var suspendable: Bool
    /// SME (Matrix-Erweiterung des M4) vor dem Gast verbergen (QEMU).
    public var hideSME: Bool
    /// Zusätzliche QEMU-Argumente (Experten).
    public var extraQEMUArguments: [String]

    public init(nestedVirtualization: Bool = false, memoryBalloon: Bool = true, entropyDevice: Bool = true,
                serialLog: Bool = true, suspendable: Bool = false, hideSME: Bool = false, extraQEMUArguments: [String] = []) {
        self.nestedVirtualization = nestedVirtualization
        self.memoryBalloon = memoryBalloon
        self.entropyDevice = entropyDevice
        self.serialLog = serialLog
        self.suspendable = suspendable
        self.hideSME = hideSME
        self.extraQEMUArguments = extraQEMUArguments
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AdvancedSettings()
        nestedVirtualization = try c.decode(.nestedVirtualization, default: d.nestedVirtualization)
        memoryBalloon = try c.decode(.memoryBalloon, default: d.memoryBalloon)
        entropyDevice = try c.decode(.entropyDevice, default: d.entropyDevice)
        serialLog = try c.decode(.serialLog, default: d.serialLog)
        suspendable = try c.decode(.suspendable, default: d.suspendable)
        hideSME = try c.decode(.hideSME, default: d.hideSME)
        extraQEMUArguments = try c.decode(.extraQEMUArguments, default: d.extraQEMUArguments)
    }
}

public enum TPMMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Kein TPM. Die Windows-Installation umgeht die Prüfung per Antwortdatei.
    case off
    /// Emuliertes TPM 2.0 über swtpm.
    case emulated

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .off: return "Aus (Prüfung wird umgangen)"
        case .emulated: return "Emuliertes TPM 2.0 (swtpm)"
        }
    }
}

/// Einstellungen für die automatische Windows-Installation. Das Passwort wird bewusst
/// nicht gespeichert, es landet nur einmalig im Antwortdatei-ISO.
public struct UnattendSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var userName: String
    public var computerName: String
    public var uiLanguage: String
    public var inputLocale: String
    public var timeZone: String
    /// Schlüssel, der nur die Edition auswählt. Standard: öffentlicher KMS-Client-Schlüssel
    /// für Windows 11 Pro (aktiviert nicht, eigener Schlüssel danach in den Einstellungen).
    public var productKey: String
    public var imageName: String
    public var bypassHardwareChecks: Bool
    public var installGuestDrivers: Bool

    public static let windows11ProKMSClientKey = "W269N-WFGWX-YVC9B-4J6C9-T83GX"

    /// Vorlagen für Sprache, Tastatur und Zeitzone.
    public struct RegionPreset: Equatable, Identifiable, Sendable {
        public var id: String { locale }
        public var title: String
        public var locale: String
        public var inputLocale: String
        public var timeZone: String
    }

    public static let regionPresets: [RegionPreset] = [
        RegionPreset(title: "Deutsch (Deutschland)", locale: "de-DE", inputLocale: "0407:00000407", timeZone: "W. Europe Standard Time"),
        RegionPreset(title: "Deutsch (Österreich)", locale: "de-AT", inputLocale: "0c07:00000407", timeZone: "W. Europe Standard Time"),
        RegionPreset(title: "Deutsch (Schweiz)", locale: "de-CH", inputLocale: "0807:00000807", timeZone: "W. Europe Standard Time"),
        RegionPreset(title: "Türkçe (Türkiye)", locale: "tr-TR", inputLocale: "041f:0000041f", timeZone: "Turkey Standard Time"),
        RegionPreset(title: "English (United States)", locale: "en-US", inputLocale: "0409:00000409", timeZone: "Pacific Standard Time"),
        RegionPreset(title: "English (United Kingdom)", locale: "en-GB", inputLocale: "0809:00000809", timeZone: "GMT Standard Time")
    ]

    public mutating func apply(_ preset: RegionPreset) {
        uiLanguage = preset.locale
        inputLocale = preset.inputLocale
        timeZone = preset.timeZone
    }

    public init(enabled: Bool = true, userName: String = "", computerName: String = "PLURALISM-WIN",
                uiLanguage: String = "de-DE", inputLocale: String = "0407:00000407",
                timeZone: String = "W. Europe Standard Time",
                productKey: String = UnattendSettings.windows11ProKMSClientKey,
                imageName: String = "Windows 11 Pro", bypassHardwareChecks: Bool = true,
                installGuestDrivers: Bool = true) {
        self.enabled = enabled
        self.userName = userName
        self.computerName = computerName
        self.uiLanguage = uiLanguage
        self.inputLocale = inputLocale
        self.timeZone = timeZone
        self.productKey = productKey
        self.imageName = imageName
        self.bypassHardwareChecks = bypassHardwareChecks
        self.installGuestDrivers = installGuestDrivers
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = UnattendSettings()
        enabled = try c.decode(.enabled, default: d.enabled)
        userName = try c.decode(.userName, default: d.userName)
        computerName = try c.decode(.computerName, default: d.computerName)
        uiLanguage = try c.decode(.uiLanguage, default: d.uiLanguage)
        inputLocale = try c.decode(.inputLocale, default: d.inputLocale)
        timeZone = try c.decode(.timeZone, default: d.timeZone)
        productKey = try c.decode(.productKey, default: d.productKey)
        imageName = try c.decode(.imageName, default: d.imageName)
        bypassHardwareChecks = try c.decode(.bypassHardwareChecks, default: d.bypassHardwareChecks)
        installGuestDrivers = try c.decode(.installGuestDrivers, default: d.installGuestDrivers)
    }
}

public struct WindowsSettings: Codable, Equatable, Sendable {
    public var tpm: TPMMode
    public var secureBoot: Bool
    public var unattend: UnattendSettings
    /// Host-Port für Remote Desktop (Gast-Port 3389), nil = aus.
    public var rdpHostPort: Int?

    public init(tpm: TPMMode = .off, secureBoot: Bool = false, unattend: UnattendSettings = UnattendSettings(), rdpHostPort: Int? = nil) {
        self.tpm = tpm
        self.secureBoot = secureBoot
        self.unattend = unattend
        self.rdpHostPort = rdpHostPort
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tpm = try c.decode(.tpm, default: .off)
        secureBoot = try c.decode(.secureBoot, default: false)
        unattend = try c.decode(.unattend, default: UnattendSettings())
        rdpHostPort = try c.decodeIfPresent(Int.self, forKey: .rdpHostPort)
    }
}

// MARK: - Gesamtkonfiguration

public struct VMConfiguration: Codable, Equatable, Identifiable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: UUID
    public var name: String
    public var guestOS: GuestOS
    public var engine: VMEngineKind
    public var cpuCount: Int
    public var memoryMiB: Int
    public var disk: DiskSettings
    public var media: MediaSettings
    public var display: DisplaySettings
    public var network: NetworkSettings
    public var sharedFolders: [SharedFolder]
    public var integration: IntegrationSettings
    public var advanced: AdvancedSettings
    public var windows: WindowsSettings
    public var notes: String
    public var createdAt: Date
    public var lastStartedAt: Date?

    public init(id: UUID = UUID(), name: String, guestOS: GuestOS, engine: VMEngineKind? = nil,
                cpuCount: Int, memoryMiB: Int, disk: DiskSettings, media: MediaSettings = MediaSettings(),
                display: DisplaySettings = DisplaySettings(), network: NetworkSettings = NetworkSettings(),
                sharedFolders: [SharedFolder] = [], integration: IntegrationSettings = IntegrationSettings(),
                advanced: AdvancedSettings = AdvancedSettings(), windows: WindowsSettings = WindowsSettings(),
                notes: String = "", createdAt: Date = Date(), lastStartedAt: Date? = nil) {
        self.schemaVersion = VMConfiguration.currentSchemaVersion
        self.id = id
        self.name = name
        self.guestOS = guestOS
        self.engine = engine ?? guestOS.defaultEngine
        self.cpuCount = cpuCount
        self.memoryMiB = memoryMiB
        self.disk = disk
        self.media = media
        self.display = display
        self.network = network
        self.sharedFolders = sharedFolders
        self.integration = integration
        self.advanced = advanced
        self.windows = windows
        self.notes = notes
        self.createdAt = createdAt
        self.lastStartedAt = lastStartedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(.schemaVersion, default: VMConfiguration.currentSchemaVersion)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(.name, default: "Virtuelle Maschine")
        guestOS = try c.decode(GuestOS.self, forKey: .guestOS)
        engine = try c.decode(.engine, default: guestOS.defaultEngine)
        cpuCount = try c.decode(.cpuCount, default: 2)
        memoryMiB = try c.decode(.memoryMiB, default: 4096)
        disk = try c.decode(.disk, default: DiskSettings())
        media = try c.decode(.media, default: MediaSettings())
        display = try c.decode(.display, default: DisplaySettings())
        network = try c.decode(.network, default: NetworkSettings())
        sharedFolders = try c.decode(.sharedFolders, default: [])
        integration = try c.decode(.integration, default: IntegrationSettings())
        advanced = try c.decode(.advanced, default: AdvancedSettings())
        windows = try c.decode(.windows, default: WindowsSettings())
        notes = try c.decode(.notes, default: "")
        createdAt = try c.decode(.createdAt, default: Date())
        lastStartedAt = try c.decodeIfPresent(Date.self, forKey: .lastStartedAt)
    }

    /// Sinnvolle Startkonfiguration für einen Gast auf diesem Mac.
    public static func makeDefault(name: String, guestOS: GuestOS, host: HostProfile) -> VMConfiguration {
        let rec = ResourceAdvisor.recommend(for: guestOS, host: host)
        let engine = guestOS.defaultEngine
        let format: DiskFormat = engine == .qemu ? .qcow2 : .raw
        var config = VMConfiguration(
            name: name,
            guestOS: guestOS,
            engine: engine,
            cpuCount: rec.cpuCount,
            memoryMiB: rec.memoryMiB,
            disk: DiskSettings(sizeGiB: rec.diskGiB, format: format)
        )
        if guestOS == .windows {
            config.display = DisplaySettings(widthPixels: 1920, heightPixels: 1080, autoResize: false,
                                             qemuDevice: .ramfb, qemuFrontend: .integrated)
            config.windows.rdpHostPort = 33389
            config.advanced.serialLog = false
        }
        return config
    }

    /// Prüft die Konfiguration und liefert verständliche Probleme. Leere Liste = in Ordnung.
    public func validationIssues(host: HostProfile) -> [String] {
        var issues: [String] = []
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append("Die VM braucht einen Namen.")
        }
        if cpuCount < 1 {
            issues.append("Mindestens ein virtueller Prozessorkern ist nötig.")
        }
        if cpuCount > host.totalCores {
            issues.append("Mehr virtuelle Kerne (\(cpuCount)) als der Mac hat (\(host.totalCores)).")
        }
        let limits = ResourceAdvisor.limits(host: host)
        if memoryMiB < 512 {
            issues.append("Mindestens 512 MB Arbeitsspeicher sind nötig.")
        }
        if memoryMiB > limits.maxMemoryMiB {
            issues.append("Zu viel Arbeitsspeicher: höchstens \(limits.maxMemoryMiB / 1024) GB, damit macOS genug übrig bleibt.")
        }
        if !disk.format.isSupported(by: engine) {
            issues.append("Das Plattenformat \(disk.format.displayName) passt nicht zur Engine \(engine.displayName).")
        }
        if disk.format == .asif && host.macOSMajorVersion < 26 {
            issues.append("ASIF-Platten brauchen macOS 26 oder neuer.")
        }
        if guestOS == .windows {
            if engine != .qemu {
                issues.append("Windows-Gäste laufen in Pluralism nur über die QEMU-Engine.")
            }
            if cpuCount < 2 { issues.append("Windows 11 braucht mindestens 2 Kerne.") }
            if memoryMiB < 4096 { issues.append("Windows 11 braucht mindestens 4 GB Arbeitsspeicher.") }
            if disk.sizeGiB < 64 { issues.append("Windows 11 braucht mindestens 64 GB Platte.") }
        }
        if advanced.nestedVirtualization && !host.supportsNestedVirtualization {
            issues.append("Verschachtelte Virtualisierung braucht einen M3-Chip oder neuer und macOS 15.")
        }
        var seen = Set<String>()
        for folder in sharedFolders {
            if !seen.insert(folder.name.lowercased()).inserted {
                issues.append("Der Freigabename \(folder.name) ist doppelt vergeben.")
            }
        }
        var hostPorts = Set<Int>()
        let forwards = network.portForwards + (windows.rdpHostPort.map { [PortForward(hostPort: $0, guestPort: 3389)] } ?? [])
        for forward in forwards {
            if !(1...65535).contains(forward.hostPort) || !(1...65535).contains(forward.guestPort) {
                issues.append("Ungültiger Port in einer Weiterleitung (\(forward.hostPort) zu \(forward.guestPort)).")
            }
            if !hostPorts.insert(forward.hostPort).inserted {
                issues.append("Der Mac-Port \(forward.hostPort) ist mehrfach weitergeleitet.")
            }
        }
        return issues
    }

    /// Kurzer, stabiler Bezeichner (für Socket-Pfade und Logs).
    public var shortID: String {
        String(id.uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
    }
}

// MARK: - MAC-Adressen

public enum MACAddress {
    /// Zufällige, lokal verwaltete Unicast-Adresse mit dem Präfix 52:54:00 (wie QEMU).
    public static func random() -> String {
        var bytes: [UInt8] = [0x52, 0x54, 0x00]
        for _ in 0..<3 { bytes.append(UInt8.random(in: 0...255)) }
        return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    public static func isValid(_ string: String) -> Bool {
        let parts = string.split(separator: ":")
        guard parts.count == 6 else { return false }
        return parts.allSatisfy { $0.count == 2 && UInt8($0, radix: 16) != nil }
    }
}

// MARK: - Hilfen zum toleranten Dekodieren

extension KeyedDecodingContainer {
    /// Liest einen Wert oder nimmt den Standardwert, wenn das Feld fehlt.
    /// So bleiben alte config.json-Dateien lesbar, wenn neue Felder dazukommen.
    func decode<T: Decodable>(_ key: Key, default defaultValue: T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? defaultValue
    }
}

// MARK: - JSON

public enum PluralismJSON {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
