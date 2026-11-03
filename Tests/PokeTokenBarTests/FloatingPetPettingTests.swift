import AppKit
import SwiftUI
import XCTest
@testable import PokeTokenBar

/// Stroking the floating pet: pure detector + priority/sizing logic. Real mouse strokes
/// cannot be simulated here; the detector is fed the (x, timestamp) samples they produce.
final class PettingDetectorTests: XCTestCase {
    private let stroke: CGFloat = 14

    /// Feed samples every 50 ms along the given x waypoints; returns how many samples triggered.
    private func triggers(_ waypoints: [CGFloat], step: TimeInterval = 0.05,
                          detector: inout PettingDetector) -> Int {
        var time: TimeInterval = 100
        var count = 0
        for x in waypoints {
            if detector.feed(x: x, at: time, minStroke: stroke) { count += 1 }
            time += step
        }
        return count
    }

    func testWiggleTriggers() {
        var detector = PettingDetector()
        // start, then 4 strokes of 30pt: right, left, right, left = 3 reversals.
        XCTAssertEqual(triggers([10, 25, 40, 25, 10, 25, 40, 25, 10], detector: &detector), 2,
                       "third and fourth reversal both qualify")
    }

    func testStraightPassDoesNotTrigger() {
        var detector = PettingDetector()
        XCTAssertEqual(triggers(Array(stride(from: CGFloat(0), through: 200, by: 10)), detector: &detector), 0)
    }

    func testSlowBackAndForthDoesNotTrigger() {
        var detector = PettingDetector()
        // Same 30pt strokes, but 0.5 s per sample: reversals fall out of the 1.2 s window.
        XCTAssertEqual(triggers([10, 40, 10, 40, 10, 40, 10, 40], step: 0.5, detector: &detector), 0)
    }

    func testLongPauseResetsState() {
        var detector = PettingDetector()
        XCTAssertEqual(triggers([10, 40, 10, 40], detector: &detector), 0, "only 2 reversals so far")
        var time: TimeInterval = 100 + PettingDetector.window + 1
        // After the pause one more reversal must not complete the old count.
        XCTAssertFalse(detector.feed(x: 10, at: time, minStroke: stroke))
        time += 0.05
        XCTAssertFalse(detector.feed(x: 40, at: time, minStroke: stroke))
        time += 0.05
        XCTAssertFalse(detector.feed(x: 10, at: time, minStroke: stroke))
    }

    func testJitterBelowMinimumStrokeDoesNotTrigger() {
        var detector = PettingDetector()
        // 8pt strokes against a 14pt minimum, fast and many.
        let jitter = (0..<30).map { CGFloat($0 % 2 == 0 ? 10 : 18) }
        XCTAssertEqual(triggers(jitter, detector: &detector), 0)
    }

    func testMinimumStrokeScalesTheThreshold() {
        // 20pt strokes: enough for a 14pt minimum, too short for a 40pt one (big pet).
        let wiggle: [CGFloat] = [10, 30, 10, 30, 10, 30, 10]
        var small = PettingDetector()
        var big = PettingDetector()
        var time: TimeInterval = 100
        var smallHits = 0, bigHits = 0
        for x in wiggle {
            if small.feed(x: x, at: time, minStroke: 14) { smallHits += 1 }
            if big.feed(x: x, at: time, minStroke: 40) { bigHits += 1 }
            time += 0.05
        }
        XCTAssertGreaterThan(smallHits, 0)
        XCTAssertEqual(bigHits, 0)
    }

    func testResetForgetsReversals() {
        var detector = PettingDetector()
        XCTAssertEqual(triggers([10, 40, 10, 40], detector: &detector), 0)
        detector.reset()   // mouse exit or mouse down
        // Continuing at the same instant: one more reversal alone must not trigger.
        XCTAssertEqual(triggers([10, 40, 10], detector: &detector), 0)
    }
}

/// The heart bubble: Bool state decision, priority, tooltip suppression and the pixel art.
@MainActor
final class StrokeHeartBubbleTests: XCTestCase {
    func testStrokeShowsHeartsUnlessALimitAlertIsActive() {
        XCTAssertTrue(FloatingPetController.heartsShowing(afterStrokeWithAlertActive: false))
        XCTAssertFalse(FloatingPetController.heartsShowing(afterStrokeWithAlertActive: true))
    }

    func testHeartsDurationIsAboutTwoSeconds() {
        XCTAssertEqual(FloatingPetController.heartDuration, .milliseconds(1800))
    }

    func testHeartsOrAlertReserveBubbleHeadroom() {
        XCTAssertTrue(FloatingPetController.isShowingBubble(alertActive: false, heartsShowing: true))
        XCTAssertTrue(FloatingPetController.isShowingBubble(alertActive: true, heartsShowing: false))
        XCTAssertFalse(FloatingPetController.isShowingBubble(alertActive: false, heartsShowing: false))
    }

    func testNativeToolTipIsClearedWhileABubbleShows() {
        XCTAssertNil(FloatingPetController.nativeToolTip("Today: 1 tokens", bubbleShowing: true))
        XCTAssertEqual(FloatingPetController.nativeToolTip("Today: 1 tokens", bubbleShowing: false),
                       "Today: 1 tokens")
    }

    func testHeartStateStartsHidden() {
        XCTAssertFalse(PetHeartState().isShowing)
    }

    func testHeartBubbleArtRowsShareOneWidth() {
        let rows = HeartBubbleArt.rows
        XCTAssertTrue(rows.allSatisfy { $0.count == rows[0].count })
    }

    func testHeartIsSymmetricExceptShadeAndHighlight() {
        // Rows 3...10 hold the heart; the tail below is deliberately lopsided.
        for row in HeartBubbleArt.rows[3...10] {
            let plain = row.map { "RDH".contains($0) ? Character("R") : $0 }
            XCTAssertEqual(String(plain.reversed()), String(plain), row)
        }
    }

    func testHeartBubbleFitsThePanelAndHeadroom() {
        let rows = HeartBubbleArt.rows
        XCTAssertLessThanOrEqual(CGFloat(rows[0].count) * HeartBubbleArt.pixel, FloatingPetController.bubbleMinWidth)
        // bubble + 6pt bottom padding + 8pt VStack spacing
        XCTAssertLessThanOrEqual(CGFloat(rows.count) * HeartBubbleArt.pixel + 6 + 8,
                                 FloatingPetController.bubbleHeadroom)
    }

    func testEveryArtCellHasAColorOrIsTransparent() {
        let cells = Set(HeartBubbleArt.rows.joined())
        XCTAssertEqual(cells, ["O", "W", "R", "D", "H", "."])
        for cell in cells where cell != "." { XCTAssertNotNil(HeartBubbleArt.color(for: cell)) }
    }

    func testHeartsLabelIsLocalizedInEveryLanguage() {
        let labels = AppLanguage.allCases.map { L($0).floatingPetHeartsLabel }
        XCTAssertFalse(labels.contains(""))
        XCTAssertGreaterThan(Set(labels).count, 1)
    }
}

/// Optional sample-data renders of the heart bubble alone and above the floating egg.
/// Set `PTB_PETTING_RENDER_DIR` to write PNGs; otherwise skipped.
@MainActor
final class FloatingPetPettingRenderingTests: XCTestCase {
    func testRenderHeartBubble() throws {
        guard let directory = ProcessInfo.processInfo.environment["PTB_PETTING_RENDER_DIR"] else {
            throw XCTSkip("PTB_PETTING_RENDER_DIR not set")
        }
        let petSize: CGFloat = 96
        let l = L(.en)
        for (scheme, name, desktop) in [
            (ColorScheme.light, "light", NSColor(calibratedWhite: 0.78, alpha: 1)),
            (ColorScheme.dark, "dark", NSColor(calibratedWhite: 0.16, alpha: 1)),
        ] {
            let variants: [(String, AnyView)] = [
                ("bubble", AnyView(HeartBubbleView(l: l))),
                ("before", AnyView(SpriteView(speciesID: nil, size: petSize, animated: false, shiny: false)
                    .frame(width: petSize, height: petSize))),
                ("after", AnyView(VStack(spacing: 8) {
                    HeartBubbleView(l: l)
                    SpriteView(speciesID: nil, size: petSize, animated: false, shiny: false)
                        .frame(width: petSize, height: petSize)
                })),
            ]
            for (label, content) in variants {
                let renderer = ImageRenderer(content: content
                    .padding(24)
                    .background(Color(nsColor: desktop))
                    .environment(\.colorScheme, scheme))
                renderer.scale = 4
                let image = try XCTUnwrap(renderer.nsImage)
                let rep = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
                let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: directory)
                    .appendingPathComponent("pet-\(label)-\(name).png"))
            }
        }
    }
}
