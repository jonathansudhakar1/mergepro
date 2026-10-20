import XCTest
@testable import MergeProCore
final class RiskRulesTests: XCTestCase {
    func testSensitivePathsAndSecretEvidenceNeverContainSecretValue() throws {
        let file = DiffFile(path:".github/workflows/ci.yml",status:.added,patch:"@@ -0,0 +1,1 @@\n+TOKEN=ghp_012345678901234567890123456789012345")
        let risks = RiskRules.evaluate(files:[file],viewed:[],usualSize:0)
        XCTAssertTrue(risks.contains { $0.kind == .sensitivePath })
        XCTAssertTrue(risks.contains { $0.kind == .possibleSecret && $0.line == 1 })
        XCTAssertFalse(String(decoding:try JSONEncoder().encode(risks),as:UTF8.self).contains("ghp_"))
    }
    func testDependencyAndMissingTestRulesRespectTestChanges() {
        let source = DiffFile(path:"src/main.swift",status:.modified,patch:nil)
        let lock = DiffFile(path:"package-lock.json",status:.modified,patch:nil)
        XCTAssertTrue(lock.collapsedByDefault)
        XCTAssertTrue(RiskRules.evaluate(files:[source,lock],viewed:[],usualSize:nil).contains { $0.kind == .sourceWithoutTests })
        let tests = DiffFile(path:"Tests/MainTests.swift",status:.added,patch:nil)
        XCTAssertFalse(RiskRules.evaluate(files:[source,tests],viewed:[],usualSize:nil).contains { $0.kind == .sourceWithoutTests })
    }
    func testUnknownAndManualClassificationWinsOverBotName() {
        XCTAssertEqual(AgentClassifier.classify(login:"someone",actorType:nil),.unknown)
        XCTAssertEqual(AgentClassifier.classify(login:"dependabot[bot]",actorType:"Bot"),.automation)
        XCTAssertEqual(AgentClassifier.classify(login:"copilot",actorType:"Bot"),.agent)
        XCTAssertEqual(AgentClassifier.classify(login:"copilot",actorType:"Bot",manual:["copilot":.human]),.human)
    }
}

extension RiskRulesTests {
    func testAgentHintsRemainDeterministicAndManualOverrideWins() {
        XCTAssertEqual(AgentClassifier.classify(login:"person",actorType:"User",branch:"copilot/fix",labels:[],coauthors:[]),.agent)
        XCTAssertEqual(AgentClassifier.classify(login:"person",actorType:nil,branch:"fix",labels:["agent:codex"],coauthors:[]),.agent)
        XCTAssertEqual(AgentClassifier.classify(login:"person",actorType:nil,manual:["person":.human],branch:"copilot/fix",labels:[],coauthors:[]),.human)
    }
}
