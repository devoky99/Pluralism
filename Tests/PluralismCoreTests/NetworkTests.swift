import Foundation
@testable import PluralismCore
import XCTest

final class NetworkTests: XCTestCase {
    let mac: [UInt8] = [0x52, 0x54, 0x00, 0xAA, 0xBB, 0xCC]

    func testDiscoverFrameLayout() {
        let frame = DHCPProbe.discoverFrame(mac: mac, transactionID: 0x1234_5678)
        // Ethernet: Broadcast-Ziel, eigene MAC als Quelle, IPv4
        XCTAssertEqual(Array(frame[0..<6]), [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertEqual(Array(frame[6..<12]), mac)
        XCTAssertEqual(Array(frame[12..<14]), [0x08, 0x00])
        // IPv4-Kopf: Version 4, 20 Bytes, UDP, 0.0.0.0 -> 255.255.255.255
        let ip = Array(frame[14..<34])
        XCTAssertEqual(ip[0], 0x45)
        XCTAssertEqual(ip[9], 17)
        XCTAssertEqual(Array(ip[12..<16]), [0, 0, 0, 0])
        XCTAssertEqual(Array(ip[16..<20]), [255, 255, 255, 255])
        XCTAssertEqual(Int(ip[2]) << 8 | Int(ip[3]), frame.count - 14)
        // Prüfsumme über den IPv4-Kopf ergibt 0
        XCTAssertEqual(DHCPProbe.checksum(ip), 0)
        // UDP 68 -> 67
        let udp = Array(frame[34...])
        XCTAssertEqual(Int(udp[0]) << 8 | Int(udp[1]), 68)
        XCTAssertEqual(Int(udp[2]) << 8 | Int(udp[3]), 67)
        XCTAssertEqual(Int(udp[4]) << 8 | Int(udp[5]), udp.count)
        let pseudo = DHCPProbe.pseudoHeader(source: [0, 0, 0, 0], destination: [255, 255, 255, 255],
                                            proto: 17, length: UInt16(udp.count))
        XCTAssertEqual(DHCPProbe.checksum(pseudo + udp), 0)
        // BOOTP: Anfrage, Transaktion, Client-MAC, Magic Cookie, DHCPDISCOVER
        let bootp = Array(udp[8...])
        XCTAssertEqual(bootp[0], 1)
        XCTAssertEqual(Array(bootp[4..<8]), [0x12, 0x34, 0x56, 0x78])
        XCTAssertEqual(Array(bootp[28..<34]), mac)
        XCTAssertEqual(Array(bootp[236..<240]), [99, 130, 83, 99])
        XCTAssertEqual(Array(bootp[240..<243]), [53, 1, 1])
        XCTAssertGreaterThanOrEqual(bootp.count, 300)
    }

    /// Baut eine Antwort, wie sie ein DHCP-Server schicken würde.
    func makeOffer(transactionID: UInt32, yourAddress: [UInt8], server: [UInt8], type: UInt8 = 2) -> [UInt8] {
        var bootp = [UInt8](repeating: 0, count: 236)
        bootp[0] = 2
        bootp[1] = 1
        bootp[2] = 6
        bootp.replaceSubrange(4..<8, with: DHCPProbe.be32(transactionID))
        bootp.replaceSubrange(16..<20, with: yourAddress)
        bootp.replaceSubrange(28..<34, with: mac)
        bootp += [99, 130, 83, 99, 53, 1, type, 54, 4] + server + [1, 4, 255, 255, 255, 0, 255]
        var udp = DHCPProbe.be16(67) + DHCPProbe.be16(68) + DHCPProbe.be16(UInt16(8 + bootp.count)) + [0, 0]
        udp += bootp
        var ip: [UInt8] = [0x45, 0] + DHCPProbe.be16(UInt16(20 + udp.count)) + [0, 0, 0, 0, 64, 17, 0, 0]
        ip += server + [255, 255, 255, 255]
        return [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x02, 0, 0, 0, 0, 1, 0x08, 0x00] + ip + udp
    }

    func testParseOffer() {
        let frame = makeOffer(transactionID: 42, yourAddress: [192, 168, 150, 2], server: [192, 168, 150, 1])
        let reply = DHCPProbe.parseReply(frame: frame, transactionID: 42)
        XCTAssertEqual(reply, DHCPProbe.Reply(messageType: 2, yourAddress: "192.168.150.2", serverAddress: "192.168.150.1"))
    }

    func testParseRejectsOtherTraffic() {
        let frame = makeOffer(transactionID: 42, yourAddress: [192, 168, 150, 2], server: [192, 168, 150, 1])
        XCTAssertNil(DHCPProbe.parseReply(frame: frame, transactionID: 43))          // fremde Transaktion
        XCTAssertNil(DHCPProbe.parseReply(frame: Array(frame.prefix(100)), transactionID: 42))
        var arp = frame
        arp[12] = 0x08
        arp[13] = 0x06
        XCTAssertNil(DHCPProbe.parseReply(frame: arp, transactionID: 42))
        // Das eigene Discover ist keine Antwort
        XCTAssertNil(DHCPProbe.parseReply(frame: DHCPProbe.discoverFrame(mac: mac, transactionID: 42), transactionID: 42))
    }

    func testChecksumKnownValue() {
        // Beispiel aus RFC 1071, Abschnitt 3
        let bytes: [UInt8] = [0x00, 0x01, 0xF2, 0x03, 0xF4, 0xF5, 0xF6, 0xF7]
        XCTAssertEqual(DHCPProbe.checksum(bytes), ~UInt16(0xDDF2))
    }

    // MARK: Adresse des Gasts erkennen

    func ipv4Frame(source: [UInt8]) -> [UInt8] {
        var ip: [UInt8] = [0x45, 0, 0, 20, 0, 0, 0, 0, 64, 6, 0, 0]
        ip += source + [192, 168, 64, 1]
        return [0x02, 0, 0, 0, 0, 1] + mac + [0x08, 0x00] + ip
    }

    func arpFrame(sender: [UInt8]) -> [UInt8] {
        let arp: [UInt8] = [0, 1, 8, 0, 6, 4, 0, 1] + mac + sender + [0, 0, 0, 0, 0, 0] + [192, 168, 64, 1]
        return [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF] + mac + [0x08, 0x06] + arp
    }

    func testGuestAddressWatcher() {
        var watcher = GuestAddressWatcher(network: [192, 168, 65, 0], mask: [255, 255, 255, 0])
        func observe(_ frame: [UInt8]) -> String? {
            frame.withUnsafeBytes { watcher.observe($0) }
        }
        // DHCP-Discover hat Absender 0.0.0.0, zählt nicht
        XCTAssertNil(observe(DHCPProbe.discoverFrame(mac: mac, transactionID: 1)))
        // Link-local vor dem DHCP und fremde Bereiche zählen nicht
        XCTAssertNil(observe(ipv4Frame(source: [169, 254, 3, 4])))
        XCTAssertNil(observe(ipv4Frame(source: [192, 168, 64, 2])))
        // Erste echte Adresse wird gemeldet, danach nur Änderungen
        XCTAssertEqual(observe(arpFrame(sender: [192, 168, 65, 2])), "192.168.65.2")
        XCTAssertNil(observe(ipv4Frame(source: [192, 168, 65, 2])))
        XCTAssertEqual(observe(ipv4Frame(source: [192, 168, 65, 7])), "192.168.65.7")
        // Netz- und Broadcast-Adresse nicht
        XCTAssertNil(observe(ipv4Frame(source: [192, 168, 65, 255])))
        XCTAssertNil(observe(ipv4Frame(source: [192, 168, 65, 0])))
        // zu kurz oder IPv6
        XCTAssertNil(observe([0x08, 0x00]))
        var v6 = ipv4Frame(source: [192, 168, 65, 9])
        v6[12] = 0x86
        v6[13] = 0xDD
        XCTAssertNil(observe(v6))
    }
}
