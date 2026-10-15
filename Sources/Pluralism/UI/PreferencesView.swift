import AppKit
import PluralismCore
import SwiftUI

/// Einstellungen der App (Cmd+,).
struct PreferencesView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TabView {
            GeneralPreferences()
                .tabItem { Label("Allgemein", systemImage: "gearshape") }
            QEMUPreferences()
                .tabItem { Label("QEMU", systemImage: "shippingbox") }
            MediaPreferences(downloads: model.downloads)
                .tabItem { Label("Treiber", systemImage: "arrow.down.circle") }
        }
        .frame(width: 620, height: 460)
    }
}

private struct GeneralPreferences: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(PreferenceKeys.keyboardLayout) private var keyboardLayout = ""

    var body: some View {
        Form {
            Section("VM-Bibliothek") {
                LabeledContent("Ordner") {
                    Text(model.library.directory.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Im Finder zeigen") {
                        NSWorkspace.shared.activateFileViewerSelecting([model.library.directory])
                    }
                    Button("Anderen Ordner wählen …") {
                        if let url = FilePicker.chooseDirectory(title: "Ordner für die VMs wählen") {
                            model.setLibraryDirectory(url)
                        }
                    }
                }
                Hint("Jede VM ist ein Ordner mit der Endung .pluralismvm. Er enthält Platte, Konfiguration, Snapshots und Logs.")
            }
            Section("Tastatur (QEMU-VMs)") {
                Picker("Mac-Tastatur", selection: $keyboardLayout) {
                    Text("Automatisch erkennen").tag("")
                    Text("ISO (z. B. Deutsch)").tag("iso")
                    Text("ANSI (US)").tag("ansi")
                }
                Hint("Wichtig für die Tasten ^ und < auf deutschen Tastaturen. Gilt für neu geöffnete VM-Fenster.")
            }
            Section("Dieser Mac") {
                LabeledContent("Chip", value: model.host.chipName)
                LabeledContent("Kerne", value: "\(String(model.host.performanceCores)) Performance + \(String(model.host.efficiencyCores)) Effizienz")
                LabeledContent("Arbeitsspeicher", value: Format.memory(mib: model.host.physicalMemoryMiB))
                LabeledContent("macOS", value: "\(String(model.host.macOSMajorVersion)).\(String(model.host.macOSMinorVersion))")
                LabeledContent("Verschachtelte Virtualisierung", value: model.host.supportsNestedVirtualization ? "verfügbar" : "nicht verfügbar")
            }
        }
        .formStyle(.grouped)
    }
}

private struct QEMUPreferences: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(PreferenceKeys.qemuPathOverride) private var qemuOverride = ""

    var body: some View {
        Form {
            Section("Gefundene Werkzeuge") {
                if let report = model.toolchainReport {
                    ForEach(Array(report.lines.enumerated()), id: \.offset) { _, line in
                        LabeledContent {
                            Text(line.value)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        } label: {
                            Label(line.label, systemImage: line.ok ? "checkmark.circle.fill" : "xmark.circle")
                                .foregroundStyle(line.ok ? Color.green : Color.orange)
                        }
                    }
                } else {
                    Text("Wird geprüft …")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Neu prüfen") { model.refreshToolchain() }
                        .disabled(model.isDetectingToolchain)
                    if model.isDetectingToolchain {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                Hint("QEMU und swtpm sind in Pluralism enthalten. Ohne eigenen Pfad nutzt Pluralism die mitgelieferte Version.")
            }
            Section("Eigenes QEMU (optional)") {
                HStack {
                    TextField("Pfad zu qemu-system-aarch64", text: $qemuOverride)
                    Button("Auswählen …") {
                        if let url = FilePicker.chooseExecutable(title: "qemu-system-aarch64 wählen") {
                            qemuOverride = url.path
                            model.refreshToolchain()
                        }
                    }
                }
                Hint("Zum Beispiel ein eigener QEMU-Build mit dem Gerät tpm-crb-device für ein echtes TPM unter Windows. Leer lassen für die mitgelieferte Version.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct MediaPreferences: View {
    @ObservedObject var downloads: DownloadService
    @AppStorage(PreferenceKeys.virtioISOPath) private var virtioPath = ""

    var body: some View {
        Form {
            Section("virtio-win (Windows-Treiber)") {
                LabeledContent("Datei", value: virtioPath.isEmpty ? "keine" : virtioPath)
                DownloadButton(downloads: downloads, id: "virtio", title: "Herunterladen",
                               url: DownloadService.virtioWinURL, fileName: "virtio-win.iso") { url in
                    virtioPath = url.path
                }
            }
            Section("Windows 11 ARM64") {
                Button("Download-Seite von Microsoft öffnen") {
                    NSWorkspace.shared.open(DownloadService.windowsARMPageURL)
                }
            }
        }
        .formStyle(.grouped)
    }
}
