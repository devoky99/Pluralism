import Darwin
import Foundation
import PluralismCore
import vmnet

/// Fehler beim Aufbau des Netzwerks.
public enum VMNetworkError: Error, LocalizedError, Equatable {
    case vmnet(String, Int)
    case invalidMAC(String)
    case invalidAddress(String)
    case socket(String, Int32)
    case timeout

    public var errorDescription: String? {
        switch self {
        case .vmnet(let step, let code):
            return "vmnet: \(step) fehlgeschlagen (\(VMNetworkError.describe(code)), Code \(code))."
        case .invalidMAC(let mac):
            return "Ungültige MAC-Adresse: \(mac)"
        case .invalidAddress(let address):
            return "Ungültige IP-Adresse: \(address)"
        case .socket(let step, let code):
            return "Netzwerk-Socket: \(step) fehlgeschlagen (\(String(cString: strerror(code))))."
        case .timeout:
            return "vmnet hat nicht rechtzeitig geantwortet."
        }
    }

    static func describe(_ code: Int) -> String {
        switch code {
        case 1000: return "Erfolg"
        case 1001: return "allgemeiner Fehler"
        case 1002: return "zu wenig Speicher oder fehlende Berechtigung"
        case 1003: return "ungültiger Parameter"
        case 1004: return "Einrichtung unvollständig"
        case 1005: return "Zugriff verweigert"
        case 1006: return "Paket zu groß"
        case 1007: return "Puffer erschöpft"
        case 1008: return "zu viele Pakete"
        case 1009: return "Freigabedienst belegt"
        case 1010: return "nicht berechtigt"
        default: return "unbekannt"
        }
    }
}

/// Betriebsart eines vmnet-Netzes.
public enum VMNetworkMode: Sendable {
    /// Internet und Mac (NAT nach außen).
    case shared
    /// Nur der Mac.
    case hostOnly
}

/// Ein eigenes vmnet-Netz für eine VM (macOS 26 und neuer).
///
/// Erkenntnisse aus der Prüfung auf macOS 27 (pluralism-netcheck in der CI):
/// - Ohne Root möglich, aber nur mit Entitlement `com.apple.security.virtualization`
///   (ohne Entitlement scheitert `vmnet_network_create`).
/// - Einen eigenen Adressbereich setzen bricht den Start der Schnittstelle ab. vmnet wählt den
///   Bereich deshalb selbst (meist 192.168.64.0/24 bzw. 192.168.128.0/24 für „Nur Mac“).
/// - DHCP-Reservierungen funktionieren, müssen aber vor dem Anlegen feststehen.
///
/// Daher zwei Schritte: Ein Probenetz verrät den Adressbereich, den vmnet vergeben wird, dann
/// entsteht das echte Netz mit Reservierung der zweiten Adresse (.2) für die MAC des Gasts.
/// Weicht der Bereich danach ab, bekommt der Gast seine Adresse dynamisch per DHCP.
public final class VMNetwork {
    public let ref: vmnet_network_ref
    public let mode: VMNetworkMode
    /// Tatsächliche Adressen. `guestAddress` ist nur gesetzt, wenn die Reservierung greift.
    public let addressing: GuestNetworkAddressing?

    public init(mode: VMNetworkMode, guestMAC: String, reserveAddress: Bool = true) throws {
        guard let macBytes = MACAddress.bytes(guestMAC) else {
            throw VMNetworkError.invalidMAC(guestMAC)
        }
        self.mode = mode

        var planned: GuestNetworkAddressing?
        var reservation: [UInt8]?
        if reserveAddress {
            let probe = try VMNetwork.create(mode: mode, mac: nil, address: nil)
            planned = VMNetwork.addressing(of: probe, reserveGuest: true)
            if let guest = planned?.guestAddress {
                reservation = VMNetwork.bytes(guest)
            }
        }

        let network = try VMNetwork.create(mode: mode, mac: reservation == nil ? nil : macBytes, address: reservation)
        ref = network
        let actual = VMNetwork.addressing(of: network, reserveGuest: false)
        if let actual, let planned, actual.subnet == planned.subnet, actual.prefixLength == planned.prefixLength {
            addressing = planned
        } else {
            addressing = actual
        }
    }

    /// Legt ein Netz an, optional mit Reservierung der IPv4-Adresse `address` für die MAC `mac`.
    static func create(mode: VMNetworkMode, mac: [UInt8]?, address: [UInt8]?) throws -> vmnet_network_ref {
        var status = vmnet_return_t.VMNET_SUCCESS
        let operatingMode: operating_modes_t = mode == .shared ? .VMNET_SHARED_MODE : .VMNET_HOST_MODE
        guard let configuration = vmnet_network_configuration_create(operatingMode, &status),
              status == .VMNET_SUCCESS else {
            throw VMNetworkError.vmnet("Netzkonfiguration anlegen", Int(status.rawValue))
        }
        if let mac, let address, mac.count == 6, address.count == 4 {
            var etherAddress = ether_addr_t(octet: (mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]))
            var guest = in_addr()
            withUnsafeMutableBytes(of: &guest.s_addr) { raw in
                for index in 0..<4 { raw[index] = address[index] }
            }
            status = vmnet_network_configuration_add_dhcp_reservation(configuration, &etherAddress, &guest)
            guard status == .VMNET_SUCCESS else {
                throw VMNetworkError.vmnet("DHCP-Reservierung", Int(status.rawValue))
            }
        }
        guard let network = vmnet_network_create(configuration, &status), status == .VMNET_SUCCESS else {
            throw VMNetworkError.vmnet("Netz anlegen", Int(status.rawValue))
        }
        return network
    }

    /// Adressbereich eines angelegten Netzes.
    static func addressing(of network: vmnet_network_ref, reserveGuest: Bool) -> GuestNetworkAddressing? {
        var subnet = in_addr()
        var mask = in_addr()
        vmnet_network_get_ipv4_subnet(network, &subnet, &mask)
        let subnetBytes = withUnsafeBytes(of: &subnet.s_addr) { Array($0) }
        let maskBytes = withUnsafeBytes(of: &mask.s_addr) { Array($0) }
        return GuestNetworkAddressing.from(network: subnetBytes, mask: maskBytes, reserveGuest: reserveGuest)
    }

    static func bytes(_ dotted: String) -> [UInt8]? {
        let parts = dotted.split(separator: ".").compactMap { UInt8($0) }
        return parts.count == 4 ? parts : nil
    }
}
