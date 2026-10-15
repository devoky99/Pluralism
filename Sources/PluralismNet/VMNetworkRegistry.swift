import Foundation
import PluralismCore

/// Hält die vmnet-Netze, solange Pluralism läuft.
///
/// Geprüft auf macOS 27: Ein freigegebenes Netz gibt seinen Adressbereich erst frei, wenn der
/// Prozess endet. Ein zweites Netz mit demselben festen Bereich scheitert im selben Prozess,
/// ein Netz ohne festen Bereich bekäme bei jedem Start den nächsten Bereich. Deshalb wird das
/// Netz einer VM beim nächsten Start wiederverwendet, die Adresse bleibt gleich.
public final class VMNetworkRegistry: @unchecked Sendable {
    public static let shared = VMNetworkRegistry()

    private let lock = NSLock()
    private var networks: [String: VMNetwork] = [:]

    public init() {}

    /// Netz für Modus, MAC und Bereich (nil: vmnet wählt), bei Bedarf neu angelegt.
    public func network(mode: VMNetworkMode, guestMAC: String, subnet: String?) throws -> VMNetwork {
        let key = "\(mode)|\(subnet ?? "auto")|\(guestMAC.lowercased())"
        lock.lock()
        defer { lock.unlock() }
        if let existing = networks[key] {
            return existing
        }
        let network = try VMNetwork(mode: mode, guestMAC: guestMAC, subnet: subnet)
        networks[key] = network
        return network
    }

    /// Netz mit festem Bereich, sonst ein Bereich, den vmnet wählt. Der Hinweis erklärt den Ausweichweg.
    public func acquire(mode: VMNetworkMode, guestMAC: String, fixedHostAddress: String?) throws -> (VMNetwork, notice: String?) {
        guard let fixedHostAddress else {
            return (try network(mode: mode, guestMAC: guestMAC, subnet: nil), nil)
        }
        do {
            return (try network(mode: mode, guestMAC: guestMAC, subnet: fixedHostAddress), nil)
        } catch {
            let network = try network(mode: mode, guestMAC: guestMAC, subnet: nil)
            let fixed = VMNetwork.bytes(fixedHostAddress).map { "\($0[0]).\($0[1]).\($0[2]).0/24" } ?? fixedHostAddress
            let range = network.addressing?.description ?? "einem anderen Bereich"
            let notice = "Der feste Adressbereich \(fixed) ist gerade belegt (z. B. nach Ändern der MAC-Adresse). "
                + "Die VM bekommt diesmal eine Adresse aus \(range). Nach einem Neustart von Pluralism gilt wieder die feste Adresse."
            return (network, notice)
        }
    }
}
