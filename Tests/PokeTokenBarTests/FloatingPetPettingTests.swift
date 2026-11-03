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

/// Hearts reuse the prayer particle system; they must not make the pet wobble like the egg.
@MainActor
final class StrokeHeartTests: XCTestCase {
    func testHeartParticlesStackWithoutWobbling() {
        let burst = EmojiBurst()
        burst.spawn("❤️")
        burst.spawn("❤️")
        XCTAssertEqual(burst.particles.map(\.emoji), ["❤️", "❤️"], "rapid strokes stack up")
        XCTAssertEqual(burst.wobbleCount, 0)
        burst.spawn("🙏", wobbles: true)
        XCTAssertEqual(burst.wobbleCount, 1, "prayers still wobble the egg")
    }
}

/// Optional sample-data renders of the floating pet with three hearts frozen mid-flight.
/// Set `PTB_PETTING_RENDER_DIR` to write PNGs; otherwise skipped.
@MainActor
final class FloatingPetPettingRenderingTests: XCTestCase {
    func testRenderPetWithHearts() throws {
        guard let directory = ProcessInfo.processInfo.environment["PTB_PETTING_RENDER_DIR"] else {
            throw XCTSkip("PTB_PETTING_RENDER_DIR not set")
        }
        let petSize: CGFloat = 128
        let emojiSize = EmojiParticleLayer.emojiSize(petSize: petSize)
        for (scheme, name, desktop) in [
            (ColorScheme.light, "light", NSColor(calibratedWhite: 0.78, alpha: 1)),
            (ColorScheme.dark, "dark", NSColor(calibratedWhite: 0.16, alpha: 1)),
        ] {
            for (label, hearts) in [("before", [(Double, Double)]()),
                                    ("after", [(0.2, 0.3), (0.55, 0.55), (0.85, 0.8)])] {
                let pet = ZStack {
                    SpriteView(speciesID: nil, size: petSize, animated: false, shiny: false)
                        .frame(width: petSize, height: petSize)
                    ForEach(hearts, id: \.0) { fraction, progress in
                        EmojiParticleFrame(emoji: "❤️", xFraction: fraction, petSize: petSize,
                                           emojiSize: emojiSize, progress: progress)
                    }
                }
                .frame(width: petSize, height: petSize)
                .padding(36)
                .background(Color(nsColor: desktop))
                .environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: pet)
                renderer.scale = 2
                let image = try XCTUnwrap(renderer.nsImage)
                let rep = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
                let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: directory)
                    .appendingPathComponent("pet-\(label)-\(name).png"))
            }
        }
    }
}
