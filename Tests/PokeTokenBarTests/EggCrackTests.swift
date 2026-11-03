import XCTest
@testable import PokeTokenBar

final class EggCrackTests: XCTestCase {
    func testStageChangesExactlyAtTheThresholds() {
        let expected: [(Double, Int)] = [
            (0, 0), (0.2, 0), (0.399, 0), (0.40, 1), (0.5, 1), (0.699, 1),
            (0.70, 2), (0.8, 2), (0.899, 2), (0.90, 3), (0.95, 3), (1.0, 3),
        ]
        for (progress, stage) in expected {
            XCTAssertEqual(EggCracks.stage(forProgress: progress), stage, "progress \(progress)")
        }
    }

    func testEveryCrackCellStaysInsideTheEggBody() {
        for stage in 1...3 {
            let cells = EggCracks.cells(stage: stage)
            XCTAssertFalse(cells.isEmpty)
            for cell in cells {
                XCTAssertTrue(EggCracks.bodyContains(cell), "stage \(stage) cell (\(cell.x), \(cell.y)) leaves the egg")
            }
        }
    }

    func testBodyMaskRejectsTheOutlineAndTheOutside() {
        XCTAssertFalse(EggCracks.bodyContains(.init(x: 0, y: 15)))
        XCTAssertFalse(EggCracks.bodyContains(.init(x: 15, y: 0)))
        XCTAssertFalse(EggCracks.bodyContains(.init(x: 15, y: 29)))
        XCTAssertFalse(EggCracks.bodyContains(.init(x: 15, y: 30)))
        XCTAssertFalse(EggCracks.bodyContains(.init(x: -1, y: 15)))
        XCTAssertTrue(EggCracks.bodyContains(.init(x: 15, y: 15)))
    }

    func testEachStageKeepsThePreviousCracksAndAddsMore() {
        XCTAssertTrue(EggCracks.cells(stage: 0).isEmpty)
        for stage in 1...2 {
            let smaller = Set(EggCracks.cells(stage: stage))
            let larger = Set(EggCracks.cells(stage: stage + 1))
            XCTAssertTrue(smaller.isSubset(of: larger))
            XCTAssertGreaterThan(larger.count, smaller.count)
        }
    }

    func testTheBigSplitSpansTheWidthOfTheUpperHalf() {
        let cells = EggCracks.cells(stage: 3)
        XCTAssertLessThanOrEqual(cells.map(\.x).min() ?? 99, 4)
        XCTAssertGreaterThanOrEqual(cells.map(\.x).max() ?? 0, 25)
        XCTAssertTrue(cells.allSatisfy { $0.y < EggCracks.gridSize / 2 + 2 })
    }

    @MainActor
    func testStoreReportsNoCracksWhileRaisingAPokemon() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("crack-\(UUID()).json")
        var state = CompanionState()
        state.active = MonState(baseID: 4, pathIDs: [4], stageIndex: 0, usedAtStage: 0, rarity: .common, totalForms: 1)
        state.eggUsage = PokemonBalance.eggHatchThreshold   // stale egg progress must not crack anything
        try JSONEncoder().encode(state).write(to: url)
        XCTAssertEqual(CompanionStore(fileURL: url).eggCrackStage, 0)
    }
}
