/// Feste Adressbereiche für die eigenen Netze der VMs.
///
/// Jede VM bekommt einen Platz (0 bis 39) und damit je Modus ein eigenes /24:
/// „Internet und Mac“ 192.168.(160 + Platz).0/24, „Nur Mac“ 192.168.(200 + Platz).0/24.
/// Der Mac ist .1, die VM per DHCP-Reservierung .2. Die Bereiche liegen außerhalb der Bereiche,
/// die vmnet selbst vergibt (ab 192.168.64 bzw. 192.168.128), und außerhalb typischer Heimnetze.
///
/// Geprüft auf macOS 27: vmnet nimmt einen eigenen Bereich nur an, wenn die Adresse des Macs (.1)
/// übergeben wird. Mit der Netzadresse (.0) lässt sich die Schnittstelle nicht starten.
public enum FixedSubnet {
    public static let slots = 0...39
    static let sharedBase = 160
    static let hostOnlyBase = 200

    /// Dritter Teil der Adresse für Platz und Modus, nil ohne Netz.
    public static func thirdOctet(slot: Int, mode: NetworkMode) -> Int? {
        guard slots.contains(slot) else { return nil }
        switch mode {
        case .nat: return sharedBase + slot
        case .hostOnly: return hostOnlyBase + slot
        case .none: return nil
        }
    }

    /// Adresse des Macs im Netz, so wie vmnet sie für den Bereich erwartet.
    public static func hostAddress(slot: Int?, mode: NetworkMode) -> String? {
        guard let slot, let octet = thirdOctet(slot: slot, mode: mode) else { return nil }
        return "192.168.\(octet).1"
    }

    /// Geplante Adressen der VM.
    public static func addressing(slot: Int?, mode: NetworkMode) -> GuestNetworkAddressing? {
        guard let slot, let octet = thirdOctet(slot: slot, mode: mode) else { return nil }
        return GuestNetworkAddressing(subnet: "192.168.\(octet).0", prefixLength: 24,
                                      hostAddress: "192.168.\(octet).1", guestAddress: "192.168.\(octet).2")
    }

    /// Kleinster freier Platz, nil wenn alle vergeben sind.
    public static func allocate(used: Set<Int>) -> Int? {
        slots.first { !used.contains($0) }
    }
}
