import XCTest

@MainActor
final class ShellTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func isolatedApplication() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MERGEPRO_UI_TEST_NAMESPACE"] = UUID().uuidString
        return app
    }

    func testOAuthConfigurationAndOptionalPreferencesAreNativeAndPersisted() {
        let app = isolatedApplication()
        app.launch()
        let main = app.windows["MergePro"]
        XCTAssertTrue(main.waitForExistence(timeout:5))
        XCTAssertTrue(main.buttons["connectGitHub"].waitForExistence(timeout:3))
        XCTAssertFalse(main.buttons["Cancel connection"].exists, "sign-in must not start automatically")
        app.typeKey(",",modifierFlags:.command)
        let settings = app.windows["MergePro Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout:3))
        let clientID = settings.textFields["githubClientID"]
        XCTAssertTrue(clientID.waitForExistence(timeout:3),settings.debugDescription)
        let original = clientID.value as? String ?? ""
        clientID.click(); app.typeKey("a",modifierFlags:.command); app.typeKey(.delete,modifierFlags:[])
        app.typeText("fixture-public-client")
        settings.buttons["Save configuration"].click()
        XCTAssertTrue(settings.staticTexts.matching(NSPredicate(format:"value == %@","GitHub OAuth App configuration saved.")).firstMatch.waitForExistence(timeout:3))
        app.terminate(); app.launch()
        app.typeKey(",",modifierFlags:.command)
        let restored = app.windows["MergePro Settings"].textFields["githubClientID"]
        XCTAssertTrue(restored.waitForExistence(timeout:3))
        XCTAssertEqual(restored.value as? String,"fixture-public-client")
        restored.click(); app.typeKey("a",modifierFlags:.command); app.typeKey(.delete,modifierFlags:[])
        if !original.isEmpty { app.typeText(original) }
        app.windows["MergePro Settings"].buttons["Save configuration"].click()
        XCTAssertTrue(app.windows["MergePro Settings"].descendants(matching:.any)["notificationsPreference"].exists)
        XCTAssertTrue(app.windows["MergePro Settings"].descendants(matching:.any)["loginPreference"].exists)
    }

    // Removing the Settings scene or menu-bar reopen action must fail this flow.
    func testLaunchSettingsAndReopenWindowFromMenuBar() {
        let app = isolatedApplication()
        app.launch()
        let mainWindow = app.windows["MergePro"]
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 5))
        XCTAssertTrue(mainWindow.staticTexts.matching(NSPredicate(format: "value == %@", "No accounts connected")).firstMatch.waitForExistence(timeout: 3), mainWindow.debugDescription)

        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows["MergePro Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        XCTAssertTrue(settings.descendants(matching: .any)["Accounts"].exists, settings.debugDescription)
        settings.buttons[XCUIIdentifierCloseWindow].click()
        mainWindow.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(mainWindow.waitForNonExistence(timeout: 3))

        let statusItem = app.statusItems["mergeProStatus"]
        XCTAssertTrue(statusItem.waitForExistence(timeout: 3), app.debugDescription)
        statusItem.click()
        app.buttons["Open MergePro"].click()
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 3))
        XCTAssertTrue(mainWindow.staticTexts.matching(NSPredicate(format: "value == %@", "No accounts connected")).firstMatch.waitForExistence(timeout: 3), mainWindow.debugDescription)

        // Closed-window restoration must not suppress setup on the next app launch.
        mainWindow.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(mainWindow.waitForNonExistence(timeout:3))
        app.terminate(); app.launch()
        XCTAssertTrue(app.windows["MergePro"].waitForExistence(timeout:5))
        app.terminate()
    }
}
