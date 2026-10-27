import CoreGraphics
import XCTest
@testable import Corral

final class DitherArtTests: XCTestCase {

    private func pixels(_ image: CGImage) -> [UInt8] {
        let data = image.dataProvider?.data as Data? ?? Data()
        return [UInt8](data)
    }

    /// Share of cells with any ink, at the size a badge tile draws.
    private func coverage(_ scene: ArtScene, cols: Int = 88, rows: Int = 31) -> Double {
        let params = DitherArt.Params(seed: DitherArt.seed(scene.rawValue), strength: 0.5, count: 4)
        let image = DitherArt.render(
            DitherArt.field(scene, params, aspect: Double(cols) / Double(rows)),
            ink: BadgeTier.gold.ink, cols: cols, rows: rows
        )!
        let bytes = pixels(image)
        let inked = stride(from: 3, to: bytes.count, by: 4).filter { bytes[$0] > 0 }.count
        return Double(inked) / Double(cols * rows)
    }

    /// The plate is a function of its inputs and nothing else, so the same
    /// person sees the same picture, and a cached one is never wrong.
    func testRenderingIsDeterministic() {
        let params = DitherArt.Params(seed: 42, strength: 0.6, count: 3)
        for scene in ArtScene.allCases {
            let a = DitherArt.render(DitherArt.field(scene, params, aspect: 2.8), ink: BadgeTier.silver.ink, cols: 70, rows: 25)!
            let b = DitherArt.render(DitherArt.field(scene, params, aspect: 2.8), ink: BadgeTier.silver.ink, cols: 70, rows: 25)!
            XCTAssertEqual(pixels(a), pixels(b), scene.rawValue)
        }
    }

    /// Every scene draws something, and none floods the plate — on a wide tile
    /// and on the square the share card uses.
    func testEveryScenePrintsAPicture() {
        for scene in ArtScene.allCases {
            for (cols, rows) in [(88, 31), (30, 30)] {
                let share = coverage(scene, cols: cols, rows: rows)
                XCTAssertGreaterThan(share, 0.03, "\(scene.rawValue) at \(cols)×\(rows) is nearly empty")
                XCTAssertLessThan(share, 0.92, "\(scene.rawValue) at \(cols)×\(rows) is nearly solid")
            }
        }
    }

    func testDitherLevels() {
        for row in 0..<8 {
            for col in 0..<8 {
                XCTAssertEqual(DitherArt.level(0, col: col, row: row), 0)
                XCTAssertEqual(DitherArt.level(1, col: col, row: row), 2)
            }
        }
        // Half density on three levels is half ink everywhere: exactly the
        // middle level, so a flat fill prints as a flat tint, not as noise.
        let half = (0..<64).map { DitherArt.level(0.5, col: $0 % 8, row: $0 / 8) }
        XCTAssertEqual(Set(half), [1])
        let quarter = (0..<64).map { DitherArt.level(0.25, col: $0 % 8, row: $0 / 8) }
        XCTAssertEqual(quarter.filter { $0 == 1 }.count, 32, "a quarter is every other cell at half ink")
    }

    /// Two people's plates differ where their work differs.
    func testPlatesAreFedTheirOwnNumbers() {
        var report = InsightReport(days: 30, since: Date())
        report.sessions = 10
        report.peakParallel = 5
        report.dispatches = 120
        let badges = BadgeCatalog.evaluate(report)
        let conductor = badges.first { $0.id == "conductor" }!
        XCTAssertEqual(DitherArt.Params.of(conductor, report: report).count, 5)
        XCTAssertEqual(DitherArt.Params.of(badges.first { $0.id == "delegator" }!, report: report).count, 120)

        let few = DitherArt.Params(seed: 1, strength: 0.5, count: 2)
        let many = DitherArt.Params(seed: 1, strength: 0.5, count: 6)
        let a = DitherArt.render(DitherArt.field(.conductor, few, aspect: 2.8), ink: BadgeTier.gold.ink, cols: 70, rows: 25)!
        let b = DitherArt.render(DitherArt.field(.conductor, many, aspect: 2.8), ink: BadgeTier.gold.ink, cols: 70, rows: 25)!
        XCTAssertNotEqual(pixels(a), pixels(b))
    }

    func testEveryBadgeAndArchetypeHasAScene() {
        let badges = BadgeCatalog.evaluate(InsightReport(days: 30, since: Date()))
        for badge in badges {
            XCTAssertNotNil(ArtScene(rawValue: badge.id), "no plate for \(badge.id)")
        }
        XCTAssertEqual(ArtScene.of(ArchetypeCatalog.explorer), .marathon)
    }
}
