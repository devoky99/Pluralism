/// Übersetzt Scrollbewegungen vom Trackpad oder Mausrad in Rastschritte des virtuellen Mausrads.
///
/// QEMU kennt nur ganze Rastschritte (wie ein klassisches Mausrad), kein stufenloses Scrollen.
/// Windows scrollt pro Rastschritt drei Zeilen, bei 100 % Skalierung etwa 50 Pixel. Ein Rastschritt
/// entspricht deshalb 50 Pixeln Fingerweg, gemessen in Pixeln des Gastbildschirms. So bewegt sich der
/// Inhalt im Gast ungefähr so weit wie die Finger auf dem Trackpad.
///
/// Weitere Regeln:
/// - Pro Geste nur eine Richtung (senkrecht oder waagrecht), damit leichtes Abweichen nicht in die
///   andere Richtung scrollt.
/// - Schwung (das Nachlaufen nach dem Loslassen) lässt sich abschalten.
/// - Waagrecht scrollt der Gast mit Umschalt + Mausrad, weil QEMUs USB-Tablet nur ein senkrechtes Rad hat.
public struct ScrollTranslator: Sendable {
    public struct Settings: Equatable, Sendable {
        /// Faktor auf die Geschwindigkeit, 1 = Inhalt folgt den Fingern.
        public var speed: Double
        /// Schwung nach dem Loslassen weitergeben.
        public var momentum: Bool
        /// Richtung umkehren.
        public var invert: Bool

        public init(speed: Double = 1, momentum: Bool = true, invert: Bool = false) {
            self.speed = speed
            self.momentum = momentum
            self.invert = invert
        }
    }

    public enum Phase: Sendable {
        /// Finger setzen auf.
        case began
        /// Finger bewegen sich.
        case changed
        /// Finger heben ab.
        case ended
        /// Nachlauf nach dem Abheben.
        case momentum
        /// Ein klassisches Mausrad (ein Ereignis pro Raste, Werte in Zeilen).
        case wheel
    }

    /// Rastschritte: positiv heißt nach oben bzw. nach links scrollen.
    public struct Steps: Equatable, Sendable {
        public var vertical: Int
        public var horizontal: Int

        public init(vertical: Int = 0, horizontal: Int = 0) {
            self.vertical = vertical
            self.horizontal = horizontal
        }

        public var isEmpty: Bool { vertical == 0 && horizontal == 0 }
    }

    enum Axis: Sendable {
        case vertical
        case horizontal
    }

    /// Pixel des Gastbildschirms pro Rastschritt (drei Zeilen in Windows).
    public static let guestPixelsPerStep: Double = 50
    /// Höchstens so viele Rastschritte pro Ereignis, damit ein Ruck den Gast nicht überflutet.
    public static let maxStepsPerEvent = 6

    private var accumulatedX = 0.0
    private var accumulatedY = 0.0
    private var axis: Axis?

    public init() {}

    /// - Parameters:
    ///   - deltaX, deltaY: Bewegung wie von macOS gemeldet (positiv: Inhalt nach rechts bzw. unten,
    ///     also nach links bzw. oben scrollen). Beim Trackpad in Punkten, beim Mausrad in Zeilen.
    ///   - guestPixelsPerPoint: Pixel des Gastbildschirms pro Punkt im Fenster.
    public mutating func translate(deltaX: Double, deltaY: Double, phase: Phase,
                                   guestPixelsPerPoint: Double, settings: Settings) -> Steps {
        let sign: Double = settings.invert ? -1 : 1
        let speed = min(max(settings.speed, 0.1), 5)

        switch phase {
        case .began:
            accumulatedX = 0
            accumulatedY = 0
            axis = nil
        case .momentum where !settings.momentum:
            return Steps()
        case .wheel:
            // Klassisches Rad: eine Zeile entspricht einer Raste.
            accumulatedY += deltaY * sign * speed
            accumulatedX += deltaX * sign * speed
            return takeSteps(unit: 1)
        default:
            break
        }

        let scale = max(guestPixelsPerPoint, 0.1) * speed * sign
        var dx = deltaX * scale
        var dy = deltaY * scale
        if axis == nil, max(abs(dx), abs(dy)) >= 2 {
            axis = abs(dx) > abs(dy) ? .horizontal : .vertical
        }
        switch axis {
        case .vertical: dx = 0
        case .horizontal: dy = 0
        case nil: return Steps()
        }
        accumulatedX += dx
        accumulatedY += dy
        return takeSteps(unit: ScrollTranslator.guestPixelsPerStep)
    }

    private mutating func takeSteps(unit: Double) -> Steps {
        let limit = ScrollTranslator.maxStepsPerEvent
        let vertical = max(-limit, min(limit, Int(accumulatedY / unit)))
        let horizontal = max(-limit, min(limit, Int(accumulatedX / unit)))
        accumulatedY -= Double(vertical) * unit
        accumulatedX -= Double(horizontal) * unit
        // Was über die Grenze hinausgeht, verfällt: kein Nachlaufen über viele Ereignisse.
        accumulatedY = max(-unit, min(unit, accumulatedY))
        accumulatedX = max(-unit, min(unit, accumulatedX))
        return Steps(vertical: vertical, horizontal: horizontal)
    }
}
