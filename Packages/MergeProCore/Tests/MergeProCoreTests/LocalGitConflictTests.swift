import XCTest
import Foundation
import Darwin
@testable import MergeProCore

final class LocalGitConflictTests: XCTestCase {
    func testMergeStagesAndLiteralCurrentResolutionPreserveOtherIndexAndMode() async throws {
        let f = try await fixture(path: ":(glob)*\nfile.txt"); defer { f.remove() }
        let service = f.service
        let document = try await service.conflictDocument(path: f.path, directory: f.repo)
        XCTAssertEqual(document.base?.text, "base\n")
        XCTAssertEqual(document.current?.text, "current\n")
        XCTAssertEqual(document.incoming?.text, "incoming\n")
        XCTAssertTrue(document.workingText?.contains("<<<<<<<") == true)
        let snapshot = try await service.resolveConflict(document: document, resolution: .current, directory: f.repo)
        XCTAssertFalse(snapshot.status.entries.contains { $0.path == f.path && $0.isUnmerged })
        XCTAssertEqual(try String(contentsOf: f.file, encoding: .utf8), "current\n")
        let names = try await f.git(["diff", "--cached", "--name-only", "-z"]); XCTAssertEqual(names, "")
        var metadata = stat(); XCTAssertEqual(lstat(f.file.path, &metadata), 0); XCTAssertNotEqual(metadata.st_mode & 0o111, 0)
    }
    func testPlainStageRefusesFileThatStillHasMarkers() async throws {
        let f = try await fixture(); defer { f.remove() }
        do { _ = try await f.service.stage(paths: [f.path], directory: f.repo); XCTFail() }
        catch { XCTAssertEqual(error as? LocalGitMutationError, .unresolvedConflict(f.path)) }
        let snapshot = try await f.service.snapshot(directory: f.repo)
        XCTAssertTrue(snapshot.status.entries.contains { $0.path == f.path && $0.isUnmerged })
    }
    func testManualResultStagesOnlySelectedFileAndRejectsMarkers() async throws {
        let f = try await fixture(); defer { f.remove() }
        try Data("keep unstaged\n".utf8).write(to: f.repo.appendingPathComponent("other.txt"))
        let d = try await f.service.conflictDocument(path: f.path, directory: f.repo)
        do { _ = try await f.service.resolveConflict(document: d, resolution: .text(d.workingText!), directory: f.repo); XCTFail() }
        catch { XCTAssertEqual(error as? LocalGitConflictError, .remainingMarkers) }
        let s = try await f.service.resolveConflict(document: d, resolution: .text("chosen\n"), directory: f.repo)
        XCTAssertTrue(s.status.entries.contains { $0.path == "other.txt" && $0.worktreeStatus == "M" })
        let staged = try await f.git(["show", ":" + f.path]); XCTAssertEqual(staged, "chosen\n")
    }
    func testMissingIncomingSideMeansDeletion() async throws {
        let f = try await fixture(deleteIncoming: true); defer { f.remove() }
        let d = try await f.service.conflictDocument(path: f.path, directory: f.repo)
        XCTAssertNil(d.incoming)
        _ = try await f.service.resolveConflict(document: d, resolution: .incoming, directory: f.repo)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.file.path))
        let unmerged = try await f.git(["ls-files", "--unmerged", "-z"]); XCTAssertEqual(unmerged, "")
    }
    func testRebaseStagesRepresentOntoAndReplayedCommit() async throws {
        let f = try await fixture(rebase: true); defer { f.remove() }
        let d = try await f.service.conflictDocument(path: f.path, directory: f.repo)
        XCTAssertEqual(d.current?.text, "incoming\n")
        XCTAssertEqual(d.incoming?.text, "current\n")
        _ = try await f.service.resolveConflict(document: d, resolution: .incoming, directory: f.repo)
        XCTAssertEqual(try String(contentsOf: f.file, encoding: .utf8), "current\n")
    }
    func testExternalWorktreeAndIndexChangesRejectBeforeWrite() async throws {
        let f = try await fixture(); defer { f.remove() }
        var d = try await f.service.conflictDocument(path: f.path, directory: f.repo)
        try Data("external result\n".utf8).write(to: f.file)
        do { _ = try await f.service.resolveConflict(document: d, resolution: .current, directory: f.repo); XCTFail() }
        catch { XCTAssertEqual(error as? LocalGitMutationError, .staleSnapshot) }
        XCTAssertEqual(try String(contentsOf: f.file, encoding: .utf8), "external result\n")
        d = try await f.service.conflictDocument(path: f.path, directory: f.repo)
        try Data("other staged\n".utf8).write(to: f.repo.appendingPathComponent("other.txt")); _ = try await f.git(["add", "--", "other.txt"])
        do { _ = try await f.service.resolveConflict(document: d, resolution: .text("overwrite\n"), directory: f.repo); XCTFail() }
        catch { XCTAssertEqual(error as? LocalGitMutationError, .staleSnapshot) }
        XCTAssertEqual(try String(contentsOf: f.file, encoding: .utf8), "external result\n")
    }
    func testSymlinkAndTraversalAreRejectedAndOutsideFilePreserved() async throws {
        let f = try await fixture(); defer { f.remove() }
        let d = try await f.service.conflictDocument(path: f.path, directory: f.repo)
        let outside = f.root.appendingPathComponent("outside.txt"); try Data("safe\n".utf8).write(to: outside)
        try FileManager.default.removeItem(at: f.file); try FileManager.default.createSymbolicLink(at: f.file, withDestinationURL: outside)
        do { _ = try await f.service.resolveConflict(document: d, resolution: .current, directory: f.repo); XCTFail() } catch {}
        do { _ = try await f.service.conflictDocument(path: f.path, directory: f.repo); XCTFail() } catch {}
        for path in ["../outside.txt", ".git/config", "/tmp/x", "a/../../x"] {
            do { _ = try await f.service.conflictDocument(path: path, directory: f.repo); XCTFail(path) } catch {}
        }
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "safe\n")
    }
    func testBinaryOversizedAndCancelledResultsCannotWrite() async throws {
        let f = try await fixture(); defer { f.remove() }
        var d = try await f.service.conflictDocument(path: f.path, directory: f.repo)
        do { _ = try await f.service.resolveConflict(document: d, resolution: .text("x\0y"), directory: f.repo); XCTFail() }
        catch { XCTAssertEqual(error as? LocalGitConflictError, .binaryOrInvalidText) }
        do { _ = try await f.service.resolveConflict(document: d, resolution: .text(String(repeating: "a", count: 2 * 1024 * 1024 + 1)), directory: f.repo); XCTFail() }
        catch { XCTAssertEqual(error as? LocalGitMutationError, .oversizedFile) }
        let canceledDocument = d
        let task = Task { try await f.service.resolveConflict(document: canceledDocument, resolution: .current, directory: f.repo) }; task.cancel()
        do { _ = try await task.value; XCTFail() } catch {}
        XCTAssertTrue(try String(contentsOf: f.file, encoding: .utf8).contains("<<<<<<<"))
        try Data([0xff, 0x0a]).write(to: f.file)
        do { d = try await f.service.conflictDocument(path: f.path, directory: f.repo); XCTFail() }
        catch { XCTAssertEqual(error as? LocalGitConflictError, .binaryOrInvalidText) }
    }
    func testStagingFailureReportsSavedResultWithoutSilentlyClaimingResolution() async throws {
        let f = try await fixture(); defer { f.remove() }
        let d = try await f.service.conflictDocument(path: f.path, directory: f.repo)
        let service = LocalGitService(runner: RejectConflictAddRunner(base: f.runner), authorizedRoots: [f.root])
        do { _ = try await service.resolveConflict(document: d, resolution: .text("saved result\n"), directory: f.repo); XCTFail() }
        catch { guard case .savedButNotStaged = error as? LocalGitConflictError else { return XCTFail("\(error)") } }
        XCTAssertEqual(try String(contentsOf: f.file, encoding: .utf8), "saved result\n")
        let unmerged = try await f.git(["ls-files", "--unmerged", "-z"]); XCTAssertFalse(unmerged.isEmpty)
    }
    func testModeOnlyChangeRejectsDocumentEvenWhenGitDiffIsIdentical() async throws {
        let f = try await fixture(); defer { f.remove() }
        _ = try await f.git(["config", "core.fileMode", "false"])
        let d = try await f.service.conflictDocument(path: f.path, directory: f.repo)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: f.file.path)
        do { _ = try await f.service.resolveConflict(document: d, resolution: .current, directory: f.repo); XCTFail() }
        catch { XCTAssertEqual(error as? LocalGitMutationError, .staleSnapshot) }
    }
    func testRepositoryRootWithSystemAncestorAliasUsesCanonicalAnchor() async throws {
        let f = try await fixture(); defer { f.remove() }
        let snapshot = try await f.service.snapshot(directory: f.repo)
        let canonical = try LocalGitPathAccess.canonicalURL(snapshot.repository.directory)
        XCTAssertEqual(canonical.path, try LocalGitPathAccess.canonicalURL(f.repo).path)
        let document = try await f.service.conflictDocument(path: f.path, directory: f.repo)
        XCTAssertEqual(document.current?.text, "current\n")
    }
    func testNestedParentSymlinkIsRejectedEvenWhenDestinationIsAuthorized() async throws {
        let f = try await fixture(path: "nested/conflict.txt"); defer { f.remove() }
        let nested = f.repo.appendingPathComponent("nested")
        let destination = f.repo.appendingPathComponent("moved-nested")
        try FileManager.default.moveItem(at: nested, to: destination)
        try FileManager.default.createSymbolicLink(at: nested, withDestinationURL: destination)
        let before = try Data(contentsOf: destination.appendingPathComponent("conflict.txt"))
        do { _ = try await f.service.conflictDocument(path: f.path, directory: f.repo); XCTFail("Nested symlink must not become a read/write anchor") }
        catch { XCTAssertEqual(error as? LocalGitMutationError, .unsupportedFileType) }
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("conflict.txt")), before)
    }
    func testSymlinkedRootReportedByGitIsRejectedBeforeAnchoring() async throws {
        let f = try await fixture(); defer { f.remove() }
        let alias = f.root.appendingPathComponent("repo-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.repo)
        let runner = SymlinkConflictRootRunner(base: f.runner, alias: alias)
        let service = LocalGitService(runner: runner, authorizedRoots: [f.root])
        do { _ = try await service.conflictDocument(path: f.path, directory: f.repo); XCTFail("A reported symlink root must not become an anchor") }
        catch { XCTAssertEqual(error as? LocalGitMutationError, .unsupportedFileType) }
        XCTAssertTrue(try String(contentsOf: f.file, encoding: .utf8).contains("<<<<<<<"))
    }
    func testConflictBlocksKeepContextAndCRLFAndSupportDiff3Both() {
        let text = "before\r\n<<<<<<< HEAD\r\na\r\n||||||| base\r\nz\r\n=======\r\nb\r\n>>>>>>> branch\r\nafter\r\n"
        let parsed = LocalTextConflictDocument(text: text)
        XCTAssertEqual(parsed.blocks.count, 1)
        XCTAssertEqual(parsed.resolving([0: .both]), "before\r\na\r\nb\r\nafter\r\n")
        XCTAssertEqual(parsed.resolving([:]), text)
        XCTAssertFalse(LocalTextConflictDocument.containsMarkers("ordinary text mentions <<<<<<< in a sentence\n"))
        XCTAssertTrue(LocalTextConflictDocument.containsMarkers("<<<<<<< deliberate marker line\n"))
    }
    private func fixture(path: String = "conflict.txt", deleteIncoming: Bool = false, rebase: Bool = false) async throws -> ConflictFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MergePro-conflict-\(UUID())")
        let repo = root.appendingPathComponent("repo"); try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let f = ConflictFixture(root: root, repo: repo, path: path)
        try FileManager.default.createDirectory(at: f.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try await f.git(["init", "-b", "main"]); _ = try await f.git(["config", "user.name", "Fixture"]); _ = try await f.git(["config", "user.email", "fixture@example.invalid"])
        try Data("base\n".utf8).write(to: f.file); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.file.path)
        try Data("other\n".utf8).write(to: repo.appendingPathComponent("other.txt"))
        _ = try await f.git(["add", "."]); _ = try await f.git(["commit", "-m", "base"]); _ = try await f.git(["branch", "incoming"])
        try Data("current\n".utf8).write(to: f.file); _ = try await f.git(["add", "."]); _ = try await f.git(["commit", "-m", "current"])
        _ = try await f.git(["switch", "incoming"])
        if deleteIncoming { try FileManager.default.removeItem(at: f.file) } else { try Data("incoming\n".utf8).write(to: f.file) }
        _ = try await f.git(["add", "."]); _ = try await f.git(["commit", "-m", "incoming"]); _ = try await f.git(["switch", "main"])
        let result = try await f.runner.run(arguments: rebase ? ["rebase", "incoming"] : ["merge", "incoming"], directory: repo)
        XCTAssertNotEqual(result.exitCode, 0)
        return f
    }
}
private struct ConflictFixture: Sendable {
    let root: URL; let repo: URL; let path: String
    var file: URL { repo.appendingPathComponent(path) }
    var runner: ProcessGitRunner { ProcessGitRunner(environment: ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_EDITOR": "/usr/bin/true", "GIT_SEQUENCE_EDITOR": "/usr/bin/true", "GIT_TERMINAL_PROMPT": "0"]) }
    var service: LocalGitService { LocalGitService(runner: runner, authorizedRoots: [root]) }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func git(_ arguments: [String]) async throws -> String {
        let r = try await runner.run(arguments: arguments, directory: repo)
        guard r.exitCode == 0 else { throw NSError(domain: "Fixture", code: Int(r.exitCode), userInfo: [NSLocalizedDescriptionKey: String(decoding: r.standardError, as: UTF8.self)]) }
        return String(decoding: r.standardOutput, as: UTF8.self)
    }
}

private struct RejectConflictAddRunner: GitRunner {
    let base: ProcessGitRunner
    func run(arguments: [String], directory: URL) async throws -> GitResult {
        if arguments.contains("add") { throw NSError(domain: "Fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "deliberate staging failure"]) }
        return try await base.run(arguments: arguments, directory: directory)
    }
}

private struct SymlinkConflictRootRunner: GitRunner {
    let base: ProcessGitRunner
    let alias: URL
    func run(arguments: [String], directory: URL) async throws -> GitResult {
        let result = try await base.run(arguments: arguments, directory: directory)
        let command = arguments.starts(with: GitReadOnlyOptions.global) ? Array(arguments.dropFirst(GitReadOnlyOptions.global.count)) : arguments
        if command == ["rev-parse", "--show-toplevel"], result.exitCode == 0 {
            return .init(exitCode: 0, standardOutput: Data((alias.path + "\n").utf8))
        }
        return result
    }
}
