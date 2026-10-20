import XCTest
@testable import MergeProRendering
final class TextMateConformanceTests:XCTestCase {
    func testScopeStacksAndRangesMatchPinnedWASMReference() async throws {
        let url=Bundle.module.url(forResource:"conformance",withExtension:"json",subdirectory:"Fixtures")!
        let cases=try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as! [[String:Any]]
        for value in cases {
            let grammar=try JSONSerialization.data(withJSONObject:value["grammar"]!)
            let dependencies=try (value["dependencies"] as! [[String:Any]]).map { try JSONSerialization.data(withJSONObject:$0) }
            let actual=try await CodeTokenizer.shared.textMate(value["source"] as! String,grammar:grammar,dependencies:dependencies)
            let expected=(value["expected"] as! [[String:Any]]).map { CodeToken(range:NSRange(location:$0["location"] as! Int,length:$0["length"] as! Int),scopes:$0["scopes"] as! [String]) }
            XCTAssertEqual(actual,expected,value["name"] as! String)
        }
    }
}

extension TextMateConformanceTests {
    func testMalformedGrammarDataAndRegexFailWithoutExecutingSource() async {
        for grammar in [Data("not JSON".utf8),Data(#"{"scopeName":"source.invalid","patterns":[{"match":"[","name":"invalid"}]}"#.utf8)] {
            do { _ = try await CodeTokenizer.shared.textMate("');throw new Error('source must remain data');",grammar:grammar);XCTFail("Invalid grammar accepted") } catch {}
        }
    }
    func testSourceThatLooksLikeJavaScriptRemainsData() async throws {
        let source="globalThis.nativeCreate = null; throw new Error('not code');"
        let grammar=Data(#"{"scopeName":"source.data","patterns":[{"match":"[A-Za-z]+","name":"word"}]}"#.utf8)
        let result=try await CodeTokenizer.shared.textMate(source,grammar:grammar)
        XCTAssertTrue(result.contains { $0.scopes.contains("word") })
        XCTAssertTrue(result.allSatisfy { NSMaxRange($0.range) <= source.utf16.count })
    }
}
