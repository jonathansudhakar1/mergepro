import XCTest

/// Prepared for the bounded Task 9 native run. Every launch targets the isolated signed bundle.
@MainActor final class MergeFlowTests:XCTestCase {
    private var fixture:XCUIApplication?
    override func setUpWithError() throws { continueAfterFailure=false }
    override func tearDown() async throws { fixture?.terminate();fixture=nil }
    private func app(_ topology:String="none") -> XCUIApplication {
        let app=XCUIApplication(bundleIdentifier:"app.mergepro.mac.fixtures")
        app.launchEnvironment["MERGEPRO_UI_TEST_NAMESPACE"]=UUID().uuidString
        app.launchEnvironment["MERGEPRO_MERGE_FIXTURES"]="1"
        app.launchEnvironment["MERGEPRO_MERGE_TOPOLOGY"]=topology
        fixture=app;return app
    }
    func testKeyboardPopupEscapeAndEditableFieldSuppression() {
        let app=app();app.launch();let window=app.windows["main"]
        let card=window.descendants(matching:.any)["prCard-1"];XCTAssertTrue(card.waitForExistence(timeout:10));card.click();app.typeText("m")
        let sheet=window.descendants(matching:.any)["mergeOptionsSheet"];XCTAssertTrue(sheet.waitForExistence(timeout:5))
        XCTAssertFalse(sheet.staticTexts["mergeOutcome"].exists);app.typeKey(.escape,modifierFlags:[]);XCTAssertFalse(sheet.exists)
        XCTAssertTrue(card.exists)
        let filter=window.textFields["prFilter"];filter.click();app.typeText("m");XCTAssertEqual(filter.value as? String,"m");XCTAssertFalse(sheet.exists)
    }
    func testIneligibleDraftHasNoMergeHandleAndPendingConfirmationDoesNotMoveCard() {
        let app=app();app.launch();let window=app.windows["main"]
        XCTAssertTrue(window.descendants(matching:.any)["prCard-1"].waitForExistence(timeout:10))
        XCTAssertFalse(window.descendants(matching:.any)["mergeDrag-4"].exists)
        window.descendants(matching:.any)["prCard-1"].click();app.typeText("m")
        let confirm=window.buttons["confirmMerge"];XCTAssertTrue(confirm.waitForExistence(timeout:5));confirm.click()
        XCTAssertTrue(window.staticTexts["mergeOutcome"].waitForExistence(timeout:10))
        app.typeKey(.escape,modifierFlags:[]);XCTAssertTrue(window.descendants(matching:.any)["prCard-1"].exists)
    }
    func testEligibleDragOpensConfirmationAndEscapePreservesCard() {
        let app=app();app.launch();let window=app.windows["main"]
        let handle=window.descendants(matching:.any)["mergeDrag-3"]
        XCTAssertTrue(handle.waitForExistence(timeout:10))
        XCTAssertTrue(window.descendants(matching:.any)["stateDrag-3"].exists)
        XCTAssertFalse(window.descendants(matching:.any)["mergeDrag-4"].exists)
        XCTAssertTrue(handle.isHittable)
        // Native macOS StaticText exposes the heading as its value; the column's
        // inherited identifier also appears on its count and empty content view.
        let targets=window.staticTexts.matching(identifier:"prColumn-merged")
            .matching(NSPredicate(format:"value == %@ OR label == %@","Merged","Merged"))
        func attachTargetHierarchy() {
            let attachment=XCTAttachment(string:window.debugDescription)
            attachment.name="Merged drop target precondition hierarchy"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let targetCount=targets.count
        guard targetCount == 1 else {
            attachTargetHierarchy()
            XCTFail("Expected one Merged header, found \(targetCount)")
            return
        }
        let target=targets.element(boundBy:0)
        let targetIsHittable=target.isHittable
        if !targetIsHittable { attachTargetHierarchy() }
        XCTAssertTrue(targetIsHittable,"Merged header must be physically hittable before dragging")
        // Element dragging rejects this hittable SwiftUI control's scroll-view trait.
        // Use dynamic centers of the same verified elements for the physical drag.
        handle.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5))
            .press(forDuration:0.2,thenDragTo:target.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)))
        let sheet=window.descendants(matching:.any)["mergeOptionsSheet"]
        XCTAssertTrue(sheet.waitForExistence(timeout:5));XCTAssertFalse(window.staticTexts["mergeOutcome"].exists)
        app.typeKey(.escape,modifierFlags:[]);XCTAssertFalse(sheet.exists)
        XCTAssertTrue(window.descendants(matching:.any)["prCard-3"].exists)
    }
    func testInferredStackFixtureIsLabeledInferred() {
        let app=app("inferred");app.launch()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format:"label CONTAINS %@","Inferred stack")).firstMatch.waitForExistence(timeout:10))
    }
    func testNativeStackFixtureIsLabeledNative() {
        let app=app("native");app.launch()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format:"label CONTAINS %@","Native stack")).firstMatch.waitForExistence(timeout:10))
    }
}
