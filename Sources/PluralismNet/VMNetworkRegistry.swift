import Foundation
import PluralismCore

/// Vergibt die vmnet-Netze der VMs.
///
/// Wie bei der Apple-Engine von UTM: Das Netz gehört denen, die es benutzen (Paketbrücke bzw.
/// `VZVmnetNetworkDeviceAttachment`). Die Registry merkt es sich nur schwach. Solange es noch
/// jemand hält (z. B. eine VM, die gerade beendet wird), bekommt ein neuer Start dasselbe Netz;
/// sonst entsteht ein neues mit demselben festen Bereich. Ist der Bereich belegt, wählt vmnet einen.
///
/// Nebenläufigkeit: `entries` nur unter `lock`.
public final class VMNetworkRegistry: @unchecked Sendable {
    public static let shared = VMNetworkRegistry()

    private struct Entry {
        weak var network: VMNetwork?
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    public init() {}

    /// Netz für Modus, MAC und Bereich (nil: vmnet wählt), bei Bedarf neu angelegt.
    public func network(mode: VMNetworkMode, guestMAC: String, subnet: String?) throws -> VMNetwork {
        let key = "\(mode)|\(subnet ?? "auto")|\(guestMAC.lowercased())"
        lock.lock()
        defer { lock.unlock() }
        if let existing = entries[key]?.network {
            return existing
        }
        entries = entries.filter { $0.value.network != nil }
        let network = try VMNetwork(mode: mode, guestMAC: guestMAC, subnet: subnet)
        entries[key] = Entry(network: network)
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
            let notice = "Der feste Adressbereich \(fixed) ist gerade belegt (etwa durch ein anderes Programm oder ein VPN). "
                + "Die VM bekommt diesmal eine Adresse aus \(range)."
            return (network, notice)
        }
    }
}
