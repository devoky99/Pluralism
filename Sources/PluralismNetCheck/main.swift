import Darwin
import Foundation
import PluralismCore
import PluralismNet

// pluralism-netcheck: prüft das vmnet-Netzwerk von Pluralism ohne VM.
//
// Ablauf wie bei einer QEMU-VM: vmnet-Netz anlegen, Paketbrücke starten, dann selbst den Gast
// spielen: über den Datagramm-Socket ein DHCP-Discover senden und auf das Angebot von vmnet
// warten. Kommt eine Adresse zurück, funktionieren Netz und Brücke.
//
// Aufruf: pluralism-netcheck [--host-only] [--subnet A.B.C.D] [--no-reservation]
//                            [--others N] [--cycles N] [--pause S] [--timeout S]
// --subnet:  eigenen Bereich /24 setzen (Adresse geht unverändert an vmnet), Reservierung der .2
// --others:  vorher N weitere Netze mit gestarteter Schnittstelle offen halten (andere VMs)
// --cycles:  N-mal hintereinander anlegen, prüfen, freigeben (VM mehrmals starten)
// --app:     Netz wie die App über VMNetworkRegistry holen (wiederverwenden, Ausweichbereich)
// --block:   den festen Bereich vorher selbst belegen (Ausweichweg prüfen)
// Ausgabe: eine JSON-Zeile, Exit-Code 0 bei Erfolg.

struct Options {
    var hostOnly = false
    var subnet: String?
    var reserve = true
    var others = 0
    var cycles = 1
    var app = false
    var block = false
    var pause: TimeInterval = 0.5
    var timeout: TimeInterval = 6
}

func parseOptions() -> Options {
    var options = Options()
    var arguments = CommandLine.arguments.dropFirst().makeIterator()
    while let argument = arguments.next() {
        switch argument {
        case "--host-only":
            options.hostOnly = true
        case "--subnet":
            options.subnet = arguments.next()
        case "--no-reservation":
            options.reserve = false
        case "--others":
            if let value = arguments.next(), let count = Int(value) { options.others = count }
        case "--cycles":
            if let value = arguments.next(), let count = Int(value) { options.cycles = max(1, count) }
        case "--app":
            options.app = true
        case "--block":
            options.block = true
        case "--pause":
            if let value = arguments.next(), let seconds = Double(value) { options.pause = seconds }
        case "--timeout":
            if let value = arguments.next(), let seconds = Double(value) { options.timeout = seconds }
        default:
            break
        }
    }
    return options
}

// Code auf oberster Ebene gehört in Swift 6 dem Main Actor, ebenso diese Hilfsfunktionen.
let directory = "/tmp/pluralism-netcheck-\(getpid())"
var cleanupPaths: [String] = []

@MainActor
func cleanup() {
    for path in cleanupPaths {
        unlink(path)
    }
    rmdir(directory)
}

@MainActor
func emit(_ fields: [String: Any], exitCode: Int32) -> Never {
    cleanup()
    var output = fields
    output["uid"] = Int(getuid())
    output["ok"] = exitCode == 0
    if let data = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]),
       let line = String(data: data, encoding: .utf8) {
        print(line)
    }
    exit(exitCode)
}

func log(_ text: String) {
    FileHandle.standardError.write((text + "\n").data(using: .utf8)!)
}

/// Ein Durchlauf: Netz anlegen, Brücke starten, DHCP-Angebot holen, alles wieder freigeben.
/// Liefert die Felder und den Exit-Code (0 = Erfolg).
@MainActor
func runOnce(options: Options, mode: VMNetworkMode, tag: String) -> ([String: Any], Int32) {
    let mac = options.app ? appMAC : MACAddress.random()
    let macBytes = MACAddress.bytes(mac)!
    let hostSocket = directory + "/\(tag)h.sock"
    let guestSocket = directory + "/\(tag)q.sock"
    cleanupPaths += [hostSocket, guestSocket]
    log("Netz für \(mac) anlegen")

    let network: VMNetwork
    var notice: String?
    do {
        if options.app {
            let acquired = try VMNetworkRegistry.shared.acquire(mode: mode, guestMAC: mac, fixedHostAddress: options.subnet)
            network = acquired.0
            notice = acquired.notice
        } else {
            network = try VMNetwork(mode: mode, guestMAC: mac, subnet: options.subnet, reserveAddress: options.reserve)
        }
    } catch {
        return (["step": "network", "error": error.localizedDescription], 2)
    }
    let addressing = network.addressing
    var fields: [String: Any] = [
        "subnet": addressing?.description ?? "?",
        "expected": addressing?.guestAddress ?? "dynamisch"
    ]
    if let notice {
        fields["notice"] = notice
    }

    let relay = PacketRelay(network: network, hostSocketPath: hostSocket, guestSocketPath: guestSocket)
    do {
        try relay.start()
    } catch {
        return (fields.merging(["step": "interface", "error": error.localizedDescription]) { $1 }, 3)
    }
    defer { relay.stop() }

    // Den Gast spielen: eigenen Socket binden, wie QEMU mit -netdev dgram.
    let guestFD: Int32
    let hostAddress: sockaddr_un
    do {
        guestFD = try UnixDatagram.bind(guestSocket)
        hostAddress = try UnixDatagram.address(hostSocket)
    } catch {
        return (fields.merging(["step": "guest-socket", "error": error.localizedDescription]) { $1 }, 4)
    }
    defer { close(guestFD) }

    var offer: DHCPProbe.Reply?
    var framesSeen = 0
    attempts: for attempt in 1...3 {
        let transactionID = UInt32.random(in: 1...UInt32.max)
        UnixDatagram.send(guestFD, DHCPProbe.discoverFrame(mac: macBytes, transactionID: transactionID), to: hostAddress)
        log("DHCP-Discover \(attempt) gesendet")
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
    fields["mtu"] = relay.mtu
    fields["framesSeen"] = framesSeen
    fields["toGuest"] = Int(statistics.framesToGuest)
    fields["fromGuest"] = Int(statistics.framesFromGuest)

    guard let offer else {
        return (fields.merging(["step": "dhcp", "error": "keine DHCP-Antwort"]) { $1 }, 5)
    }

    // Wie ein Gast nach dem DHCP: ARP-Ankündigung mit der neuen Adresse. Die Brücke soll sie erkennen.
    if let yours = DHCPProbe.bytes(offer.yourAddress) {
        let arp: [UInt8] = [0, 1, 8, 0, 6, 4, 0, 1] + macBytes + yours + [0, 0, 0, 0, 0, 0] + yours
        UnixDatagram.send(guestFD, [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF] + macBytes + [0x08, 0x06] + arp, to: hostAddress)
        Thread.sleep(forTimeInterval: 0.3)
        fields["detected"] = relay.guestIPv4 ?? "-"
    }
    let matches = addressing?.guestAddress == nil || offer.yourAddress == addressing?.guestAddress
    fields["step"] = "done"
    fields["offer"] = offer.yourAddress
    fields["server"] = offer.serverAddress ?? ""
    fields["reservationMatches"] = matches
    return (fields, matches ? 0 : 6)
}

let options = parseOptions()
let mode: VMNetworkMode = options.hostOnly ? .hostOnly : .shared
let appMAC = MACAddress.random()
mkdir(directory, 0o700)
log("uid \(getuid())")

// Andere laufende VMs simulieren (mit gestarteter Schnittstelle).
var otherRelays: [PacketRelay] = []
var otherSubnets: [String] = []
for index in 0..<options.others {
    do {
        let other = try VMNetwork(mode: mode, guestMAC: MACAddress.random())
        let hostSocket = directory + "/o\(index)h.sock"
        cleanupPaths.append(hostSocket)
        let otherRelay = PacketRelay(network: other, hostSocketPath: hostSocket,
                                     guestSocketPath: directory + "/o\(index)q.sock")
        try otherRelay.start()
        otherRelays.append(otherRelay)
        otherSubnets.append(other.addressing?.description ?? "?")
    } catch {
        emit(["step": "others", "error": error.localizedDescription, "others": otherSubnets], exitCode: 7)
    }
}

// Festen Bereich vorher belegen, als liefe dort schon eine andere VM.
var blocker: PacketRelay?
if options.block, let subnet = options.subnet {
    do {
        let blocking = try VMNetwork(mode: mode, guestMAC: MACAddress.random(), subnet: subnet)
        let hostSocket = directory + "/bh.sock"
        cleanupPaths.append(hostSocket)
        let relay = PacketRelay(network: blocking, hostSocketPath: hostSocket, guestSocketPath: directory + "/bq.sock")
        try relay.start()
        blocker = relay
    } catch {
        emit(["step": "block", "error": error.localizedDescription], exitCode: 7)
    }
}

if options.cycles == 1 {
    let (fields, code) = runOnce(options: options, mode: mode, tag: "c0")
    blocker?.stop()
    emit(fields.merging(["others": otherSubnets]) { $1 }, exitCode: code)
}

// Mehrere Durchläufe: bleibt der Bereich beim erneuten Start derselbe?
var results: [[String: Any]] = []
var worst: Int32 = 0
for cycle in 0..<options.cycles {
    let (fields, code) = autoreleasepool { runOnce(options: options, mode: mode, tag: "c\(cycle)") }
    results.append(["subnet": fields["subnet"] ?? "?", "offer": fields["offer"] ?? "-",
                    "detected": fields["detected"] ?? "-", "step": fields["step"] ?? "?",
                    "error": fields["error"] ?? "", "notice": fields["notice"] ?? ""])
    worst = max(worst, code)
    Thread.sleep(forTimeInterval: options.pause)
}
blocker?.stop()
emit(["cycles": results, "others": otherSubnets], exitCode: worst)
