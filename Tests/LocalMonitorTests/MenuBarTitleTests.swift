import XCTest
@testable import LocalMonitor

final class MenuBarTitleTests: XCTestCase {
    func testCountTextShowsOnlyRunningProjects() {
        let title = MenuBarTitle(
            runningCount: 2,
            totalCount: 7,
            externalCount: 0,
            displayMode: .count
        )

        XCTAssertEqual(title.countText, "2")
    }
}
