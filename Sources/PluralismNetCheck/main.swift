import Darwin
import Foundation
import PluralismCore
import PluralismNet

// pluralism-netcheck: prüft das vmnet-Netzwerk von Pluralism ohne VM.
//
// Ablauf wie bei einer QEMU-VM: vmnet-Netz anlegen (eigenes /24, DHCP-Reservierung),
// Paketbrücke starten, dann selbst den Gast spielen: über den Datagramm-Socket ein
// DHCP-Discover senden und auf das Angebot von vmnet warten. Kommt die reservierte Adresse
// zurück, funktionieren Netz, Reservierung und Brücke.
//
// Aufruf: pluralism-netcheck [--host-only] [--plain] [--index 150] [--timeout 6]
// --plain: ohne eigenen Adressbereich und ohne Reservierung (Diagnose)
// Ausgabe: eine JSON-Zeile, Exit-Code 0 bei Erfolg.

struct Options {
    var hostOnly = false
    var setSubnet = true
    var reserve = true
    var index = 150
    var timeout: TimeInterval = 6
}

func parseOptions() -> Options {
    var options = Options()
    var arguments = CommandLine.arguments.dropFirst().makeIterator()
    while let argument = arguments.next() {
        switch argument {
        case "--host-only":
            options.hostOnly = true
        case "--plain":
            options.setSubnet = false
            options.reserve = false
        case "--no-subnet":
            options.setSubnet = false
        case "--no-reservation":
            options.reserve = false
        case "--index":
            if let value = arguments.next(), let index = Int(value) { options.index = index }
        case "--timeout":
            if let value = arguments.next(), let seconds = Double(value) { options.timeout = seconds }
        default:
            break
        }
    }
    return options
}

var cleanupPaths: [String] = []

func report(_ fields: [String: Any], exitCode: Int32) -> Never {
    for path in cleanupPaths {
        unlink(path)
    }
    if let directory = cleanupPaths.first.map({ ($0 as NSString).deletingLastPathComponent }) {
        rmdir(directory)
    }
    var output = fields
    output["uid"] = Int(getuid())
    output["ok"] = exitCode == 0
    if let data = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]),
       let line = String(data: data, encoding: .utf8) {
        print(line)
    }
    exit(exitCode)
}

let options = parseOptions()
let addressing = GuestNetworkAddressing(index: options.index)
let mac = MACAddress.random()
let macBytes = MACAddress.bytes(mac)!
let directory = "/tmp/pluralism-netcheck-\(getpid())"
mkdir(directory, 0o700)
let hostSocket = directory + "/h.sock"
let guestSocket = directory + "/q.sock"
cleanupPaths = [hostSocket, guestSocket]

FileHandle.standardError.write("Netz \(addressing.subnet)/24 für \(mac) anlegen (uid \(getuid()))\n".data(using: .utf8)!)

let network: VMNetwork
do {
    network = try VMNetwork(mode: options.hostOnly ? .hostOnly : .shared, addressing: addressing, guestMAC: mac,
                            setSubnet: options.setSubnet, reserveAddress: options.reserve)
} catch {
    report(["step": "network", "error": error.localizedDescription], exitCode: 2)
}

let relay = PacketRelay(network: network, hostSocketPath: hostSocket, guestSocketPath: guestSocket)
do {
    try relay.start()
} catch {
    report(["step": "interface", "error": error.localizedDescription], exitCode: 3)
}

// Den Gast spielen: eigenen Socket binden, wie QEMU mit -netdev dgram.
let guestFD: Int32
let hostAddress: sockaddr_un
do {
    guestFD = try UnixDatagram.bind(guestSocket)
    hostAddress = try UnixDatagram.address(hostSocket)
} catch {
    relay.stop()
    report(["step": "guest-socket", "error": error.localizedDescription], exitCode: 4)
}

var offer: DHCPProbe.Reply?
var framesSeen = 0
let started = Date()
attempts: for attempt in 1...3 {
    let transactionID = UInt32.random(in: 1...UInt32.max)
    UnixDatagram.send(guestFD, DHCPProbe.discoverFrame(mac: macBytes, transactionID: transactionID), to: hostAddress)
    FileHandle.standardError.write("DHCP-Discover \(attempt) gesendet\n".data(using: .utf8)!)
    let deadline = Date().addingTimeInterval(options.timeout)
    while Date() < deadline {
        guard let frame = UnixDatagram.receive(guestFD, timeout: deadline.timeIntervalSinceNow) else { break }
        framesSeen += 1
        if let reply = DHCPProbe.parseReply(frame: frame, transactionID: transactionID) {
            offer = reply
            break attempts
        }
    }
}

let statistics = relay.statistics
relay.stop()
close(guestFD)

let details: [String: Any] = [
    "subnet": addressing.subnet,
    "expected": addressing.guestAddress,
    "mtu": relay.mtu,
    "framesSeen": framesSeen,
    "toGuest": Int(statistics.framesToGuest),
    "fromGuest": Int(statistics.framesFromGuest),
    "seconds": Double(Int(Date().timeIntervalSince(started) * 10)) / 10
]

guard let offer else {
    report(details.merging(["step": "dhcp", "error": "keine DHCP-Antwort"]) { $1 }, exitCode: 5)
}
let matches = !options.reserve || offer.yourAddress == addressing.guestAddress
report(details.merging([
    "step": "done",
    "offer": offer.yourAddress,
    "server": offer.serverAddress ?? "",
    "messageType": Int(offer.messageType),
    "reservationMatches": matches
]) { $1 }, exitCode: matches ? 0 : 6)
