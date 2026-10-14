import AppKit
import SwiftUI

@main
struct PluralismApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        WindowGroup("Pluralism", id: "library") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 580)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Neue virtuelle Maschine …") {
                    model.showNewVMWizard = true
                }
                .keyboardShortcut("n", modifiers: [.command])
            }
        }

        WindowGroup("Virtuelle Maschine", id: "display", for: UUID.self) { $vmID in
            DisplayWindowView(vmID: vmID)
                .environmentObject(model)
        }
        .defaultSize(width: 1280, height: 820)

        Settings {
            PreferencesView()
                .environmentObject(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppModel.shared.hasActiveVMs else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Es laufen noch virtuelle Maschinen."
        alert.informativeText = "Beim Beenden werden sie sofort ausgeschaltet, ungesicherte Daten in den Gästen gehen verloren. Besser vorher herunterfahren."
        alert.addButton(withTitle: "Abbrechen")
        alert.addButton(withTitle: "Trotzdem beenden")
        alert.alertStyle = .warning
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.terminateAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
