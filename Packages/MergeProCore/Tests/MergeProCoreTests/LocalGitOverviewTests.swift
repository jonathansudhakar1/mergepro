import XCTest
@testable import MergeProCore

final class LocalGitOverviewTests: XCTestCase, @unchecked Sendable {
    func testOverviewShowsHugeUntrackedFilesWithoutReadingContentOrHashingIndex() async throws {
        let f = try await OverviewFixture.make(); defer { f.remove() }
        let large = f.root.appendingPathComponent("large.dat")
        FileManager.default.createFile(atPath: large.path, contents: nil)
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: 16 * 1024 * 1024); try handle.close()
        let recorder = OverviewRecordingRunner(base: f.runner)
        let service = LocalGitService(runner: recorder, authorizedRoots: [f.root])
        let start = ContinuousClock.now
        let overview = try await service.overview(directory: f.root)
        print("LOCAL_OVERVIEW 16MiB-untracked: \(start.duration(to: .now))")
        XCTAssertEqual(overview.status.branch, "main")
        XCTAssertTrue(overview.status.entries.contains { $0.path == "large.dat" && $0.isUntracked })
        XCTAssertTrue(overview.branches.contains { $0.name == "main" && $0.isCurrent })
        let commands = await recorder.commands
        XCTAssertFalse(commands.contains { $0.first == "ls-files" || $0.first == "diff" })
        do { _ = try await service.snapshot(directory: f.root); XCTFail("Write admission must retain bounded content validation") }
        catch { XCTAssertEqual(error as? LocalGitMutationError, .oversizedFile) }
    }
    func testOverviewPreservesConflictRecoveryState() async throws {
        let f = try await OverviewFixture.make(); defer { f.remove() }
        _ = try await f.git(["switch", "-c", "topic"])
        try Data("topic\n".utf8).write(to: f.root.appendingPathComponent("a.txt"))
        _ = try await f.git(["commit", "-am", "topic"])
        _ = try await f.git(["switch", "main"])
        try Data("main\n".utf8).write(to: f.root.appendingPathComponent("a.txt"))
        _ = try await f.git(["commit", "-am", "main"])
        _ = try await f.runner.run(arguments: ["merge", "--no-edit", "topic"], directory: f.root)
        let overview = try await LocalGitService(runner: f.runner, authorizedRoots: [f.root]).overview(directory: f.root)
        XCTAssertEqual(overview.operation, .conflicts(operation: "merge", paths: ["a.txt"]))
        XCTAssertTrue(overview.status.entries.first?.isUnmerged == true)
    }
    func testReviewedTargetAdvanceRejectsMergeWithoutChangingHead() async throws {
        let f = try await OverviewFixture.make(); defer { f.remove() }
        _ = try await f.git(["branch", "topic"])
        let reviewed = try await f.git(["rev-parse", "topic"])
        _ = try await f.git(["switch", "topic"])
        _ = try await f.git(["commit", "--allow-empty", "-m", "unreviewed"])
        _ = try await f.git(["switch", "main"])
        let service = LocalGitService(runner: f.runner, authorizedRoots: [f.root])
        let current = try await service.snapshot(directory: f.root)
        do {
            _ = try await service.begin(operation: .merge, target: "topic", directory: f.root, expected: current, reviewedHead: reviewed, reviewedTarget: reviewed)
            XCTFail("A fresh snapshot must not admit a target that moved after preview")
        } catch { XCTAssertEqual(error as? LocalGitMutationError, .staleSnapshot) }
        let after = try await f.git(["rev-parse", "HEAD"])
        XCTAssertEqual(after, reviewed)
    }
    func testExternalHeadChangeDuringTargetResolutionRejectsAdmission() async throws {
        let f = try await OverviewFixture.make(); defer { f.remove() }
        _ = try await f.git(["branch", "topic"])
        let runner = OverviewHeadChangingRunner(base: f.runner)
        let service = LocalGitService(runner: runner, authorizedRoots: [f.root])
        let before = try await service.snapshot(directory: f.root)
        await runner.arm()
        do {
            _ = try await service.begin(operation: .merge, target: "topic", directory: f.root, expected: before, reviewedHead: before.status.head, reviewedTarget: before.status.head)
            XCTFail("External HEAD changes while resolving must invalidate mutation admission")
        } catch { XCTAssertEqual(error as? LocalGitMutationError, .staleSnapshot) }
        let didMerge = await runner.didMerge
        XCTAssertFalse(didMerge)
    }

}

private actor OverviewRecordingRunner: GitRunner {
    let base: ProcessGitRunner
    var commands: [[String]] = []
    init(base: ProcessGitRunner) { self.base = base }
    func run(arguments: [String], directory: URL) async throws -> GitResult {
        commands.append(arguments)
        return try await base.run(arguments: arguments, directory: directory)
    }
}
private struct OverviewFixture: Sendable {
    let root: URL
    let runner: ProcessGitRunner
    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MergeProOverview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let f = Self(root: root, runner: ProcessGitRunner(environment: ["GIT_CONFIG_NOSYSTEM":"1", "GIT_CONFIG_GLOBAL":"/dev/null", "GIT_EDITOR":"/usr/bin/true", "GIT_TERMINAL_PROMPT":"0"]))
        _ = try await f.git(["init", "-b", "main"])
        _ = try await f.git(["config", "user.name", "Fixture"])
        _ = try await f.git(["config", "user.email", "fixture@example.invalid"])
        try Data("base\n".utf8).write(to: root.appendingPathComponent("a.txt"))
        _ = try await f.git(["add", "--", "a.txt"])
        _ = try await f.git(["commit", "-m", "initial"])
        return f
    }
    func git(_ arguments: [String]) async throws -> String {
        let result = try await runner.run(arguments: arguments, directory: root)
        guard result.exitCode == 0 else { throw LocalGitError.commandFailed(command: arguments.first ?? "git", exitCode: result.exitCode) }
        return String(decoding: result.standardOutput, as: UTF8.self).trimmingCharacters(in: .newlines)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

private actor OverviewHeadChangingRunner: GitRunner {
    let base: ProcessGitRunner
    var armed = false
    var didMerge = false
    init(base: ProcessGitRunner) { self.base = base }
    func arm() { armed = true }
    func run(arguments: [String], directory: URL) async throws -> GitResult {
        // Reads arrive with GitReadOnlyOptions in front of the subcommand.
        let command = arguments.starts(with: GitReadOnlyOptions.global) ? Array(arguments.dropFirst(GitReadOnlyOptions.global.count)) : arguments
        if command.first == "merge" { didMerge = true }
        if armed && command.first == "rev-parse" && command.contains("topic^{commit}") {
            armed = false
            let changed = try await base.run(arguments: ["commit", "--allow-empty", "-m", "external HEAD change"], directory: directory)
            guard changed.exitCode == 0 else { throw LocalGitError.malformedOutput }
        }
        return try await base.run(arguments: arguments, directory: directory)
    }
}
