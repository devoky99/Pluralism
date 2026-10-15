import AppKit
import Foundation
import PluralismCore

/// Laufzustand einer VM, wie ihn die Oberfläche anzeigt.
enum VMRunState: Equatable {
    case stopped
    case starting
    case running
    case paused
    case saving
    case restoring
    case stopping
    case error(String)

    var displayName: String {
        switch self {
        case .stopped: return "Ausgeschaltet"
        case .starting: return "Startet"
        case .running: return "Läuft"
        case .paused: return "Pausiert"
        case .saving: return "Zustand wird gesichert"
        case .restoring: return "Zustand wird geladen"
        case .stopping: return "Fährt herunter"
        case .error: return "Fehler"
        }
    }

    /// Die VM belegt gerade Ressourcen (Prozess oder VZ-Objekt existiert).
    var isActive: Bool {
        switch self {
        case .stopped, .error: return false
        default: return true
        }
    }

    var isStopped: Bool { !isActive }

    var errorMessage: String? {
        if case .error(let message) = self { return message }
        return nil
    }
}

/// Welches Netz eine laufende VM tatsächlich nutzt.
enum ActiveNetwork: Equatable {
    case none
    /// Eigenes vmnet-Netz. Adressbereich wählt vmnet, der Gast bekommt per Reservierung meist die .2.
    case vmnet(GuestNetworkAddressing?)
    /// Ausweichweg: QEMU-Usermode-Netz bzw. Apples einfaches NAT.
    case fallback

    var description: String {
        switch self {
        case .none: return "kein Netzwerk"
        case .vmnet(let addressing):
            guard let addressing else { return "vmnet" }
            if let guest = addressing.guestAddress {
                return "vmnet, Adresse \(guest)"
            }
            return "vmnet, Adresse per DHCP aus \(addressing.description)"
        case .fallback: return "Ausweich-Netz"
        }
    }

    var guestAddress: String? {
        if case .vmnet(let addressing) = self { return addressing?.guestAddress }
        return nil
    }
}

/// Gemeinsame Schnittstelle der beiden Engines.
/// Alle Methoden werden auf dem Hauptthread aufgerufen, `onStateChange` meldet ebenfalls
/// auf dem Hauptthread.
protocol VMEngine: AnyObject {
    var state: VMRunState { get }
    /// Netz der laufenden VM (für die Anzeige).
    var activeNetwork: ActiveNetwork { get }
    var onStateChange: ((VMRunState) -> Void)? { get set }
    /// Hinweise für die Oberfläche (z. B. "Gesicherter Zustand war ungültig").
    var onNotice: ((String) -> Void)? { get set }
    /// `activeNetwork` hat sich geändert (z. B. Adresse des Gasts erkannt). Hauptthread.
    var onNetworkChange: (() -> Void)? { get set }

    func start()
    /// Gast sauber herunterfahren (ACPI bzw. requestStop).
    func requestShutdown()
    /// Sofort ausschalten.
    func forceStop()
    func pause()
    func resume()

    /// Zustand sichern und VM beenden, beim nächsten Start dort weitermachen.
    var supportsSuspend: Bool { get }
    func suspend()

    /// Ansicht mit dem Bildschirm der VM. nil, wenn das Bild woanders erscheint.
    func makeDisplayView() -> NSView?
    /// Text, wenn kein eigener Bildschirm verfügbar ist.
    var displayHint: String? { get }

    /// Konfiguration übernehmen (nur im ausgeschalteten Zustand).
    func update(configuration: VMConfiguration)

    /// Strg+Alt+Entf an den Gast schicken (nur QEMU).
    func sendCtrlAltDelete()
    /// Ein Abbild (ISO) während des Betriebs als USB-Speicher anhängen (Apple-Engine, macOS 15).
    func hotPlugImage(_ url: URL, completion: @escaping (Error?) -> Void)
    var supportsHotPlug: Bool { get }

    /// Beim Beenden der App: alles sofort stoppen (keine Kindprozesse zurücklassen).
    func terminateImmediately()
}

enum PluralismError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}
