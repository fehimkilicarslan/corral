import AppKit
import SwiftUI
import XCTest
@testable import Corral

/// The visual rules that are easy to undo by accident: contrast floors, the
/// light-mode variants, and motion that has to stay off under Reduce Motion.
@MainActor
final class DesignTests: XCTestCase {

    // ─ Measuring ────────────────────────────────────────────────────────────

    /// The colour a view draws at its centre, in sRGB.
    ///
    /// The renderer's image is sRGB, but `colorAt` hands its components back
    /// labelled as generic RGB; converting that label to sRGB would shift
    /// every value. So the components are taken as the sRGB they are.
    private func sample<V: View>(_ view: V, _ scheme: ColorScheme) -> NSColor {
        let renderer = ImageRenderer(content: view.frame(width: 8, height: 8).environment(\.colorScheme, scheme))
        let image = renderer.cgImage!
        XCTAssertEqual(image.colorSpace?.name, CGColorSpace.sRGB)
        let raw = NSBitmapImageRep(cgImage: image).colorAt(x: 4, y: 4)!
        return NSColor(srgbRed: raw.redComponent, green: raw.greenComponent, blue: raw.blueComponent, alpha: 1)
    }

    private func luminance(_ color: NSColor) -> Double {
        func linear(_ c: CGFloat) -> Double {
            let c = Double(c)
            return c <= 0.040_45 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent)
            + 0.0722 * linear(color.blueComponent)
    }

    private func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// `color` as drawn over a row, against the row alone.
    private func contrastOnRow(_ color: Color, _ scheme: ColorScheme) -> Double {
        let row = sample(Rectangle().fill(Theme.rowBackground), scheme)
        let ink = sample(ZStack { Rectangle().fill(Theme.rowBackground); Rectangle().fill(color) }, scheme)
        return contrast(ink, row)
    }

    // ─ Contrast ─────────────────────────────────────────────────────────────

    /// The quietest text in the app was 2.7:1 on a white row and 3.5:1 on a
    /// dark one. It must not drift back down.
    func testFaintTextClearsItsFloor() {
        XCTAssertGreaterThan(contrastOnRow(Theme.faint, .light), 3.0)
        XCTAssertGreaterThan(contrastOnRow(Theme.faint, .dark), 3.5)
        // And it stays quieter than secondary text, or the hierarchy is gone.
        XCTAssertLessThan(contrastOnRow(Theme.faint, .light), contrastOnRow(Theme.subtle, .light))
    }

    /// Bronze, silver and gold are used as text: "Top tier", the tier pills,
    /// the badge count. Gold on white was 2:1.
    func testTierColoursReadAsTextInBothAppearances() {
        let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let dark = NSColor(srgbRed: 0.12, green: 0.12, blue: 0.12, alpha: 1)
        for tier in [BadgeTier.bronze, .silver, .gold] {
            XCTAssertGreaterThan(contrast(sample(Rectangle().fill(tier.color), .light), white), 4.5, tier.title)
            XCTAssertGreaterThan(contrast(sample(Rectangle().fill(tier.color), .dark), dark), 4.5, tier.title)
        }
    }

    /// The share card forces dark, so it keeps the bright metals even when the
    /// app around it is light.
    func testForcedDarkResolvesTheDarkMetal() {
        let gold = sample(Rectangle().fill(BadgeTier.gold.color), .dark)
        XCTAssertEqual(Double(gold.redComponent), 0.91, accuracy: 0.02)
    }

    // ─ Plates ───────────────────────────────────────────────────────────────

    /// On a white page the half-tone prints heavier, or a light-mode plate is
    /// a pale wash.
    func testLightInkPrintsAHeavierHalfTone() {
        func halfTone(_ ink: DitherArt.Ink) -> Set<UInt8> {
            let image = DitherArt.render({ _ in 0.5 }, ink: ink, cols: 16, rows: 16)!
            let bytes = [UInt8](image.dataProvider!.data! as Data)
            return Set(stride(from: 3, to: bytes.count, by: 4).map { bytes[$0] })
        }
        let gold = BadgeTier.gold.ink
        XCTAssertEqual(halfTone(gold), [UInt8((0.42 * 255).rounded())])
        XCTAssertEqual(halfTone(gold.onLight), [UInt8((0.62 * 255).rounded())])
    }

    // ─ Motion ───────────────────────────────────────────────────────────────

    func testEdgePanelMotion() {
        XCTAssertNil(EdgePanelController.duration(opening: true, reduceMotion: true))
        XCTAssertNil(EdgePanelController.duration(opening: false, reduceMotion: true))
        let open = EdgePanelController.duration(opening: true, reduceMotion: false)!
        let close = EdgePanelController.duration(opening: false, reduceMotion: false)!
        XCTAssertLessThan(close, open, "closing is quicker than opening")
        XCTAssertLessThanOrEqual(open, 0.3)

        // No control point above 1: the panel settles without passing its mark.
        var point = [Float](repeating: 0, count: 2)
        for index in 1...2 {
            EdgePanelController.timing.getControlPoint(at: index, values: &point)
            XCTAssertLessThanOrEqual(point[1], 1)
        }
    }

    // ─ Numbers and the ladder ───────────────────────────────────────────────

    func testCountsAreGroupedAndTheLadderIsShown() {
        var report = InsightReport(days: 90, since: Date())
        report.sessions = 40
        report.dispatches = 1_234
        let badges = BadgeCatalog.evaluate(report)

        let delegator = badges.first { $0.id == "delegator" }!
        XCTAssertEqual(delegator.value, "\(1_234.formatted()) subagents")
        XCTAssertEqual(delegator.ladder, ["10 subagents", "50 subagents", "200 subagents"])
        XCTAssertFalse(delegator.lowerIsBetter)

        let calm = badges.first { $0.id == "calm" }!
        XCTAssertEqual(calm.ladder, ["12%", "6%", "2%"])
        XCTAssertTrue(calm.lowerIsBetter)
        XCTAssertFalse(calm.hasData, "a locked badge still shows the ladder it is judged on")

        let post = ShareText.post(report: report, archetype: ArchetypeCatalog.pick(badges), badges: badges)
        XCTAssertTrue(post.contains("\(40.formatted()) sessions"))
    }
}
