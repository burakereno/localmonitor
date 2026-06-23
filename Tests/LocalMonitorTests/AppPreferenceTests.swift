import XCTest
@testable import LocalMonitor

final class AppPreferenceTests: XCTestCase {
    func testStopProjectsOnQuitDefaultsToFalse() {
        let defaults = UserDefaults.standard
        let key = AppPreference.stopProjectsOnQuitKey
        let previous = defaults.object(forKey: key)
        defaults.removeObject(forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        XCTAssertFalse(AppPreference.stopProjectsOnQuit)
    }
}
