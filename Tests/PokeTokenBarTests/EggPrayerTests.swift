import XCTest
@testable import PokeTokenBar

// MARK: 알 기도하기 (위약 버튼) — 세는 것 말고는 아무것도 바꾸지 않는다.

private struct PrayerOfflineProvider: PokeProviding {
    func line(baseSpeciesID: Int) async throws -> EvoLine { throw URLError(.notConnectedToInternet) }
    func baseSpeciesIndex() async throws -> [BaseSpecies] { [] }
    func baseSpecies(id: Int) async throws -> BaseSpecies? { nil }
}

@MainActor
final class EggPrayerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let line = EvoLine(
        baseID: 1,
        tree: EvoNode(speciesID: 1, children: [EvoNode(speciesID: 2, children: [EvoNode(speciesID: 3, children: [])])]),
        rarity: .common,
        names: [1: ["en": "P1"], 2: ["en": "P2"], 3: ["en": "P3"]])

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("prayer-\(UUID().uuidString).json")
    }

    /// Egg at the hatch threshold; `pending` = species already rolled (the prefetched case).
    private func hatchReadyEgg(seed: UInt64 = 7, pending: Bool, purchased: Bool = false,
                               provider: (any PokeProviding)? = nil) -> CompanionStore {
        let url = tempURL()
        let json = "{\"installBaselineSet\":true,\"usedSinceInstall\":10000000,\"spentTokens\":0,"
            + "\"lastDate\":\"d\",\"active\":null,\"dex\":[],\"collectedFinals\":[],"
            + "\"eggUsage\":\(PokemonBalance.eggHatchThreshold),"
            + "\"eggWasPurchased\":\(purchased)"
            + (pending ? ",\"pendingHatchID\":1" : "") + "}"
        try? json.data(using: .utf8)!.write(to: url)
        return CompanionStore(provider: provider ?? StubProvider(value: line), clock: { self.now },
                              fileURL: url, rng: SeededRNG(seed: seed))
    }

    private func activeStoreWithWallet() -> CompanionStore {
        let url = tempURL()
        let mon = "{\"baseID\":10,\"pathIDs\":[10],\"stageIndex\":0,\"usedAtStage\":200000000,"
            + "\"rarity\":\"common\",\"totalForms\":3,\"isShiny\":false}"
        let json = "{\"installBaselineSet\":true,\"usedSinceInstall\":5000000000,\"spentTokens\":0,"
            + "\"lastDate\":\"d\",\"active\":\(mon),\"dex\":[],\"collectedFinals\":[]}"
        try? json.data(using: .utf8)!.write(to: url)
        return CompanionStore(provider: PrayerOfflineProvider(), clock: { self.now }, fileURL: url,
                              rng: SeededRNG(seed: 7))
    }

    /// The hatched individual with the one field prayers may differ in, and the random id, normalised.
    private func rollSignature(_ store: CompanionStore) throws -> Data {
        var mon = try XCTUnwrap(store.state.active)
        mon.prayers = nil
        mon.profile?.instanceID = ""
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(mon)
    }

    // MARK: pray()

    func testPrayCountsAndRemembersFutility() {
        let futile = hatchReadyEgg(pending: true, purchased: true)
        futile.pray(); futile.pray(); futile.pray()
        XCTAssertEqual(futile.state.eggPrayers, PrayerRecord(count: 3, wasFutile: true, eggWasPurchased: true))

        let early = hatchReadyEgg(pending: false)
        early.pray()
        XCTAssertEqual(early.state.eggPrayers, PrayerRecord(count: 1, wasFutile: false, eggWasPurchased: false))
        early.pray()
        XCTAssertFalse(early.state.eggPrayers?.wasFutile ?? true, "flag is fixed at the first prayer")
    }

    func testPrayIsIgnoredWhileRaisingAPokemon() {
        let store = activeStoreWithWallet()
        store.pray()
        XCTAssertNil(store.state.eggPrayers)
    }

    // MARK: no effect on the roll

    func testPrayersDoNotChangeTheHatchResult() async throws {
        for pending in [true, false] {
            let plain = hatchReadyEgg(pending: pending)
            let prayed = hatchReadyEgg(pending: pending)
            for _ in 0..<50 { prayed.pray() }
            await plain.hatchIfNeeded()
            await prayed.hatchIfNeeded()
            XCTAssertNotNil(plain.state.active)
            XCTAssertEqual(try rollSignature(plain), try rollSignature(prayed),
                           "pending=\(pending): prayers must not alter species/rarity/shiny/nature/form/profile")
        }
    }

    // MARK: copy on hatch, reset on every new egg

    func testHatchCopiesPrayersAndClearsEggScope() async throws {
        let store = hatchReadyEgg(pending: true, purchased: true)
        store.pray(); store.pray()
        await store.hatchIfNeeded()
        XCTAssertEqual(store.state.active?.prayers, PrayerRecord(count: 2, wasFutile: true, eggWasPurchased: true))
        XCTAssertNil(store.state.eggPrayers)
        XCTAssertFalse(store.state.eggWasPurchased)
    }

    func testGraduationKeepsPrayersOnTheDexEntryAndStartsAPlainEgg() async throws {
        let store = hatchReadyEgg(pending: true)
        store.pray()
        await store.hatchIfNeeded()
        for stage in 0..<3 {
            store.applyUsage(PokemonBalance.phaseThreshold(rarity: .common, totalForms: 3, stageIndex: stage))
        }
        XCTAssertNil(store.state.active)
        XCTAssertEqual(store.state.dex.first?.prayers?.count, 1)
        XCTAssertNil(store.state.eggPrayers, "the next egg starts without prayers")
        XCTAssertFalse(store.state.eggWasPurchased)
    }

    func testBuyEggResetsPrayersAndMarksPurchase() {
        let store = activeStoreWithWallet()
        XCTAssertTrue(store.buyFreshEgg())
        XCTAssertNil(store.state.eggPrayers)
        XCTAssertTrue(store.state.eggWasPurchased)
        store.pray()
        XCTAssertEqual(store.state.eggPrayers?.eggWasPurchased, true)
    }

    func testReleasedEntryKeepsThePrayersOfTheIndividual() {
        let store = activeStoreWithWallet()
        var state = store.state
        state.active?.prayers = PrayerRecord(count: 4, wasFutile: true, eggWasPurchased: false)
        let url = tempURL()
        try? JSONEncoder().encode(state).write(to: url)
        let reloaded = CompanionStore(provider: PrayerOfflineProvider(), clock: { self.now }, fileURL: url,
                                      rng: SeededRNG(seed: 7))
        XCTAssertEqual(reloaded.dexEntries.first?.prayers?.count, 4, "detail view reads the synthesized active entry")
        XCTAssertTrue(reloaded.buyFreshEgg())
        XCTAssertEqual(reloaded.state.dex.last?.prayers?.count, 4)
    }

    func testImportedSaveWithAnActivePokemonDropsEggPrayers() {
        var state = CompanionState()
        state.active = MonState(baseID: 4, pathIDs: [4], stageIndex: 0, usedAtStage: 0, rarity: .common, totalForms: 1)
        state.eggPrayers = PrayerRecord(count: 9, wasFutile: true, eggWasPurchased: true)
        state.eggWasPurchased = true
        let clean = SaveTransfer.sanitized(state)
        XCTAssertNil(clean.eggPrayers)
        XCTAssertFalse(clean.eggWasPurchased)
    }

    func testSanitizeClampsAnAbsurdPrayerCount() {
        var state = CompanionState()
        state.eggPrayers = PrayerRecord(count: Int.max, wasFutile: false, eggWasPurchased: false)
        XCTAssertEqual(SaveTransfer.sanitized(state).eggPrayers?.count, SaveTransfer.maxTokenValue)
    }

    // MARK: persistence

    func testPrayerFieldsSurviveEncodeAndSaveTransfer() throws {
        var state = CompanionState()
        state.eggPrayers = PrayerRecord(count: 5, wasFutile: true, eggWasPurchased: true)
        state.eggWasPurchased = true
        state.active = nil
        let envelope = try SaveTransfer.decode(
            SaveTransfer.encode(state: state, appVersion: "x", deviceName: "d", now: now))
        XCTAssertEqual(envelope.state.eggPrayers, state.eggPrayers)
        XCTAssertTrue(envelope.state.eggWasPurchased)

        let mon = MonState(baseID: 1, pathIDs: [1], stageIndex: 0, usedAtStage: 0, rarity: .common, totalForms: 1,
                           prayers: PrayerRecord(count: 2, wasFutile: false, eggWasPurchased: false))
        let decodedMon = try JSONDecoder().decode(MonState.self, from: JSONEncoder().encode(mon))
        XCTAssertEqual(decodedMon.prayers, mon.prayers)
        let entry = DexEntry(baseID: 1, finalID: 1, chainOrder: [1], rarity: .common, caughtAt: nil,
                             prayers: mon.prayers)
        let decodedEntry = try JSONDecoder().decode(DexEntry.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(decodedEntry.prayers, mon.prayers)
    }

    func testOldSavesDecodeWithoutPrayers() throws {
        let state = try JSONDecoder().decode(CompanionState.self, from: Data("{\"eggUsage\":5}".utf8))
        XCTAssertNil(state.eggPrayers)
        XCTAssertFalse(state.eggWasPurchased)
        let mon = try JSONDecoder().decode(MonState.self, from: Data(
            "{\"baseID\":1,\"pathIDs\":[1],\"stageIndex\":0,\"usedAtStage\":0,\"rarity\":\"common\",\"totalForms\":1}".utf8))
        XCTAssertNil(mon.prayers)
        let entry = try JSONDecoder().decode(DexEntry.self, from: Data(
            "{\"baseID\":1,\"finalID\":1,\"chainOrder\":[1],\"rarity\":\"common\"}".utf8))
        XCTAssertNil(entry.prayers)
        let broken = try JSONDecoder().decode(CompanionState.self, from: Data("{\"eggPrayers\":\"oops\"}".utf8))
        XCTAssertNil(broken.eggPrayers, "a damaged field must not take the whole save down")
    }

    // MARK: text

    func testPrayerHatchNotificationText() {
        let ko = L(.ko), en = L(.en)
        XCTAssertEqual(ko.notifPrayerHatchBody("피카츄", prayers: 37, shiny: false, legendary: false),
                       "기도 37번 끝에 피카츄가 나왔어요!")
        XCTAssertEqual(ko.notifPrayerHatchBody("뮤", prayers: 37, shiny: false, legendary: true),
                       "기도 37번… 통했다?! 뮤가 나왔어요!")
        XCTAssertEqual(ko.notifPrayerHatchBody("피카츄", prayers: 37, shiny: true, legendary: false),
                       "기도 37번 끝에 이로치 피카츄가 나왔어요!")
        XCTAssertEqual(ko.notifPrayerHatchBody("뮤", prayers: 3, shiny: true, legendary: true),
                       "기도 3번… 통했다?! 이로치 뮤가 나왔어요!")
        XCTAssertEqual(en.notifPrayerHatchBody("Pikachu", prayers: 37, shiny: false, legendary: false),
                       "After 37 prayers: Pikachu hatched!")
        XCTAssertEqual(en.notifPrayerHatchBody("Mew", prayers: 37, shiny: true, legendary: true),
                       "37 prayers… it worked?! A shiny Mew hatched!")
    }

    func testFutileNoteDependsOnHowTheEggArrived() {
        XCTAssertEqual(L(.ko).prayerFutileNote(purchased: true), "참고: 이 아이는 알을 산 순간 정해져 있었어요.")
        XCTAssertEqual(L(.ko).prayerFutileNote(purchased: false), "참고: 이 아이는 알이 온 순간 정해져 있었어요.")
        XCTAssertEqual(L(.ko).prayerBornWith(37), "기도 37회로 태어남")
        XCTAssertEqual(L(.ko).prayerCount(3), "기도 3회")
    }

    // MARK: floating pet click routing and particles

    func testClickPraysOverAnEggAndOpensThePopoverForAPokemon() {
        XCTAssertEqual(FloatingPetController.clickAction(subjectIsEgg: true), .pray)
        XCTAssertEqual(FloatingPetController.clickAction(subjectIsEgg: false), .openPopover)
    }

    func testBurstSpawnsClampedParticlesAndRemovesThemItself() async throws {
        let burst = PrayerBurst()
        burst.spawn(xFraction: -3)
        burst.spawn(xFraction: 7)
        burst.spawn()
        XCTAssertEqual(burst.particles.count, 3, "rapid clicks stack up")
        XCTAssertEqual(burst.wobbleCount, 3)
        XCTAssertEqual(burst.particles[0].xFraction, 0)
        XCTAssertEqual(burst.particles[1].xFraction, 1)
        XCTAssertTrue(burst.particles.allSatisfy { (0...1).contains($0.xFraction) })
        try await Task.sleep(for: PrayerBurst.lifetime + .milliseconds(300))
        XCTAssertTrue(burst.particles.isEmpty, "each particle removes itself")
        XCTAssertEqual(burst.wobbleCount, 3)
    }

    func testEmojiStaysInsideThePetFrameAtEverySize() {
        for petSize in stride(from: CGFloat(48), through: 384, by: 8) {
            let emoji = PrayerEmojiLayer.emojiSize(petSize: petSize)
            XCTAssertLessThanOrEqual(emoji, petSize)
            for fraction in [0.0, 1.0] {
                let centre = emoji / 2 + CGFloat(fraction) * (petSize - emoji)
                XCTAssertGreaterThanOrEqual(centre - emoji / 2, 0)
                XCTAssertLessThanOrEqual(centre + emoji / 2, petSize)
            }
        }
    }

    func testHoverTextShowsPrayersOnlyWhenThereAreSome() {
        let l = L(.ko)
        let plain = FloatingPetView.hoverTooltip(todayTokens: 1, limitUtilization: nil, mode: .used, l: l)
        let prayed = FloatingPetView.hoverTooltip(todayTokens: 1, limitUtilization: nil, mode: .used, l: l, prayers: 3)
        XCTAssertFalse(plain.contains("기도"))
        XCTAssertEqual(prayed, plain + "\n기도 3회")
    }

    // MARK: prayer-triggered usage refresh

    private func makeRouter(clock: @escaping () -> Date, log: PrayerCallLog) -> PetClickRouter {
        PetClickRouter(pray: { log.prays += 1 }, spawnEmoji: { log.emojis += 1 },
                       refreshUsage: { log.refreshes += 1 }, openPopover: { log.opens += 1 }, clock: clock)
    }

    func testPrayerRefreshIsThrottledToOncePerInterval() {
        var current = now
        let log = PrayerCallLog()
        let router = makeRouter(clock: { current }, log: log)

        router.handle(subjectIsEgg: true)
        XCTAssertEqual(log.refreshes, 1, "the first click refreshes")
        current = now.addingTimeInterval(FloatingPetController.prayerRefreshInterval - 1)
        router.handle(subjectIsEgg: true)
        router.handle(subjectIsEgg: true)
        XCTAssertEqual(log.refreshes, 1, "clicks inside the interval do not refresh")
        XCTAssertEqual(log.prays, 3, "every click still prays")
        XCTAssertEqual(log.emojis, 3, "and spawns its emoji")
        current = now.addingTimeInterval(FloatingPetController.prayerRefreshInterval)
        router.handle(subjectIsEgg: true)
        XCTAssertEqual(log.refreshes, 2, "a click after the interval refreshes again")
    }

    func testClickingAHatchedPokemonOpensThePopoverWithoutPrayingOrRefreshing() {
        let log = PrayerCallLog()
        let router = makeRouter(clock: { self.now }, log: log)
        router.handle(subjectIsEgg: false)
        XCTAssertEqual(log.opens, 1)
        XCTAssertEqual(log.prays + log.emojis + log.refreshes, 0)
    }

    func testShouldRefreshOnPrayerDecision() {
        XCTAssertTrue(FloatingPetController.shouldRefreshOnPrayer(lastRefreshAt: nil, now: now))
        XCTAssertFalse(FloatingPetController.shouldRefreshOnPrayer(lastRefreshAt: now, now: now))
        XCTAssertTrue(FloatingPetController.shouldRefreshOnPrayer(
            lastRefreshAt: now, now: now.addingTimeInterval(FloatingPetController.prayerRefreshInterval)))
    }
}

@MainActor
private final class PrayerCallLog {
    var prays = 0, emojis = 0, refreshes = 0, opens = 0
}
