import Foundation
import XCTest
@testable import LocalMonitor

@MainActor
final class UpdateCheckerTests: XCTestCase {
    func testVersionCompareHandlesPatchAndMissingSegments() {
        XCTAssertTrue(UpdateChecker.compare("1.0.1", isNewerThan: "1.0.0"))
        XCTAssertTrue(UpdateChecker.compare("1.1", isNewerThan: "1.0.9"))
        XCTAssertFalse(UpdateChecker.compare("1.0.0", isNewerThan: "1.0"))
        XCTAssertFalse(UpdateChecker.compare("1.0.0", isNewerThan: "1.0.1"))
    }

    func testReleaseInfoNormalizesResolvedLatestURL() throws {
        let url = try XCTUnwrap(URL(string: "https://github.com/burakereno/localmonitor/releases/tag/v0.1.14"))

        let info = try UpdateChecker.releaseInfo(fromResolvedLatestURL: url)

        XCTAssertEqual(info.version, "0.1.14")
        XCTAssertEqual(
            info.downloadURL.absoluteString,
            "https://github.com/burakereno/localmonitor/releases/download/v0.1.14/LocalMonitor.dmg"
        )
    }
}
