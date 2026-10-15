import Darwin
import Dispatch
import Foundation
import PluralismCore
import vmnet

/// Paketbrücke zwischen einer QEMU-Netzwerkkarte und einem vmnet-Netz.
///
/// QEMU läuft mit `-netdev stream` und verbindet sich mit einem Unix-Stream-Socket von Pluralism.
/// Vor jedem Ethernet-Rahmen stehen 4 Byte Länge (`StreamFraming`). Pluralism reicht die Rahmen
/// gebündelt an vmnet weiter und umgekehrt. So bekommt die Windows-VM Apples Netzstack, ohne dass
/// QEMU Root-Rechte oder das Apple-Entitlement `com.apple.vm.networking` braucht.
///
/// Warum Stream statt Datagramm: Bei Unix-Datagrammen verwirft macOS Rahmen, sobald der
/// Empfangspuffer von QEMU (4 KB, also zwei volle Rahmen) voll ist. Bei einem Stream wartet der
/// Sender stattdessen, und Pluralism puffert bis zu `outboundLimit` Bytes. Erst darüber werden
/// Rahmen verworfen, wie bei einem überlasteten Switch-Port.
///
/// Nebenläufigkeit: Aller veränderliche Zustand gehört der seriellen `queue`. `start()` und `stop()`
/// werden von außen aufgerufen und greifen über `queue.sync` zu. Die Rückrufe `frameObserver` und
/// `onGuestAddress` werden vor `start()` gesetzt und danach nur noch auf der `queue` gelesen.
public final class PacketRelay: @unchecked Sendable {
    public struct Statistics: Equatable, Sendable {
        public var framesToGuest: UInt64 = 0
        public var framesFromGuest: UInt64 = 0
        public var droppedToGuest: UInt64 = 0
        public var droppedFromGuest: UInt64 = 0
        /// Verbindungen von QEMU (mehr als eine nach einem Neustart von QEMU).
        public var connections: Int = 0
        /// Höchster Pufferstand Richtung QEMU in Bytes.
        public var peakBufferedToGuest: Int = 0
    }

    public let network: VMNetwork
    /// Unix-Socket, mit dem sich QEMU verbindet.
    public let socketPath: String
    public private(set) var mtu: Int = 1500
    public private(set) var maxPacketSize: Int = 1514

    /// Wird (auf einer internen Queue) aufgerufen, wenn ein Rahmen vom Netz für den Gast ankommt.
    /// Nur für Prüfprogramme gedacht.
    public var frameObserver: (@Sendable ([UInt8]) -> Void)?

    /// Wird (auf einer internen Queue) aufgerufen, sobald der Gast eine neue IPv4-Adresse benutzt.
    public var onGuestAddress: (@Sendable (String) -> Void)?

    /// So viele Bytes dürfen auf QEMU warten, darüber werden Rahmen verworfen.
    private let outboundLimit = 4 << 20
    private let receiveChunk = 256 << 10
    private let batchSize = 64

    private let queue = DispatchQueue(label: "pluralism.net.relay", qos: .userInteractive)
    private var interface: interface_ref?
    private var acceptSource: DispatchSourceRead?
    private var client: Client?
    private var decoder = StreamFrameDecoder()
    private var outbound: [UInt8] = []
    private var outboundStart = 0
    private var pendingWrites = 0
    private var stats = Statistics()
    private var watcher: GuestAddressWatcher?
    private var learnedAddress: String?

    private var receiveBuffer: UnsafeMutableRawPointer?
    private var readPackets: UnsafeMutablePointer<vmpktdesc>?
    private var readIovecs: UnsafeMutablePointer<iovec>?
    private var readStorage: UnsafeMutableRawPointer?
    private var writePackets: UnsafeMutablePointer<vmpktdesc>?
    private var writeIovecs: UnsafeMutablePointer<iovec>?
    private var writeStorage: UnsafeMutableRawPointer?

    /// Eine Verbindung von QEMU mit Lese- und Schreibquelle. Der Deskriptor wird geschlossen,
    /// wenn beide Quellen abgemeldet sind (vorher wäre er womöglich schon neu vergeben).
    private final class Client {
        let fd: Int32
        let readSource: DispatchSourceRead
        let writeSource: DispatchSourceWrite
        var writeSourceActive = false

        init(fd: Int32, readSource: DispatchSourceRead, writeSource: DispatchSourceWrite) {
            self.fd = fd
            self.readSource = readSource
            self.writeSource = writeSource
        }
    }

    public init(network: VMNetwork, socketPath: String) {
        self.network = network
        self.socketPath = socketPath
        if let addressing = network.addressing, let subnet = VMNetwork.bytes(addressing.subnet) {
            let prefix = addressing.prefixLength
            let maskValue: UInt32 = prefix == 0 ? 0 : UInt32.max << (32 - UInt32(prefix))
            let mask = [UInt8(maskValue >> 24), UInt8((maskValue >> 16) & 0xFF),
                        UInt8((maskValue >> 8) & 0xFF), UInt8(maskValue & 0xFF)]
            watcher = GuestAddressWatcher(network: subnet, mask: mask)
        }
    }

    deinit {
        // Niemand hält die Brücke mehr, also läuft auch kein Ereignis mehr: direkt aufräumen.
        let stopped = shutDownLocked()
        PacketRelay.stopInterface(stopped)
        freeBuffers()
    }

    /// Adresse, die der Gast zuletzt benutzt hat (aus seinen eigenen Rahmen).
    public var guestIPv4: String? {
        queue.sync { learnedAddress }
    }

    public var statistics: Statistics {
        queue.sync { stats }
    }

    /// Öffnet den Socket für QEMU und startet die vmnet-Schnittstelle. Blockiert, bis vmnet antwortet.
    /// Darf nicht auf der internen Queue aufgerufen werden.
    public func start(timeout: TimeInterval = 10) throws {
        guard queue.sync(execute: { interface == nil }) else { return }
        let listenFD = try UnixStream.listen(socketPath)

        let description = xpc_dictionary_create(nil, nil, 0)
        // Der Gast benutzt seine eigene MAC-Adresse (für die DHCP-Reservierung).
        xpc_dictionary_set_bool(description, vmnet_allocate_mac_address_key, false)
        // Ganze, normale Ethernet-Rahmen: QEMU erwartet keine Segmentierungs-Hilfen.
        xpc_dictionary_set_bool(description, vmnet_enable_tso_key, false)
        xpc_dictionary_set_bool(description, vmnet_enable_checksum_offload_key, false)

        let semaphore = DispatchSemaphore(value: 0)
        let result = StartResult()
        let started = vmnet_interface_start_with_network(network.ref, description, queue) { status, params in
            result.status = status
            result.parameters = params
            semaphore.signal()
        }
        guard let started else {
            closeListener(listenFD)
            throw VMNetworkError.vmnet("Schnittstelle starten", 1001)
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            _ = vmnet_stop_interface(started, DispatchQueue.global()) { _ in }
            closeListener(listenFD)
            throw VMNetworkError.timeout
        }
        guard result.status == .VMNET_SUCCESS else {
            closeListener(listenFD)
            throw VMNetworkError.vmnet("Schnittstelle starten", Int(result.status.rawValue))
        }
        var reportedMTU = 0
        var reportedMax = 0
        if let parameters = result.parameters {
            reportedMTU = Int(xpc_dictionary_get_uint64(parameters, vmnet_mtu_key))
            reportedMax = Int(xpc_dictionary_get_uint64(parameters, vmnet_max_packet_size_key))
        }

        queue.sync {
            if reportedMTU > 0 { mtu = reportedMTU }
            if reportedMax > 0 { maxPacketSize = reportedMax }
            maxPacketSize = max(maxPacketSize, mtu + 18)
            allocateBuffers()
            interface = started

            let accept = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
            accept.setEventHandler { [weak self] in
                self?.acceptClient(listenFD)
            }
            // Die Socket-Datei bleibt liegen: Ein neuer Start derselben VM hat sie womöglich schon
            // neu angelegt. Aufgeräumt wird vor dem nächsten Start.
            accept.setCancelHandler {
                close(listenFD)
            }
            accept.resume()
            acceptSource = accept
        }

        _ = vmnet_interface_set_event_callback(started, interface_event_t.VMNET_INTERFACE_PACKETS_AVAILABLE, queue) { [weak self] _, event in
            let estimate = Int(xpc_dictionary_get_uint64(event, vmnet_estimated_packets_available_key))
            self?.forwardFromNetwork(estimate: estimate)
        }
    }

    /// Hält die Brücke an und gibt Socket und Schnittstelle frei.
    public func stop() {
        let stopped = queue.sync { shutDownLocked() }
        PacketRelay.stopInterface(stopped)
    }

    /// Schickt einen Rahmen so ins Netz, als käme er vom Gast (für Prüfprogramme).
    public func injectFromGuest(_ frame: [UInt8]) {
        queue.async { [weak self] in
            guard let self else { return }
            frame.withUnsafeBytes { self.queueToNetwork($0) }
            self.flushToNetwork()
        }
    }

    // MARK: Verbindung von QEMU

    private func acceptClient(_ listenFD: Int32) {
        let fd = Darwin.accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        // QEMU verbindet sich nach einem Neustart neu: alte Verbindung aufgeben.
        dropClient()
        UnixStream.configure(fd, sendBuffer: 2 << 20, receiveBuffer: 2 << 20)

        let readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let writeSource = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        let closer = DescriptorCloser(fd: fd, users: 2)
        readSource.setEventHandler { [weak self] in
            self?.readFromClient()
        }
        writeSource.setEventHandler { [weak self] in
            self?.flushToGuest()
        }
        readSource.setCancelHandler { closer.release() }
        writeSource.setCancelHandler { closer.release() }
        readSource.resume()
        // Die Schreibquelle läuft nur, solange Daten auf QEMU warten.
        client = Client(fd: fd, readSource: readSource, writeSource: writeSource)
        stats.connections += 1
    }

    private func dropClient() {
        guard let client else { return }
        self.client = nil
        if !client.writeSourceActive {
            // Eine angehaltene Quelle darf nicht freigegeben werden: erst fortsetzen, dann abmelden.
            client.writeSource.resume()
        }
        client.writeSource.cancel()
        client.readSource.cancel()
        decoder.reset()
        outbound.removeAll(keepingCapacity: true)
        outboundStart = 0
        pendingWrites = 0
    }

    // MARK: Gast -> vmnet

    private func readFromClient() {
        guard let client, let buffer = receiveBuffer else { return }
        let count = Darwin.read(client.fd, buffer, receiveChunk)
        if count == 0 {
            dropClient()
            return
        }
        if count < 0 {
            if errno != EAGAIN && errno != EINTR { dropClient() }
            return
        }
        do {
            try decoder.append(UnsafeRawBufferPointer(start: buffer, count: count)) { frame in
                queueToNetwork(frame)
            }
        } catch {
            // Kaputter Datenstrom: Verbindung neu aufbauen lassen.
            dropClient()
            return
        }
        flushToNetwork()
    }

    private func queueToNetwork(_ frame: UnsafeRawBufferPointer) {
        guard frame.count >= 14, frame.count <= maxPacketSize, let source = frame.baseAddress,
              let packets = writePackets, let iovecs = writeIovecs, let target = iovecs[pendingWrites].iov_base else {
            stats.droppedFromGuest += 1
            return
        }
        if watcher != nil, let address = watcher?.observe(frame) {
            learnedAddress = address
            onGuestAddress?(address)
        }
        memcpy(target, source, frame.count)
        iovecs[pendingWrites].iov_len = frame.count
        packets[pendingWrites].vm_pkt_size = frame.count
        packets[pendingWrites].vm_pkt_iov = iovecs + pendingWrites
        packets[pendingWrites].vm_pkt_iovcnt = 1
        packets[pendingWrites].vm_flags = 0
        pendingWrites += 1
        if pendingWrites == batchSize {
            flushToNetwork()
        }
    }

    private func flushToNetwork() {
        guard pendingWrites > 0 else { return }
        let queued = pendingWrites
        pendingWrites = 0
        guard let interface, let packets = writePackets else {
            stats.droppedFromGuest += UInt64(queued)
            return
        }
        var count = Int32(queued)
        if vmnet_write(interface, packets, &count) == .VMNET_SUCCESS {
            stats.framesFromGuest += UInt64(count)
            stats.droppedFromGuest += UInt64(queued - Int(count))
        } else {
            stats.droppedFromGuest += UInt64(queued)
        }
    }

    // MARK: vmnet -> Gast

    private func forwardFromNetwork(estimate: Int) {
        guard let interface, let packets = readPackets, let iovecs = readIovecs else { return }
        while true {
            let wanted = min(max(estimate, 1), batchSize)
            for index in 0..<wanted {
                iovecs[index].iov_len = maxPacketSize
                packets[index].vm_pkt_size = maxPacketSize
                packets[index].vm_pkt_iov = iovecs + index
                packets[index].vm_pkt_iovcnt = 1
                packets[index].vm_flags = 0
            }
            var count = Int32(wanted)
            let status = vmnet_read(interface, packets, &count)
            guard status == .VMNET_SUCCESS, count > 0 else { break }
            for index in 0..<Int(count) {
                let size = packets[index].vm_pkt_size
                guard let base = iovecs[index].iov_base else { continue }
                let frame = UnsafeRawBufferPointer(start: base, count: size)
                if let frameObserver {
                    frameObserver(Array(frame))
                }
                guard client != nil, outbound.count - outboundStart + StreamFraming.headerSize + size <= outboundLimit else {
                    // Keine Verbindung (QEMU startet noch) oder QEMU kommt nicht hinterher.
                    stats.droppedToGuest += 1
                    continue
                }
                outbound.append(contentsOf: StreamFraming.header(length: size))
                outbound.append(contentsOf: frame)
                stats.framesToGuest += 1
            }
            if Int(count) < wanted { break }
        }
        stats.peakBufferedToGuest = max(stats.peakBufferedToGuest, outbound.count - outboundStart)
        flushToGuest()
    }

    /// Schreibt wartende Bytes an QEMU, ohne zu blockieren. Was nicht passt, schreibt die
    /// Schreibquelle, sobald QEMU wieder liest.
    private func flushToGuest() {
        guard let client else { return }
        while outboundStart < outbound.count {
            let written = outbound.withUnsafeBytes { raw in
                Darwin.write(client.fd, raw.baseAddress! + outboundStart, raw.count - outboundStart)
            }
            if written > 0 {
                outboundStart += written
                continue
            }
            if written < 0 && errno == EINTR { continue }
            if written < 0 && errno == EAGAIN {
                if !client.writeSourceActive {
                    client.writeSource.resume()
                    client.writeSourceActive = true
                }
                if outboundStart >= outbound.count / 2 {
                    outbound.removeFirst(outboundStart)
                    outboundStart = 0
                }
                return
            }
            dropClient()
            return
        }
        outbound.removeAll(keepingCapacity: true)
        outboundStart = 0
        if client.writeSourceActive {
            client.writeSource.suspend()
            client.writeSourceActive = false
        }
    }

    // MARK: Aufräumen

    /// Meldet Quellen ab und gibt die Schnittstelle zum Anhalten zurück. Nur auf der `queue`
    /// oder in `deinit` aufrufen.
    private func shutDownLocked() -> interface_ref? {
        acceptSource?.cancel()
        acceptSource = nil
        dropClient()
        let stopped = interface
        interface = nil
        return stopped
    }

    private static func stopInterface(_ stopped: interface_ref?) {
        guard let stopped else { return }
        _ = vmnet_interface_set_event_callback(stopped, interface_event_t.VMNET_INTERFACE_PACKETS_AVAILABLE, nil, nil)
        let semaphore = DispatchSemaphore(value: 0)
        let status = vmnet_stop_interface(stopped, DispatchQueue.global()) { _ in
            semaphore.signal()
        }
        if status == .VMNET_SUCCESS {
            _ = semaphore.wait(timeout: .now() + 3)
        }
    }

    private func closeListener(_ fd: Int32) {
        close(fd)
        unlink(socketPath)
    }

    // MARK: Speicher

    private func allocateBuffers() {
        freeBuffers()
        let storageSize = batchSize * maxPacketSize
        let rStorage = UnsafeMutableRawPointer.allocate(byteCount: storageSize, alignment: 16)
        let wStorage = UnsafeMutableRawPointer.allocate(byteCount: storageSize, alignment: 16)
        let rIovecs = UnsafeMutablePointer<iovec>.allocate(capacity: batchSize)
        let wIovecs = UnsafeMutablePointer<iovec>.allocate(capacity: batchSize)
        let rPackets = UnsafeMutablePointer<vmpktdesc>.allocate(capacity: batchSize)
        let wPackets = UnsafeMutablePointer<vmpktdesc>.allocate(capacity: batchSize)
        for index in 0..<batchSize {
            rIovecs[index] = iovec(iov_base: rStorage + index * maxPacketSize, iov_len: maxPacketSize)
            wIovecs[index] = iovec(iov_base: wStorage + index * maxPacketSize, iov_len: maxPacketSize)
            rPackets[index] = vmpktdesc(vm_pkt_size: maxPacketSize, vm_pkt_iov: rIovecs + index, vm_pkt_iovcnt: 1, vm_flags: 0)
            wPackets[index] = vmpktdesc(vm_pkt_size: maxPacketSize, vm_pkt_iov: wIovecs + index, vm_pkt_iovcnt: 1, vm_flags: 0)
        }
        readStorage = rStorage
        writeStorage = wStorage
        readIovecs = rIovecs
        writeIovecs = wIovecs
        readPackets = rPackets
        writePackets = wPackets
        receiveBuffer = UnsafeMutableRawPointer.allocate(byteCount: receiveChunk, alignment: 16)
    }

    private func freeBuffers() {
        readPackets?.deallocate()
        writePackets?.deallocate()
        readIovecs?.deallocate()
        writeIovecs?.deallocate()
        readStorage?.deallocate()
        writeStorage?.deallocate()
        receiveBuffer?.deallocate()
        readPackets = nil
        writePackets = nil
        readIovecs = nil
        writeIovecs = nil
        readStorage = nil
        writeStorage = nil
        receiveBuffer = nil
    }
}

/// Ergebnis des asynchronen Starts einer vmnet-Schnittstelle.
private final class StartResult: @unchecked Sendable {
    var status = vmnet_return_t.VMNET_FAILURE
    var parameters: xpc_object_t?
}

/// Schließt einen Deskriptor, sobald alle Dispatch-Quellen darauf abgemeldet sind.
/// Nur auf einer seriellen Queue benutzt.
private final class DescriptorCloser: @unchecked Sendable {
    private let fd: Int32
    private var users: Int

    init(fd: Int32, users: Int) {
        self.fd = fd
        self.users = users
    }

    func release() {
        users -= 1
        if users == 0 {
            close(fd)
        }
    }
}

/// Unix-Stream-Sockets für die Paketbrücke und das Prüfprogramm.
public enum UnixStream {
    public static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else {
            throw VMNetworkError.socket("Pfad zu lang: \(path)", ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (index, byte) in bytes.enumerated() {
                raw[index] = byte
            }
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    /// Lauschender Socket an `path` (nicht blockierend). Nur der eigene Benutzer darf sich verbinden.
    public static func listen(_ path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw VMNetworkError.socket("socket", errno) }
        unlink(path)
        var address = try self.address(path)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw VMNetworkError.socket("bind \(path)", code)
        }
        chmod(path, 0o600)
        guard Darwin.listen(fd, 4) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            throw VMNetworkError.socket("listen \(path)", code)
        }
        setNonBlocking(fd)
        return fd
    }

    /// Verbindet sich mit `path` (blockierend).
    public static func connect(_ path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw VMNetworkError.socket("socket", errno) }
        var address = try self.address(path)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            close(fd)
            throw VMNetworkError.socket("connect \(path)", code)
        }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    /// Nicht blockierend, kein SIGPIPE, große Puffer.
    public static func configure(_ fd: Int32, sendBuffer: Int32, receiveBuffer: Int32) {
        var send = sendBuffer
        var receive = receiveBuffer
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &send, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &receive, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        setNonBlocking(fd)
    }

    static func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    /// Schreibt alle Bytes (blockierender Socket).
    @discardableResult
    public static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var offset = 0
        return bytes.withUnsafeBytes { raw in
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0 && errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    /// Wartet bis zu `timeout` Sekunden auf Daten und liest, was da ist.
    public static func read(_ fd: Int32, maxLength: Int = 65536, timeout: TimeInterval) -> [UInt8]? {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let milliseconds = Int32(max(0, timeout * 1000))
        guard poll(&descriptor, 1, milliseconds) > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: maxLength)
        let length = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, maxLength) }
        guard length > 0 else { return nil }
        return Array(buffer[0..<length])
    }
}
