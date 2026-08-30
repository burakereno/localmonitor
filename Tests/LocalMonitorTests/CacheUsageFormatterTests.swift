import Foundation
import XCTest
@testable import LocalMonitor

final class CacheUsageFormatterTests: XCTestCase {
    func testUsesGigabytesWhenLimitIsAtLeastOneGigabyte() {
        let text = CacheUsageFormatter.string(
            bytes: 400_000_000,
            limitBytes: 1_500_000_000,
            locale: Locale(identifier: "tr_TR")
        )

        XCTAssertEqual(text, "0,4/1,5 GB")
    }

    func testUsesMegabytesForSubGigabyteLimits() {
        let text = CacheUsageFormatter.string(
            bytes: 88_700_000,
            limitBytes: 750_000_000,
            locale: Locale(identifier: "tr_TR")
        )

        XCTAssertEqual(text, "88,7/750 MB")
    }
}
