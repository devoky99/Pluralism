import Foundation
@testable import PluralismCore
import XCTest

final class ScrollTests: XCTestCase {
    let standard = ScrollTranslator.Settings()

    /// Eine Geste mit `count` gleichen Schritten, Summe der Rastschritte.
    func gesture(_ translator: inout ScrollTranslator, dx: Double = 0, dy: Double, count: Int,
                 pixelsPerPoint: Double = 1, settings: ScrollTranslator.Settings) -> ScrollTranslator.Steps {
        var total = ScrollTranslator.Steps()
        for index in 0..<count {
            let steps = translator.translate(deltaX: dx, deltaY: dy, phase: index == 0 ? .began : .changed,
                                             guestPixelsPerPoint: pixelsPerPoint, settings: settings)
            total.vertical += steps.vertical
            total.horizontal += steps.horizontal
        }
        return total
    }

    func testTrackpadDistanceMatchesWindowsLineSteps() {
        var translator = ScrollTranslator()
        // 300 Punkte nach unten gewischt (Inhalt nach unten = nach oben scrollen), Gast 1:1
        let steps = gesture(&translator, dy: 10, count: 30, settings: standard)
        XCTAssertEqual(steps.vertical, 6)                    // 300 / 50
        XCTAssertEqual(steps.horizontal, 0)
    }

    func testGuestScaleAndSpeed() {
        var translator = ScrollTranslator()
        // Gast doppelt so groß wie das Fenster: 150 Punkte sind 300 Gastpixel
        XCTAssertEqual(gesture(&translator, dy: -5, count: 30, pixelsPerPoint: 2, settings: standard).vertical, -6)
        var slow = ScrollTranslator()
        XCTAssertEqual(gesture(&slow, dy: 10, count: 30, settings: .init(speed: 0.5)).vertical, 3)
    }

    func testAxisLockKeepsGestureStraight() {
        var translator = ScrollTranslator()
        // Überwiegend senkrecht mit etwas seitlichem Zittern
        let steps = gesture(&translator, dx: 4, dy: 10, count: 30, settings: standard)
        XCTAssertEqual(steps.horizontal, 0)
        XCTAssertEqual(steps.vertical, 6)
        var sideways = ScrollTranslator()
        let horizontal = gesture(&sideways, dx: -10, dy: 3, count: 20, settings: standard)
        XCTAssertEqual(horizontal.vertical, 0)
        XCTAssertEqual(horizontal.horizontal, -4)
    }

    func testMomentumCanBeSwitchedOff() {
        var translator = ScrollTranslator()
        _ = gesture(&translator, dy: 10, count: 5, settings: standard)
        let withMomentum = translator.translate(deltaX: 0, deltaY: 60, phase: .momentum, guestPixelsPerPoint: 1, settings: standard)
        XCTAssertEqual(withMomentum.vertical, 1)
        let without = translator.translate(deltaX: 0, deltaY: 300, phase: .momentum, guestPixelsPerPoint: 1,
                                           settings: .init(momentum: false))
        XCTAssertTrue(without.isEmpty)
    }

    func testInvertAndMouseWheel() {
        var translator = ScrollTranslator()
        let wheel = translator.translate(deltaX: 0, deltaY: 1, phase: .wheel, guestPixelsPerPoint: 1, settings: standard)
        XCTAssertEqual(wheel.vertical, 1)
        let inverted = translator.translate(deltaX: 0, deltaY: 1, phase: .wheel, guestPixelsPerPoint: 1, settings: .init(invert: true))
        XCTAssertEqual(inverted.vertical, -1)
    }

    func testBurstIsLimitedAndDoesNotRunAway() {
        var translator = ScrollTranslator()
        let first = translator.translate(deltaX: 0, deltaY: 2000, phase: .began, guestPixelsPerPoint: 1, settings: standard)
        XCTAssertEqual(first.vertical, ScrollTranslator.maxStepsPerEvent)
        // Der Rest verfällt, das nächste kleine Ereignis löst höchstens einen Schritt aus
        let next = translator.translate(deltaX: 0, deltaY: 1, phase: .changed, guestPixelsPerPoint: 1, settings: standard)
        XCTAssertLessThanOrEqual(next.vertical, 1)
    }

    func testPeripheralScrollSettingsDecodeWithDefaultsAndClamp() throws {
        let old = try JSONDecoder().decode(PeripheralSettings.self, from: Data(#"{"audioOutput":true}"#.utf8))
        XCTAssertEqual(old.scrollSpeed, 1)
        XCTAssertTrue(old.scrollMomentum)
        XCTAssertFalse(old.invertScroll)
        let wild = try JSONDecoder().decode(PeripheralSettings.self, from: Data(#"{"scrollSpeed":20}"#.utf8))
        XCTAssertEqual(wild.scrollSpeed, 3)
        XCTAssertEqual(wild.scrollSettings.speed, 3)
    }
}
