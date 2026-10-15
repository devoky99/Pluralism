import AppKit
import CoreGraphics
import Foundation
import PluralismCore
import Synchronization

/// Liest und schreibt Bytes über den Unix-Socket für das RFB-Protokoll.
private final class SocketByteStream: RFBByteSource, RFBByteSink, Sendable {
    let socket: UnixSocket

    init(socket: UnixSocket) {
        self.socket = socket
    }

    func read(exactly count: Int) throws -> [UInt8] {
        try socket.readExactly(count)
    }

    func write(_ bytes: [UInt8]) throws {
        try socket.writeAll(bytes)
    }
}

/// Verbindung zum VNC-Server einer QEMU-VM. Hält das Bild der VM im Speicher und
/// schickt Tastatur und Maus an den Gast. Eine Zwischenablage gibt es bewusst nicht.
///
/// Nebenläufigkeit: `stream` und `client` werden in `connect` gesetzt, bevor der Lesethread startet,
/// und danach nicht mehr geändert. Bildpuffer, Größe und `updateScheduled` schützt `lock`.
/// `running` ist atomar. Die Rückrufe gehören dem Main Actor.
final class RFBConnection: @unchecked Sendable {
    private var stream: SocketByteStream?
    private var client: RFBClientProtocol?
    private let sendQueue = DispatchQueue(label: "pluralism.rfb.send")
    private let lock = NSLock()
    /// Bild der VM (BGRX, 32 Bit). Lebt bis zur nächsten Größenänderung oder `deinit`, nur unter `lock`.
    private var buffer: UnsafeMutableRawPointer?
    private var width = 0
    private var height = 0
    private let running = Atomic<Bool>(false)
    private var updateScheduled = false

    /// Neues Bild verfügbar.
    @MainActor var onUpdate: (() -> Void)?
    /// Gast-Auflösung geändert.
    @MainActor var onResize: ((Int, Int) -> Void)?
    /// Verbindung beendet.
    @MainActor var onDisconnect: ((Error?) -> Void)?

    deinit {
        close()
        buffer?.deallocate()
    }

    /// Verbindet (mit Wiederholungen), führt den Handshake aus und startet den Lesethread.
    func connect(path: String, timeout: TimeInterval, isCancelled: () -> Bool) throws {
        let socket = try UnixSocket.connect(path: path, timeout: timeout, isCancelled: isCancelled)
        let stream = SocketByteStream(socket: socket)
        let client = RFBClientProtocol(source: stream, sink: stream)
        let info = try client.handshake()
        self.stream = stream
        self.client = client
        lock.lock()
        resizeLocked(width: info.width, height: info.height)
        lock.unlock()
        running.store(true, ordering: .releasing)
        let thread = Thread { [weak self] in
            self?.readLoop()
        }
        thread.name = "pluralism.rfb.read"
        thread.start()
    }

    func currentSize() -> (width: Int, height: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (width, height)
    }

    /// Kopie des aktuellen Bildes.
    func makeImage() -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        guard let buffer, width > 0, height > 0 else { return nil }
        let bytesPerRow = width * 4
        let data = Data(bytes: buffer, count: bytesPerRow * height)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo,
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: Eingaben

    func sendKey(down: Bool, keysym: UInt32, scancode: UInt32?) {
        sendQueue.async { [weak self] in
            try? self?.client?.sendKey(down: down, keysym: keysym, scancode: scancode)
        }
    }

    func sendPointer(buttonMask: UInt8, x: Int, y: Int) {
        sendQueue.async { [weak self] in
            try? self?.client?.sendPointer(buttonMask: buttonMask, x: x, y: y)
        }
    }

    func close() {
        running.store(false, ordering: .releasing)
        stream?.socket.close()
    }

    // MARK: Lesen

    private func readLoop() {
        guard let client else { return }
        var failure: Error?
        do {
            let size = currentSize()
            try client.requestUpdate(incremental: false, width: size.width, height: size.height)
            while running.load(ordering: .acquiring) {
                let message = try client.readMessage()
                switch message {
                case .framebufferUpdate(let rects):
                    var resized = false
                    lock.lock()
                    for rect in rects {
                        switch rect.content {
                        case .raw(let pixels):
                            if let buffer {
                                RFBFramebufferWriter.blitRaw(pixels, rect: rect, into: buffer,
                                                             bytesPerRow: width * 4, width: width, height: height)
                            }
                        case .copyRect(let sourceX, let sourceY):
                            if let buffer {
                                RFBFramebufferWriter.copyRect(sourceX: sourceX, sourceY: sourceY, rect: rect, in: buffer,
                                                              bytesPerRow: width * 4, width: width, height: height)
                            }
                        case .desktopSize:
                            resizeLocked(width: rect.width, height: rect.height)
                            resized = true
                        case .qemuExtendedKeySupport:
                            break
                        }
                    }
                    let w = width
                    let h = height
                    lock.unlock()
                    if resized {
                        MainQueue.async { [weak self] in self?.onResize?(w, h) }
                    }
                    scheduleUpdate()
                    try client.requestUpdate(incremental: !resized, width: w, height: h)
                case .serverCutText:
                    // Isolation: Zwischenablage-Inhalte des Gasts werden verworfen.
                    break
                case .bell:
                    MainQueue.async { NSSound.beep() }
                case .colorMapEntries:
                    break
                }
            }
        } catch {
            failure = error
        }
        running.store(false, ordering: .releasing)
        let reason = failure
        MainQueue.async { [weak self] in self?.onDisconnect?(reason) }
    }

    /// Fasst viele Bildänderungen zu einer Aktualisierung auf dem Hauptthread zusammen.
    private func scheduleUpdate() {
        lock.lock()
        let alreadyScheduled = updateScheduled
        updateScheduled = true
        lock.unlock()
        if alreadyScheduled { return }
        MainQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.updateScheduled = false
            self.lock.unlock()
            self.onUpdate?()
        }
    }

    private func resizeLocked(width newWidth: Int, height newHeight: Int) {
        buffer?.deallocate()
        buffer = nil
        width = max(0, newWidth)
        height = max(0, newHeight)
        let byteCount = width * height * 4
        if byteCount > 0 {
            let memory = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 16)
            memset(memory, 0, byteCount)
            buffer = memory
        }
    }
}
