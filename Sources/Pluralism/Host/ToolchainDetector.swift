import Foundation
import PluralismCore

/// Schlüssel für die App-Einstellungen (UserDefaults).
enum PreferenceKeys {
    static let libraryPath = "libraryPath"
    static let qemuPathOverride = "qemuPathOverride"
    static let keyboardLayout = "keyboardLayout"          // "", "iso", "ansi"
    static let virtioISOPath = "virtioISOPath"
}

/// Ergebnis der Werkzeugsuche, mit verständlichen Zeilen für die Einstellungen.
struct ToolchainReport {
    var toolchain: QEMUToolchain?
    var lines: [(label: String, value: String, ok: Bool)]
}

/// Sucht QEMU, qemu-img, swtpm und die UEFI-Firmware.
enum ToolchainDetector {
    static func detect(qemuOverride: String?) -> ToolchainReport {
        let fm = FileManager.default
        var lines: [(String, String, Bool)] = []

        func findBinary(_ name: String, preferredDirectory: String? = nil) -> String? {
            var dirs = QEMUToolchainLocator.binaryDirectories
            if let preferredDirectory { dirs.insert(preferredDirectory, at: 0) }
            for dir in dirs {
                let path = (dir as NSString).appendingPathComponent(name)
                if fm.isExecutableFile(atPath: path) { return path }
            }
            return nil
        }

        var qemuPath: String?
        if let qemuOverride, !qemuOverride.isEmpty, fm.isExecutableFile(atPath: qemuOverride) {
            qemuPath = qemuOverride
        } else {
            qemuPath = findBinary("qemu-system-aarch64")
        }

        guard let qemu = qemuPath else {
            lines.append(("QEMU", "nicht gefunden (brew install qemu)", false))
            return ToolchainReport(toolchain: nil, lines: lines.map { (label: $0.0, value: $0.1, ok: $0.2) })
        }
        let qemuDir = (qemu as NSString).deletingLastPathComponent

        let versionOutput = (try? ShellCommand.run(qemu, ["-version"], timeout: 20).output) ?? ""
        let version = QEMUToolchainLocator.parseVersion(versionOutput)
        let versionText = version.map { " (" + $0 + ")" } ?? ""
        lines.append(("QEMU", qemu + versionText, true))

        let deviceOutput = (try? ShellCommand.run(qemu, ["-machine", "virt", "-device", "help"], timeout: 30).output) ?? ""
        let devices = QEMUToolchainLocator.parseDeviceHelp(deviceOutput)

        let qemuImg = findBinary("qemu-img", preferredDirectory: qemuDir)
        lines.append(("qemu-img", qemuImg ?? "nicht gefunden", qemuImg != nil))

        let swtpm = findBinary("swtpm", preferredDirectory: qemuDir)
        lines.append(("swtpm (TPM)", swtpm ?? "nicht gefunden (brew install swtpm)", swtpm != nil))

        func findFile(_ names: [String]) -> String? {
            for dir in QEMUToolchainLocator.firmwareDirectories(forQEMUBinary: qemu) {
                for name in names {
                    let path = (dir as NSString).appendingPathComponent(name)
                    if fm.fileExists(atPath: path) { return path }
                }
            }
            return nil
        }

        let code = findFile(QEMUToolchainLocator.firmwareCodeNames)
        let vars = findFile(QEMUToolchainLocator.firmwareVarsNames)
        let secureCode = findFile(QEMUToolchainLocator.secureFirmwareCodeNames)
        let secureVars = findFile(QEMUToolchainLocator.secureFirmwareVarsNames)
        lines.append(("UEFI-Firmware", code ?? "nicht gefunden", code != nil && vars != nil))
        lines.append(("Secure-Boot-Firmware", secureCode ?? "nicht vorhanden (optional)", secureCode != nil && secureVars != nil))

        let tpmDevice: String
        if devices.contains("tpm-crb-device") {
            tpmDevice = "tpm-crb-device (für Windows geeignet)"
        } else if devices.contains("tpm-tis-device") {
            tpmDevice = "tpm-tis-device (mit Windows ARM unzuverlässig)"
        } else {
            tpmDevice = devices.isEmpty ? "unbekannt" : "keins"
        }
        lines.append(("TPM-Gerät", tpmDevice, devices.contains("tpm-crb-device")))

        let toolchain = QEMUToolchain(qemuSystemPath: qemu, qemuImgPath: qemuImg, swtpmPath: swtpm,
                                      firmwareCodePath: code, firmwareVarsTemplatePath: vars,
                                      secureFirmwareCodePath: secureCode, secureFirmwareVarsTemplatePath: secureVars,
                                      devices: devices, version: version)
        return ToolchainReport(toolchain: toolchain, lines: lines.map { (label: $0.0, value: $0.1, ok: $0.2) })
    }
}
