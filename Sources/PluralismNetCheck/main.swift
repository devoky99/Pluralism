import Darwin
import Foundation
import PluralismCore
import PluralismNet

// pluralism-netcheck: prüft das vmnet-Netzwerk von Pluralism ohne VM, von Ende zu Ende.
//
// Ablauf wie bei einer QEMU-VM: vmnet-Netz anlegen, Paketbrücke starten, dann selbst den Gast
// spielen. Der „Gast“ verbindet sich wie QEMU (-netdev stream) mit der Brücke und prüft:
// DHCP (Angebot und Bestätigung), Gateway per ARP, Namensauflösung über das Gateway,
// TCP-Verbindungsaufbau und Ping ins Internet, Mac -> VM (UDP und /sbin/ping) und VM -> Mac per UDP.
//
// Aufruf: pluralism-netcheck [--host-only] [--subnet A.B.C.D] [--no-reservation] [--app]
//                            [--others N] [--cycles N] [--pause S] [--block] [--legacy] [--quick]
// --subnet:  eigener Bereich /24, angegeben als Adresse des Macs (.1)
// --app:     Netz wie die App über VMNetworkRegistry holen
// --others:  vorher N weitere Netze mit laufender Brücke offen halten (andere VMs)
// --cycles:  N-mal hintereinander anlegen, prüfen, freigeben (VM mehrmals starten)
// --block:   den festen Bereich vorher selbst belegen (Ausweichweg prüfen)
// --legacy:  nur die alte vmnet-Schnittstelle prüfen, die QEMUs eigene vmnet-Netdevs nutzen
// --quick:   nur DHCP und ARP, ohne Internet- und Mac-Tests
// --qemu P:  echtes QEMU (Pfad P) mit dem -netdev-Argument von Pluralism an die Brücke hängen
// --qemu-vmnet P: echtes QEMU legt das Netz selbst an (-netdev vmnet-shared/-host wie UTM)
// Ausgabe: eine JSON-Zeile, Exit-Code 0 bei Erfolg.

struct Options {
    var hostOnly = false
    var subnet: String?
    var reserve = true
    var app = false
    var others = 0
    var cycles = 1
    var pause: TimeInterval = 0.5
    var block = false
    var legacy = false
    var quick = false
    var qemu: String?
    var qemuVmnet: String?
}

func parseOptions() -> Options {
    var options = Options()
    var arguments = CommandLine.arguments.dropFirst().makeIterator()
    while let argument = arguments.next() {
        switch argument {
        case "--host-only": options.hostOnly = true
        case "--subnet": options.subnet = arguments.next()
        case "--no-reservation": options.reserve = false
        case "--app": options.app = true
        case "--others":
            if let value = arguments.next(), let count = Int(value) { options.others = count }
        case "--cycles":
            if let value = arguments.next(), let count = Int(value) { options.cycles = max(1, count) }
        case "--pause":
            if let value = arguments.next(), let seconds = Double(value) { options.pause = seconds }
        case "--block": options.block = true
        case "--legacy": options.legacy = true
        case "--quick": options.quick = true
        case "--qemu": options.qemu = arguments.next()
        case "--qemu-vmnet": options.qemuVmnet = arguments.next()
        default: break
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

// MARK: Simulierter Gast

/// Spielt die Netzwerkkarte eines Gasts: verbindet sich wie QEMU mit der Brücke,
/// schickt Rahmen mit Längenfeld und beantwortet ARP-Anfragen für die eigene Adresse.
final class SimulatedGuest {
    let fd: Int32
    let mac: [UInt8]
    var ip: [UInt8]?
    private var decoder = StreamFrameDecoder()
    private var pending: [[UInt8]] = []
    private(set) var pingsAnswered = 0

    init(socketPath: String, mac: [UInt8]) throws {
        fd = try UnixStream.connect(socketPath)
        self.mac = mac
    }

    deinit {
        close(fd)
    }

    func send(_ frame: [UInt8]) {
        UnixStream.writeAll(fd, StreamFraming.encode(frame))
    }

    /// Nächster Rahmen innerhalb von `timeout` Sekunden.
    func receive(timeout: TimeInterval) -> [UInt8]? {
        let deadline = Date().addingTimeInterval(timeout)
        while pending.isEmpty {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0, let chunk = UnixStream.read(fd, maxLength: 1 << 20, timeout: remaining) else { return nil }
            var frames: [[UInt8]] = []
            try? chunk.withUnsafeBytes { raw in
                try decoder.append(raw) { frame in frames.append(Array(frame)) }
            }
            pending += frames
        }
        return pending.removeFirst()
    }

    /// Wartet auf den ersten Rahmen, für den `match` etwas liefert. Beantwortet nebenbei ARP.
    func wait<T>(timeout: TimeInterval, _ match: ([UInt8]) -> T?) -> T? {
        let deadline = Date().addingTimeInterval(timeout)
        while deadline.timeIntervalSinceNow > 0 {
            guard let frame = receive(timeout: deadline.timeIntervalSinceNow) else { return nil }
            if let ip, let arp = Packets.parseARP(frame), arp.operation == 1, arp.targetIP == ip {
                send(Packets.arpReply(senderMAC: mac, senderIP: ip, targetMAC: arp.senderMAC, targetIP: arp.senderIP))
            }
            // Ping beantworten wie ein echter Gast
            if let ip, let packet = Packets.parseIPv4(frame), packet.destination == ip,
               let reply = Packets.icmpEchoReply(to: packet), frame.count >= 12 {
                let packetBytes = Packets.ipv4(source: ip, destination: packet.source, proto: .icmp, payload: reply)
                send(Packets.ethernet(destination: Array(frame[6..<12]), source: mac, type: 0x0800, payload: packetBytes))
                pingsAnswered += 1
            }
            if let result = match(frame) {
                return result
            }
        }
        return nil
    }

    func sendIPv4(to destinationMAC: [UInt8], destination: [UInt8], proto: Packets.IPProtocol, payload: [UInt8]) {
        guard let ip else { return }
        let packet = Packets.ipv4(source: ip, destination: destination, proto: proto, payload: payload,
                                  identification: UInt16.random(in: 1...UInt16.max))
        send(Packets.ethernet(destination: destinationMAC, source: mac, type: 0x0800, payload: packet))
    }
}

// MARK: Sockets auf dem Mac

func socketAddress(_ ip: [UInt8], port: UInt16) -> sockaddr_in {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    withUnsafeMutableBytes(of: &address.sin_addr.s_addr) { raw in
        for index in 0..<4 { raw[index] = ip[index] }
    }
    return address
}

/// UDP-Socket auf dem Mac, optional an einen Port gebunden.
func hostUDPSocket(bindPort: UInt16?) -> Int32 {
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    if let bindPort {
        var address = socketAddress([0, 0, 0, 0], port: bindPort)
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
    }
    return fd
}

/// Adressen der Netzwerkschnittstellen des Macs (IPv4) mit Namen.
func hostInterfaces() -> [String: String] {
    var result: [String: String] = [:]
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0, let first = list else { return result }
    defer { freeifaddrs(list) }
    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    while let entry = cursor {
        if let address = entry.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET) {
            let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                withUnsafeBytes(of: pointer.pointee.sin_addr.s_addr) { Array($0) }
            }
            result[Packets.dotted(ip)] = String(cString: entry.pointee.ifa_name)
        }
        cursor = entry.pointee.ifa_next
    }
    return result
}

/// Schickt ein UDP-Paket vom Mac; liefert Erfolg und bei Fehler den Fehlercode.
func hostSend(_ fd: Int32, to ip: [UInt8], port: UInt16, _ payload: [UInt8]) -> (ok: Bool, error: Int32) {
    var address = socketAddress(ip, port: port)
    let sent = payload.withUnsafeBytes { raw in
        withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }
    return (sent == payload.count, sent < 0 ? errno : 0)
}

func hostReceive(_ fd: Int32, timeout: TimeInterval) -> [UInt8]? {
    var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    guard poll(&descriptor, 1, Int32(timeout * 1000)) > 0 else { return nil }
    var buffer = [UInt8](repeating: 0, count: 2048)
    let length = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, 2048, 0) }
    return length > 0 ? Array(buffer[0..<length]) : nil
}

// MARK: Ein Durchlauf

/// Netz anlegen, Brücke starten, Gast spielen, alles wieder freigeben.
@MainActor
func runOnce(options: Options, mode: VMNetworkMode, tag: String) -> ([String: Any], Int32) {
    let mac = options.app ? appMAC : MACAddress.random()
    let macBytes = MACAddress.bytes(mac)!
    let socketPath = directory + "/\(tag).sock"
    cleanupPaths.append(socketPath)
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
    var fields: [String: Any] = [
        "subnet": network.addressing?.description ?? "?",
        "expected": network.addressing?.guestAddress ?? "dynamisch"
    ]
    if let notice { fields["notice"] = notice }

    let relay = PacketRelay(network: network, socketPath: socketPath)
    do {
        try relay.start()
    } catch {
        fields["step"] = "interface"
        fields["error"] = error.localizedDescription
        return (fields, 3)
    }
    defer { relay.stop() }

    let guest: SimulatedGuest
    do {
        guest = try SimulatedGuest(socketPath: socketPath, mac: macBytes)
    } catch {
        fields["step"] = "connect"
        fields["error"] = error.localizedDescription
        return (fields, 4)
    }

    func finish(_ step: String, _ code: Int32) -> ([String: Any], Int32) {
        let statistics = relay.statistics
        fields["mtu"] = relay.mtu
        fields["toGuest"] = Int(statistics.framesToGuest)
        fields["fromGuest"] = Int(statistics.framesFromGuest)
        fields["droppedToGuest"] = Int(statistics.droppedToGuest)
        fields["connections"] = statistics.connections
        fields["peakBuffered"] = statistics.peakBufferedToGuest
        fields["step"] = step
        return (fields, code)
    }

    // DHCP: Angebot
    var offer: DHCPProbe.Reply?
    var transactionID: UInt32 = 0
    for attempt in 1...3 where offer == nil {
        transactionID = UInt32.random(in: 1...UInt32.max)
        guest.send(DHCPProbe.discoverFrame(mac: macBytes, transactionID: transactionID))
        log("DHCP-Discover \(attempt)")
        let xid = transactionID
        offer = guest.wait(timeout: 4) { frame in
            DHCPProbe.parseReply(frame: frame, transactionID: xid).flatMap { $0.messageType == 2 ? $0 : nil }
        }
    }
    guard let offer, let offered = DHCPProbe.bytes(offer.yourAddress) else {
        fields["error"] = "keine DHCP-Antwort"
        return finish("dhcp", 5)
    }
    fields["offer"] = offer.yourAddress
    let gateway = offer.serverAddress.flatMap(DHCPProbe.bytes) ?? [offered[0], offered[1], offered[2], 1]
    fields["server"] = Packets.dotted(gateway)
    let matches = network.addressing?.guestAddress == nil || offer.yourAddress == network.addressing?.guestAddress
    fields["reservationMatches"] = matches

    // DHCP: Bestätigung
    let xid = transactionID
    guest.send(DHCPProbe.requestFrame(mac: macBytes, transactionID: xid, requested: offered, server: gateway))
    let ack = guest.wait(timeout: 4) { frame -> DHCPProbe.Reply? in
        guard let reply = DHCPProbe.parseReply(frame: frame, transactionID: xid), reply.messageType == 5 || reply.messageType == 6 else { return nil }
        return reply
    }
    fields["ack"] = ack.map { $0.messageType == 5 ? "ACK" : "NAK" } ?? "-"
    guest.ip = offered

    // Gateway per ARP
    guest.send(Packets.arpRequest(senderMAC: macBytes, senderIP: offered, targetIP: gateway))
    let gatewayMAC = guest.wait(timeout: 3) { frame -> [UInt8]? in
        guard let arp = Packets.parseARP(frame), arp.operation == 2, arp.senderIP == gateway else { return nil }
        return arp.senderMAC
    }
    fields["gatewayARP"] = gatewayMAC != nil
    Thread.sleep(forTimeInterval: 0.2)
    fields["detected"] = relay.guestIPv4 ?? "-"
    if options.quick {
        return finish("done", matches ? 0 : 6)
    }
    let gwMAC = gatewayMAC ?? Packets.broadcastMAC

    // Namensauflösung über das Gateway (DNS-Weiterleitung von vmnet)
    let dnsID = UInt16.random(in: 1...UInt16.max)
    let dnsPort = UInt16.random(in: 40000...60000)
    guest.sendIPv4(to: gwMAC, destination: gateway, proto: .udp,
                   payload: Packets.udp(source: offered, destination: gateway, sourcePort: dnsPort, destinationPort: 53,
                                        payload: Packets.dnsQuery(identifier: dnsID, name: "apple.com")))
    let dns = guest.wait(timeout: 5) { frame -> Packets.DNSAnswer? in
        guard let packet = Packets.parseIPv4(frame), let udp = Packets.parseUDP(packet), udp.destinationPort == dnsPort else { return nil }
        return Packets.parseDNSResponse(udp.payload, identifier: dnsID)
    }
    fields["dns"] = dns.map { "rcode \($0.responseCode), \($0.answerCount) Antworten" } ?? "-"

    // TCP-Verbindungsaufbau ins Internet (1.1.1.1:443)
    let remote: [UInt8] = [1, 1, 1, 1]
    let tcpPort = UInt16.random(in: 40000...60000)
    let sequence = UInt32.random(in: 1...UInt32.max)
    guest.sendIPv4(to: gwMAC, destination: remote, proto: .tcp,
                   payload: Packets.tcp(source: offered, destination: remote, sourcePort: tcpPort, destinationPort: 443,
                                        sequence: sequence, acknowledgment: 0, flags: [.syn]))
    let synAck = guest.wait(timeout: 5) { frame -> Packets.TCP? in
        guard let packet = Packets.parseIPv4(frame), packet.source == remote, let tcp = Packets.parseTCP(packet),
              tcp.destinationPort == tcpPort else { return nil }
        return tcp
    }
    if let synAck {
        fields["tcp"] = synAck.flags.contains([.syn, .ack]) ? "SYN-ACK" : "Flags \(synAck.flags.rawValue)"
        guest.sendIPv4(to: gwMAC, destination: remote, proto: .tcp,
                       payload: Packets.tcp(source: offered, destination: remote, sourcePort: tcpPort, destinationPort: 443,
                                            sequence: sequence &+ 1, acknowledgment: 0, flags: [.rst]))
    } else {
        fields["tcp"] = "-"
    }

    // Ping ins Internet
    let pingID = UInt16.random(in: 1...UInt16.max)
    guest.sendIPv4(to: gwMAC, destination: remote, proto: .icmp, payload: Packets.icmpEchoRequest(identifier: pingID, sequence: 1))
    let pong = guest.wait(timeout: 4) { frame -> Bool? in
        guard let packet = Packets.parseIPv4(frame), Packets.icmpEchoReplyIdentifier(packet) == pingID else { return nil }
        return true
    }
    fields["ping"] = pong ?? false

    // Mac -> VM per UDP
    let probePort = UInt16.random(in: 40000...60000)
    let macSocket = hostUDPSocket(bindPort: nil)
    let sendResult = hostSend(macSocket, to: offered, port: probePort, Array("hallo vm".utf8))
    let sentToVM = sendResult.ok
    let atVM = guest.wait(timeout: 4) { frame -> Bool? in
        guard let packet = Packets.parseIPv4(frame), let udp = Packets.parseUDP(packet), udp.destinationPort == probePort else { return nil }
        return true
    }
    fields["macToVM"] = sentToVM && atVM == true
    if !sentToVM { fields["macToVMError"] = "\(sendResult.error): " + String(cString: strerror(sendResult.error)) }
    close(macSocket)

    // VM -> Mac per UDP an das Gateway (die Adresse des Macs im VM-Netz)
    let listenPort = UInt16.random(in: 40000...60000)
    let listener = hostUDPSocket(bindPort: listenPort)
    guest.sendIPv4(to: gwMAC, destination: gateway, proto: .udp,
                   payload: Packets.udp(source: offered, destination: gateway, sourcePort: 50001, destinationPort: listenPort,
                                        payload: Array("hallo mac".utf8)))
    fields["vmToMac"] = hostReceive(listener, timeout: 3) != nil
    close(listener)

    // Mac -> VM mit /sbin/ping (Programm von Apple). Gelingt das, während das eigene Prüfprogramm
    // „No route to host“ bekommt, blockiert macOS das Prüfprogramm über „Lokales Netzwerk“.
    let ping = Process()
    ping.executableURL = URL(fileURLWithPath: "/sbin/ping")
    ping.arguments = ["-c", "2", "-t", "4", Packets.dotted(offered)]
    let pingPipe = Pipe()
    ping.standardOutput = pingPipe
    ping.standardError = pingPipe
    if (try? ping.run()) != nil {
        _ = guest.wait(timeout: 5) { _ -> Bool? in ping.isRunning ? nil : true }
        ping.waitUntilExit()
        fields["macPing"] = ping.terminationStatus == 0
        fields["pingsAnswered"] = guest.pingsAnswered
        let text = String(decoding: pingPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        fields["macPingOutput"] = text.split(separator: "\n").filter { $0.contains("transmitted") || $0.contains("ping:") }.joined(separator: " | ")
    }

    return finish("done", matches ? 0 : 6)
}

// MARK: Ablauf

let options = parseOptions()
let mode: VMNetworkMode = options.hostOnly ? .hostOnly : .shared
let appMAC = MACAddress.random()
mkdir(directory, 0o700)
log("uid \(getuid())")

if options.legacy {
    let result = LegacyVmnetProbe.run(mode: mode)
    emit(["step": "legacy", "status": result.status, "mtu": result.mtu, "start": result.startAddress ?? "-"],
         exitCode: result.status == 1000 ? 0 : 8)
}

// Echtes QEMU mit dem -netdev-Argument von Pluralism: verbindet es sich mit der Brücke?
if let qemuPath = options.qemu {
    do {
        let network = try VMNetwork(mode: mode, guestMAC: appMAC, subnet: options.subnet)
        let path = directory + "/q.sock"
        cleanupPaths.append(path)
        let relay = PacketRelay(network: network, socketPath: path)
        try relay.start()
        let netdev = QEMUCommandBuilder.netdevArgument(.vmnetRelay(socket: path), restrictToHost: false) ?? ""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: qemuPath)
        process.arguments = ["-machine", "virt", "-accel", "tcg", "-cpu", "max", "-m", "256", "-nodefaults",
                             "-display", "none", "-S", "-netdev", netdev,
                             "-device", QEMUCommandBuilder.networkDeviceArgument(mac: appMAC)]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        Thread.sleep(forTimeInterval: 4)
        let running = process.isRunning
        let connections = relay.statistics.connections
        if running { process.terminate() }
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        relay.stop()
        emit(["step": "qemu", "netdev": netdev, "running": running, "connections": connections,
              "output": String(output.suffix(400))], exitCode: connections >= 1 && running ? 0 : 9)
    } catch {
        emit(["step": "qemu", "error": error.localizedDescription], exitCode: 9)
    }
}

// Echtes QEMU legt das Netz selbst an (wie UTM): startet es, und hat der Mac danach die Gateway-Adresse?
if let qemuPath = options.qemuVmnet {
    let hostAddress = options.subnet ?? "192.168.165.1"
    let parts = hostAddress.split(separator: ".")
    let addressing = GuestNetworkAddressing(subnet: parts.dropLast().joined(separator: ".") + ".0", prefixLength: 24,
                                            hostAddress: hostAddress, guestAddress: nil)
    let netdev = QEMUCommandBuilder.netdevArgument(.vmnet(hostOnly: options.hostOnly, addressing: addressing),
                                                    restrictToHost: options.hostOnly) ?? ""
    let process = Process()
    process.executableURL = URL(fileURLWithPath: qemuPath)
    process.arguments = ["-machine", "virt", "-accel", "tcg", "-cpu", "max", "-m", "256", "-nodefaults",
                         "-display", "none", "-S", "-netdev", netdev,
                         "-device", QEMUCommandBuilder.networkDeviceArgument(mac: appMAC)]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
    } catch {
        emit(["step": "qemu-vmnet", "error": error.localizedDescription], exitCode: 10)
    }
    Thread.sleep(forTimeInterval: 4)
    let running = process.isRunning
    let interface = hostInterfaces()[hostAddress]
    if running { process.terminate() }
    process.waitUntilExit()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    emit(["step": "qemu-vmnet", "netdev": netdev, "running": running, "hostInterface": interface ?? "-",
          "output": String(output.suffix(400))], exitCode: running && interface != nil ? 0 : 10)
}

// Andere laufende VMs simulieren (mit gestarteter Schnittstelle).
var otherRelays: [PacketRelay] = []
var otherSubnets: [String] = []
for index in 0..<options.others {
    do {
        let other = try VMNetwork(mode: mode, guestMAC: MACAddress.random())
        let path = directory + "/o\(index).sock"
        cleanupPaths.append(path)
        let otherRelay = PacketRelay(network: other, socketPath: path)
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
        let path = directory + "/b.sock"
        cleanupPaths.append(path)
        let relay = PacketRelay(network: blocking, socketPath: path)
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
                    "step": fields["step"] ?? "?", "error": fields["error"] ?? "", "notice": fields["notice"] ?? ""])
    worst = max(worst, code)
    Thread.sleep(forTimeInterval: options.pause)
}
blocker?.stop()
emit(["cycles": results, "others": otherSubnets], exitCode: worst)
