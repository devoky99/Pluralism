import Foundation

/// Erzeugt die Antwortdatei (autounattend.xml) und ein Einrichtungsskript für eine
/// automatische Installation von Windows 11 ARM64.
///
/// Was die Antwortdatei erledigt:
/// - Hardwareprüfungen umgehen (TPM, Secure Boot, RAM, CPU) über die LabConfig-Schlüssel
/// - Platte 0 (die NVMe-Systemplatte) partitionieren: EFI, MSR, Windows
/// - Edition per Schlüssel auswählen, Lizenz akzeptieren
/// - Lokales Konto anlegen, Online-Konto-Seiten ausblenden, einmal automatisch anmelden
/// - Bei der ersten Anmeldung `pluralism-setup.cmd` vom Antwort-Medium ausführen
///   (Treiber per pnputil, Remote Desktop nur wenn gewünscht)
///
/// Laufwerksbuchstaben der CDs stehen vorher nicht fest. Deshalb sucht das Skript
/// alle Buchstaben von D bis Z ab, statt feste Pfade zu verwenden.
public enum UnattendBuilder {
    public struct Input: Equatable, Sendable {
        public var settings: UnattendSettings
        public var password: String
        /// Sprache des Installationsmediums (z. B. "de-DE"), falls bekannt. Nur dann setzt
        /// die Antwortdatei die Setup-Sprache, sonst fragt Setup einmal danach.
        public var mediaLanguage: String?
        public var enableRemoteDesktop: Bool

        public init(settings: UnattendSettings, password: String, mediaLanguage: String? = nil, enableRemoteDesktop: Bool = true) {
            self.settings = settings
            self.password = password
            self.mediaLanguage = mediaLanguage
            self.enableRemoteDesktop = enableRemoteDesktop
        }
    }

    public static let setupScriptName = "pluralism-setup.cmd"
    public static let driverFolderName = "pluralism-drivers"

    /// Treiberordner im virtio-win-ISO, die Pluralism für ARM64 übernimmt. Nur Geräte für
    /// Netzwerk, Speicher und Peripherie, keine Kanäle zwischen Mac und Gast.
    public static let virtioDriverFolders = ["NetKVM", "viostor", "vioscsi", "Balloon",
                                             "viorng", "vioinput", "viogpudo"]

    /// Relativer Pfad eines Treibers im virtio-win-ISO für Windows 11 ARM64.
    public static func virtioDriverPath(_ folder: String) -> String {
        "\(folder)/w11/ARM64"
    }

    // MARK: - autounattend.xml

    public static func makeAutounattendXML(_ input: Input) -> String {
        let s = input.settings
        let arch = "processorArchitecture=\"arm64\" publicKeyToken=\"31bf3856ad364e35\" language=\"neutral\" versionScope=\"nonSxS\""
        let user = sanitizedUserName(s.userName)
        let computer = sanitizedComputerName(s.computerName)
        let password = xml(input.password)
        var x = ""

        x += "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
        x += "<unattend xmlns=\"urn:schemas-microsoft-com:unattend\" xmlns:wcm=\"http://schemas.microsoft.com/WMIConfig/2002/State\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">\n"

        // windowsPE
        x += "  <settings pass=\"windowsPE\">\n"
        x += "    <component name=\"Microsoft-Windows-International-Core-WinPE\" \(arch)>\n"
        if let language = input.mediaLanguage {
            x += "      <SetupUILanguage><UILanguage>\(xml(language))</UILanguage></SetupUILanguage>\n"
            x += "      <UILanguage>\(xml(language))</UILanguage>\n"
        }
        x += "      <InputLocale>\(xml(s.inputLocale))</InputLocale>\n"
        x += "      <SystemLocale>\(xml(s.uiLanguage))</SystemLocale>\n"
        x += "      <UserLocale>\(xml(s.uiLanguage))</UserLocale>\n"
        x += "    </component>\n"
        x += "    <component name=\"Microsoft-Windows-Setup\" \(arch)>\n"
        if s.bypassHardwareChecks {
            x += "      <RunSynchronous>\n"
            let checks = ["BypassTPMCheck", "BypassSecureBootCheck", "BypassRAMCheck", "BypassCPUCheck", "BypassStorageCheck"]
            for (index, check) in checks.enumerated() {
                x += "        <RunSynchronousCommand wcm:action=\"add\">\n"
                x += "          <Order>\(index + 1)</Order>\n"
                x += "          <Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v \(check) /t REG_DWORD /d 1 /f</Path>\n"
                x += "        </RunSynchronousCommand>\n"
            }
            x += "      </RunSynchronous>\n"
        }
        x += "      <DiskConfiguration>\n"
        x += "        <Disk wcm:action=\"add\">\n"
        x += "          <DiskID>0</DiskID>\n"
        x += "          <WillWipeDisk>true</WillWipeDisk>\n"
        x += "          <CreatePartitions>\n"
        x += "            <CreatePartition wcm:action=\"add\"><Order>1</Order><Type>EFI</Type><Size>300</Size></CreatePartition>\n"
        x += "            <CreatePartition wcm:action=\"add\"><Order>2</Order><Type>MSR</Type><Size>16</Size></CreatePartition>\n"
        x += "            <CreatePartition wcm:action=\"add\"><Order>3</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>\n"
        x += "          </CreatePartitions>\n"
        x += "          <ModifyPartitions>\n"
        x += "            <ModifyPartition wcm:action=\"add\"><Order>1</Order><PartitionID>1</PartitionID><Format>FAT32</Format><Label>System</Label></ModifyPartition>\n"
        x += "            <ModifyPartition wcm:action=\"add\"><Order>2</Order><PartitionID>2</PartitionID></ModifyPartition>\n"
        x += "            <ModifyPartition wcm:action=\"add\"><Order>3</Order><PartitionID>3</PartitionID><Format>NTFS</Format><Label>Windows</Label><Letter>C</Letter></ModifyPartition>\n"
        x += "          </ModifyPartitions>\n"
        x += "        </Disk>\n"
        x += "        <WillShowUI>OnError</WillShowUI>\n"
        x += "      </DiskConfiguration>\n"
        x += "      <ImageInstall>\n"
        x += "        <OSImage>\n"
        x += "          <InstallTo><DiskID>0</DiskID><PartitionID>3</PartitionID></InstallTo>\n"
        if !s.imageName.isEmpty {
            x += "          <InstallFrom>\n"
            x += "            <MetaData wcm:action=\"add\"><Key>/IMAGE/NAME</Key><Value>\(xml(s.imageName))</Value></MetaData>\n"
            x += "          </InstallFrom>\n"
        }
        x += "          <WillShowUI>OnError</WillShowUI>\n"
        x += "        </OSImage>\n"
        x += "      </ImageInstall>\n"
        x += "      <UserData>\n"
        x += "        <AcceptEula>true</AcceptEula>\n"
        if !s.productKey.isEmpty {
            x += "        <ProductKey><Key>\(xml(s.productKey))</Key><WillShowUI>OnError</WillShowUI></ProductKey>\n"
        }
        x += "      </UserData>\n"
        x += "    </component>\n"
        x += "  </settings>\n"

        // specialize
        x += "  <settings pass=\"specialize\">\n"
        x += "    <component name=\"Microsoft-Windows-Shell-Setup\" \(arch)>\n"
        x += "      <ComputerName>\(xml(computer))</ComputerName>\n"
        x += "      <TimeZone>\(xml(s.timeZone))</TimeZone>\n"
        x += "    </component>\n"
        x += "    <component name=\"Microsoft-Windows-Deployment\" \(arch)>\n"
        x += "      <RunSynchronous>\n"
        x += "        <RunSynchronousCommand wcm:action=\"add\">\n"
        x += "          <Order>1</Order>\n"
        x += "          <Path>reg add HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\OOBE /v BypassNRO /t REG_DWORD /d 1 /f</Path>\n"
        x += "        </RunSynchronousCommand>\n"
        x += "      </RunSynchronous>\n"
        x += "    </component>\n"
        x += "  </settings>\n"

        // oobeSystem
        x += "  <settings pass=\"oobeSystem\">\n"
        x += "    <component name=\"Microsoft-Windows-International-Core\" \(arch)>\n"
        x += "      <InputLocale>\(xml(s.inputLocale))</InputLocale>\n"
        x += "      <SystemLocale>\(xml(s.uiLanguage))</SystemLocale>\n"
        if let language = input.mediaLanguage {
            x += "      <UILanguage>\(xml(language))</UILanguage>\n"
        }
        x += "      <UserLocale>\(xml(s.uiLanguage))</UserLocale>\n"
        x += "    </component>\n"
        x += "    <component name=\"Microsoft-Windows-Shell-Setup\" \(arch)>\n"
        x += "      <OOBE>\n"
        x += "        <HideEULAPage>true</HideEULAPage>\n"
        x += "        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>\n"
        x += "        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>\n"
        x += "        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>\n"
        x += "        <ProtectYourPC>3</ProtectYourPC>\n"
        x += "      </OOBE>\n"
        x += "      <UserAccounts>\n"
        x += "        <LocalAccounts>\n"
        x += "          <LocalAccount wcm:action=\"add\">\n"
        x += "            <Name>\(xml(user))</Name>\n"
        x += "            <DisplayName>\(xml(user))</DisplayName>\n"
        x += "            <Group>Administrators</Group>\n"
        x += "            <Password><Value>\(password)</Value><PlainText>true</PlainText></Password>\n"
        x += "          </LocalAccount>\n"
        x += "        </LocalAccounts>\n"
        x += "      </UserAccounts>\n"
        x += "      <AutoLogon>\n"
        x += "        <Enabled>true</Enabled>\n"
        x += "        <LogonCount>1</LogonCount>\n"
        x += "        <Username>\(xml(user))</Username>\n"
        x += "        <Password><Value>\(password)</Value><PlainText>true</PlainText></Password>\n"
        x += "      </AutoLogon>\n"
        x += "      <FirstLogonCommands>\n"
        x += "        <SynchronousCommand wcm:action=\"add\">\n"
        x += "          <Order>1</Order>\n"
        x += "          <Description>Pluralism-Einrichtung</Description>\n"
        x += "          <CommandLine>\(xml(firstLogonCommand))</CommandLine>\n"
        x += "        </SynchronousCommand>\n"
        x += "      </FirstLogonCommands>\n"
        x += "    </component>\n"
        x += "  </settings>\n"
        x += "</unattend>\n"
        return x
    }

    /// Sucht das Einrichtungsskript auf allen Laufwerken und startet es.
    public static var firstLogonCommand: String {
        "cmd.exe /c for %i in (D E F G H I J K L M N O P Q R S T U V W X Y Z) do @if exist %i:\\\(setupScriptName) call %i:\\\(setupScriptName)"
    }

    // MARK: - pluralism-setup.cmd

    public static func makeSetupScript(_ input: Input) -> String {
        var lines: [String] = []
        lines.append("@echo off")
        lines.append("rem Pluralism: Einrichtung nach der Windows-Installation")
        lines.append("set PLURALISMSRC=%~d0")
        if input.settings.installGuestDrivers {
            lines.append("echo Treiber werden installiert ...")
            lines.append("if exist \"%PLURALISMSRC%\\\(driverFolderName)\" pnputil /add-driver \"%PLURALISMSRC%\\\(driverFolderName)\\*.inf\" /subdirs /install")
        }
        if input.enableRemoteDesktop {
            lines.append("echo Remote Desktop wird eingeschaltet ...")
            lines.append("reg add \"HKLM\\SYSTEM\\CurrentControlSet\\Control\\Terminal Server\" /v fDenyTSConnections /t REG_DWORD /d 0 /f")
            lines.append("netsh advfirewall firewall set rule group=\"@FirewallAPI.dll,-28752\" new enable=Yes")
        }
        lines.append("rem Energiesparen aus: eine VM soll nicht in den Ruhezustand gehen")
        lines.append("powercfg /hibernate off")
        lines.append("powercfg /change standby-timeout-ac 0")
        lines.append("echo Pluralism-Einrichtung abgeschlossen.")
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    // MARK: - Hilfen

    /// Windows-Rechnername: höchstens 15 Zeichen, Buchstaben, Ziffern, Bindestrich.
    public static func sanitizedComputerName(_ raw: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-")
        let cleaned = String(raw.unicodeScalars.filter { allowed.contains($0) })
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let result = String(trimmed.prefix(15))
        if result.isEmpty || result.allSatisfy(\.isNumber) {
            return "PLURALISM-WIN"
        }
        return result
    }

    /// Lokaler Kontoname ohne die von Windows verbotenen Zeichen.
    public static func sanitizedUserName(_ raw: String) -> String {
        let forbidden = CharacterSet(charactersIn: "\"/\\[]:;|=,+*?<>@%")
        let cleaned = String(raw.unicodeScalars.filter { !forbidden.contains($0) && !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespaces)
        let result = String(cleaned.prefix(20))
        let reserved = ["administrator", "guest", "gast", "defaultaccount"]
        if result.isEmpty || reserved.contains(result.lowercased()) {
            return "Benutzer"
        }
        return result
    }

    /// Liest die Sprache aus `sources/lang.ini` eines Windows-ISOs.
    /// Beispiel: "[Available UI Languages]\nde-DE = 3".
    public static func parseLanguage(fromLangIni text: String) -> String? {
        var inSection = false
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inSection = line.lowercased() == "[available ui languages]"
                continue
            }
            if inSection, let eq = line.firstIndex(of: "=") {
                let code = line[..<eq].trimmingCharacters(in: .whitespaces)
                if code.count >= 5 && code.contains("-") {
                    return code
                }
            }
        }
        return nil
    }

    public static func xml(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for ch in text {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(ch)
            }
        }
        return out
    }
}
