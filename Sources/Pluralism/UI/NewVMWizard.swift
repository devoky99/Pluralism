import AppKit
import PluralismCore
import SwiftUI

/// Assistent für neue VMs: System wählen, Medium, Ressourcen, Zusammenfassung.
struct NewVMWizard: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var step = 0
    @State private var os: GuestOS = .linux
    @State private var name = "Linux"
    @State private var installerPath = ""
    @State private var virtioPath = UserDefaults.standard.string(forKey: PreferenceKeys.virtioISOPath) ?? ""
    @State private var unattend = UnattendSettings(userName: NSUserName())
    @State private var password = ""
    @State private var regionID = "de-DE"
    @State private var cpuCount = 4
    @State private var memoryGiB = 8
    @State private var diskGiB = 64
    @State private var engine: VMEngineKind = .appleVirtualization
    @State private var appleDiskFormat: DiskFormat = .raw
    @State private var creating = false
    @State private var errorText: String?

    private let stepTitles = ["System", "Medium", "Ressourcen", "Übersicht"]

    var body: some View {
        VStack(spacing: 0) {
            stepIndicator
                .padding(.top, 18)
                .padding(.bottom, 8)
            Divider()
            Group {
                switch step {
                case 0: systemStep
                case 1: mediaStep
                case 2: resourcesStep
                default: summaryStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            footer
                .padding(16)
        }
        .frame(width: 640, height: 600)
        .onAppear { applyRecommendations() }
    }

    // MARK: Kopf und Fuß

    private var stepIndicator: some View {
        HStack(spacing: 18) {
            ForEach(Array(stepTitles.enumerated()), id: \.offset) { index, title in
                HStack(spacing: 6) {
                    Text(String(index + 1))
                        .font(.caption.bold())
                        .frame(width: 20, height: 20)
                        .background(index <= step ? Color.accentColor : Color.secondary.opacity(0.25), in: Circle())
                        .foregroundStyle(index <= step ? Color.white : Color.primary)
                    Text(title)
                        .foregroundStyle(index == step ? Color.primary : Color.secondary)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if let errorText {
                Text(errorText)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .lineLimit(3)
            }
            Spacer()
            if creating {
                ProgressView()
                    .controlSize(.small)
                Text("Wird angelegt …")
                    .foregroundStyle(.secondary)
            }
            Button("Abbrechen") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(creating)
            if step > 0 {
                Button("Zurück") {
                    errorText = nil
                    step -= 1
                }
                .disabled(creating)
            }
            if step < stepTitles.count - 1 {
                Button("Weiter") { next() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("VM anlegen") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(creating)
            }
        }
    }

    // MARK: Schritt 1: System

    private var systemStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Welches System soll laufen?")
                .font(.title2.weight(.semibold))
            HStack(spacing: 16) {
                osCard(.linux, title: "Linux", subtitle: "Fedora, Ubuntu, Debian, Arch …\nApple Virtualization, sehr schnell")
                osCard(.windows, title: "Windows 11", subtitle: "ARM64-Version\nQEMU mit Hypervisor.framework")
            }
            TextField("Name der VM", text: $name)
                .textFieldStyle(.roundedBorder)
            Hint("Pluralism unterstützt nur ARM64-Gäste. x86-Systeme laufen nicht.")
            if os == .windows && model.toolchain == nil {
                Label("QEMU fehlt noch. Im Terminal: brew install qemu swtpm. Danach in den Einstellungen von Pluralism „Neu prüfen“.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
        .padding(24)
    }

    private func osCard(_ value: GuestOS, title: String, subtitle: String) -> some View {
        Button {
            if os != value {
                os = value
                name = value == .windows ? "Windows 11" : "Linux"
                applyRecommendations()
            }
        } label: {
            VStack(spacing: 10) {
                GuestIcon(os: value, size: 34)
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 150)
            .background(os == value ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .stroke(os == value ? Color.accentColor : Color.clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }

    // MARK: Schritt 2: Medium

    private var mediaStep: some View {
        Form {
            Section("Installationsmedium") {
                HStack {
                    TextField("ISO-Datei", text: $installerPath)
                    Button("Auswählen …") {
                        if let url = FilePicker.chooseFile(title: "Installations-ISO wählen", extensions: ["iso", "img"]) {
                            installerPath = url.path
                        }
                    }
                }
                if os == .windows {
                    HStack {
                        Hint("Das offizielle ARM64-ISO gibt es bei Microsoft. Eine Lizenz für Windows 11 Pro wird benötigt.")
                        Spacer()
                        Button("Download-Seite öffnen") {
                            NSWorkspace.shared.open(DownloadService.windowsARMPageURL)
                        }
                    }
                } else {
                    Hint("Wichtig: die ARM64- bzw. aarch64-Version der Distribution nehmen (z. B. Fedora Workstation aarch64, Ubuntu Desktop arm64).")
                }
            }
            if os == .windows {
                Section("Treiber (virtio-win)") {
                    HStack {
                        TextField("virtio-win.iso", text: $virtioPath)
                        Button("Auswählen …") {
                            if let url = FilePicker.chooseFile(title: "virtio-win-ISO wählen", extensions: ["iso"]) {
                                virtioPath = url.path
                                UserDefaults.standard.set(url.path, forKey: PreferenceKeys.virtioISOPath)
                            }
                        }
                    }
                    DownloadButton(downloads: model.downloads, id: "virtio", title: "virtio-win herunterladen (ca. 700 MB)",
                                   url: DownloadService.virtioWinURL, fileName: "virtio-win.iso") { url in
                        virtioPath = url.path
                        UserDefaults.standard.set(url.path, forKey: PreferenceKeys.virtioISOPath)
                    }
                    Hint("Enthält die ARM64-Treiber für Netzwerk (NetKVM), Anzeige, Ballon und mehr. Pluralism kopiert sie in die Antwortdatei.")
                }
                Section("Automatische Installation") {
                    Toggle("Windows automatisch installieren", isOn: $unattend.enabled)
                    if unattend.enabled {
                        TextField("Benutzername", text: $unattend.userName)
                        SecureField("Passwort (darf leer sein)", text: $password)
                        TextField("Rechnername", text: $unattend.computerName)
                        Picker("Sprache und Tastatur", selection: $regionID) {
                            ForEach(UnattendSettings.regionPresets) { preset in
                                Text(preset.title).tag(preset.id)
                            }
                        }
                        TextField("Edition", text: $unattend.imageName)
                        TextField("Produktschlüssel", text: $unattend.productKey)
                            .font(.system(.body, design: .monospaced))
                        Hint("Der Standardschlüssel wählt nur die Edition Pro aus und aktiviert nicht. Den eigenen Schlüssel später in Windows eingeben. Das Passwort wird nur in das Installationsmedium geschrieben, nicht in die Konfiguration.")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Schritt 3: Ressourcen

    private var resourcesStep: some View {
        let limits = ResourceAdvisor.limits(host: model.host)
        return Form {
            Section("Dein Mac") {
                LabeledContent("Chip", value: model.host.chipName)
                LabeledContent("Kerne", value: "\(String(model.host.performanceCores)) Performance + \(String(model.host.efficiencyCores)) Effizienz")
                LabeledContent("Arbeitsspeicher", value: Format.memory(mib: model.host.physicalMemoryMiB))
            }
            Section("Virtuelle Maschine") {
                Stepper(value: $cpuCount, in: (os == .windows ? 2 : 1)...limits.maxCPUCount) {
                    LabeledContent("Virtuelle Kerne", value: String(cpuCount))
                }
                Stepper(value: $memoryGiB, in: (os == .windows ? 4 : 1)...max(4, limits.maxMemoryMiB / 1024)) {
                    LabeledContent("Arbeitsspeicher", value: "\(String(memoryGiB)) GB")
                }
                Stepper(value: $diskGiB, in: (os == .windows ? 64 : 16)...2048, step: 16) {
                    LabeledContent("Platte", value: "\(String(diskGiB)) GB")
                }
                Hint("Die Platte ist dünn belegt: sie belegt auf dem Mac nur, was der Gast wirklich schreibt.")
                if os == .linux {
                    Picker("Engine", selection: $engine) {
                        ForEach(VMEngineKind.allCases) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    if engine == .appleVirtualization && model.host.macOSMajorVersion >= 26 {
                        Picker("Plattenformat", selection: $appleDiskFormat) {
                            Text(DiskFormat.raw.displayName).tag(DiskFormat.raw)
                            Text(DiskFormat.asif.displayName).tag(DiskFormat.asif)
                        }
                        Hint("ASIF ist Apples neues Format: bleibt auch beim Kopieren auf andere Datenträger klein.")
                    }
                }
                Button("Empfehlung übernehmen") { applyRecommendations(keepEngine: true) }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Schritt 4: Übersicht

    private var summaryStep: some View {
        Form {
            Section("Zusammenfassung") {
                LabeledContent("Name", value: name)
                LabeledContent("System", value: os.displayName)
                LabeledContent("Engine", value: (os == .windows ? VMEngineKind.qemu : engine).displayName)
                LabeledContent("Kerne", value: String(cpuCount))
                LabeledContent("Arbeitsspeicher", value: "\(String(memoryGiB)) GB")
                LabeledContent("Platte", value: "\(String(diskGiB)) GB")
                LabeledContent("Medium", value: installerPath.isEmpty ? "keins" : (installerPath as NSString).lastPathComponent)
                if os == .windows {
                    LabeledContent("Treiber", value: virtioPath.isEmpty ? "keine (kein Netzwerk!)" : (virtioPath as NSString).lastPathComponent)
                    LabeledContent("Automatische Installation", value: unattend.enabled ? "ja, Benutzer \(unattend.userName)" : "nein")
                }
            }
            Section {
                Hint(os == .windows
                     ? "Nach dem Anlegen startet die Installation mit „Starten“. Windows richtet sich selbst ein und startet dabei mehrmals neu. Das dauert etwa 15 bis 30 Minuten."
                     : "Nach dem Anlegen startet die VM vom ISO. Nach der Installation das Medium auswerfen.")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Logik

    private func applyRecommendations(keepEngine: Bool = false) {
        let rec = ResourceAdvisor.recommend(for: os, host: model.host)
        cpuCount = rec.cpuCount
        memoryGiB = max(1, rec.memoryMiB / 1024)
        diskGiB = rec.diskGiB
        if !keepEngine {
            engine = os.defaultEngine
        }
        if let preset = UnattendSettings.regionPresets.first(where: { $0.id == regionID }) {
            unattend.apply(preset)
        }
    }

    private func next() {
        errorText = nil
        switch step {
        case 0:
            if name.trimmingCharacters(in: .whitespaces).isEmpty {
                errorText = "Bitte einen Namen eingeben."
                return
            }
        case 1:
            if !installerPath.isEmpty && !FileManager.default.fileExists(atPath: installerPath) {
                errorText = "Die ISO-Datei wurde nicht gefunden."
                return
            }
            if os == .windows && installerPath.isEmpty {
                errorText = "Für Windows wird das ARM64-ISO gebraucht."
                return
            }
            if os == .windows && unattend.enabled && unattend.userName.trimmingCharacters(in: .whitespaces).isEmpty {
                errorText = "Bitte einen Benutzernamen für Windows eingeben."
                return
            }
            if let preset = UnattendSettings.regionPresets.first(where: { $0.id == regionID }) {
                unattend.apply(preset)
            }
        default:
            break
        }
        step += 1
    }


    private func create() {
        errorText = nil
        var config = VMConfiguration.makeDefault(name: name.trimmingCharacters(in: .whitespaces), guestOS: os, host: model.host)
        config.engine = os == .windows ? .qemu : engine
        config.cpuCount = cpuCount
        config.memoryMiB = memoryGiB * 1024
        let format: DiskFormat = config.engine == .qemu ? .qcow2 : appleDiskFormat
        config.disk = DiskSettings(sizeGiB: diskGiB, format: format)
        config.media.installerISOPath = installerPath.isEmpty ? nil : installerPath
        config.media.attachInstaller = !installerPath.isEmpty
        if os == .windows {
            config.media.driverISOPath = virtioPath.isEmpty ? nil : virtioPath
            config.windows.unattend = unattend
        }

        let issues = config.validationIssues(host: model.host)
        if let first = issues.first {
            errorText = first
            return
        }
        if config.engine == .qemu && model.toolchain == nil {
            errorText = "QEMU wurde nicht gefunden (brew install qemu swtpm)."
            return
        }

        func existingURL(_ path: String) -> URL? {
            path.isEmpty || !FileManager.default.fileExists(atPath: path) ? nil : URL(fileURLWithPath: path)
        }

        creating = true
        let request = AppModel.NewVMRequest(configuration: config,
                                            password: password,
                                            windowsISO: existingURL(installerPath),
                                            virtioISO: existingURL(virtioPath))
        model.createVM(request) { result in
            creating = false
            switch result {
            case .success:
                dismiss()
            case .failure(let error):
                errorText = error.localizedDescription
            }
        }
    }
}

/// Download-Knopf mit Fortschrittsanzeige.
struct DownloadButton: View {
    @ObservedObject var downloads: DownloadService
    let id: String
    let title: String
    let url: URL
    let fileName: String
    let onFinished: (URL) -> Void

    var body: some View {
        if let progress = downloads.progress[id] {
            HStack {
                ProgressView(value: progress)
                    .frame(width: 180)
                Text("\(Int(progress * 100)) %")
                    .monospacedDigit()
                Button("Abbrechen") { downloads.cancel(id) }
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Button(title) {
                    downloads.download(id: id, from: url, fileName: fileName, completion: onFinished)
                }
                if let error = downloads.errors[id] {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }
}
