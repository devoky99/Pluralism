import PluralismCore
import SwiftUI

/// Einstellungen einer ausgeschalteten VM.
struct VMSettingsView: View {
    let original: VMConfiguration
    let host: HostProfile
    let toolchain: QEMUToolchain?
    let onSave: (VMConfiguration) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: VMConfiguration
    @State private var errorText: String?
    @State private var extraArguments: String

    init(original: VMConfiguration, host: HostProfile, toolchain: QEMUToolchain?, onSave: @escaping (VMConfiguration) throws -> Void) {
        self.original = original
        self.host = host
        self.toolchain = toolchain
        self.onSave = onSave
        _draft = State(initialValue: original)
        _extraArguments = State(initialValue: original.advanced.extraQEMUArguments.joined(separator: "\n"))
    }

    private var limits: ResourceLimits { ResourceAdvisor.limits(host: host) }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                generalSection
                hardwareSection
                displaySection
                networkSection
                integrationSection
                if draft.guestOS == .windows {
                    windowsSection
                }
                advancedSection
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if let errorText {
                    Text(errorText)
                        .foregroundStyle(.red)
                        .font(.callout)
                        .lineLimit(3)
                }
                Spacer()
                Button("Abbrechen") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Sichern") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft == original && extraArguments == original.advanced.extraQEMUArguments.joined(separator: "\n"))
            }
            .padding(16)
        }
        .frame(width: 620, height: 680)
    }

    // MARK: Abschnitte

    private var generalSection: some View {
        Section("Allgemein") {
            TextField("Name", text: $draft.name)
            if draft.guestOS == .linux {
                Picker("Engine", selection: $draft.engine) {
                    ForEach(VMEngineKind.allCases) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                .onChange(of: draft.engine) { _, newEngine in
                    if !draft.disk.format.isSupported(by: newEngine) {
                        errorText = "Das Plattenformat \(draft.disk.format.displayName) passt nicht zu dieser Engine."
                    } else {
                        errorText = nil
                    }
                }
                Hint("Apple Virtualization ist für Linux die schnellste und am besten integrierte Wahl. QEMU ist eine Ausweichmöglichkeit (z. B. für spätere 3D-Grafik).")
            }
            TextField("Notizen", text: $draft.notes, axis: .vertical)
                .lineLimit(2...5)
        }
    }

    private var hardwareSection: some View {
        Section("Prozessor, Speicher, Platte") {
            Stepper(value: $draft.cpuCount, in: 1...limits.maxCPUCount) {
                LabeledContent("Virtuelle Kerne", value: String(draft.cpuCount))
            }
            if draft.cpuCount > limits.comfortableCPUCount {
                Hint("Mehr Kerne als Performance-Kerne (\(String(host.performanceCores))) bringen selten etwas und kosten Akku.")
            }
            Stepper(value: Binding(get: { draft.memoryMiB / 1024 },
                                   set: { draft.memoryMiB = $0 * 1024 }),
                    in: 1...max(1, limits.maxMemoryMiB / 1024)) {
                LabeledContent("Arbeitsspeicher", value: "\(String(draft.memoryMiB / 1024)) GB")
            }
            Stepper(value: $draft.disk.sizeGiB, in: original.disk.sizeGiB...4096, step: 16) {
                LabeledContent("Platte", value: "\(String(draft.disk.sizeGiB)) GB")
            }
            Hint("Die Platte kann nur wachsen. Danach im Gast die Partition vergrößern.")
            Picker("Schreibcache", selection: $draft.disk.syncMode) {
                ForEach(DiskSyncMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
        }
    }

    private var displaySection: some View {
        Section("Anzeige") {
            if draft.engine == .appleVirtualization {
                Toggle("Auflösung folgt der Fenstergröße", isOn: $draft.display.autoResize)
                Stepper(value: $draft.display.widthPixels, in: 640...7680, step: 64) {
                    LabeledContent("Startbreite", value: "\(String(draft.display.widthPixels)) px")
                }
                Stepper(value: $draft.display.heightPixels, in: 480...4320, step: 60) {
                    LabeledContent("Starthöhe", value: "\(String(draft.display.heightPixels)) px")
                }
            } else {
                Picker("Grafikgerät", selection: $draft.display.qemuDevice) {
                    ForEach(QEMUDisplayDevice.allCases) { device in
                        Text(device.displayName).tag(device)
                    }
                }
                Picker("Bild anzeigen", selection: $draft.display.qemuFrontend) {
                    ForEach(QEMUDisplayFrontend.allCases) { frontend in
                        Text(frontend.displayName).tag(frontend)
                    }
                }
                Hint(draft.guestOS == .windows ? "Zwischenablage für Windows vorerst über Remote Desktop (Windows App von Microsoft)." : "„Eigenes QEMU-Fenster“ unterstützt die Zwischenablage in beide Richtungen, im Pluralism-Fenster geht Text vom Mac zum Gast.")
            }
        }
    }

    private var networkSection: some View {
        Section("Netzwerk") {
            Picker("Modus", selection: $draft.network.mode) {
                ForEach(NetworkMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            HStack {
                TextField("MAC-Adresse", text: $draft.network.macAddress)
                    .font(.system(.body, design: .monospaced))
                Button("Neu") { draft.network.macAddress = MACAddress.random() }
            }
            if !MACAddress.isValid(draft.network.macAddress) {
                Hint("Ungültige MAC-Adresse (Format 52:54:00:12:34:56).")
            }
            if draft.engine == .qemu {
                ForEach($draft.network.portForwards) { $forward in
                    HStack {
                        Picker("", selection: $forward.proto) {
                            ForEach(PortProtocol.allCases) { proto in
                                Text(proto.rawValue.uppercased()).tag(proto)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 80)
                        TextField("Mac-Port", value: $forward.hostPort, format: .number.grouping(.never))
                        Text("→")
                        TextField("Gast-Port", value: $forward.guestPort, format: .number.grouping(.never))
                        Button {
                            let id = forward.id
                            draft.network.portForwards.removeAll { $0.id == id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button("Portweiterleitung hinzufügen") {
                    draft.network.portForwards.append(PortForward(hostPort: 2222, guestPort: 22, label: "SSH"))
                }
                Hint("Weiterleitungen gelten für 127.0.0.1 auf dem Mac, z. B. ssh -p 2222 benutzer@127.0.0.1.")
            } else {
                Hint("Der Gast bekommt eine eigene Adresse im Netz 192.168.64.0/24 und ist vom Mac aus direkt erreichbar.")
            }
        }
    }

    private var integrationSection: some View {
        Section("Integration") {
            Toggle("Gemeinsame Zwischenablage", isOn: $draft.integration.clipboard)
            Toggle("Ton ausgeben", isOn: $draft.integration.audioOutput)
            if draft.engine == .appleVirtualization {
                Toggle("Mikrofon", isOn: $draft.integration.audioInput)
                Toggle("Systemkürzel an den Gast (z. B. Cmd+Tab)", isOn: $draft.integration.captureSystemKeys)
            }
        }
    }

    private var windowsSection: some View {
        Section("Windows") {
            Picker("TPM", selection: $draft.windows.tpm) {
                ForEach(TPMMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            if draft.windows.tpm == .emulated {
                if toolchain?.swtpmPath == nil {
                    Hint("swtpm fehlt: brew install swtpm")
                } else if toolchain?.supportsTPMCRB == false {
                    Hint("Dieses QEMU hat nur tpm-tis-device. Mit Windows ARM auf Apple Silicon meldet Windows dann oft „Code 10“. Ein QEMU-Build mit tpm-crb-device behebt das.")
                }
            }
            Toggle("Secure Boot", isOn: $draft.windows.secureBoot)
                .disabled(toolchain?.supportsSecureBoot != true && !draft.windows.secureBoot)
            if toolchain?.supportsSecureBoot != true {
                Hint("Für Secure Boot fehlt eine ARM64-Firmware mit Microsoft-Schlüsseln (edk2-aarch64-secure-code.fd).")
            } else {
                Hint("Beim Umschalten werden die UEFI-Variablen neu angelegt.")
            }
            Toggle("Remote Desktop weiterleiten", isOn: Binding(
                get: { draft.windows.rdpHostPort != nil },
                set: { draft.windows.rdpHostPort = $0 ? 33389 : nil }))
            if draft.windows.rdpHostPort != nil {
                TextField("Mac-Port für RDP", value: Binding(
                    get: { draft.windows.rdpHostPort ?? 33389 },
                    set: { draft.windows.rdpHostPort = $0 }), format: .number.grouping(.never))
            }
        }
    }

    private var advancedSection: some View {
        Section("Erweitert") {
            Toggle("Verschachtelte Virtualisierung", isOn: $draft.advanced.nestedVirtualization)
                .disabled(!host.supportsNestedVirtualization)
            if !host.supportsNestedVirtualization {
                Hint("Braucht einen M3-Chip oder neuer und macOS 15.")
            }
            Toggle("Speicher-Ballon (gibt freien Gastspeicher an macOS zurück)", isOn: $draft.advanced.memoryBalloon)
            Toggle("Zufallsgenerator-Gerät", isOn: $draft.advanced.entropyDevice)
            Toggle("Serielle Konsole protokollieren", isOn: $draft.advanced.serialLog)
            if draft.engine == .appleVirtualization {
                Toggle("Anhalten ermöglichen (ohne Ton-Gerät)", isOn: $draft.advanced.suspendable)
                Hint("Apples Framework kann den Zustand nur sichern, wenn bestimmte Geräte fehlen.")
            }
            if draft.engine == .qemu {
                Toggle("SME vor dem Gast verbergen", isOn: $draft.advanced.hideSME)
                Hint("Nur bei Problemen einschalten. SME ist die Matrix-Erweiterung des M4, die Parallels für KI-Lasten durchreicht.")
                VStack(alignment: .leading) {
                    Text("Zusätzliche QEMU-Argumente (eins pro Zeile)")
                    TextEditor(text: $extraArguments)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 60)
                }
            }
        }
    }

    // MARK: Sichern

    private func save() {
        var result = draft
        result.name = result.name.trimmingCharacters(in: .whitespacesAndNewlines)
        result.advanced.extraQEMUArguments = extraArguments
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if !MACAddress.isValid(result.network.macAddress) {
            errorText = "Die MAC-Adresse ist ungültig."
            return
        }
        let issues = result.validationIssues(host: host)
        if let first = issues.first {
            errorText = first
            return
        }
        do {
            try onSave(result)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
