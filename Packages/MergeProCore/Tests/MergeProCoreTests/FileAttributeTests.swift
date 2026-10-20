import XCTest
@testable import MergeProCore
final class FileAttributeTests:XCTestCase {
    func testAttributesApplyInOrderAndDoNotEscapeRepository() {
        let rules=FileAttributeRules("*.m linguist-language=Swift\nvendor/** linguist-vendored\n*.swift linguist-generated\nSources/Hand.swift -linguist-generated\n")
        XCTAssertEqual(rules.attributes(for:"Sources/File.m").language,"swift")
        XCTAssertTrue(rules.attributes(for:"vendor/lib/a.c").vendored)
        XCTAssertTrue(rules.attributes(for:"Sources/Auto.swift").generated)
        XCTAssertFalse(rules.attributes(for:"Sources/Hand.swift").generated)
        XCTAssertNil(rules.attributes(for:"../File.m").language)
    }
}
