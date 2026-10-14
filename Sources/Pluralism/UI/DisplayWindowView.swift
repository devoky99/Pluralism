import AppKit
import PluralismCore
import SwiftUI

/// Fenster mit dem Bildschirm einer laufenden VM.
struct DisplayWindowView: View {
    @EnvironmentObject private var model: AppModel
    let vmID: UUID?

    var body: some View {
        if let vmID, let session = model.session(for: vmID) {
            DisplayContent(session: session)
        } else {
            Text("Keine virtuelle Maschine gewählt.")
                .foregroundStyle(.secondary)
                .frame(minWidth: 400, minHeight: 300)
        }
    }
}

struct DisplayContent: View {
    @ObservedObject var session: VMSession

    var body: some View {
        screen
            .frame(minWidth: 640, minHeight: 400)
            .background(Color.black)
            .navigationTitle(session.configuration.name)
            .navigationSubtitle(session.state.displayName)
            .toolbar { toolbar }
    }

    @ViewBuilder
    private var screen: some View {
        switch session.state {
        case .running, .paused, .stopping, .saving:
            if let hint = session.engine.displayHint {
                placeholder(systemImage: "macwindow.on.rectangle", text: hint)
            } else {
                VMScreen(session: session)
                    .overlay(alignment: .center) {
                        if session.state == .paused {
                            Label("Pausiert", systemImage: "pause.circle.fill")
                                .font(.title)
                                .padding(16)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
            }
        case .starting, .restoring:
            VStack(spacing: 12) {
                ProgressView()
                Text(session.state.displayName)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .stopped:
            VStack(spacing: 14) {
                Image(systemName: "power")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("Ausgeschaltet")
                    .foregroundStyle(.secondary)
                Button("Starten") { session.start() }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .error(let message):
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40))
                    .foregroundStyle(.red)
                ScrollView {
                    Text(message)
                        .textSelection(.enabled)
                        .foregroundStyle(.white)
                        .frame(maxWidth: 560)
                }
                .frame(maxHeight: 220)
                Button("Erneut starten") { session.start() }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func placeholder(systemImage: String, text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 40))
            Text(text)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            if session.state == .running {
                Button { session.pause() } label: { Label("Pause", systemImage: "pause.fill") }
                    .help("Pausieren")
            } else if session.state == .paused {
                Button { session.resume() } label: { Label("Fortsetzen", systemImage: "play.fill") }
                    .help("Fortsetzen")
            }
            if session.configuration.engine == .qemu && session.state == .running {
                Button { session.engine.sendCtrlAltDelete() } label: {
                    Label("Strg+Alt+Entf", systemImage: "keyboard")
                }
                .help("Strg+Alt+Entf an den Gast senden")
            }
            if session.state.isActive {
                Button { session.shutdown() } label: { Label("Herunterfahren", systemImage: "power") }
                    .help("Gast sauber herunterfahren")
                Button(role: .destructive) { session.forceStop() } label: {
                    Label("Ausschalten", systemImage: "bolt.slash")
                }
                .help("Sofort ausschalten")
            }
        }
    }
}

/// Bettet die Anzeige der Engine (VZVirtualMachineView oder RFBDisplayView) ein.
struct VMScreen: NSViewRepresentable {
    let session: VMSession

    func makeNSView(context: Context) -> NSView {
        session.engine.makeDisplayView() ?? NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
