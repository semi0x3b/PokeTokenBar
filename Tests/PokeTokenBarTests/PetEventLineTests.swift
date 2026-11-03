import XCTest
@testable import PokeTokenBar

private struct EventLineProvider: PokeProviding {
    let value: EvoLine
    func line(baseSpeciesID: Int) async throws -> EvoLine { value }
    func baseSpeciesIndex() async throws -> [BaseSpecies] { [BaseSpecies(id: value.baseID, captureRate: 255)] }
}

/// The floating pet's hover text shows the latest hatch / evolution line for an hour.
@MainActor
final class PetEventLineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private var line: EvoLine {
        EvoLine(baseID: 1,
                tree: EvoNode(speciesID: 1, children: [EvoNode(speciesID: 2, children: [EvoNode(speciesID: 3, children: [])])]),
                rarity: .common,
                names: [1: ["en": "Bulb", "ko": "이상해씨"], 2: ["en": "Ivy", "ko": "이상해풀"], 3: ["en": "Venu", "ko": "이상해꽃"]])
    }

    private func store(clock: @escaping () -> Date) -> CompanionStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("event-line-\(UUID()).json")
        let store = CompanionStore(provider: EventLineProvider(value: line), clock: clock, fileURL: url,
                                   rng: SeededRNG(seed: 7))
        store.setLanguage(.en)
        return store
    }

    // MARK: how long the line stays

    func testEventLineIsShownForExactlyOneHour() {
        let event = CompanionStore.CompanionEvent(text: "hatched", at: now)
        let lifetime = FloatingPetController.eventLineLifetime
        XCTAssertEqual(lifetime, 3600)
        XCTAssertEqual(FloatingPetController.eventLine(for: event, now: now), "hatched")
        XCTAssertEqual(FloatingPetController.eventLine(for: event, now: now.addingTimeInterval(lifetime - 1)), "hatched")
        XCTAssertNil(FloatingPetController.eventLine(for: event, now: now.addingTimeInterval(lifetime)))
        XCTAssertNil(FloatingPetController.eventLine(for: nil, now: now))
    }

    func testHoverTextPutsTheEventBetweenTheUsageLineAndThePrayerLine() {
        let l = L(.en)
        let plain = FloatingPetView.hoverTooltip(todayTokens: 1, limitUtilization: nil, mode: .used, l: l)
        let full = FloatingPetView.hoverTooltip(todayTokens: 1, limitUtilization: nil, mode: .used, l: l,
                                                eventLine: "EVENT", prayers: 3)
        XCTAssertEqual(full, plain + "\nEVENT\n" + l.prayerHoverLine(3))
        XCTAssertEqual(FloatingPetView.hoverTooltip(todayTokens: 1, limitUtilization: nil, mode: .used, l: l,
                                                    eventLine: nil), plain)
    }

    // MARK: what the store records (the dev build has no system notifications, so this is the only trace)

    func testHatchAndEvolutionAreRecordedAndTheNewerReplacesTheOlder() async {
        var current = now
        let store = store(clock: { current })
        XCTAssertNil(store.latestEvent)

        await store.hatch(baseID: 1)
        XCTAssertEqual(store.latestEvent?.text, "Bulb hatched from the egg!")
        XCTAssertEqual(store.latestEvent?.at, now)

        current = now.addingTimeInterval(120)
        store.applyUsage(PokemonBalance.phaseThreshold(rarity: .common, totalForms: 3, stageIndex: 0))
        XCTAssertEqual(store.latestEvent?.text, "Bulb evolved into Ivy!")
        XCTAssertEqual(store.latestEvent?.at, current)
    }

    func testGraduationIsRecordedToo() async {
        let store = store(clock: { self.now })
        await store.hatch(baseID: 1)
        for stage in 0..<3 {
            store.applyUsage(PokemonBalance.phaseThreshold(rarity: .common, totalForms: 3, stageIndex: stage))
        }
        XCTAssertEqual(store.latestEvent?.text, L(.en).notifGraduateBody("Venu"))
    }

    // MARK: the evolution line names both Pokémon

    func testEvolutionLineNamesBothWithTheRightKoreanParticles() {
        let ko = L(.ko)
        XCTAssertEqual(ko.notifEvolveBody(from: "피카츄", to: "라이츄"), "피카츄가 라이츄로 진화했어요!")
        XCTAssertEqual(ko.notifEvolveBody(from: "리자드", to: "리자몽"), "리자드가 리자몽으로 진화했어요!")
        XCTAssertEqual(ko.notifEvolveBody(from: "이상해씨", to: "이상해풀"), "이상해씨가 이상해풀로 진화했어요!")
        XCTAssertEqual(L(.en).notifEvolveBody(from: "Pichu", to: "Pikachu"), "Pichu evolved into Pikachu!")
        for language in AppLanguage.allCases {
            let text = L(language).notifEvolveBody(from: "AAA", to: "BBB")
            XCTAssertTrue(text.contains("AAA") && text.contains("BBB"), "\(language) drops a name")
        }
    }
}
