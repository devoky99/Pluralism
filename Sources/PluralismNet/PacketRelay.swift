import Darwin
import Dispatch
import Foundation
import PluralismCore
import vmnet

/// Paketbrücke zwischen einer QEMU-Netzwerkkarte und einem vmnet-Netz.
///
/// QEMU läuft mit `-netdev dgram`: Jeder Ethernet-Rahmen des Gasts kommt als ein Datagramm
/// über einen Unix-Socket bei Pluralism an und geht unverändert an vmnet, und umgekehrt.
/// So bekommt die Windows-VM Apples schnellen Netzstack, ohne dass QEMU Root-Rechte braucht.
public final class PacketRelay {
    public struct Statistics: Equatable, Sendable {
        public var framesToGuest: UInt64 = 0
        public var framesFromGuest: UInt64 = 0
        public var droppedToGuest: UInt64 = 0
        public var droppedFromGuest: UInt64 = 0
    }

    public let network: VMNetwork
    public let hostSocketPath: String
    public let guestSocketPath: String
    public private(set) var mtu: Int = 1500
    public private(set) var maxPacketSize: Int = 1514

    /// Wird (auf einer internen Queue) aufgerufen, wenn ein Rahmen vom Netz für den Gast ankommt.
    /// Nur für Prüfprogramme gedacht; normalerweise gehen die Rahmen direkt an QEMU.
    public var frameObserver: (([UInt8]) -> Void)?

    private let queue = DispatchQueue(label: "pluralism.net.relay", qos: .userInteractive)
    private var interface: interface_ref?
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var guestAddress = sockaddr_un()
    private var stats = Statistics()

    private let batchSize = 64
    private var readPackets: UnsafeMutablePointer<vmpktdesc>?
    private var readIovecs: UnsafeMutablePointer<iovec>?
    private var readStorage: UnsafeMutableRawPointer?
    private var writePackets: UnsafeMutablePointer<vmpktdesc>?
    private var writeIovecs: UnsafeMutablePointer<iovec>?
    private var writeStorage: UnsafeMutableRawPointer?

    public init(network: VMNetwork, hostSocketPath: String, guestSocketPath: String) {
        self.network = network
        self.hostSocketPath = hostSocketPath
        self.guestSocketPath = guestSocketPath
    }

    deinit {
        stop()
        freeBuffers()
    }

    public var statistics: Statistics {
        queue.sync { stats }
    }

    /// Bindet den Socket und startet die vmnet-Schnittstelle. Blockiert, bis vmnet antwortet.
    /// Darf nicht auf der internen Queue aufgerufen werden.
    public func start(timeout: TimeInterval = 10) throws {
        guard interface == nil else { return }
        guestAddress = try UnixDatagram.address(guestSocketPath)
        fd = try UnixDatagram.bind(hostSocketPath)

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
            cleanupSocket()
            throw VMNetworkError.vmnet("Schnittstelle starten", 1001)
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            _ = vmnet_stop_interface(started, DispatchQueue.global()) { _ in }
            cleanupSocket()
            throw VMNetworkError.timeout
        }
        guard result.status == .VMNET_SUCCESS else {
            cleanupSocket()
            throw VMNetworkError.vmnet("Schnittstelle starten", Int(result.status.rawValue))
        }
        if let parameters = result.parameters {
            let reportedMTU = Int(xpc_dictionary_get_uint64(parameters, vmnet_mtu_key))
            let reportedMax = Int(xpc_dictionary_get_uint64(parameters, vmnet_max_packet_size_key))
            if reportedMTU > 0 { mtu = reportedMTU }
            if reportedMax > 0 { maxPacketSize = reportedMax }
        }
        maxPacketSize = max(maxPacketSize, mtu + 18)
        allocateBuffers()

        queue.sync {
            interface = started
        }

        _ = vmnet_interface_set_event_callback(started, interface_event_t.VMNET_INTERFACE_PACKETS_AVAILABLE, queue) { [weak self] _, event in
            let estimate = Int(xpc_dictionary_get_uint64(event, vmnet_estimated_packets_available_key))
            self?.forwardFromNetwork(estimate: estimate)
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.forwardFromGuest()
        }
        source.resume()
        queue.sync {
            readSource = source
        }
    }

    /// Hält die Brücke an und gibt Socket und Schnittstelle frei.
    public func stop() {
        var stoppedInterface: interface_ref?
        queue.sync {
            readSource?.cancel()
            readSource = nil
            stoppedInterface = interface
            interface = nil
        }
        if let stoppedInterface {
            _ = vmnet_interface_set_event_callback(stoppedInterface, interface_event_t.VMNET_INTERFACE_PACKETS_AVAILABLE, nil, nil)
            let semaphore = DispatchSemaphore(value: 0)
            let status = vmnet_stop_interface(stoppedInterface, DispatchQueue.global()) { _ in
                semaphore.signal()
            }
            if status == .VMNET_SUCCESS {
                _ = semaphore.wait(timeout: .now() + 3)
            }
        }
        cleanupSocket()
    }

    /// Schickt einen Rahmen so ins Netz, als käme er vom Gast (für Prüfprogramme).
    public func injectFromGuest(_ frame: [UInt8]) {
        queue.async { [weak self] in
            guard let self, let interface = self.interface, let packets = self.writePackets,
                  let iovecs = self.writeIovecs, frame.count <= self.maxPacketSize else { return }
            frame.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress, let target = iovecs[0].iov_base else { return }
                memcpy(target, base, frame.count)
            }
            iovecs[0].iov_len = frame.count
            packets[0].vm_pkt_size = frame.count
            packets[0].vm_pkt_iovcnt = 1
            packets[0].vm_flags = 0
            var count: Int32 = 1
            if vmnet_write(interface, packets, &count) == .VMNET_SUCCESS, count == 1 {
                self.stats.framesFromGuest += 1
            } else {
                self.stats.droppedFromGuest += 1
            }
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
            guard status == .VMNET_SUCCESS, count > 0 else { return }
            for index in 0..<Int(count) {
                let size = packets[index].vm_pkt_size
                guard let base = iovecs[index].iov_base else { continue }
                if let frameObserver {
                    frameObserver(Array(UnsafeRawBufferPointer(start: base, count: size)))
                }
                let sent = withUnsafePointer(to: &guestAddress) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                        sendto(fd, base, size, 0, address, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
                if sent == size {
                    stats.framesToGuest += 1
                } else {
                    // QEMU läuft noch nicht oder ist beendet: Rahmen verwerfen wie ein echtes Netz.
                    stats.droppedToGuest += 1
                }
            }
            if Int(count) < wanted { return }
        }
    }

    // MARK: Gast -> vmnet

    private func forwardFromGuest() {
        guard let interface, let packets = writePackets, let iovecs = writeIovecs else { return }
        while true {
            var received = 0
            while received < batchSize {
                guard let buffer = iovecs[received].iov_base else { break }
                let length = recv(fd, buffer, maxPacketSize, MSG_DONTWAIT)
                if length <= 0 { break }
                iovecs[received].iov_len = length
                packets[received].vm_pkt_size = length
                packets[received].vm_pkt_iov = iovecs + received
                packets[received].vm_pkt_iovcnt = 1
                packets[received].vm_flags = 0
                received += 1
            }
            guard received > 0 else { return }
            var count = Int32(received)
            if vmnet_write(interface, packets, &count) == .VMNET_SUCCESS {
                stats.framesFromGuest += UInt64(count)
                stats.droppedFromGuest += UInt64(received - Int(count))
            } else {
                stats.droppedFromGuest += UInt64(received)
            }
            if received < batchSize { return }
        }
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
    }

    private func freeBuffers() {
        readPackets?.deallocate()
        writePackets?.deallocate()
        readIovecs?.deallocate()
        writeIovecs?.deallocate()
        readStorage?.deallocate()
        writeStorage?.deallocate()
        readPackets = nil
        writePackets = nil
        readIovecs = nil
        writeIovecs = nil
        readStorage = nil
        writeStorage = nil
    }

    private func cleanupSocket() {
        if fd >= 0 {
            close(fd)
            fd = -1
        }
        unlink(hostSocketPath)
    }
}

/// Ergebnis des asynchronen Starts einer vmnet-Schnittstelle.
private final class StartResult: @unchecked Sendable {
    var status = vmnet_return_t.VMNET_FAILURE
    var parameters: xpc_object_t?
}

/// Unix-Datagramm-Sockets für die Paketbrücke.
public enum UnixDatagram {
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

    /// Legt einen Datagramm-Socket an, bindet ihn an `path` und stellt ihn auf nicht blockierend.
    public static func bind(_ path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw VMNetworkError.socket("socket", errno) }
        unlink(path)
        var address = try self.address(path)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            close(fd)
            throw VMNetworkError.socket("bind \(path)", code)
        }
        // Größere Puffer: Datagramme bis 64 KB, Warteschlange für Lastspitzen.
        var sendBuffer: Int32 = 1 << 20
        var receiveBuffer: Int32 = 4 << 20
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sendBuffer, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &receiveBuffer, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        return fd
    }

    /// Schickt ein Datagramm an `address`.
    @discardableResult
    public static func send(_ fd: Int32, _ bytes: [UInt8], to address: sockaddr_un) -> Int {
        var target = address
        return bytes.withUnsafeBytes { buffer in
            withUnsafePointer(to: &target) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, buffer.baseAddress, buffer.count, 0, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
        }
    }

    /// Wartet bis zu `timeout` Sekunden auf ein Datagramm.
    public static func receive(_ fd: Int32, maxLength: Int = 65536, timeout: TimeInterval) -> [UInt8]? {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let milliseconds = Int32(max(0, timeout * 1000))
        guard poll(&descriptor, 1, milliseconds) > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: maxLength)
        let length = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, maxLength, 0) }
        guard length > 0 else { return nil }
        return Array(buffer[0..<length])
    }
}
