import XCTest
@testable import MergeProCore

final class LocalGitHistoryTests: XCTestCase, @unchecked Sendable {
    func testPagesRemainPinnedWhenHeadAdvancesAndSearchIsLiteral() async throws {
        let f = try await HistoryFixture.make(); defer { f.remove() }
        for index in 1...52 { _ = try await f.git(["commit", "--allow-empty", "-m", "entry \(index)"]) }
        let first = try await f.service.history(directory: f.repo)
        XCTAssertEqual(first.commits.count, 50)
        let cursor = try XCTUnwrap(first.nextCursor)
        _ = try await f.git(["commit", "--allow-empty", "-m", "new tip"])
        let second = try await f.service.history(directory: f.repo, cursor: cursor)
        XCTAssertEqual(second.commits.count, 3)
        XCTAssertNil(second.nextCursor)
        XCTAssertTrue(Set(first.commits.map(\.id)).isDisjoint(with: second.commits.map(\.id)))
        XCTAssertEqual(second.commits.last?.subject, "root [literal]")
        let searched = try await f.service.history(directory: f.repo, search: "[literal]")
        XCTAssertEqual(searched.commits.map(\.subject), ["root [literal]"])
    }
    func testRootCommitUsesEmptyTreeAndLiteralHistoricalPath() async throws {
        let f = try await HistoryFixture.make(); defer { f.remove() }
        let sha = try await f.git(["rev-parse", "HEAD"])
        let detail = try await f.service.commitDetails(commit: sha, directory: f.repo)
        XCTAssertTrue(detail.commit.parents.isEmpty)
        XCTAssertEqual(detail.files.map(\.path), [f.path])
        XCTAssertEqual(detail.commit.authorName, "History Tester")
        XCTAssertTrue(detail.commit.refs.contains("HEAD -> main"))
        let diff = try await f.service.commitDiff(commit: sha, path: f.path, directory: f.repo)
        XCTAssertNil(diff.firstParent)
        XCTAssertTrue(try XCTUnwrap(diff.patch).contains("+root content"))
        try Data("uncommitted replacement".utf8).write(to: f.repo.appendingPathComponent(f.path))
        _ = try await f.git(["commit", "--allow-empty", "-m", "later"])
        let immutable = try await f.service.commitDiff(commit: sha, path: f.path, directory: f.repo)
        XCTAssertEqual(diff, immutable)
    }
    func testMergeDetailsCompareFirstParentAndComparisonPinsBothTips() async throws {
        let f = try await HistoryFixture.make(); defer { f.remove() }
        _ = try await f.git(["switch", "-c", "topic"])
        try Data("topic\n".utf8).write(to: f.repo.appendingPathComponent("topic.txt"))
        _ = try await f.git(["add", "--", "topic.txt"]); _ = try await f.git(["commit", "-m", "topic change"])
        let topic = try await f.git(["rev-parse", "HEAD"])
        _ = try await f.git(["switch", "main"]); _ = try await f.git(["commit", "--allow-empty", "-m", "main change"])
        let head = try await f.git(["rev-parse", "HEAD"])
        let comparison = try await f.service.compare(target: "topic", directory: f.repo)
        XCTAssertEqual(comparison.head, head); XCTAssertEqual(comparison.target, topic)
        XCTAssertEqual(comparison.ahead, 1); XCTAssertEqual(comparison.behind, 1)
        XCTAssertEqual(comparison.files.map(\.path), ["topic.txt"])
        _ = try await f.git(["merge", "--no-ff", "topic", "-m", "merge topic"])
        let merge = try await f.git(["rev-parse", "HEAD"])
        let detail = try await f.service.commitDetails(commit: merge, directory: f.repo)
        XCTAssertEqual(detail.commit.parents, [head, topic]); XCTAssertEqual(detail.files.map(\.path), ["topic.txt"])
        let diff = try await f.service.commitDiff(commit: merge, path: "topic.txt", directory: f.repo)
        XCTAssertEqual(diff.firstParent, head); XCTAssertTrue(try XCTUnwrap(diff.patch).contains("+topic"))
    }
    func testBinaryAndOversizedFilesHaveExplicitUnavailableResult() async throws {
        let f = try await HistoryFixture.make(); defer { f.remove() }
        try Data([0, 1, 2, 3]).write(to: f.repo.appendingPathComponent("binary.dat"))
        try Data(repeating: 65, count: 1_100_000).write(to: f.repo.appendingPathComponent("large.txt"))
        _ = try await f.git(["add", "--", "binary.dat", "large.txt"]); _ = try await f.git(["commit", "-m", "unavailable"])
        let sha = try await f.git(["rev-parse", "HEAD"])
        let binary = try await f.service.commitDiff(commit: sha, path: "binary.dat", directory: f.repo)
        XCTAssertEqual(binary.unavailable, .binary); XCTAssertNil(binary.patch)
        let large = try await f.service.commitDiff(commit: sha, path: "large.txt", directory: f.repo)
        XCTAssertEqual(large.unavailable, .oversized); XCTAssertNil(large.patch)
    }
    func testUnsafeIdentifiersAndUnauthorizedRepositoryAreRejected() async throws {
        let f = try await HistoryFixture.make(); defer { f.remove() }
        let sha = try await f.git(["rev-parse", "HEAD"])
        for path in ["../outside", "/absolute", ".git/config", "a/../b", ""] {
            do { _ = try await f.service.commitDiff(commit: sha, path: path, directory: f.repo); XCTFail("Accepted \(path)") }
            catch { XCTAssertEqual(error as? LocalGitMutationError, .invalidTarget) }
        }
        do { _ = try await f.service.commitDetails(commit: "HEAD", directory: f.repo); XCTFail("Expected immutable OID") }
        catch { XCTAssertEqual(error as? LocalGitMutationError, .invalidTarget) }
        do { _ = try await LocalGitService(authorizedRoots: []).history(directory: f.repo); XCTFail("Expected authorization failure") }
        catch { guard case .authorizationRequired = error as? LocalGitError else { return XCTFail("\(error)") } }
    }
    func testComparisonValidationRejectsAdvancingTargetOrHead() async throws {
        let f = try await HistoryFixture.make(); defer { f.remove() }
        _ = try await f.git(["branch", "topic"])
        let original = try await f.service.compare(target: "topic", directory: f.repo)
        try await f.service.validateComparison(original, directory: f.repo)
        _ = try await f.git(["commit", "--allow-empty", "-m", "advance head"])
        do { try await f.service.validateComparison(original, directory: f.repo); XCTFail("Accepted changed HEAD") }
        catch { XCTAssertEqual(error as? LocalGitMutationError, .staleSnapshot) }
        let newReview = try await f.service.compare(target: "topic", directory: f.repo)
        _ = try await f.git(["branch", "-f", "topic", "HEAD"])
        do { try await f.service.validateComparison(newReview, directory: f.repo); XCTFail("Accepted changed target") }
        catch { XCTAssertEqual(error as? LocalGitMutationError, .staleSnapshot) }
    }
    func testUnbornRepositoryAndCancellation() async throws {
        let f = try await HistoryFixture.make(); defer { f.remove() }
        _ = try await f.git(["switch", "--orphan", "empty"])
        let page = try await f.service.history(directory: f.repo)
        XCTAssertTrue(page.commits.isEmpty); XCTAssertNil(page.nextCursor)
        let task = Task { try Task.checkCancellation(); return try await f.service.history(directory: f.repo) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
    }
}

private struct HistoryFixture: Sendable {
    let repo: URL
    let path = "--雪 [literal]\nfile.txt"
    var runner: ProcessGitRunner { ProcessGitRunner(environment: ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0"]) }
    var service: LocalGitService { LocalGitService(runner: runner, authorizedRoots: [repo]) }
    static func make() async throws -> Self {
        let f = Self(repo: FileManager.default.temporaryDirectory.appendingPathComponent("mergepro-history-\(UUID().uuidString)"))
        try FileManager.default.createDirectory(at: f.repo, withIntermediateDirectories: true)
        _ = try await f.git(["init", "-b", "main"])
        _ = try await f.git(["config", "user.name", "History Tester"]); _ = try await f.git(["config", "user.email", "history@example.invalid"])
        try Data("root content\n".utf8).write(to: f.repo.appendingPathComponent(f.path))
        _ = try await f.git(["--literal-pathspecs", "add", "--", f.path]); _ = try await f.git(["commit", "-m", "root [literal]"])
        return f
    }
    func git(_ arguments: [String]) async throws -> String {
        let result = try await runner.run(arguments: arguments, directory: repo)
        guard result.exitCode == 0 else { throw LocalGitError.commandFailed(command: arguments.first ?? "", exitCode: result.exitCode) }
        return String(decoding: result.standardOutput, as: UTF8.self).trimmingCharacters(in: .newlines)
    }
    func remove() { try? FileManager.default.removeItem(at: repo) }
}
