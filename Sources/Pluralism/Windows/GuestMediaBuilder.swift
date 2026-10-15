import Foundation
import PluralismCore

/// Baut das Installationshilfe-Medium für Windows (unattend.iso): Antwortdatei,
/// Einrichtungsskript und ARM64-Treiber für Netzwerk, Speicher und Peripherie.
enum GuestMediaBuilder {
    struct WindowsResult {
        var detectedLanguage: String?
        var copiedDrivers: [String]
    }

    /// Erstellt das Antwort-Medium für eine automatische Windows-Installation.
    /// Das Passwort landet nur in diesem ISO, nicht in config.json.
    static func buildWindowsSetupMedia(bundle: VMBundle,
                                       settings: UnattendSettings,
                                       password: String,
                                       enableRemoteDesktop: Bool,
                                       windowsISO: URL?,
                                       virtioISO: URL?) throws -> WindowsResult {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("pluralism-setup-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        // Sprache des Windows-Mediums lesen, damit die Antwortdatei dazu passt.
        var language: String?
        if let windowsISO, fm.fileExists(atPath: windowsISO.path) {
            if let mount = try? ISOBuilder.attach(windowsISO) {
                defer { ISOBuilder.detach(mount) }
                let langIni = mount.appendingPathComponent("sources/lang.ini")
                var text = try? String(contentsOf: langIni, encoding: .utf8)
                if text == nil {
                    text = try? String(contentsOf: langIni, encoding: .utf16)
                }
                if let text {
                    language = UnattendBuilder.parseLanguage(fromLangIni: text)
                }
            }
        }

        // ARM64-Treiber aus dem virtio-win-ISO übernehmen.
        var copied: [String] = []
        if let virtioISO, fm.fileExists(atPath: virtioISO.path) {
            let mount = try ISOBuilder.attach(virtioISO)
            defer { ISOBuilder.detach(mount) }
            let driverRoot = staging.appendingPathComponent(UnattendBuilder.driverFolderName, isDirectory: true)
            try fm.createDirectory(at: driverRoot, withIntermediateDirectories: true)
            let winPERoot = staging.appendingPathComponent(UnattendBuilder.winPEDriverFolderName, isDirectory: true)
            try fm.createDirectory(at: winPERoot, withIntermediateDirectories: true)
            for folder in UnattendBuilder.virtioDriverFolders {
                let source = mount.appendingPathComponent(UnattendBuilder.virtioDriverPath(folder), isDirectory: true)
                guard fm.fileExists(atPath: source.path) else { continue }
                try fm.copyItem(at: source, to: driverRoot.appendingPathComponent(folder, isDirectory: true))
                if UnattendBuilder.winPEDriverFolders.contains(folder) {
                    try fm.copyItem(at: source, to: winPERoot.appendingPathComponent(folder, isDirectory: true))
                }
                copied.append(folder)
            }
        }

        let input = UnattendBuilder.Input(settings: settings, password: password,
                                          mediaLanguage: language, enableRemoteDesktop: enableRemoteDesktop)
        try UnattendBuilder.makeAutounattendXML(input)
            .write(to: staging.appendingPathComponent("autounattend.xml"), atomically: true, encoding: .utf8)
        try UnattendBuilder.makeSetupScript(input)
            .write(to: staging.appendingPathComponent(UnattendBuilder.setupScriptName), atomically: true, encoding: .utf8)
        try readme(drivers: copied)
            .write(to: staging.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)

        try ISOBuilder.makeISO(from: staging, volumeName: "PLURALISM_SETUP", output: bundle.unattendISOURL)
        return WindowsResult(detectedLanguage: language, copiedDrivers: copied)
    }


    private static func readme(drivers: [String]) -> String {
        var text = "Pluralism Windows-Einrichtung\r\n=============================\r\n\r\n"
        text += "Dieses Medium enthält die Antwortdatei (autounattend.xml) für die automatische\r\n"
        text += "Installation und das Skript \(UnattendBuilder.setupScriptName), das nach der ersten\r\n"
        text += "Anmeldung Treiber und Remote Desktop einrichtet.\r\n\r\n"
        if drivers.isEmpty {
            text += "Es wurden keine virtio-Treiber kopiert. Ohne NetKVM hat Windows kein Netzwerk.\r\n"
        } else {
            text += "Enthaltene ARM64-Treiber: \(drivers.joined(separator: ", "))\r\n"
        }
        return text
    }
}
