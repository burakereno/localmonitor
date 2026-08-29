import XCTest
@testable import LocalMonitor

final class AppPreferenceTests: XCTestCase {
    func testStopProjectsOnQuitDefaultsToTrue() {
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

        XCTAssertTrue(AppPreference.stopProjectsOnQuit)
    }

    func testStopProjectsOnQuitHonorsDisabledPreference() {
        let defaults = UserDefaults.standard
        let key = AppPreference.stopProjectsOnQuitKey
        let previous = defaults.object(forKey: key)
        defaults.set(false, forKey: key)
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
