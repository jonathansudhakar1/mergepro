import XCTest

/// Only the isolated fixture bundle; no user repositories or provider mutations.
@MainActor final class LocalFolderTests:XCTestCase {
    private var fixture:XCUIApplication?
    override func setUpWithError() throws { continueAfterFailure=false }
    override func tearDown() async throws { fixture?.terminate();fixture=nil;try await super.tearDown() }
    private func application()->XCUIApplication {
        let app=XCUIApplication()
        app.launchEnvironment["MERGEPRO_UI_TEST_NAMESPACE"]=UUID().uuidString
        app.launchEnvironment["MERGEPRO_PHASE23_FIXTURES"]="1"
        app.launchEnvironment["MERGEPRO_PHASE23_DESTINATION"]="local"
        fixture=app;return app
    }
    func testLocalEmptyStateAndCancellingFolderPickerPreservesNoGrant() {
        let app=application();app.launch()
        let window=app.windows["main"]
        XCTAssertTrue(window.waitForExistence(timeout:10))
        let add=window.buttons["localAddFolder"]
        XCTAssertTrue(add.waitForExistence(timeout:10),window.debugDescription)
        XCTAssertTrue(window.staticTexts["Choose a Local Repository"].exists)
        add.click()
        let cancel=app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout:5),app.debugDescription)
        cancel.click()
        XCTAssertTrue(window.staticTexts["Choose a Local Repository"].waitForExistence(timeout:5))
        XCTAssertFalse(window.buttons["Commit"].exists,"A cancelled picker cannot grant a repository or enable writes")
    }
    func testLocalNavigationRetainsEmptyWorkspaceAcrossOtherTabs() {
        let app=application();app.launch()
        let window=app.windows["main"]
        XCTAssertTrue(window.buttons["localAddFolder"].waitForExistence(timeout:10))
        window.descendants(matching:.any)["actionsNavigation"].click()
        XCTAssertTrue(window.buttons["Filters"].waitForExistence(timeout:10))
        window.descendants(matching:.any)["localNavigation"].click()
        XCTAssertTrue(window.buttons["localAddFolder"].waitForExistence(timeout:10))
        XCTAssertTrue(window.staticTexts["Choose a Local Repository"].exists)
    }
}
