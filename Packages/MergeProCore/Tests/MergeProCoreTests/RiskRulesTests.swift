import XCTest
@testable import MergeProCore
final class RiskRulesTests: XCTestCase {
    func testSensitivePathsAndSecretEvidenceNeverContainSecretValue() throws {
        let file = DiffFile(path:".github/workflows/ci.yml",status:.added,patch:"@@ -0,0 +1,1 @@\n+TOKEN=ghp_012345678901234567890123456789012345")
        let risks = RiskRules.evaluate(files:[file],viewed:[],usualSize:0)
        XCTAssertTrue(risks.contains { $0.kind == .sensitivePath })
        XCTAssertTrue(risks.contains { $0.kind == .possibleSecret && $0.line == 1 })
        XCTAssertFalse(String(decoding:try JSONEncoder.stable.encode(risks),as:UTF8.self).contains("ghp_"))
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

extension RiskRulesTests {
    func testLocallyWrittenAgentPullRequestsAreRecognized() {
        // A person's own pull request, written with a local agent that signs its commits.
        let trailers = AgentClassifier.coauthors(inCommitMessage: "Fix retry\n\nSome detail.\n\nCo-Authored-By: Claude <noreply@anthropic.com>\nco-authored-by: Sam <sam@example.com>")
        XCTAssertEqual(trailers, ["Claude <noreply@anthropic.com>", "Sam <sam@example.com>"])
        XCTAssertEqual(AgentClassifier.classify(login:"person",actorType:"User",coauthors:trailers),.agent)
        XCTAssertEqual(AgentClassifier.classify(login:"person",actorType:"User",coauthors:["Sam <sam@example.com>"]),.human)
        XCTAssertEqual(AgentClassifier.classify(login:"person",actorType:"User",coauthors:["Cursor Agent <cursoragent@cursor.com>"]),.agent)
        // Agent signatures in the body.
        XCTAssertEqual(AgentClassifier.classify(login:"person",actorType:"User",body:"Adds retries.\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)"),.agent)
        XCTAssertEqual(AgentClassifier.classify(login:"person",actorType:"User",body:"Task: https://chatgpt.com/codex/tasks/task_e_123"),.agent)
        XCTAssertEqual(AgentClassifier.classify(login:"person",actorType:"User",body:"I generated this table by hand."),.human)
        // More agents, and any agent: label.
        XCTAssertEqual(AgentClassifier.classify(login:"google-labs-jules[bot]",actorType:"Bot"),.agent)
        XCTAssertEqual(AgentClassifier.classify(login:"person",actorType:"User",branch:"cursor/fix-login"),.agent)
        XCTAssertEqual(AgentClassifier.classify(login:"person",actorType:"User",labels:["agent:aider"]),.agent)
        // The user's own conventions.
        let custom = AgentPatterns(branchPrefixes:["ai/"],labels:["written-by-ai"])
        XCTAssertEqual(AgentClassifier.classify(login:"person",actorType:"User",branch:"ai/refactor",custom:custom),.agent)
        XCTAssertEqual(AgentClassifier.classify(login:"person",actorType:"User",labels:["Written-By-AI"],custom:custom),.agent)
        XCTAssertEqual(AgentClassifier.classify(login:"person",actorType:"User",manual:["person":.human],body:"🤖 Generated with Codex",custom:custom),.human)
    }
}

extension RiskRulesTests {
    func testInventoryKeepsOnlyCoauthorTrailersAcrossCheckpoints() throws {
        let json = #"{"nodes":[{"commit":{"message":"Fix\n\nprivate detail\n\nCo-authored-by: Claude <noreply@anthropic.com>","statusCheckRollup":{"state":"SUCCESS"}}}]}"#
        let decoded = try JSONDecoder().decode(GitHubPRInventoryPayload.Node.Commits.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.nodes.first??.commit.coauthors, ["Claude <noreply@anthropic.com>"])
        let stored = try JSONEncoder().encode(decoded)
        XCTAssertFalse(String(decoding: stored, as: UTF8.self).contains("private detail"))
        XCTAssertEqual(try JSONDecoder().decode(GitHubPRInventoryPayload.Node.Commits.self, from: stored).nodes.first??.commit.coauthors, ["Claude <noreply@anthropic.com>"])
    }
}
