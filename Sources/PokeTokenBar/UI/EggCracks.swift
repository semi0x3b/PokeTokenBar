import SwiftUI

/// Cracks drawn over the static egg sprite as hatch progress fills.
///
/// PokéAPI ships a single `egg.png` (no cracked frames), so the cracks are a pixel overlay. The art is authored on the
/// 30x30 grid of the content-cropped egg (`SpriteLoader.eggImage()`: 96x96 sprite, 28x30 of egg, cropped to a 30x30
/// square), so one art cell is exactly one sprite pixel at any displayed size.
enum EggCracks {
    static let gridSize = 30

    struct Cell: Hashable { let x: Int, y: Int }

    /// Progress thresholds where the next crack stage starts.
    static let stageThresholds: [Double] = [0.40, 0.70, 0.90]

    /// 0 = intact, 1 = one small zig-zag crack, 2 = longer crack plus a branch, 3 = big split across the upper half.
    static func stage(forProgress progress: Double) -> Int {
        stageThresholds.filter { progress >= $0 }.count
    }

    /// Cells to paint for a stage. Each stage contains the previous one.
    static func cells(stage: Int) -> [Cell] {
        var cells: [Cell] = []
        if stage >= 1 { cells += smallCrack }
        if stage >= 2 { cells += longerCrack + branch }
        if stage >= 3 { cells += split }
        return cells
    }

    private static func cells(_ points: [(Int, Int)]) -> [Cell] { points.map { Cell(x: $0.0, y: $0.1) } }

    private static let smallCrack = cells([(15, 8), (15, 9), (14, 9), (14, 10), (14, 11), (13, 11), (13, 12)])
    private static let longerCrack = cells([(13, 13), (12, 13), (12, 14), (12, 15), (11, 15), (11, 16)])
    private static let branch = cells([(15, 10), (16, 10), (16, 11), (17, 11), (17, 12)])
    private static let split = cells([
        (3, 12), (4, 12), (5, 12), (5, 11), (6, 11), (7, 11), (7, 12), (8, 12), (9, 12), (9, 11), (10, 11),
        (11, 11), (11, 10), (12, 10), (13, 10), (13, 11), (14, 11), (15, 11), (15, 10), (16, 10), (17, 10),
        (17, 11), (18, 11), (19, 11), (19, 12), (20, 12), (21, 12), (21, 11), (22, 11), (23, 11), (23, 10),
        (24, 10), (25, 10), (26, 11),
    ])

    /// Columns inside the egg's outline for each row of the 30x30 grid (nil = outline or empty). Cracks stay in here.
    private static let interior: [ClosedRange<Int>?] = [
        nil, nil, 10...19, 9...20, 8...21, 7...22, 6...23, 5...24, 5...24, 4...25,
        4...25, 3...26, 3...26, 3...26, 2...27, 2...27, 2...27, 2...27, 2...27, 3...26,
        3...26, 3...26, 4...25, 4...25, 5...24, 6...23, 7...22, 9...20, nil, nil,
    ]

    static func bodyContains(_ cell: Cell) -> Bool {
        guard interior.indices.contains(cell.y) else { return false }
        return interior[cell.y]?.contains(cell.x) ?? false
    }

    /// The sprite's own outline colour (24, 24, 24).
    static let crackColor = Color(red: 24 / 255, green: 24 / 255, blue: 24 / 255)
}

/// Paints the crack cells without antialiasing so they line up with the sprite's pixels.
@MainActor
struct EggCrackOverlay: View {
    let stage: Int

    var body: some View {
        Canvas { context, size in
            let cell = size.width / CGFloat(EggCracks.gridSize)
            for crack in EggCracks.cells(stage: stage) {
                let rect = CGRect(x: CGFloat(crack.x) * cell, y: CGFloat(crack.y) * cell, width: cell, height: cell)
                context.fill(Path(rect), with: .color(EggCracks.crackColor), style: FillStyle(antialiased: false))
            }
        }
        .allowsHitTesting(false)
    }
}
