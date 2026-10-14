import AppKit
import Carbon
import PluralismCore

/// Zeigt das Bild einer QEMU-VM an und leitet Tastatur und Maus weiter.
///
/// Tastatur wie bei Parallels:
/// - Tasten werden als PC-Scancodes übertragen, das Layout im Gast entscheidet über die Zeichen.
/// - Cmd + Buchstabe wird zu Strg + Buchstabe (Kopieren, Einfügen, Speichern, ...).
/// - Cmd allein gedrückt und losgelassen öffnet das Startmenü (Windows-Taste).
/// - Cmd+Q, Cmd+W, Cmd+H, Cmd+M und Cmd+Tab bleiben beim Mac.
final class RFBDisplayView: NSView {
    private(set) var connection: RFBConnection?
    var layout: KeyboardMapping.PhysicalLayout = RFBDisplayView.detectPhysicalLayout()

    private var buttonMask: UInt8 = 0
    private var commandDown = false
    private var commandUsedWithOtherKey = false
    private var pressedScancodes: [UInt32: UInt32] = [:]   // Scancode -> Keysym
    private var trackingArea: NSTrackingArea?
    private var lastClipboardSent: String?
    private var scrollAccumulatorY: CGFloat = 0
    private var scrollAccumulatorX: CGFloat = 0
    private var keyWindowObserver: NSObjectProtocol?

    /// Mac-Kürzel, die beim Mac bleiben.
    private static let macOnlyCommandKeys: Set<UInt16> = [0x0C, 0x0D, 0x04, 0x2E, 0x30, 0x32, 0x2F]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
        layer?.magnificationFilter = .linear
        layer?.minificationFilter = .linear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) wird nicht unterstützt")
    }

    deinit {
        if let keyWindowObserver {
            NotificationCenter.default.removeObserver(keyWindowObserver)
        }
    }

    // MARK: Verbindung

    func attach(_ connection: RFBConnection) {
        self.connection = connection
        connection.onUpdate = { [weak self] in self?.refresh() }
        connection.onResize = { [weak self] _, _ in self?.refresh() }
        connection.onClipboard = { [weak self] text in
            self?.lastClipboardSent = text
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
        refresh()
    }

    func detach() {
        connection = nil
        layer?.contents = nil
    }

    private func refresh() {
        layer?.contents = connection?.makeImage()
    }

    // MARK: Fenster und Fokus

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keyWindowObserver {
            NotificationCenter.default.removeObserver(keyWindowObserver)
            self.keyWindowObserver = nil
        }
        guard let window else { return }
        keyWindowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                                                   object: window, queue: .main) { [weak self] _ in
            self?.syncClipboardToGuest()
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    override func becomeFirstResponder() -> Bool {
        syncClipboardToGuest()
        return true
    }

    override func resignFirstResponder() -> Bool {
        releaseAllKeys()
        return true
    }

    /// Mac-Zwischenablage an den Gast geben, wenn sie sich geändert hat.
    func syncClipboardToGuest(force: Bool = false) {
        guard let connection, let text = NSPasteboard.general.string(forType: .string) else { return }
        if force || text != lastClipboardSent {
            lastClipboardSent = text
            connection.sendClipboard(text)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: Maus

    private func imageRect() -> CGRect {
        guard let size = connection?.currentSize(), size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / CGFloat(size.width), bounds.height / CGFloat(size.height))
        let w = CGFloat(size.width) * scale
        let h = CGFloat(size.height) * scale
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    private func guestPoint(for event: NSEvent) -> (x: Int, y: Int)? {
        guard let size = connection?.currentSize(), size.width > 0, size.height > 0 else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let rect = imageRect()
        guard rect.width > 0, rect.height > 0 else { return nil }
        let x = (point.x - rect.minX) / rect.width * CGFloat(size.width)
        let y = (rect.maxY - point.y) / rect.height * CGFloat(size.height)
        let gx = Int(min(max(0, x), CGFloat(size.width - 1)))
        let gy = Int(min(max(0, y), CGFloat(size.height - 1)))
        return (gx, gy)
    }

    private func sendPointer(_ event: NSEvent, extraMask: UInt8 = 0) {
        guard let point = guestPoint(for: event) else { return }
        connection?.sendPointer(buttonMask: buttonMask | extraMask, x: point.x, y: point.y)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        // Ctrl-Klick wie am Mac als Rechtsklick behandeln
        if event.modifierFlags.contains(.control) {
            buttonMask |= RFBButton.right
        } else {
            buttonMask |= RFBButton.left
        }
        sendPointer(event)
    }

    override func mouseUp(with event: NSEvent) {
        buttonMask &= ~(RFBButton.left | RFBButton.right)
        sendPointer(event)
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        buttonMask |= RFBButton.right
        sendPointer(event)
    }

    override func rightMouseUp(with event: NSEvent) {
        buttonMask &= ~RFBButton.right
        sendPointer(event)
    }

    override func otherMouseDown(with event: NSEvent) {
        buttonMask |= RFBButton.middle
        sendPointer(event)
    }

    override func otherMouseUp(with event: NSEvent) {
        buttonMask &= ~RFBButton.middle
        sendPointer(event)
    }

    override func mouseMoved(with event: NSEvent) { sendPointer(event) }
    override func mouseDragged(with event: NSEvent) { sendPointer(event) }
    override func rightMouseDragged(with event: NSEvent) { sendPointer(event) }
    override func otherMouseDragged(with event: NSEvent) { sendPointer(event) }

    override func scrollWheel(with event: NSEvent) {
        let step: CGFloat = event.hasPreciseScrollingDeltas ? 12 : 1
        scrollAccumulatorY += event.scrollingDeltaY
        scrollAccumulatorX += event.scrollingDeltaX
        while abs(scrollAccumulatorY) >= step {
            let up = scrollAccumulatorY > 0
            clickWheel(up ? RFBButton.wheelUp : RFBButton.wheelDown, event: event)
            scrollAccumulatorY += up ? -step : step
        }
        while abs(scrollAccumulatorX) >= step {
            let left = scrollAccumulatorX > 0
            clickWheel(left ? RFBButton.wheelLeft : RFBButton.wheelRight, event: event)
            scrollAccumulatorX += left ? -step : step
        }
        if event.phase == .ended || event.momentumPhase == .ended {
            scrollAccumulatorX = 0
            scrollAccumulatorY = 0
        }
    }

    private func clickWheel(_ button: UInt8, event: NSEvent) {
        sendPointer(event, extraMask: button)
        sendPointer(event)
    }

    // MARK: Tastatur

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            if !translateCommandShortcut(event) {
                super.keyDown(with: event)
            }
            return
        }
        sendKeyEvent(event, down: true)
    }

    override func keyUp(with event: NSEvent) {
        if event.modifierFlags.contains(.command) { return }
        sendKeyEvent(event, down: false)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown,
              event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        if translateCommandShortcut(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Cmd + Taste als Strg + Taste an den Gast. Liefert false, wenn das Kürzel beim Mac bleibt.
    private func translateCommandShortcut(_ event: NSEvent) -> Bool {
        if RFBDisplayView.macOnlyCommandKeys.contains(event.keyCode) || event.modifierFlags.contains(.control) {
            return false
        }
        guard let scancode = KeyboardMapping.scancode(forMacKeyCode: event.keyCode, layout: layout) else {
            return true
        }
        commandUsedWithOtherKey = true
        let keysym = keysymFor(event)
        let controlScancode: UInt32 = 0x1D
        let controlKeysym: UInt32 = 0xFFE3
        connection?.sendKey(down: true, keysym: controlKeysym, scancode: controlScancode)
        connection?.sendKey(down: true, keysym: keysym, scancode: scancode)
        connection?.sendKey(down: false, keysym: keysym, scancode: scancode)
        connection?.sendKey(down: false, keysym: controlKeysym, scancode: controlScancode)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        let keyCode = event.keyCode
        guard KeyboardMapping.modifierKeyCodes.contains(keyCode),
              let scancode = KeyboardMapping.scancode(forMacKeyCode: keyCode, layout: layout) else {
            return
        }
        let keysym = KeyboardMapping.specialKeysyms[keyCode] ?? 0

        // Feststelltaste: macOS meldet nur das Umschalten, der Gast braucht Drücken und Loslassen.
        if keyCode == 0x39 {
            connection?.sendKey(down: true, keysym: keysym, scancode: scancode)
            connection?.sendKey(down: false, keysym: keysym, scancode: scancode)
            return
        }

        let down = Self.isModifierDown(keyCode: keyCode, flags: event.modifierFlags)

        // Cmd: erst beim Loslassen entscheiden, ob es ein Windows-Tastendruck war.
        if keyCode == 0x37 || keyCode == 0x36 {
            if down {
                commandDown = true
                commandUsedWithOtherKey = false
            } else {
                commandDown = false
                if !commandUsedWithOtherKey {
                    connection?.sendKey(down: true, keysym: keysym, scancode: scancode)
                    connection?.sendKey(down: false, keysym: keysym, scancode: scancode)
                }
            }
            return
        }

        if down {
            pressedScancodes[scancode] = keysym
        } else {
            pressedScancodes.removeValue(forKey: scancode)
        }
        connection?.sendKey(down: down, keysym: keysym, scancode: scancode)
    }

    private func sendKeyEvent(_ event: NSEvent, down: Bool) {
        guard let scancode = KeyboardMapping.scancode(forMacKeyCode: event.keyCode, layout: layout) else { return }
        let keysym = keysymFor(event)
        if down {
            pressedScancodes[scancode] = keysym
        } else {
            pressedScancodes.removeValue(forKey: scancode)
        }
        connection?.sendKey(down: down, keysym: keysym, scancode: scancode)
    }

    private func keysymFor(_ event: NSEvent) -> UInt32 {
        if let special = KeyboardMapping.specialKeysyms[event.keyCode] {
            return special
        }
        if let character = event.charactersIgnoringModifiers?.first {
            return KeyboardMapping.keysym(for: character)
        }
        return 0
    }

    /// Alle gedrückten Tasten loslassen (z. B. wenn das Fenster den Fokus verliert),
    /// damit im Gast keine Taste "hängen" bleibt.
    func releaseAllKeys() {
        for (scancode, keysym) in pressedScancodes {
            connection?.sendKey(down: false, keysym: keysym, scancode: scancode)
        }
        pressedScancodes.removeAll()
        commandDown = false
    }

    /// Prüft linke und rechte Modifikatortasten getrennt (geräteabhängige Bits von NSEvent).
    private static func isModifierDown(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        let raw = flags.rawValue
        switch keyCode {
        case 0x38: return raw & 0x0000_0002 != 0   // Shift links
        case 0x3C: return raw & 0x0000_0004 != 0   // Shift rechts
        case 0x3B: return raw & 0x0000_0001 != 0   // Control links
        case 0x3E: return raw & 0x0000_2000 != 0   // Control rechts
        case 0x3A: return raw & 0x0000_0020 != 0   // Option links
        case 0x3D: return raw & 0x0000_0040 != 0   // Option rechts
        case 0x37: return raw & 0x0000_0008 != 0   // Command links
        case 0x36: return raw & 0x0000_0010 != 0   // Command rechts
        default: return false
        }
    }

    /// Erkennt, ob die Mac-Tastatur ISO (z. B. deutsch) oder ANSI ist.
    static func detectPhysicalLayout() -> KeyboardMapping.PhysicalLayout {
        if let override = UserDefaults.standard.string(forKey: PreferenceKeys.keyboardLayout),
           let layout = KeyboardMapping.PhysicalLayout(rawValue: override) {
            return layout
        }
        let type = KBGetLayoutType(Int16(LMGetKbdType()))
        return type == UInt32(kKeyboardISO) ? .iso : .ansi
    }
}
