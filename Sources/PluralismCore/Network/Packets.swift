/// Kleine Bausteine für Ethernet-, ARP-, IPv4-, UDP-, TCP-, ICMP- und DNS-Pakete.
///
/// Damit spielt `pluralism-netcheck` einen Gast nach und prüft das Netz von Ende zu Ende:
/// Adresse per DHCP, Gateway per ARP, Namensauflösung, Verbindungen ins Internet und vom Mac
/// zur VM. Alles ohne VM und ohne Root. Adressen sind vier Bytes, MAC-Adressen sechs Bytes.
public enum Packets {
    public static let broadcastMAC: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]

    public enum IPProtocol: UInt8, Sendable {
        case icmp = 1
        case tcp = 6
        case udp = 17
    }

    // MARK: Ethernet

    public static func ethernet(destination: [UInt8], source: [UInt8], type: UInt16, payload: [UInt8]) -> [UInt8] {
        destination + source + DHCPProbe.be16(type) + payload
    }

    public static func etherType(_ frame: [UInt8]) -> UInt16? {
        guard frame.count >= 14 else { return nil }
        return UInt16(frame[12]) << 8 | UInt16(frame[13])
    }

    // MARK: ARP

    public struct ARP: Equatable, Sendable {
        public var operation: UInt16          // 1 Anfrage, 2 Antwort
        public var senderMAC: [UInt8]
        public var senderIP: [UInt8]
        public var targetMAC: [UInt8]
        public var targetIP: [UInt8]
    }

    public static func arpRequest(senderMAC: [UInt8], senderIP: [UInt8], targetIP: [UInt8]) -> [UInt8] {
        arp(operation: 1, destination: broadcastMAC, senderMAC: senderMAC, senderIP: senderIP,
            targetMAC: [0, 0, 0, 0, 0, 0], targetIP: targetIP)
    }

    public static func arpReply(senderMAC: [UInt8], senderIP: [UInt8], targetMAC: [UInt8], targetIP: [UInt8]) -> [UInt8] {
        arp(operation: 2, destination: targetMAC, senderMAC: senderMAC, senderIP: senderIP,
            targetMAC: targetMAC, targetIP: targetIP)
    }

    static func arp(operation: UInt16, destination: [UInt8], senderMAC: [UInt8], senderIP: [UInt8],
                    targetMAC: [UInt8], targetIP: [UInt8]) -> [UInt8] {
        let body: [UInt8] = [0, 1, 0x08, 0x00, 6, 4] + DHCPProbe.be16(operation) + senderMAC + senderIP + targetMAC + targetIP
        return ethernet(destination: destination, source: senderMAC, type: 0x0806, payload: body)
    }

    public static func parseARP(_ frame: [UInt8]) -> ARP? {
        guard etherType(frame) == 0x0806, frame.count >= 42 else { return nil }
        let a = 14
        guard frame[a + 4] == 6, frame[a + 5] == 4 else { return nil }
        return ARP(operation: UInt16(frame[a + 6]) << 8 | UInt16(frame[a + 7]),
                   senderMAC: Array(frame[(a + 8)..<(a + 14)]), senderIP: Array(frame[(a + 14)..<(a + 18)]),
                   targetMAC: Array(frame[(a + 18)..<(a + 24)]), targetIP: Array(frame[(a + 24)..<(a + 28)]))
    }

    // MARK: IPv4

    public struct IPv4: Equatable, Sendable {
        public var source: [UInt8]
        public var destination: [UInt8]
        public var proto: UInt8
        public var payload: [UInt8]
    }

    public static func ipv4(source: [UInt8], destination: [UInt8], proto: IPProtocol, payload: [UInt8],
                            identification: UInt16 = 0) -> [UInt8] {
        var header: [UInt8] = [0x45, 0x00] + DHCPProbe.be16(UInt16(20 + payload.count))
        header += DHCPProbe.be16(identification) + [0x40, 0x00, 64, proto.rawValue, 0, 0]
        header += source + destination
        let sum = DHCPProbe.checksum(header)
        header[10] = UInt8(sum >> 8)
        header[11] = UInt8(sum & 0xFF)
        return header + payload
    }

    /// IPv4-Paket aus einem Ethernet-Rahmen.
    public static func parseIPv4(_ frame: [UInt8]) -> IPv4? {
        guard etherType(frame) == 0x0800, frame.count >= 34, frame[14] >> 4 == 4 else { return nil }
        let headerLength = Int(frame[14] & 0x0F) * 4
        let total = Int(frame[16]) << 8 | Int(frame[17])
        guard headerLength >= 20, total >= headerLength, frame.count >= 14 + total else { return nil }
        return IPv4(source: Array(frame[26..<30]), destination: Array(frame[30..<34]), proto: frame[23],
                    payload: Array(frame[(14 + headerLength)..<(14 + total)]))
    }

    // MARK: UDP

    public static func udp(source: [UInt8], destination: [UInt8], sourcePort: UInt16, destinationPort: UInt16,
                           payload: [UInt8]) -> [UInt8] {
        let length = UInt16(8 + payload.count)
        var segment = DHCPProbe.be16(sourcePort) + DHCPProbe.be16(destinationPort) + DHCPProbe.be16(length) + [0, 0]
        segment += payload
        var sum = DHCPProbe.checksum(DHCPProbe.pseudoHeader(source: source, destination: destination, proto: 17, length: length) + segment)
        if sum == 0 { sum = 0xFFFF }
        segment[6] = UInt8(sum >> 8)
        segment[7] = UInt8(sum & 0xFF)
        return segment
    }

    public struct UDP: Equatable, Sendable {
        public var sourcePort: UInt16
        public var destinationPort: UInt16
        public var payload: [UInt8]
    }

    public static func parseUDP(_ packet: IPv4) -> UDP? {
        guard packet.proto == IPProtocol.udp.rawValue, packet.payload.count >= 8 else { return nil }
        let p = packet.payload
        let length = Int(p[4]) << 8 | Int(p[5])
        guard length >= 8, length <= p.count else { return nil }
        return UDP(sourcePort: UInt16(p[0]) << 8 | UInt16(p[1]), destinationPort: UInt16(p[2]) << 8 | UInt16(p[3]),
                   payload: Array(p[8..<length]))
    }

    // MARK: TCP

    public struct TCPFlags: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let fin = TCPFlags(rawValue: 0x01)
        public static let syn = TCPFlags(rawValue: 0x02)
        public static let rst = TCPFlags(rawValue: 0x04)
        public static let ack = TCPFlags(rawValue: 0x10)
    }

    public static func tcp(source: [UInt8], destination: [UInt8], sourcePort: UInt16, destinationPort: UInt16,
                           sequence: UInt32, acknowledgment: UInt32, flags: TCPFlags) -> [UInt8] {
        var segment = DHCPProbe.be16(sourcePort) + DHCPProbe.be16(destinationPort)
        segment += DHCPProbe.be32(sequence) + DHCPProbe.be32(acknowledgment)
        // Kopf 24 Bytes (mit MSS-Option), Fenster 64240
        segment += [0x60, flags.rawValue, 0xFA, 0xF0, 0, 0, 0, 0]
        segment += [2, 4, 0x05, 0xB4]   // MSS 1460
        let sum = DHCPProbe.checksum(DHCPProbe.pseudoHeader(source: source, destination: destination, proto: 6,
                                                            length: UInt16(segment.count)) + segment)
        segment[16] = UInt8(sum >> 8)
        segment[17] = UInt8(sum & 0xFF)
        return segment
    }

    public struct TCP: Equatable, Sendable {
        public var sourcePort: UInt16
        public var destinationPort: UInt16
        public var sequence: UInt32
        public var acknowledgment: UInt32
        public var flags: TCPFlags
    }

    public static func parseTCP(_ packet: IPv4) -> TCP? {
        guard packet.proto == IPProtocol.tcp.rawValue, packet.payload.count >= 20 else { return nil }
        let p = packet.payload
        func u32(_ i: Int) -> UInt32 {
            UInt32(p[i]) << 24 | UInt32(p[i + 1]) << 16 | UInt32(p[i + 2]) << 8 | UInt32(p[i + 3])
        }
        return TCP(sourcePort: UInt16(p[0]) << 8 | UInt16(p[1]), destinationPort: UInt16(p[2]) << 8 | UInt16(p[3]),
                   sequence: u32(4), acknowledgment: u32(8), flags: TCPFlags(rawValue: p[13] & 0x3F))
    }

    // MARK: ICMP

    public static func icmpEchoRequest(identifier: UInt16, sequence: UInt16, payload: [UInt8] = Array("pluralism".utf8)) -> [UInt8] {
        var message: [UInt8] = [8, 0, 0, 0] + DHCPProbe.be16(identifier) + DHCPProbe.be16(sequence) + payload
        let sum = DHCPProbe.checksum(message)
        message[2] = UInt8(sum >> 8)
        message[3] = UInt8(sum & 0xFF)
        return message
    }

    /// Kennung einer ICMP-Echo-Antwort, sonst nil.
    public static func icmpEchoReplyIdentifier(_ packet: IPv4) -> UInt16? {
        guard packet.proto == IPProtocol.icmp.rawValue, packet.payload.count >= 8, packet.payload[0] == 0 else { return nil }
        return UInt16(packet.payload[4]) << 8 | UInt16(packet.payload[5])
    }

    // MARK: DNS

    /// Anfrage nach dem A-Eintrag von `name`, Rekursion erwünscht.
    public static func dnsQuery(identifier: UInt16, name: String) -> [UInt8] {
        var message = DHCPProbe.be16(identifier) + [0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]
        for label in name.split(separator: ".") {
            let bytes = Array(label.utf8)
            message.append(UInt8(bytes.count))
            message += bytes
        }
        message += [0, 0, 1, 0, 1]   // Ende, Typ A, Klasse IN
        return message
    }

    public struct DNSAnswer: Equatable, Sendable {
        public var responseCode: UInt8
        public var answerCount: Int
    }

    /// Antwort auf `identifier`, sonst nil.
    public static func parseDNSResponse(_ message: [UInt8], identifier: UInt16) -> DNSAnswer? {
        guard message.count >= 12, UInt16(message[0]) << 8 | UInt16(message[1]) == identifier,
              message[2] & 0x80 != 0 else { return nil }
        return DNSAnswer(responseCode: message[3] & 0x0F, answerCount: Int(message[6]) << 8 | Int(message[7]))
    }

    // MARK: Adressen

    public static func dotted(_ bytes: [UInt8]) -> String {
        DHCPProbe.dotted(bytes)
    }
}
