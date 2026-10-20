import XCTest

/// Runs only against the distinct fixture target and a fresh namespace; no live provider writes.
@MainActor final class TreeNavigationTests:XCTestCase {
    private var fixture:XCUIApplication?
    override func setUpWithError() throws { continueAfterFailure=false }
    override func tearDown() async throws { fixture?.terminate();fixture=nil;try await super.tearDown() }
    private func application(destination:String)->XCUIApplication {
        let app=XCUIApplication()
        app.launchEnvironment["MERGEPRO_UI_TEST_NAMESPACE"]=UUID().uuidString
        app.launchEnvironment["MERGEPRO_PHASE23_FIXTURES"]="1"
        app.launchEnvironment["MERGEPRO_PHASE23_DESTINATION"]=destination
        app.launchEnvironment["MERGEPRO_PHASE23_REPO_COUNT"]="120"
        fixture=app;return app
    }
    private func row(_ account:String,_ repository:String,_ owner:String,_ group:String)->String {
        "outlineRow-"+["github.com",account,repository,owner,"",group].map { Data($0.utf8).base64EncodedString() }.joined(separator:"|")
    }
    private func chooseRepository(_ app:XCUIApplication)->XCUIElement {
        let window=app.windows["main"]
        XCTAssertTrue(window.waitForExistence(timeout:10))
        let search=window.textFields["Search repositories"]
        XCTAssertTrue(search.waitForExistence(timeout:10));search.click();app.typeText("phase23")
        let pinned=window.descendants(matching:.any)[row("99","7","70","pins")]
        XCTAssertTrue(pinned.waitForExistence(timeout:10),window.debugDescription);pinned.click()
        XCTAssertTrue(window.outlines["repoFileTree"].waitForExistence(timeout:10),window.debugDescription)
        return window
    }
    func testLazyNativeTreeKeyboardRefSwitchAndRelaunchRestoreSelection() {
        let app=application(destination:"repos");app.launch()
        let window=chooseRepository(app)
        let tree=window.outlines["repoFileTree"]
        let source=tree.descendants(matching:.any)["outlineRow-Sources"]
        XCTAssertTrue(source.waitForExistence(timeout:5));source.click();app.typeKey(.rightArrow,modifierFlags:[])
        let file=tree.descendants(matching:.any)["outlineRow-Sources/BuildStatus.swift"]
        XCTAssertTrue(file.waitForExistence(timeout:5),window.debugDescription);file.click()
        XCTAssertTrue(window.staticTexts["repoFilePath"].waitForExistence(timeout:5))
        XCTAssertEqual(window.staticTexts["repoFilePath"].value as? String,"Sources/BuildStatus.swift")
        let ref=window.textFields["Branch, tag or commit SHA"]
        ref.click();app.typeKey("a",modifierFlags:.command);app.typeText("v1.0");app.typeKey(.return,modifierFlags:[])
        XCTAssertTrue(window.buttons["repoCopyPermalink"].waitForExistence(timeout:5))
        let attachment=XCTAttachment(screenshot:window.screenshot());attachment.name="Phase3 native immutable file tree";attachment.lifetime = .keepAlways;add(attachment)
        // Leaving the tab allows the debounced durable state to settle through native event processing.
        window.descendants(matching:.any)["actionsNavigation"].click()
        XCTAssertTrue(window.descendants(matching:.any)["Workflows"].waitForExistence(timeout:10))
        app.terminate();app.launch()
        let restored=app.windows["main"].staticTexts["repoFilePath"]
        XCTAssertTrue(restored.waitForExistence(timeout:10),app.debugDescription)
        XCTAssertEqual(restored.value as? String,"Sources/BuildStatus.swift")
        XCTAssertEqual(app.windows["main"].textFields["Branch, tag or commit SHA"].value as? String,"v1.0")
    }
    func testActionsTypedInputsAndScopedRepositoryPRFilterStayLocal() {
        let app=application(destination:"actions");app.launch()
        let window=app.windows["main"]
        XCTAssertTrue(window.waitForExistence(timeout:10))
        window.descendants(matching:.any)["Workflows"].click()
        let run=window.buttons["Run…"].firstMatch
        XCTAssertTrue(run.waitForExistence(timeout:10),window.debugDescription);run.click()
        let sheet=window.sheets.firstMatch
        XCTAssertTrue(sheet.textFields["version"].waitForExistence(timeout:10),window.debugDescription)
        XCTAssertTrue(sheet.textFields["count"].exists)
        XCTAssertTrue(sheet.switches["dry_run"].exists)
        let attachment=XCTAttachment(screenshot:sheet.screenshot());attachment.name="Phase2 typed workflow inputs";attachment.lifetime = .keepAlways;add(attachment)
        sheet.buttons["Close"].click()
        window.descendants(matching:.any)["reposNavigation"].click()
        _=chooseRepository(app)
        window.descendants(matching:.any)["repoSectionPicker"].descendants(matching:.any)["Pull Requests"].click()
        let filter=window.textFields["prFilter"]
        XCTAssertTrue(filter.waitForExistence(timeout:10));filter.click();app.typeKey("a",modifierFlags:.command);app.typeKey(.delete,modifierFlags:[])
        let cards=window.descendants(matching:.any).matching(NSPredicate(format:"identifier BEGINSWITH %@","prCard-"))
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout:5),window.debugDescription)
        XCTAssertEqual(cards.count,1,"Clearing the editable filter must retain the enclosing repository/account scope")
    }
}
