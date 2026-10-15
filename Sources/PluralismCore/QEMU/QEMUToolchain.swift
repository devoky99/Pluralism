import Foundation

/// Die QEMU-Werkzeuge, die Pluralism für Windows-Gäste braucht (meist aus Homebrew:
/// `brew install qemu swtpm`). Die App erkennt sie beim Start; in Tests werden sie
/// von Hand gesetzt.
public struct QEMUToolchain: Equatable, Sendable {
    public var qemuSystemPath: String
    public var qemuImgPath: String?
    public var swtpmPath: String?
    public var firmwareCodePath: String?
    public var firmwareVarsTemplatePath: String?
    public var secureFirmwareCodePath: String?
    public var secureFirmwareVarsTemplatePath: String?
    /// Gerätenamen aus `qemu-system-aarch64 -machine virt -device help`.
    public var devices: Set<String>
    public var version: String?
    /// Netzwerk-Backends aus `qemu-system-aarch64 -machine none -netdev help`.
    public var netdevs: Set<String>
    /// QEMU trägt das Entitlement `com.apple.security.virtualization` (nötig für vmnet ohne Root).
    public var hasVirtualizationEntitlement: Bool

    public init(qemuSystemPath: String, qemuImgPath: String? = nil, swtpmPath: String? = nil,
                firmwareCodePath: String? = nil, firmwareVarsTemplatePath: String? = nil,
                secureFirmwareCodePath: String? = nil, secureFirmwareVarsTemplatePath: String? = nil,
                devices: Set<String> = [], version: String? = nil,
                netdevs: Set<String> = [], hasVirtualizationEntitlement: Bool = false) {
        self.qemuSystemPath = qemuSystemPath
        self.qemuImgPath = qemuImgPath
        self.swtpmPath = swtpmPath
        self.firmwareCodePath = firmwareCodePath
        self.firmwareVarsTemplatePath = firmwareVarsTemplatePath
        self.secureFirmwareCodePath = secureFirmwareCodePath
        self.secureFirmwareVarsTemplatePath = secureFirmwareVarsTemplatePath
        self.devices = devices
        self.version = version
        self.netdevs = netdevs
        self.hasVirtualizationEntitlement = hasVirtualizationEntitlement
    }

    /// QEMU kann vmnet selbst ansprechen (`-netdev vmnet-shared`/`vmnet-host`), wie bei UTM.
    /// Auf macOS 27 genügt dafür das Entitlement `com.apple.security.virtualization`; Root oder das
    /// nur auf Antrag vergebene `com.apple.vm.networking` sind nicht nötig (geprüft mit pluralism-netcheck).
    public var supportsNativeVmnet: Bool {
        hasVirtualizationEntitlement && netdevs.contains("vmnet-shared") && netdevs.contains("vmnet-host")
    }

    /// CRB-TPM, das Windows ARM64 auf Apple Silicon zuverlässig erkennt (braucht einen gepatchten QEMU-Build).
    public var supportsTPMCRB: Bool { devices.contains("tpm-crb-device") }
    /// TIS-TPM aus dem normalen QEMU. Unter Hypervisor.framework mit Windows laut Berichten unzuverlässig.
    public var supportsTPMTIS: Bool { devices.contains("tpm-tis-device") }
    public var supportsSecureBoot: Bool { secureFirmwareCodePath != nil && secureFirmwareVarsTemplatePath != nil }

    /// Wählt Firmware und Variablen-Vorlage.
    public func firmware(secureBoot: Bool) throws -> (code: String, varsTemplate: String) {
        if secureBoot {
            guard let code = secureFirmwareCodePath, let vars = secureFirmwareVarsTemplatePath else {
                throw QEMUPlanError.missingSecureBootFirmware
            }
            return (code, vars)
        }
        guard let code = firmwareCodePath, let vars = firmwareVarsTemplatePath else {
            throw QEMUPlanError.missingFirmware
        }
        return (code, vars)
    }
}

/// Reine Hilfsfunktionen zum Finden und Auswerten der Werkzeuge.
public enum QEMUToolchainLocator {
    /// Typische Installationsorte auf Apple-Silicon-Macs.
    public static let binaryDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]

    public static let firmwareCodeNames = ["edk2-aarch64-code.fd"]
    public static let firmwareVarsNames = ["edk2-arm-vars.fd"]
    public static let secureFirmwareCodeNames = ["edk2-aarch64-secure-code.fd", "AAVMF_CODE.ms.fd", "AAVMF_CODE.secboot.fd"]
    public static let secureFirmwareVarsNames = ["edk2-arm-secure-vars.fd", "AAVMF_VARS.ms.fd"]

    /// Ordner, in denen die Firmware zu einem QEMU-Binary liegen kann.
    public static func firmwareDirectories(forQEMUBinary binaryPath: String) -> [String] {
        let binDir = URL(fileURLWithPath: binaryPath).deletingLastPathComponent()
        let shareDir = binDir.deletingLastPathComponent().appendingPathComponent("share/qemu").path
        var dirs = [shareDir]
        for extra in ["/opt/homebrew/share/qemu", "/usr/local/share/qemu", "/opt/local/share/qemu"] where !dirs.contains(extra) {
            dirs.append(extra)
        }
        return dirs
    }

    /// Liest die Gerätenamen aus der Ausgabe von `-device help`.
    /// Zeilenformat: `name "tpm-tis-device", bus System, desc "..."`.
    public static func parseDeviceHelp(_ output: String) -> Set<String> {
        var names = Set<String>()
        for line in output.split(whereSeparator: \.isNewline) {
            guard let start = line.range(of: "name \"") else { continue }
            let rest = line[start.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { continue }
            names.insert(String(rest[..<end]))
        }
        return names
    }

    /// Namen aus `-netdev help` (eine Zeile pro Backend nach der Überschrift).
    public static func parseNetdevHelp(_ output: String) -> Set<String> {
        var names = Set<String>()
        for line in output.split(whereSeparator: \.isNewline) {
            let name = line.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains(" "), !name.hasSuffix(":") else { continue }
            names.insert(name)
        }
        return names
    }

    /// Liest die Version aus `QEMU emulator version 11.1.2 (...)`.
    public static func parseVersion(_ output: String) -> String? {
        guard let range = output.range(of: "version ") else { return nil }
        let rest = output[range.upperBound...]
        let version = rest.prefix { $0.isNumber || $0 == "." }
        return version.isEmpty ? nil : String(version)
    }
}

public enum QEMUPlanError: Error, LocalizedError, Equatable {
    case missingFirmware
    case missingSecureBootFirmware
    case missingSWTPM
    case noTPMDevice
    case socketPathTooLong(String)
    case unsupportedDiskFormat(String)
    case missingInstaller(String)

    public var errorDescription: String? {
        switch self {
        case .missingFirmware:
            return "Die UEFI-Firmware für ARM64 (edk2-aarch64-code.fd) wurde nicht gefunden. Installiere QEMU mit „brew install qemu“."
        case .missingSecureBootFirmware:
            return "Für Secure Boot fehlt eine Firmware mit Microsoft-Schlüsseln (edk2-aarch64-secure-code.fd). Schalte Secure Boot aus oder hinterlege einen passenden QEMU-Build."
        case .missingSWTPM:
            return "Für das emulierte TPM fehlt swtpm. Installiere es mit „brew install swtpm“ oder schalte das TPM aus."
        case .noTPMDevice:
            return "Dieses QEMU kennt kein TPM-Gerät für ARM64."
        case .socketPathTooLong(let path):
            return "Der Pfad für die Steuer-Sockets ist zu lang: \(path)"
        case .unsupportedDiskFormat(let format):
            return "Das Plattenformat \(format) kann QEMU nicht öffnen."
        case .missingInstaller(let path):
            return "Das Installationsmedium wurde nicht gefunden: \(path)"
        }
    }
}
