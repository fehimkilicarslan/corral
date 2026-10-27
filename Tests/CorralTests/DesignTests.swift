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
}
