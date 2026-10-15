import AppKit
import PluralismCore

/// Hülle um `VZVirtualMachineView`, die Scroll-Ereignisse anpasst, bevor Virtualization sie bekommt.
///
/// Virtualization rechnet Trackpad-Bewegungen selbst in Mausrad-Schritte für den Linux-Gast um. Je nach
/// Programm wirkt das zu schnell oder zu langsam; Linux bietet für ein virtuelles Mausrad keine eigene
/// Einstellung. Pluralism skaliert deshalb die Bewegung (Geschwindigkeit), kann den Nachlauf nach dem
/// Loslassen weglassen und die Richtung umkehren. Dafür ersetzt ein lokaler Ereignis-Monitor das
/// Scroll-Ereignis durch eine angepasste Kopie.
@MainActor
final class ScrollTuningView: NSView {
    let content: NSView
    var settings: ScrollTranslator.Settings
    private var monitor: Any?
    /// Nachkommastellen, die beim Runden der Punktwerte übrig bleiben (sonst gingen langsame Bewegungen verloren).
    private var remainderX = 0.0
    private var remainderY = 0.0

    init(content: NSView, settings: ScrollTranslator.Settings) {
        self.content = content
        self.settings = settings
        super.init(frame: content.frame)
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) wird nicht unterstützt")
    }

    override var acceptsFirstResponder: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            installMonitor()
            // Tastatur gleich an die VM, ohne erst ins Bild klicken zu müssen.
            Task { [weak self] in
                guard let self else { return }
                self.window?.makeFirstResponder(self.content)
            }
        } else {
            removeMonitor()
        }
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return self.adjust(event)
        }
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    private func adjust(_ event: NSEvent) -> NSEvent? {
        guard event.window === window, let window else { return event }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point), window.isKeyWindow || window.isMainWindow else { return event }
        if !settings.momentum, !event.momentumPhase.isEmpty {
            return nil
        }
        let factor = min(max(settings.speed, 0.1), 5) * (settings.invert ? -1 : 1)
        guard factor != 1, let copy = event.cgEvent?.copy() else { return event }
        if event.phase.contains(.began) {
            remainderX = 0
            remainderY = 0
        }
        // Punkte (Trackpad), mit Rest über Ereignisse hinweg
        let pointY = Double(copy.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)) * factor + remainderY
        let pointX = Double(copy.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)) * factor + remainderX
        let roundedY = pointY.rounded(.towardZero)
        let roundedX = pointX.rounded(.towardZero)
        remainderY = pointY - roundedY
        remainderX = pointX - roundedX
        copy.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(roundedY))
        copy.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(roundedX))
        // Feinwerte und Zeilen (Mausrad) gleich mitskalieren
        for field in [CGEventField.scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2] {
            copy.setDoubleValueField(field, value: copy.getDoubleValueField(field) * factor)
        }
        for field in [CGEventField.scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2] {
            let lines = Double(copy.getIntegerValueField(field)) * factor
            copy.setIntegerValueField(field, value: Int64(lines.rounded()))
        }
        return NSEvent(cgEvent: copy) ?? event
    }
}
