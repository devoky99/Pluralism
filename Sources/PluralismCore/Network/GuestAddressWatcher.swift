/// Erkennt die IPv4-Adresse des Gasts an seinen eigenen Rahmen (IPv4-Absender oder ARP).
///
/// Pluralism hat keinen Gastagenten (Isolation). Die Paketbrücke sieht aber jeden Rahmen,
/// den der Gast sendet, und kann daran ablesen, welche Adresse er tatsächlich benutzt.
/// Das funktioniert mit DHCP genauso wie mit einer fest eingetragenen Adresse.
public struct GuestAddressWatcher: Sendable {
    /// Nur Adressen aus diesem Bereich zählen (z. B. keine 169.254.x.x vor dem DHCP).
    public let network: UInt32
    public let mask: UInt32
    public private(set) var current: UInt32 = 0

    public init(network: [UInt8], mask: [UInt8]) {
        self.network = GuestAddressWatcher.number(network)
        self.mask = GuestAddressWatcher.number(mask)
    }

    /// Prüft einen Rahmen vom Gast. Liefert die Adresse, wenn sie neu ist.
    public mutating func observe(_ frame: UnsafeRawBufferPointer) -> String? {
        guard let address = GuestAddressWatcher.senderIPv4(frame), address != current,
              address & mask == network & mask,
              address & ~mask != 0, address | mask != UInt32.max else { return nil }
        current = address
        return GuestAddressWatcher.dotted(address)
    }

    /// IPv4-Absender eines Ethernet-Rahmens (IPv4 oder ARP), sonst nil.
    public static func senderIPv4(_ frame: UnsafeRawBufferPointer) -> UInt32? {
        guard frame.count >= 34 else { return nil }
        let type = UInt16(frame[12]) << 8 | UInt16(frame[13])
        let offset: Int
        switch type {
        case 0x0800:
            guard frame[14] >> 4 == 4 else { return nil }
            offset = 26
        case 0x0806:
            guard frame.count >= 42 else { return nil }
            offset = 28
        default:
            return nil
        }
        let high = UInt32(frame[offset]) << 24 | UInt32(frame[offset + 1]) << 16
        let address = high | UInt32(frame[offset + 2]) << 8 | UInt32(frame[offset + 3])
        return address == 0 ? nil : address
    }

    static func number(_ bytes: [UInt8]) -> UInt32 {
        guard bytes.count == 4 else { return 0 }
        return UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
    }

    static func dotted(_ value: UInt32) -> String {
        "\(value >> 24).\((value >> 16) & 0xFF).\((value >> 8) & 0xFF).\(value & 0xFF)"
    }
}
