import AppKit
import PluralismCore
import SwiftUI

/// Detailansicht einer VM: Steuerung, Übersicht, Medien, Freigaben, Snapshots.
struct VMDetailView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: VMSession
    @Environment(\.openWindow) private var openWindow

    @State private var showSettings = false
    @State private var snapshotName = ""
    @State private var confirmDelete = false
    @State private var snapshotToRestore: SnapshotInfo?
    @State private var busy = false

    private var config: VMConfiguration { session.configuration }
    private var isActive: Bool { session.state.isActive }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let notice = session.notice {
                    banner(notice, systemImage: "info.circle", color: .blue) { session.notice = nil }
                }
                if let message = session.state.errorMessage {
                    banner(message, systemImage: "exclamationmark.triangle", color: .red, onClose: nil)
                }
                controls
                overview
                mediaSection
                if config.guestOS == .windows {
                    windowsSection
                }
                isolationNote
                snapshotsSection
                if !config.notes.isEmpty {
                    GroupBox {
                        Text(config.notes)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    } label: {
                        Label("Notizen", systemImage: "note.text")
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 880, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(config.name)
        .toolbar { toolbarContent }
        .sheet(isPresented: $showSettings) {
            VMSettingsView(original: config, host: model.host, toolchain: model.toolchain) { updated in
                try saveSettings(updated)
            }
        }
        .confirmationDialog("„\(config.name)“ in den Papierkorb legen?", isPresented: $confirmDelete) {
            Button("In den Papierkorb legen", role: .destructive) {
                model.delete(session.id)
            }
        } message: {
            Text("Die VM mit Platte und Snapshots landet im Papierkorb und lässt sich von dort zurückholen.")
        }
        .confirmationDialog("Snapshot wiederherstellen?",
                            isPresented: Binding(get: { snapshotToRestore != nil },
                                                 set: { if !$0 { snapshotToRestore = nil } }),
                            presenting: snapshotToRestore) { snapshot in
            Button("Wiederherstellen", role: .destructive) {
                restore(snapshot)
            }
        } message: { snapshot in
            Text("Der aktuelle Stand wird durch „\(snapshot.name)“ ersetzt. Änderungen seit dem Snapshot gehen verloren.")
        }
    }

    // MARK: Kopf und Steuerung

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            GuestIcon(os: config.guestOS, size: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(config.name)
                    .font(.largeTitle.weight(.semibold))
                HStack(spacing: 12) {
                    StatusBadge(state: session.state)
                    Text(config.engine.displayName)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 10) {
            switch session.state {
            case .stopped, .error:
                Button {
                    startAndShow()
                } label: {
                    Label(session.hasSavedState ? "Fortsetzen" : "Starten", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                if session.hasSavedState {
                    Button("Gesicherten Zustand verwerfen") {
                        session.discardSavedState()
                    }
                }
            case .running:
                Button {
                    openWindow(id: "display", value: session.id)
                } label: {
                    Label("Fenster zeigen", systemImage: "macwindow")
                }
                .buttonStyle(.borderedProminent)
                Button { session.pause() } label: { Label("Pause", systemImage: "pause.fill") }
                if config.engine == .appleVirtualization {
                    Button { session.suspend() } label: { Label("Anhalten", systemImage: "moon.fill") }
                        .help("Zustand sichern und beenden. Beim nächsten Start geht es dort weiter.")
                }
                Button { session.shutdown() } label: { Label("Herunterfahren", systemImage: "power") }
                Button(role: .destructive) { session.forceStop() } label: { Label("Ausschalten", systemImage: "bolt.slash") }
            case .paused:
                Button { session.resume() } label: { Label("Fortsetzen", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
                if config.engine == .appleVirtualization {
                    Button { session.suspend() } label: { Label("Anhalten", systemImage: "moon.fill") }
                }
                Button(role: .destructive) { session.forceStop() } label: { Label("Ausschalten", systemImage: "bolt.slash") }
            default:
                ProgressView()
                    .controlSize(.small)
                Text(session.state.displayName)
                    .foregroundStyle(.secondary)
                Button(role: .destructive) { session.forceStop() } label: { Label("Ausschalten", systemImage: "bolt.slash") }
            }
        }
    }

    private func startAndShow() {
        session.start()
        openWindow(id: "display", value: session.id)
    }

    // MARK: Übersicht

    private var overview: some View {
        GroupBox {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                infoRow("System", config.guestOS.displayName)
                infoRow("Engine", config.engine.displayName)
                infoRow("Prozessoren", "\(config.cpuCount) virtuelle Kerne")
                infoRow("Arbeitsspeicher", Format.memory(mib: config.memoryMiB))
                infoRow("Platte", diskDescription)
                infoRow("Netzwerk", networkDescription)
                infoRow("Anzeige", displayDescription)
                if let started = config.lastStartedAt {
                    infoRow("Zuletzt gestartet", Format.date(started))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        } label: {
            Label("Übersicht", systemImage: "info.circle")
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
        }
    }

    private var diskDescription: String {
        var text = "\(config.disk.sizeGiB) GB, \(config.disk.format.displayName)"
        if config.engine == .qemu {
            text += ", \(config.guestOS == .windows ? config.disk.bus.displayName : DiskBus.virtio.displayName)"
        }
        if let used = DiskImageService.allocatedBytes(of: session.bundle.diskURL(for: config)) {
            text += ", belegt \(Format.bytes(used))"
        }
        return text
    }

    private var networkDescription: String {
        guard config.network.mode != .none else { return config.network.mode.displayName }
        var text = config.network.mode.displayName
        if session.state.isActive {
            switch session.engine.activeNetwork {
            case .vmnet(let addressing):
                if let guest = addressing?.guestAddress {
                    text += ", Adresse \(guest)"
                } else if let addressing {
                    text += ", Adresse per DHCP aus \(addressing.description)"
                }
                text += " (schnelles Netz)"
            case .fallback: text += " (Ausweich-Netz)"
            case .none: break
            }
        }
        return text
    }

    /// Ziel für Remote Desktop: im schnellen Netz direkt die VM, sonst die Weiterleitung auf localhost.
    /// Die Adresse steht erst fest, wenn die VM läuft (vmnet wählt den Bereich beim Start).
    private var remoteDesktopTarget: String? {
        guard let port = config.windows.rdpHostPort, session.state.isActive else { return nil }
        switch session.engine.activeNetwork {
        case .vmnet(let addressing): return addressing?.guestAddress
        case .fallback: return "localhost:\(port)"
        case .none: return nil
        }
    }

    private var displayDescription: String {
        switch config.engine {
        case .appleVirtualization:
            let resize = config.display.autoResize ? ", passt sich dem Fenster an" : ""
            return "virtio-gpu, \(config.display.widthPixels)×\(config.display.heightPixels)\(resize)"
        case .qemu:
            return "\(config.display.qemuDevice.displayName), \(config.display.qemuFrontend.displayName)"
        }
    }

    // MARK: Medien

    private var mediaSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if let path = config.media.installerISOPath, !path.isEmpty {
                    HStack {
                        Image(systemName: "opticaldisc")
                        Text((path as NSString).lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(path)
                        Spacer()
                        Toggle("Beim Start anhängen", isOn: Binding(
                            get: { config.media.attachInstaller },
                            set: { value in update { $0.media.attachInstaller = value } }))
                            .disabled(isActive)
                    }
                } else {
                    Text("Kein Installationsmedium gewählt.")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("ISO auswählen …") {
                        if let url = FilePicker.chooseFile(title: "Installationsmedium wählen", extensions: ["iso", "img"]) {
                            update {
                                $0.media.installerISOPath = url.path
                                $0.media.attachInstaller = true
                            }
                        }
                    }
                    .disabled(isActive)
                    if config.media.attachInstaller && config.media.installerISOPath != nil {
                        Button("Auswerfen") {
                            update { $0.media.attachInstaller = false }
                        }
                        .disabled(isActive)
                    }
                    if isActive && session.engine.supportsHotPlug {
                        Button("ISO im Betrieb einlegen …") { hotPlugISO() }
                            .disabled(busy)
                    }
                }
                if config.guestOS == .linux {
                    Hint("Nach der Installation das Medium auswerfen. Weitere ISOs lassen sich im laufenden Betrieb als USB-Laufwerk einlegen (macOS 15).")
                } else {
                    Hint("Beim ersten Start installiert sich Windows automatisch (Antwortdatei mit Treibern). Danach das Installationsmedium auswerfen.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        } label: {
            Label("Medien", systemImage: "opticaldisc")
        }
    }

    private func hotPlugISO() {
        guard let url = FilePicker.chooseFile(title: "ISO in die laufende VM einlegen", extensions: ["iso", "img"]) else { return }
        busy = true
        session.engine.hotPlugImage(url) { error in
            busy = false
            if let error {
                model.show(error, title: "Einlegen fehlgeschlagen")
            } else {
                session.notice = "„\(url.lastPathComponent)“ ist als USB-Laufwerk eingelegt."
            }
        }
    }

    // MARK: Isolation

    private var isolationNote: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Text("Diese VM ist vom Mac abgeschottet: keine gemeinsame Zwischenablage, keine geteilten Ordner, kein Kanal zwischen Mac und Gast.")
                Hint("Verbindungen nach außen nur über das Netzwerk und die Peripherie (Bildschirm, Tastatur, Maus, Ton).")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        } label: {
            Label("Isolation", systemImage: "lock.shield")
        }
    }

    // MARK: Windows

    private var windowsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if config.windows.rdpHostPort != nil {
                    HStack {
                        if let target = remoteDesktopTarget {
                            Text("Remote Desktop über \(target)")
                        } else {
                            Text("Remote Desktop: Adresse erscheint, sobald die VM läuft")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("RDP-Verbindung öffnen") {
                            if let target = remoteDesktopTarget { openRemoteDesktop(target: target) }
                        }
                        .disabled(session.state != .running || remoteDesktopTarget == nil)
                    }
                    Hint("Für die „Windows App“ von Microsoft. Die Verbindungsdatei schaltet Zwischenablage, Laufwerke und Geräte-Umleitung aus, die VM bleibt isoliert. Remote Desktop braucht Windows 11 Pro.")
                }
                HStack(spacing: 16) {
                    Text("TPM: \(config.windows.tpm.displayName)")
                    Text("Secure Boot: \(config.windows.secureBoot ? "an" : "aus")")
                }
                .foregroundStyle(.secondary)
                if session.state == .running {
                    Button("Strg+Alt+Entf senden") { session.engine.sendCtrlAltDelete() }
                }
                diskMigrationControls
                Hint("Andere Auflösungen: im Gast den virtio-gpu-Treiber (viogpudo) installieren, VM ausschalten und in den Einstellungen unter Anzeige auf virtio-gpu umstellen.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        } label: {
            Label("Windows", systemImage: "pc")
        }
    }

    @ViewBuilder
    private var diskMigrationControls: some View {
        switch (config.disk.bus, config.disk.migration) {
        case (.nvme, nil):
            HStack {
                Text("Systemplatte: NVMe (langsamer)")
                Spacer()
                Button("Auf schnelle Platte umstellen") {
                    do {
                        try session.beginVirtioMigration()
                    } catch {
                        model.show(error, title: "Umstellung nicht möglich")
                    }
                }
                .disabled(isActive)
            }
            Hint("Stellt die Systemplatte in zwei Schritten auf virtio um. Vorher legt Pluralism automatisch einen Snapshot an.")
        case (.nvme, .driverPending?):
            HStack {
                Text("Umstellung Schritt 1: Windows einmal mindestens zwei Minuten laufen lassen und herunterfahren.")
                Spacer()
                Button("Abbrechen") {
                    try? session.cancelVirtioMigration()
                }
                .disabled(isActive)
            }
        case (_, .readyToSwitch?):
            Text("Umstellung Schritt 2: Beim nächsten Start läuft die Systemplatte über virtio.")
        default:
            EmptyView()
        }
    }

    private func openRemoteDesktop(target: String) {
        let user = config.windows.unattend.userName
        var lines = [
            "full address:s:\(target)",
            "prompt for credentials:i:1",
            "screen mode id:i:1",
            "dynamic resolution:i:1",
            "smart sizing:i:1",
            "audiomode:i:0",
            // Isolation: nichts vom Mac in die VM umleiten
            "redirectclipboard:i:0",
            "redirectprinters:i:0",
            "redirectsmartcards:i:0",
            "redirectcomports:i:0",
            "redirectposdevices:i:0",
            "drivestoredirect:s:",
            "camerastoredirect:s:",
            "devicestoredirect:s:",
            "usbdevicestoredirect:s:"
        ]
        if !user.isEmpty {
            lines.append("username:s:\(UnattendBuilder.sanitizedUserName(user))")
        }
        let url = session.bundle.url.appendingPathComponent("\(config.name).rdp")
        do {
            try lines.joined(separator: "\r\n").write(to: url, atomically: true, encoding: .utf8)
            if !NSWorkspace.shared.open(url) {
                model.alert = AlertItem(title: "Keine RDP-App gefunden",
                                        message: "Installiere die „Windows App“ von Microsoft aus dem Mac App Store und versuche es erneut.")
            }
        } catch {
            model.show(error, title: "RDP-Datei konnte nicht geschrieben werden")
        }
    }

    // MARK: Snapshots

    private var snapshotsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("Name des Snapshots (optional)", text: $snapshotName)
                        .textFieldStyle(.roundedBorder)
                    Button("Snapshot erstellen") { createSnapshot() }
                        .disabled(isActive || busy)
                }
                if session.snapshots.isEmpty {
                    Text("Noch keine Snapshots.")
                        .foregroundStyle(.secondary)
                }
                ForEach(session.snapshots) { snapshot in
                    HStack {
                        Image(systemName: "clock.arrow.circlepath")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(snapshot.name)
                            Text(Format.date(snapshot.createdAt))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Wiederherstellen") { snapshotToRestore = snapshot }
                            .disabled(isActive || busy)
                        Button(role: .destructive) {
                            do {
                                try session.deleteSnapshot(snapshot)
                            } catch {
                                model.show(error, title: "Snapshot löschen fehlgeschlagen")
                            }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .disabled(busy)
                    }
                }
                Hint("Snapshots sichern Platte, UEFI-Variablen und TPM per APFS-Klon. Sie entstehen sofort und belegen nur den Platz, der sich danach ändert. Nur bei ausgeschalteter VM.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        } label: {
            Label("Snapshots", systemImage: "clock.arrow.circlepath")
        }
    }

    private func createSnapshot() {
        busy = true
        do {
            try session.createSnapshot(name: snapshotName.trimmingCharacters(in: .whitespaces))
            snapshotName = ""
        } catch {
            model.show(error, title: "Snapshot fehlgeschlagen")
        }
        busy = false
    }

    private func restore(_ snapshot: SnapshotInfo) {
        busy = true
        do {
            try session.restoreSnapshot(snapshot)
            session.notice = "„\(snapshot.name)“ wurde wiederhergestellt."
        } catch {
            model.show(error, title: "Wiederherstellen fehlgeschlagen")
        }
        busy = false
    }

    // MARK: Werkzeugleiste

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            Button {
                showSettings = true
            } label: {
                Label("Einstellungen", systemImage: "slider.horizontal.3")
            }
            .disabled(isActive)
            .help(isActive ? "Einstellungen lassen sich nur bei ausgeschalteter VM ändern." : "Einstellungen der VM")

            Menu {
                Button("Klonen") { model.clone(session.id) }
                    .disabled(isActive)
                Button("Im Finder zeigen") {
                    NSWorkspace.shared.activateFileViewerSelecting([session.bundle.url])
                }
                Button("Engine-Log öffnen") {
                    NSWorkspace.shared.open(session.bundle.engineLogURL)
                }
                Button("Serielles Log öffnen") {
                    NSWorkspace.shared.open(session.bundle.serialLogURL)
                }
                if config.engine == .qemu {
                    Button("UEFI-Variablen zurücksetzen") {
                        try? FileManager.default.removeItem(at: session.bundle.qemuEFIVariablesURL)
                        session.notice = "Die UEFI-Variablen werden beim nächsten Start neu angelegt."
                    }
                    .disabled(isActive)
                }
                Divider()
                Button("In den Papierkorb legen …", role: .destructive) { confirmDelete = true }
                    .disabled(isActive)
            } label: {
                Label("Mehr", systemImage: "ellipsis.circle")
            }
        }
    }

    // MARK: Hilfen

    private func update(_ change: (inout VMConfiguration) -> Void) {
        var updated = config
        change(&updated)
        do {
            try model.save(updated)
        } catch {
            model.show(error, title: "Änderung nicht gespeichert")
        }
    }

    private func saveSettings(_ updated: VMConfiguration) throws {
        let old = config
        // Plattengröße wachsen lassen
        if updated.disk.sizeGiB > old.disk.sizeGiB {
            try DiskImageService.grow(at: session.bundle.diskURL(for: old), toGiB: updated.disk.sizeGiB,
                                      format: old.disk.format, toolchain: model.toolchain)
        }
        // Secure Boot umgeschaltet: andere Variablen-Vorlage nötig
        if old.windows.secureBoot != updated.windows.secureBoot {
            try? FileManager.default.removeItem(at: session.bundle.qemuEFIVariablesURL)
        }
        try model.save(updated)
    }

    private func banner(_ text: String, systemImage: String, color: Color, onClose: (() -> Void)?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
            Text(text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let onClose {
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(12)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
