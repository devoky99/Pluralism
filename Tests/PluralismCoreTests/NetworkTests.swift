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
}
