import XCTest
@testable import Corral

final class UpdateCheckTests: XCTestCase {

    private func json(_ fields: [String: Any]) -> Data {
        var object: [String: Any] = [
            "tag_name": "v0.1.27",
            "html_url": "https://github.com/popyapp/corral/releases/tag/v0.1.27",
            "draft": false,
            "prerelease": false,
        ]
        object.merge(fields) { $1 }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    func testReadsTheLatestRelease() {
        let release = UpdateCheck.release(from: json([:]))
        XCTAssertEqual(release?.version, "0.1.27")
        XCTAssertEqual(release?.page.absoluteString, "https://github.com/popyapp/corral/releases/tag/v0.1.27")
    }

    func testRefusesWhatIsNotARelease() {
        XCTAssertNil(UpdateCheck.release(from: json(["draft": true])))
        XCTAssertNil(UpdateCheck.release(from: json(["prerelease": true])))
        XCTAssertNil(UpdateCheck.release(from: json(["tag_name": "nightly"])))
        XCTAssertNil(UpdateCheck.release(from: json(["html_url": "https://example.com/corral.dmg"])))
        XCTAssertNil(UpdateCheck.release(from: Data("not json".utf8)))
    }

    func testVersionsCompareAsNumbers() {
        XCTAssertTrue(UpdateCheck.isNewer("0.1.28", than: "0.1.27"))
        XCTAssertTrue(UpdateCheck.isNewer("0.1.10", than: "0.1.9"))
        XCTAssertTrue(UpdateCheck.isNewer("0.2", than: "0.1.30"))
        XCTAssertTrue(UpdateCheck.isNewer("v0.1.28", than: "0.1.27"))
        XCTAssertFalse(UpdateCheck.isNewer("0.1.27", than: "0.1.27"))
        XCTAssertFalse(UpdateCheck.isNewer("0.1.27", than: "0.1.27.0"))
        XCTAssertFalse(UpdateCheck.isNewer("0.1.26", than: "0.1.27"))
    }

    /// `make app` stamps the last tag plus how far past it the tree is.
    func testALocalBuildIsLevelWithItsTag() {
        XCTAssertTrue(UpdateCheck.isNewer("0.1.26", than: "0.1.25+3"))
        XCTAssertFalse(UpdateCheck.isNewer("0.1.25", than: "0.1.25+3"))
    }

    /// `swift run` has no Info.plist and reports "dev"; nothing is newer than
    /// what cannot be read.
    func testAnUnreadableVersionIsNeverBehind() {
        XCTAssertFalse(UpdateCheck.isNewer("0.1.27", than: "dev"))
        XCTAssertFalse(UpdateCheck.isNewer("nightly", than: "0.1.27"))
    }

    func testOnceADay() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(UpdateCheck.isDue(lastChecked: nil, now: now))
        XCTAssertFalse(UpdateCheck.isDue(lastChecked: now.addingTimeInterval(-23 * 3_600), now: now))
        XCTAssertTrue(UpdateCheck.isDue(lastChecked: now.addingTimeInterval(-24 * 3_600), now: now))
    }
}
