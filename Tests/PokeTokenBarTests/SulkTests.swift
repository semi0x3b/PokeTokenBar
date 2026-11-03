import AppKit
import XCTest
@testable import PokeTokenBar

// "Neglected? It turns its back": sulk state, idle-day counting, and back-sprite URL/cache/fallback.
// StubProvider / SeededRNG come from CompanionTests.swift.

private let utc = TimeZone(identifier: "UTC")!
private let sulkNow = Date(timeIntervalSince1970: 1_700_000_000)

private func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utc
    return calendar
}

private func noon(_ year: Int, _ month: Int, _ day: Int) -> Date {
    utcCalendar().date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
}

private func dayKey(_ year: Int, _ month: Int, _ day: Int) -> String {
    LocalUsageReader.localDayFormatter(timeZone: utc).string(from: noon(year, month, day))
}

private func day(_ date: String, _ tokens: Int) -> DailyUsage {
    DailyUsage(date: date, inputTokens: 0, outputTokens: 0, cacheCreationTokens: 0,
               cacheReadTokens: 0, totalTokens: tokens, totalCost: 0, costCoverage: .empty)
}

private final class SulkClock: @unchecked Sendable {
    nonisolated(unsafe) var now = sulkNow
}

@MainActor
final class SulkStateTests: XCTestCase {
    private func hatchedStore() async -> CompanionStore {
        let clock = SulkClock()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("poke-sulk-\(UUID().uuidString).json")
        let node = EvoNode(speciesID: 1, children: [])
        let line = EvoLine(baseID: 1, tree: node, rarity: .common, names: [:])
        let store = CompanionStore(provider: StubProvider(value: line), clock: { clock.now },
                                   fileURL: url, rng: SeededRNG(seed: 5))
        await store.hatch(baseID: 1)
        clock.now = sulkNow.addingTimeInterval(60)   // let the hatch event window expire
        return store
    }

    private func update(_ store: CompanionStore, today: Int, idleDays: Int, hasData: Bool = true,
                        limitWarning: Bool = false) {
        store.update(todayTokensByProvider: ["test": today], todayDate: "d", monthTotal: 0, burnTier: .idle,
                     limitWarning: limitWarning, hasUsageData: hasData, idleDaysBeforeToday: idleDays)
    }

    func testSulksWhenTodayAndYesterdayAreIdle() async {
        let store = await hatchedStore()
        update(store, today: 0, idleDays: 1)
        XCTAssertEqual(store.displayState, .sulk)
        XCTAssertTrue(store.facesBack)
        XCTAssertEqual(store.sulkDays, 2)
        update(store, today: 0, idleDays: 4)
        XCTAssertEqual(store.sulkDays, 5)
    }

    func testUnknownYesterdayNeverSulks() async {
        let store = await hatchedStore()
        update(store, today: 0, idleDays: 0)   // 0 = yesterday unknown or active
        XCTAssertEqual(store.displayState, .sleep)
        XCTAssertFalse(store.facesBack)
        XCTAssertEqual(store.sulkDays, 0)
    }

    func testNoUsageDataDoesNotSulk() async {
        let store = await hatchedStore()
        // The first update only fixes the install baseline, so run one with data before losing it.
        update(store, today: 0, idleDays: 0)
        update(store, today: 0, idleDays: 3, hasData: false)
        XCTAssertEqual(store.displayState, .sleep)
        XCTAssertFalse(store.facesBack)
    }

    func testTiredBeatsSulk() async {
        let store = await hatchedStore()
        update(store, today: 0, idleDays: 3, limitWarning: true)
        XCTAssertEqual(store.displayState, .tired)
    }

    func testSulkBeatsSleepAndUsageEndsIt() async {
        let store = await hatchedStore()
        update(store, today: 0, idleDays: 2)
        XCTAssertEqual(store.displayState, .sulk)
        update(store, today: 500, idleDays: 2)
        XCTAssertNotEqual(store.displayState, .sulk)
        XCTAssertFalse(store.facesBack)
        XCTAssertEqual(store.sulkDays, 0)
    }

    func testLevelUpBeatsSulk() async {
        let clock = SulkClock()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("poke-sulk-\(UUID().uuidString).json")
        let line = EvoLine(baseID: 1, tree: EvoNode(speciesID: 1, children: []), rarity: .common, names: [:])
        let store = CompanionStore(provider: StubProvider(value: line), clock: { clock.now },
                                   fileURL: url, rng: SeededRNG(seed: 5))
        await store.hatch(baseID: 1)   // the hatch event window is still open
        update(store, today: 0, idleDays: 3)
        XCTAssertEqual(store.displayState, .levelUp)
    }

    func testEggNeverSulks() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("poke-sulk-\(UUID().uuidString).json")
        let line = EvoLine(baseID: 1, tree: EvoNode(speciesID: 1, children: []), rarity: .common, names: [:])
        let store = CompanionStore(provider: StubProvider(value: line), clock: { sulkNow },
                                   fileURL: url, rng: SeededRNG(seed: 1))
        update(store, today: 0, idleDays: 3)
        XCTAssertEqual(store.displayState, .egg)
    }
}

final class IdleDaysTests: XCTestCase {
    private func makeLedger(_ series: [DailyUsage]) -> UsageLedger {
        var ledger = UsageLedger()
        ledger.merge(series)
        return ledger
    }

    func testCountsConsecutiveIdleDaysBeforeToday() {
        // Sep 1-9: used on the 5th, idle 6-9; today is the 10th.
        let series = (1...9).map { day(dayKey(2026, 9, $0), $0 == 5 ? 100 : 0) }
        XCTAssertEqual(makeLedger(series).idleDays(before: noon(2026, 9, 10), calendar: utcCalendar()), 4)
    }

    func testYesterdayActiveMeansZero() {
        let series = [day(dayKey(2026, 9, 8), 0), day(dayKey(2026, 9, 9), 50)]
        XCTAssertEqual(makeLedger(series).idleDays(before: noon(2026, 9, 10), calendar: utcCalendar()), 0)
    }

    func testCountStopsAtWhatTheLedgerCovers() {
        // Coverage starts on the 8th: the 6th and 7th are unknown, not idle.
        let series = [day(dayKey(2026, 9, 8), 0), day(dayKey(2026, 9, 9), 0)]
        XCTAssertEqual(makeLedger(series).idleDays(before: noon(2026, 9, 10), calendar: utcCalendar()), 2)
    }

    func testUncoveredYesterdayIsUnknown() {
        XCTAssertEqual(UsageLedger().idleDays(before: noon(2026, 9, 10), calendar: utcCalendar()), 0)
        // First day of a month, nothing from the previous month on record.
        let series = [day(dayKey(2026, 10, 1), 0)]
        XCTAssertEqual(makeLedger(series).idleDays(before: noon(2026, 10, 1), calendar: utcCalendar()), 0)
    }

    func testADayTheAppNeverScannedStopsTheCount() {
        // September was last scanned on the 28th (the laptop slept through the 29th and 30th); October
        // was scanned on the 1st and 2nd. Sep 29/30 sit inside `coveredSince` but nobody saw them.
        var ledger = makeLedger((1...28).map { day(dayKey(2026, 9, $0), 0) })
        ledger.merge([day(dayKey(2026, 10, 1), 0), day(dayKey(2026, 10, 2), 0)])
        XCTAssertTrue(ledger.covers(dayKey(2026, 9, 30)))
        XCTAssertFalse(ledger.wasScanned(dayKey(2026, 9, 30)))
        XCTAssertEqual(ledger.idleDays(before: noon(2026, 10, 3), calendar: utcCalendar()), 2)
        // Yesterday itself unscanned: unknown, not idle.
        XCTAssertEqual(ledger.idleDays(before: noon(2026, 10, 1), calendar: utcCalendar()), 0)
    }

    func testScannedCoverageSurvivesSaveAndLoad() {
        let suite = "SulkLedger-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let saved = makeLedger([day(dayKey(2026, 9, 28), 0), day(dayKey(2026, 9, 29), 0)])
        saved.save(to: defaults)
        let loaded = UsageLedger.load(from: defaults)
        XCTAssertEqual(loaded, saved)
        XCTAssertTrue(loaded.wasScanned(dayKey(2026, 9, 29)))
        XCTAssertFalse(loaded.wasScanned(dayKey(2026, 9, 30)))
    }

    func testMonthBoundaryReachesIntoThePreviousMonth() {
        var ledger = makeLedger([day(dayKey(2026, 9, 29), 0), day(dayKey(2026, 9, 30), 0)])
        ledger.merge([day(dayKey(2026, 10, 1), 0), day(dayKey(2026, 10, 2), 0)])
        XCTAssertEqual(ledger.idleDays(before: noon(2026, 10, 3), calendar: utcCalendar()), 4)
        // Used on the last day of September: yesterday on Oct 1 is active.
        let active = makeLedger([day(dayKey(2026, 9, 30), 70)])
        XCTAssertEqual(active.idleDays(before: noon(2026, 10, 1), calendar: utcCalendar()), 0)
    }
}

@MainActor
final class BackSpriteTests: XCTestCase {
    private let base = "https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon"

    func testBackURLs() {
        let gif = "\(base)/versions/generation-v/black-white/animated"
        XCTAssertEqual(SpriteStore.spriteURL(speciesID: 25, animated: true, shiny: false, back: true).absoluteString,
                       "\(gif)/back/25.gif")
        XCTAssertEqual(SpriteStore.spriteURL(speciesID: 25, animated: true, shiny: true, back: true).absoluteString,
                       "\(gif)/back/shiny/25.gif")
        XCTAssertEqual(SpriteStore.spriteURL(speciesID: 25, animated: false, shiny: false, back: true).absoluteString,
                       "\(base)/back/25.png")
        XCTAssertEqual(SpriteStore.spriteURL(speciesID: 25, animated: false, shiny: true, back: true).absoluteString,
                       "\(base)/back/shiny/25.png")
        XCTAssertEqual(SpriteStore.spriteURL(speciesID: 25, animated: true, shiny: false).absoluteString,
                       "\(gif)/25.gif")   // front is unchanged
    }

    func testBackCacheKeyDiffersFromFrontAndFrontKeyIsUnchanged() {
        for animated in [false, true] {
            for shiny in [false, true] {
                XCTAssertNotEqual(SpriteStore.cacheKey(speciesID: 25, animated: animated, shiny: shiny, back: true),
                                  SpriteStore.cacheKey(speciesID: 25, animated: animated, shiny: shiny))
            }
        }
        XCTAssertEqual(SpriteStore.cacheKey(speciesID: 25, animated: false, shiny: false), "25-s")
        XCTAssertEqual(SpriteStore.cacheKey(speciesID: 25, animated: true, shiny: true, back: true), "25-back-sha")
    }

    func testViewIdentityKeysIncludeBack() {
        XCTAssertNotEqual(SpriteView.frameTaskID(speciesID: 25, shiny: false, floor: 0, back: true),
                          SpriteView.frameTaskID(speciesID: 25, shiny: false, floor: 0))
        XCTAssertNotEqual(AppDelegate.menuSpriteKey(id: 25, shiny: false, floor: 0.4, back: true),
                          AppDelegate.menuSpriteKey(id: 25, shiny: false, floor: 0.4))
        XCTAssertTrue(SpriteView.needsReload(loadedID: 25, loadedShiny: false, id: 25, shiny: false,
                                             loadedBack: false, back: true))
    }

    private func pngData(_ color: NSColor) -> Data {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        color.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        return rep.representation(using: .png, properties: [:])!
    }

    func testMissingBackFallsBackToFrontAndBackWinsWhenCached() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sulk-sprites-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        SpriteLoader.imageCache.removeAllObjects()

        try pngData(.red).write(to: dir.appendingPathComponent("25-s.png"))
        let fallback = SpriteLoader.cachedImage(speciesID: 25, directory: dir, back: true)
        XCTAssertNotNil(fallback, "no back sprite cached: the front sprite must show instead of nothing")
        XCTAssertNotNil(SpriteLoader.cachedImage(speciesID: 25, shiny: true, directory: dir, back: true),
                        "shiny + back miss falls through plain back to the plain front")

        try pngData(.blue).write(to: dir.appendingPathComponent("25-back-s.png"))
        let back = SpriteLoader.cachedImage(speciesID: 25, directory: dir, back: true)
        XCTAssertNotNil(back)
        XCTAssertNotEqual(back?.tiffRepresentation, fallback?.tiffRepresentation)
        XCTAssertNil(SpriteLoader.cachedImage(speciesID: 26, directory: dir, back: true))
    }
}
