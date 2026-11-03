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

    func testHeartLevelGrowsAndCaps() {
        var level = 0
        var seen: [Int] = []
        for _ in 0..<5 {
            level = FloatingPetController.heartLevel(after: level, alertActive: false)
            seen.append(level)
        }
        XCTAssertEqual(seen, [1, 2, 3, 3, 3])
    }

    func testActiveLimitAlertBlocksHearts() {
        XCTAssertEqual(FloatingPetController.heartLevel(after: 2, alertActive: true), 0)
    }

    func testHeartsOrAlertReserveBubbleHeadroom() {
        XCTAssertTrue(FloatingPetController.isShowingBubble(alertActive: false, heartLevel: 1))
        XCTAssertTrue(FloatingPetController.isShowingBubble(alertActive: true, heartLevel: 0))
        XCTAssertFalse(FloatingPetController.isShowingBubble(alertActive: false, heartLevel: 0))
        let pet: CGFloat = 96
        let panel = FloatingPetController.panelSize(petSize: pet, showingBubble: true)
        XCTAssertGreaterThanOrEqual(panel.height - pet, 40, "hearts bubble (~32pt) + spacing fits the headroom")
    }

    func testHeartBubbleArtIsSymmetricAndFitsThePanel() {
        for count in 1...FloatingPetController.maxHeartLevel {
            let rows = HeartBubbleArt.rows(count: count)
            let width = rows[0].count
            XCTAssertTrue(rows.allSatisfy { $0.count == width }, "rows must share one width")
            XCTAssertEqual(width % 2, 1, "odd width keeps the tail centered")
            for row in rows {
                let plain = row.replacingOccurrences(of: "H", with: "R")   // highlight is deliberately asymmetric
                XCTAssertEqual(String(plain.reversed()), plain)
            }
            XCTAssertLessThanOrEqual(CGFloat(width) * HeartBubbleArt.pixel, FloatingPetController.bubbleMinWidth)
            // bubble + 6pt bottom padding + 8pt VStack spacing
            XCTAssertLessThanOrEqual(CGFloat(rows.count) * HeartBubbleArt.pixel + 6 + 8,
                                     FloatingPetController.bubbleHeadroom)
            let heartPixels = rows.joined().filter { $0 == "R" || $0 == "H" }.count
            XCTAssertEqual(heartPixels, count * 27, "each 7x6 heart bitmap has 27 pixels")
        }
    }

    func testHeartsLabelIsLocalizedInEveryLanguage() {
        let labels = AppLanguage.allCases.map { L($0).floatingPetHeartsLabel }
        XCTAssertFalse(labels.contains(""))
        XCTAssertGreaterThan(Set(labels).count, 1)
    }
}

/// Optional sample-data renders of the floating pet with/without the heart bubble.
/// Set `PTB_PETTING_RENDER_DIR` to write PNGs; otherwise skipped.
@MainActor
final class FloatingPetPettingRenderingTests: XCTestCase {
    private struct StubPoke: PokeProviding {
        func line(baseSpeciesID: Int) async throws -> EvoLine {
            EvoLine(baseID: 129, tree: EvoNode(speciesID: 129, children: []), rarity: .common, names: [:])
        }
        func baseSpeciesIndex() async throws -> [BaseSpecies] { [] }
        func baseSpecies(id: Int) async throws -> BaseSpecies? { nil }
    }

    func testRenderHeartBubbleBeforeAfter() throws {
        guard let directory = ProcessInfo.processInfo.environment["PTB_PETTING_RENDER_DIR"] else {
            throw XCTSkip("PTB_PETTING_RENDER_DIR not set")
        }
        let suite = "PettingRender-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(suite).json")
        defer { try? FileManager.default.removeItem(at: file) }
        var state = CompanionState()
        state.language = .en
        state.active = MonState(baseID: 129, pathIDs: [129], stageIndex: 0, usedAtStage: 0,
                                rarity: .common, totalForms: 1, nature: .hardy)
        try JSONEncoder().encode(state).write(to: file)
        let companion = CompanionStore(provider: StubPoke(), fileURL: file, defaults: defaults)
        let store = UsageStore(providers: [], autoRefresh: false, defaults: defaults)

        let petSize: CGFloat = 96
        let canvas = FloatingPetController.panelSize(petSize: petSize, showingBubble: true)
        for (appearanceName, scheme, desktop) in [
            ("light", ColorScheme.light, NSColor(calibratedWhite: 0.78, alpha: 1)),
            ("dark", ColorScheme.dark, NSColor(calibratedWhite: 0.16, alpha: 1)),
        ] {
            for (label, level) in [("before", 0), ("hearts1", 1), ("hearts2", 2), ("hearts3", 3)] {
                let hearts = PetHeartState()
                hearts.level = level
                let host = NSHostingView(rootView: FloatingPetView(animated: false, hearts: hearts)
                    .environment(store).environment(companion)
                    .environment(\.colorScheme, scheme)
                    .frame(width: canvas.width, height: canvas.height)
                    .background(Color(nsColor: desktop)))
                host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                host.frame = NSRect(origin: .zero, size: canvas)
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: Int(canvas.width * 2), pixelsHigh: Int(canvas.height * 2),
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
                bitmap.size = canvas
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: directory)
                    .appendingPathComponent("pet-\(label)-\(appearanceName).png"))
            }
        }
    }
}
