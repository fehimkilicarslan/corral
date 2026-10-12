import XCTest
@testable import Corral

final class TrendScaleTests: XCTestCase {

    /// The case that was wrong: a window with nothing in it drew every hour
    /// at half height, as if each had held something.
    func testASeriesOfZerosIsDrawnAsNothing() {
        XCTAssertEqual(TrendScale(top: 0, bottom: 0).fraction(of: 0), 0)
    }

    /// A steady non-zero value is a level, not nothing and not everything.
    func testASteadyValueSitsOnTheMidline() {
        XCTAssertEqual(TrendScale(top: 2.9, bottom: 2.9).fraction(of: 2.9), 0.5)
    }

    func testValuesScaleBetweenBottomAndTop() {
        let scale = TrendScale(top: 10, bottom: 0)
        XCTAssertEqual(scale.fraction(of: 0), 0)
        XCTAssertEqual(scale.fraction(of: 5), 0.5)
        XCTAssertEqual(scale.fraction(of: 10), 1)
        XCTAssertEqual(TrendScale(top: 12, bottom: 2).fraction(of: 7), 0.5)
    }
}
