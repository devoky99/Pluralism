import AppKit
import PluralismCore
import SwiftUI

/// Hauptfenster: links die VM-Liste, rechts die Details der gewählten VM.
struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 340)
        } detail: {
            if let id = model.selection, let session = model.session(for: id) {
                VMDetailView(session: session)
                    .id(id)
            } else {
                EmptyLibraryView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.showNewVMWizard = true
                } label: {
                    Label("Neue VM", systemImage: "plus")
                }
                .help("Neue virtuelle Maschine anlegen")
            }
        }
        .sheet(isPresented: $model.showNewVMWizard) {
            NewVMWizard()
                .environmentObject(model)
        }
        .alert(model.alert?.title ?? "",
               isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } }),
               presenting: model.alert) { _ in
            Button("OK", role: .cancel) {}
        } message: { item in
            Text(item.message)
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List(selection: $model.selection) {
            Section("Virtuelle Maschinen") {
                ForEach(model.configurations) { config in
                    if let session = model.session(for: config.id) {
                        SidebarRow(session: session)
                            .tag(config.id)
                            .contextMenu {
                                Button("Klonen") { model.clone(config.id) }
                                Button("Im Finder zeigen") {
                                    NSWorkspace.shared.activateFileViewerSelecting([session.bundle.url])
                                }
                                Divider()
                                Button("In den Papierkorb legen", role: .destructive) { model.delete(config.id) }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if model.configurations.isEmpty {
                Text("Noch keine VMs")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct SidebarRow: View {
    @ObservedObject var session: VMSession

    var body: some View {
        HStack(spacing: 8) {
            GuestIcon(os: session.configuration.guestOS, size: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.configuration.name)
                    .lineLimit(1)
                StatusBadge(state: session.state)
                    .font(.caption)
            }
        }
        .padding(.vertical, 2)
    }
}

struct EmptyLibraryView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Willkommen bei Pluralism")
                .font(.title2)
            Text("Linux und Windows 11 für ARM als virtuelle Maschinen auf deinem \(model.host.chipName).")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Neue virtuelle Maschine …") {
                model.showNewVMWizard = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
