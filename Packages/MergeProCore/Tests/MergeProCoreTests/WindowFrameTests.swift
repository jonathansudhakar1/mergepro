import Foundation
import XCTest
@testable import MergeProCore

final class WindowFrameTests: XCTestCase {
    func testDisconnectedDisplayRestoresEntireWindowIntoVisibleScreen() {
        let visible = CGRect(x: 0, y: 40, width: 1440, height: 860)
        let old = CGRect(x: 3200, y: -900, width: 1280, height: 800)
        let restored = WindowFrameRestoration.fit(old, inside: visible, minimum: CGSize(width: 900, height: 540))
        XCTAssertTrue(visible.contains(restored))
        XCTAssertEqual(restored.size, old.size)
    }
    func testOversizedWindowFitsSmallerDisplayEvenBelowPreferredMinimum() {
        let visible = CGRect(x: -1024, y: 30, width: 1024, height: 700)
        let old = CGRect(x: -1500, y: 0, width: 1600, height: 1000)
        let restored = WindowFrameRestoration.fit(old, inside: visible, minimum: CGSize(width: 1100, height: 750))
        XCTAssertEqual(restored, visible)
    }
    func testVisibleWindowKeepsPositionAndSize() {
        let frame = CGRect(x: 140, y: 140, width: 1280, height: 800)
        XCTAssertEqual(WindowFrameRestoration.fit(frame, inside: CGRect(x: 0, y: 0, width: 1920, height: 1080), minimum: CGSize(width: 900, height: 540)), frame)
    }
    func testInvalidSavedFrameUsesCenteredDefault() {
        let visible = CGRect(x: 100, y: 60, width: 1400, height: 900)
        let restored = WindowFrameRestoration.fit(CGRect(x: CGFloat.nan, y: 0, width: 0, height: 0), inside: visible, minimum: CGSize(width: 900, height: 540))
        XCTAssertEqual(restored.size, CGSize(width: 900, height: 540))
        XCTAssertEqual(restored.midX, visible.midX)
        XCTAssertEqual(restored.midY, visible.midY)
    }
    func testSecondWindowCascadesFromTheFrontmostAndKeepsItsSize() {
        let visible = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let front = CGRect(x: 100, y: 200, width: 1000, height: 700)
        let next = WindowFrameRestoration.cascade(size: CGSize(width: 1280, height: 840), after: [front], inside: visible, minimum: CGSize(width: 900, height: 540))
        XCTAssertEqual(next.size, CGSize(width: 1280, height: 840))
        XCTAssertEqual(next.minX, 124)
        XCTAssertEqual(next.maxY, front.maxY - 24)
        XCTAssertTrue(visible.contains(next))
    }
    func testCascadeSkipsCornersAnotherWindowAlreadyUses() {
        let visible = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let a = CGRect(x: 100, y: 200, width: 1000, height: 700), b = CGRect(x: 124, y: 176, width: 1000, height: 700)
        let next = WindowFrameRestoration.cascade(size: a.size, after: [b, a], inside: visible, minimum: CGSize(width: 900, height: 540))
        XCTAssertEqual(next.origin, CGPoint(x: 148, y: 152))
    }
    func testCascadeWrapsToTheVisibleTopLeftInsteadOfLeavingTheScreen() {
        let visible = CGRect(x: 0, y: 40, width: 1440, height: 860)
        let front = CGRect(x: 420, y: 40, width: 1000, height: 600)
        let next = WindowFrameRestoration.cascade(size: front.size, after: [front], inside: visible, minimum: CGSize(width: 900, height: 540))
        XCTAssertTrue(visible.contains(next))
        XCTAssertEqual(next.minX, visible.minX);XCTAssertEqual(next.maxY, visible.maxY)
    }
    func testScreenSizedWindowsStillGetAReachableFrame() {
        let visible = CGRect(x: 0, y: 0, width: 1024, height: 700)
        let next = WindowFrameRestoration.cascade(size: CGSize(width: 1600, height: 1000), after: [visible], inside: visible, minimum: CGSize(width: 900, height: 540))
        XCTAssertTrue(visible.contains(next))
    }
}
