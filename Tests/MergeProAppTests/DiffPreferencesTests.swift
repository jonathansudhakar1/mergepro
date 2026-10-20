import XCTest
@testable import MergePro

/// Renamed diff preferences don't leave their old values behind.
final class DiffPreferencesTests:XCTestCase {
    func testRetiredThreadRailPreferenceIsRemovedAndTheOverviewStaysOff() throws {
        let suite="DiffPreferencesTests."+UUID().uuidString
        let defaults=try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        defaults.set(true,forKey:"diffThreadRailVisible")
        defaults.set(false,forKey:"unrelatedPreference")
        DiffPreferences.removeRetired(from:defaults)
        XCTAssertNil(defaults.object(forKey:"diffThreadRailVisible"))
        XCTAssertNil(defaults.object(forKey:DiffPreferences.threadOverviewVisible),"the rail's value isn't carried over: the overview starts off")
        XCTAssertNotNil(defaults.object(forKey:"unrelatedPreference"))
    }
}
