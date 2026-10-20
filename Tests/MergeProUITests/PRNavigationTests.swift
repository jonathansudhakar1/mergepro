import XCTest

@MainActor
final class PRNavigationTests: XCTestCase {
  private var fixtureApplication: XCUIApplication?
  override func setUpWithError() throws { continueAfterFailure = false }
  override func tearDown() async throws {
    await MainActor.run { fixtureApplication?.terminate();fixtureApplication=nil }
    try await super.tearDown()
  }
  private func app(_ count: Int = 500) -> XCUIApplication {
    let app = XCUIApplication(bundleIdentifier: "app.mergepro.mac.fixtures")
    app.launchEnvironment["MERGEPRO_UI_TEST_NAMESPACE"] = UUID().uuidString
    app.launchEnvironment["MERGEPRO_PR_FIXTURE_COUNT"] = String(count)
    fixtureApplication = app
    return app
  }
  func testNativeBoardListShortcutsAndEditableFieldsConsumeLetters() {
    let app = app()
    app.launch()
    let window = app.windows["main"]
    XCTAssertTrue(window.waitForExistence(timeout: 10))
    app.menuBars.menuBarItems["File"].click()
    app.menuBars.menuBarItems["File"].menus.menuItems["Open MergePro"].click()
    XCTAssertTrue(window.descendants(matching: .any)["prBoard"].waitForExistence(timeout: 5))
    app.typeKey("2", modifierFlags: .command)
    XCTAssertTrue(window.outlines["prList"].waitForExistence(timeout: 5))
    app.typeKey("1", modifierFlags: .command)
    XCTAssertTrue(window.descendants(matching: .any)["prBoard"].waitForExistence(timeout: 5))
    let filter = window.textFields["prFilter"]
    filter.click()
    app.typeText("am")
    XCTAssertEqual(filter.value as? String, "am")
    XCTAssertFalse(window.sheets.firstMatch.exists)
    XCTAssertFalse(
      window.staticTexts["Review commands are unavailable until review services are installed."]
        .exists)
  }
  func testSignedFixtureRefreshPreservesMultiselectionFocusedIdentityAndVisiblePosition() {
    let app = app()
    app.launch()
    let window = app.windows["main"]
    XCTAssertTrue(window.waitForExistence(timeout: 10))
    let cards = window.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "prCard-"))
    XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 10))
    window.scrollViews["prBoard"].scroll(byDeltaX: 0, deltaY: -450)
    let visible = cards.allElementsBoundByIndex.filter { $0.isHittable }
    XCTAssertGreaterThanOrEqual(visible.count, 2)
    guard visible.count >= 2 else { return }
    let first = visible[0]
    let second = visible[1]
    first.click()
    XCUIElement.perform(withKeyModifiers: .command) { second.click() }
    let focused = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", "Selected, Focused"), object: second)
    let settled = XCTWaiter.wait(for: [focused], timeout: 2)
    XCTAssertEqual(settled, .completed)
    XCTAssertEqual(first.value as? String, "Selected, Unfocused")
    XCTAssertEqual(second.value as? String, "Selected, Focused")
    let firstFrame = first.frame
    let secondFrame = second.frame
    let completion = window.staticTexts["fixtureRefreshStatus"]
    XCTAssertTrue(completion.exists)
    let before = completion.value as? String ?? ""
    XCTAssertFalse(before.isEmpty)
    app.typeKey("r", modifierFlags: .command)
    let finished = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value != %@", before), object: completion)
    XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 10), .completed)
    XCTAssertEqual(first.value as? String, "Selected, Unfocused")
    XCTAssertEqual(second.value as? String, "Selected, Focused")
    XCTAssertEqual(first.frame.minY, firstFrame.minY, accuracy: 2)
    XCTAssertEqual(second.frame.minY, secondFrame.minY, accuracy: 2)
    first.click()
    let plainFocus = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", "Selected, Focused"), object: first)
    XCTAssertEqual(XCTWaiter.wait(for: [plainFocus], timeout: 2), .completed)
    XCTAssertEqual(second.value as? String, "Unselected, Unfocused")
    XCUIElement.perform(withKeyModifiers: .shift) { second.click() }
    let rangeFocus = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", "Selected, Focused"), object: second)
    XCTAssertEqual(XCTWaiter.wait(for: [rangeFocus], timeout: 2), .completed)
    XCTAssertEqual(first.value as? String, "Selected, Unfocused")
    first.doubleClick()
    XCTAssertTrue(app.descendants(matching: .any)["prDetailWindow"].waitForExistence(timeout: 5))
  }
  func testCacheNavigation500Board() { verifyCacheNavigation(500) }
  func testCacheNavigation5000NativeRows() { verifyCacheNavigation(5000) }
  private func verifyCacheNavigation(_ count: Int) {
    let app = app(count)
    let launch = Date()
    app.launch()
    let window = app.windows["main"]
    XCTAssertTrue(window.waitForExistence(timeout: 10))
    if count == 5000 {
      XCTAssertTrue(window.outlines["prList"].waitForExistence(timeout: 10))
    } else {
      XCTAssertTrue(window.descendants(matching: .any)["prBoard"].waitForExistence(timeout: 10))
    }
    print(
      "TASK5 native ready \(count): \(Date().timeIntervalSince(launch))s (includes XCTest launch/AX wait)"
    )
    let start = Date()
    app.typeKey(.escape, modifierFlags: [])
    app.typeKey("j", modifierFlags: [])
    app.typeKey(.return, modifierFlags: [])
    XCTAssertTrue(app.descendants(matching: .any)["prDetailWindow"].waitForExistence(timeout: 5))
    print(
      "TASK5 native cache open \(count): \(Date().timeIntervalSince(start))s (includes XCTest key/AX wait)"
    )
  }
}
