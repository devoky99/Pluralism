import Darwin
import Foundation
import PluralismCore
import PluralismNet

// pluralism-netcheck: prüft das vmnet-Netzwerk von Pluralism ohne VM.
//
// Ablauf wie bei einer QEMU-VM: vmnet-Netz anlegen (Bereich wählt vmnet, Reservierung der .2),
// Paketbrücke starten, dann selbst den Gast spielen: über den Datagramm-Socket ein
// DHCP-Discover senden und auf das Angebot von vmnet warten. Kommt die reservierte Adresse
// zurück, funktionieren Netz, Reservierung und Brücke.
//
// Aufruf: pluralism-netcheck [--host-only] [--no-reservation] [--others N] [--timeout 6]
// --others N: vorher N weitere Netze anlegen und offen halten (wie andere laufende VMs)
// Ausgabe: eine JSON-Zeile, Exit-Code 0 bei Erfolg.

struct Options {
    var hostOnly = false
    var reserve = true
    var others = 0
    var timeout: TimeInterval = 6
}

func parseOptions() -> Options {
    var options = Options()
    var arguments = CommandLine.arguments.dropFirst().makeIterator()
    while let argument = arguments.next() {
        switch argument {
        case "--host-only":
            options.hostOnly = true
        case "--no-reservation":
            options.reserve = false
        case "--others":
            if let value = arguments.next(), let count = Int(value) { options.others = count }
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
let mode: VMNetworkMode = options.hostOnly ? .hostOnly : .shared
let mac = MACAddress.random()
let macBytes = MACAddress.bytes(mac)!
let directory = "/tmp/pluralism-netcheck-\(getpid())"
mkdir(directory, 0o700)
let hostSocket = directory + "/h.sock"
let guestSocket = directory + "/q.sock"
cleanupPaths = [hostSocket, guestSocket]

// Andere "laufende VMs" simulieren
// (mit gestarteter Schnittstelle, sonst belegt vmnet den Adressbereich nicht)
var otherRelays: [PacketRelay] = []
var otherSubnets: [String] = []
for index in 0..<options.others {
    do {
        let other = try VMNetwork(mode: mode, guestMAC: MACAddress.random())
        let otherRelay = PacketRelay(network: other, hostSocketPath: directory + "/o\(index)h.sock",
                                     guestSocketPath: directory + "/o\(index)q.sock")
        cleanupPaths.append(directory + "/o\(index)h.sock")
        try otherRelay.start()
        otherRelays.append(otherRelay)
        otherSubnets.append(other.addressing?.description ?? "?")
    } catch {
        report(["step": "others", "error": error.localizedDescription, "others": otherSubnets], exitCode: 7)
    }
}

FileHandle.standardError.write("Netz für \(mac) anlegen (uid \(getuid()))\n".data(using: .utf8)!)

let network: VMNetwork
do {
    network = try VMNetwork(mode: mode, guestMAC: mac, reserveAddress: options.reserve)
} catch {
    report(["step": "network", "error": error.localizedDescription, "others": otherSubnets], exitCode: 2)
}
let addressing = network.addressing

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
    "subnet": addressing?.description ?? "?",
    "expected": addressing?.guestAddress ?? "dynamisch",
    "others": otherSubnets,
    "mtu": relay.mtu,
    "framesSeen": framesSeen,
    "toGuest": Int(statistics.framesToGuest),
    "fromGuest": Int(statistics.framesFromGuest),
    "seconds": Double(Int(Date().timeIntervalSince(started) * 10)) / 10
]

guard let offer else {
    report(details.merging(["step": "dhcp", "error": "keine DHCP-Antwort"]) { $1 }, exitCode: 5)
}
let matches = addressing?.guestAddress == nil || offer.yourAddress == addressing?.guestAddress
report(details.merging([
    "step": "done",
    "offer": offer.yourAddress,
    "server": offer.serverAddress ?? "",
    "messageType": Int(offer.messageType),
    "reservationMatches": matches
]) { $1 }, exitCode: matches ? 0 : 6)
