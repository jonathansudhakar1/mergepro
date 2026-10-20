import Foundation
import XCTest
import MergeProCore
final class ApplicationSettingsTests: XCTestCase {
    func testSetupSettingsPersistBeforeAnyAccountExistsAndCanBeCleared() throws {
        let directory = try makeTemporaryDirectory()
        let path = directory.appendingPathComponent("settings.sqlite").path
        let store = try DatabaseStore(path:path)
        try store.setApplicationSetting("public-client-id", for:.githubClientID)
        XCTAssertEqual(try store.accounts(), [])
        let reopened = try DatabaseStore(path:path)
        XCTAssertEqual(try reopened.applicationSetting(.githubClientID), "public-client-id")
        try reopened.setApplicationSetting("replacement", for:.githubClientID)
        XCTAssertEqual(try reopened.applicationSetting(.githubClientID), "replacement")
        try reopened.setApplicationSetting(nil, for:.githubClientID)
        XCTAssertNil(try reopened.applicationSetting(.githubClientID))
    }
}
