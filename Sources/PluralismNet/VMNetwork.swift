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
        case 1002: return "zu wenig Speicher"
        case 1003: return "ungültiger Parameter"
        case 1004: return "Einrichtung unvollständig"
        case 1005: return "Zugriff verweigert"
        case 1006: return "Paket zu groß"
        case 1007: return "Puffer erschöpft"
        case 1008: return "zu viele Pakete"
        case 1009: return "Freigabedienst belegt"
        case 1010: return "nicht berechtigt"
        default: return "Code \(code)"
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
/// Jede VM bekommt ihr eigenes /24-Netz. Der Mac ist .1, der Gast bekommt per DHCP-Reservierung
/// immer .2. Dadurch ist die VM vom Mac direkt unter einer festen Adresse erreichbar, und VMs
/// sehen sich gegenseitig nicht.
///
/// Laut Apple braucht nur ein Prozess in der Sandbox das Entitlement `com.apple.vm.networking`.
/// Pluralism läuft ohne Sandbox und ohne Root.
public final class VMNetwork {
    public let ref: vmnet_network_ref
    public let addressing: GuestNetworkAddressing
    public let mode: VMNetworkMode

    /// - Parameters:
    ///   - setSubnet: eigenen Adressbereich setzen (sonst wählt vmnet selbst, meist 192.168.64.0/24)
    ///   - reserveAddress: feste Gast-Adresse per DHCP-Reservierung
    public init(mode: VMNetworkMode, addressing: GuestNetworkAddressing, guestMAC: String,
                setSubnet: Bool = true, reserveAddress: Bool = true) throws {
        guard let macBytes = MACAddress.bytes(guestMAC) else {
            throw VMNetworkError.invalidMAC(guestMAC)
        }
        self.mode = mode
        self.addressing = addressing

        var status = vmnet_return_t.VMNET_SUCCESS
        let operatingMode: operating_modes_t = mode == .shared ? .VMNET_SHARED_MODE : .VMNET_HOST_MODE
        guard let configuration = vmnet_network_configuration_create(operatingMode, &status),
              status == .VMNET_SUCCESS else {
            throw VMNetworkError.vmnet("Netzkonfiguration anlegen", Int(status.rawValue))
        }

        if setSubnet {
            var subnet = try VMNetwork.address(addressing.subnet)
            var mask = try VMNetwork.address(addressing.mask)
            status = vmnet_network_configuration_set_ipv4_subnet(configuration, &subnet, &mask)
            guard status == .VMNET_SUCCESS else {
                throw VMNetworkError.vmnet("Adressbereich \(addressing.subnet)/24 setzen", Int(status.rawValue))
            }
        }
        if reserveAddress {
            var guestAddress = try VMNetwork.address(addressing.guestAddress)
            var mac = ether_addr_t(octet: (macBytes[0], macBytes[1], macBytes[2], macBytes[3], macBytes[4], macBytes[5]))
            status = vmnet_network_configuration_add_dhcp_reservation(configuration, &mac, &guestAddress)
            guard status == .VMNET_SUCCESS else {
                throw VMNetworkError.vmnet("DHCP-Reservierung für \(addressing.guestAddress)", Int(status.rawValue))
            }
        }

        guard let network = vmnet_network_create(configuration, &status), status == .VMNET_SUCCESS else {
            throw VMNetworkError.vmnet("Netz anlegen", Int(status.rawValue))
        }
        ref = network
    }

    static func address(_ text: String) throws -> in_addr {
        var result = in_addr()
        guard inet_pton(AF_INET, text, &result) == 1 else {
            throw VMNetworkError.invalidAddress(text)
        }
        return result
    }
}
