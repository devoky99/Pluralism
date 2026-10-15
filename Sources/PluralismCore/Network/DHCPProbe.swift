import Foundation

/// Baut ein DHCP-Discover als komplettes Ethernet-Paket und wertet die Antwort aus.
/// Damit prüft `pluralism-netcheck`, ob ein vmnet-Netz samt Paketbrücke funktioniert,
/// ohne dass eine VM laufen muss: Der Test spielt selbst den Gast.
public enum DHCPProbe {
    public static let clientPort: UInt16 = 68
    public static let serverPort: UInt16 = 67

    public enum MessageType: UInt8, Sendable {
        case discover = 1
        case offer = 2
        case request = 3
        case ack = 5
        case nak = 6
    }

    public struct Reply: Equatable, Sendable {
        public var messageType: UInt8
        public var yourAddress: String
        public var serverAddress: String?
    }

    /// Ethernet-Rahmen mit IPv4/UDP/BOOTP-DHCPDISCOVER von `mac` (Broadcast).
    public static func discoverFrame(mac: [UInt8], transactionID: UInt32) -> [UInt8] {
        precondition(mac.count == 6, "MAC-Adresse braucht 6 Bytes")

        // BOOTP-Teil
        var bootp = [UInt8](repeating: 0, count: 236)
        bootp[0] = 1                                // op: Anfrage
        bootp[1] = 1                                // htype: Ethernet
        bootp[2] = 6                                // hlen
        bootp[3] = 0                                // hops
        bootp.replaceSubrange(4..<8, with: be32(transactionID))
        bootp[10] = 0x80                            // flags: Broadcast-Antwort erbeten
        bootp.replaceSubrange(28..<34, with: mac)   // chaddr
        bootp += [99, 130, 83, 99]                  // Magic Cookie
        bootp += [53, 1, MessageType.discover.rawValue]
        bootp += [61, 7, 1] + mac                   // Client Identifier
        bootp += [55, 3, 1, 3, 6]                   // Parameter: Maske, Router, DNS
        bootp += [255]                              // Ende
        while bootp.count < 300 { bootp.append(0) }

        // UDP
        let udpLength = UInt16(8 + bootp.count)
        var udp = be16(clientPort) + be16(serverPort) + be16(udpLength) + [0, 0]
        udp += bootp
        let source: [UInt8] = [0, 0, 0, 0]
        let destination: [UInt8] = [255, 255, 255, 255]
        var udpChecksum = checksum(pseudoHeader(source: source, destination: destination, proto: 17, length: udpLength) + udp)
        if udpChecksum == 0 { udpChecksum = 0xFFFF }   // 0 bedeutet bei UDP "keine Prüfsumme"
        udp[6] = UInt8(udpChecksum >> 8)
        udp[7] = UInt8(udpChecksum & 0xFF)

        // IPv4
        let totalLength = UInt16(20 + udp.count)
        var ip: [UInt8] = [0x45, 0x00] + be16(totalLength) + [0x00, 0x00, 0x00, 0x00, 64, 17, 0, 0]
        ip += source + destination
        let ipChecksum = checksum(ip)
        ip[10] = UInt8(ipChecksum >> 8)
        ip[11] = UInt8(ipChecksum & 0xFF)

        // Ethernet
        var frame: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF] + mac + [0x08, 0x00]
        frame += ip
        frame += udp
        return frame
    }

    /// Wertet einen Ethernet-Rahmen aus. Liefert die DHCP-Antwort, wenn der Rahmen eine
    /// BOOTP-Antwort mit passender Transaktionsnummer ist, sonst nil.
    public static func parseReply(frame: [UInt8], transactionID: UInt32) -> Reply? {
        guard frame.count >= 14 + 20 + 8 + 240 else { return nil }
        guard frame[12] == 0x08, frame[13] == 0x00 else { return nil }      // IPv4
        let ipStart = 14
        let headerLength = Int(frame[ipStart] & 0x0F) * 4
        guard frame[ipStart] >> 4 == 4, headerLength >= 20, frame[ipStart + 9] == 17 else { return nil } // UDP
        let udpStart = ipStart + headerLength
        guard frame.count >= udpStart + 8 + 240 else { return nil }
        let destinationPort = (UInt16(frame[udpStart + 2]) << 8) | UInt16(frame[udpStart + 3])
        guard destinationPort == clientPort else { return nil }
        let bootp = udpStart + 8
        guard frame[bootp] == 2 else { return nil }                          // op: Antwort
        let xid = (UInt32(frame[bootp + 4]) << 24) | (UInt32(frame[bootp + 5]) << 16)
            | (UInt32(frame[bootp + 6]) << 8) | UInt32(frame[bootp + 7])
        guard xid == transactionID else { return nil }
        let yiaddr = Array(frame[(bootp + 16)..<(bootp + 20)])
        guard Array(frame[(bootp + 236)..<(bootp + 240)]) == [99, 130, 83, 99] else { return nil }

        var messageType: UInt8 = 0
        var server: String?
        var index = bootp + 240
        while index < frame.count {
            let code = frame[index]
            if code == 255 { break }
            if code == 0 { index += 1; continue }
            guard index + 1 < frame.count else { break }
            let length = Int(frame[index + 1])
            let valueStart = index + 2
            guard valueStart + length <= frame.count else { break }
            if code == 53, length >= 1 {
                messageType = frame[valueStart]
            } else if code == 54, length == 4 {
                server = dotted(Array(frame[valueStart..<(valueStart + 4)]))
            }
            index = valueStart + length
        }
        guard messageType != 0 else { return nil }
        return Reply(messageType: messageType, yourAddress: dotted(yiaddr), serverAddress: server)
    }

    // MARK: Hilfen

    static func be16(_ value: UInt16) -> [UInt8] {
        [UInt8(value >> 8), UInt8(value & 0xFF)]
    }

    static func be32(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    static func pseudoHeader(source: [UInt8], destination: [UInt8], proto: UInt8, length: UInt16) -> [UInt8] {
        source + destination + [0, proto] + be16(length)
    }

    /// Internet-Prüfsumme (RFC 1071).
    static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i + 1 < bytes.count {
            sum += (UInt32(bytes[i]) << 8) | UInt32(bytes[i + 1])
            i += 2
        }
        if i < bytes.count {
            sum += UInt32(bytes[i]) << 8
        }
        while sum >> 16 != 0 {
            sum = (sum & 0xFFFF) + (sum >> 16)
        }
        return ~UInt16(sum)
    }

    /// "192.168.64.2" als vier Bytes.
    public static func bytes(_ dotted: String) -> [UInt8]? {
        let parts = dotted.split(separator: ".").compactMap { UInt8($0) }
        return parts.count == 4 ? parts : nil
    }

    static func dotted(_ bytes: [UInt8]) -> String {
        bytes.map(String.init).joined(separator: ".")
    }
}
