import XCTest
import Darwin
@testable import MergeProCore

final class GitRunnerTests: XCTestCase, @unchecked Sendable {
    /// A stand-in executable that creates its first argument once running (so tests act on a live process instead of
    /// sleeping), then `sleep`s the given seconds or `wait`s for the given file; it never reads standard input.
    private func signallingSleep() throws -> (script: URL, markers: URL) {
        let markers = try makeTemporaryDirectory(prefix: "MergePro-Git"), script = markers.appendingPathComponent("signal.sh")
        try Data("#!/bin/sh\n: > \"$1\"\nif [ \"$2\" = wait ]; then while [ ! -e \"$3\" ]; do /bin/sleep 0.02; done; else exec /bin/sleep \"$3\"; fi\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return (script, markers)
    }
    func testArgumentsRemainLiteralAndExitErrorsRetainStderr() async throws {
        let folder = try makeTemporaryDirectory(prefix: "MergePro-Git")
        let literal = "--all;$(touch injected)`touch injected2` 雪\nfile"
        let result = try await ProcessGitRunner(executableURL: URL(fileURLWithPath: "/usr/bin/printf")).run(arguments: ["%s", literal], directory: folder)
        XCTAssertEqual(String(decoding: result.standardOutput, as: UTF8.self), literal)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("injected").path))
        let failed = try await ProcessGitRunner().run(arguments: ["rev-parse", "--git-dir"], directory: folder)
        XCTAssertNotEqual(failed.exitCode, 0); XCTAssertFalse(failed.standardError.isEmpty)
    }
    func testMissingExecutableHasActionableError() async throws {
        do { _ = try await ProcessGitRunner(executableURL: URL(fileURLWithPath: "/missing/git")).run(arguments: [], directory: FileManager.default.temporaryDirectory); XCTFail() }
        catch { XCTAssertEqual(error as? GitRunnerError, .executableUnavailable(path: "/missing/git")) }
    }
    func testOutputLimitTerminatesUnboundedProcess() async throws {
        do { _ = try await ProcessGitRunner(executableURL: URL(fileURLWithPath: "/usr/bin/yes"), maximumOutputBytes: 1024).run(arguments: [], directory: FileManager.default.temporaryDirectory); XCTFail() }
        catch { XCTAssertEqual(error as? GitRunnerError, .outputLimitExceeded(stream: .standardOutput, limit: 1024)) }
    }
    func testCancellationTerminatesOwnedProcessOnlyAndReleasesDirectory() async throws {
        let unrelated = Process(); unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep"); unrelated.arguments = ["5"]; try unrelated.run()
        defer { if unrelated.isRunning { unrelated.terminate() } }
        let (script, markers) = try signallingSleep()
        let runner = ProcessGitRunner(executableURL: script)
        let started = markers.appendingPathComponent("started")
        let task = Task { try await runner.run(arguments: [started.path, "sleep", "10"], directory: FileManager.default.temporaryDirectory) }
        try await waitUntil("the owned process runs") { FileManager.default.fileExists(atPath: started.path) }
        task.cancel()
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(unrelated.isRunning)
        let next = try await runner.run(arguments: [markers.appendingPathComponent("next").path, "sleep", "0"], directory: FileManager.default.temporaryDirectory)
        XCTAssertEqual(next.exitCode, 0)
    }
    func testSameDirectoryCommandsCannotOverlap() async throws {
        let folder = try makeTemporaryDirectory(prefix: "MergePro-Git")
        let script = folder.appendingPathComponent("check.sh")
        try Data("#!/bin/sh\nmkdir lock || exit 9\n/bin/sleep 0.1\nrmdir lock\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let runner = ProcessGitRunner(executableURL: script)
        async let first = runner.run(arguments: [], directory: folder)
        async let second = ProcessGitRunner(executableURL: script).run(arguments: [], directory: folder)
        let results = try await [first, second]
        XCTAssertEqual(results.map(\.exitCode), [0, 0])
    }
    func testReaderDiscoversDisposableRepositoryAndLinkedWorktree() async throws {
        let folder = try makeTemporaryDirectory(prefix: "MergePro-Git")
        let runner = ProcessGitRunner(environment: ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"])
        _ = try await runner.run(arguments: ["init", "-b", "main"], directory: folder)
        _ = try await runner.run(arguments: ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-m", "initial"], directory: folder)
        let linked = folder.appendingPathComponent("linked 雪")
        let add = try await runner.run(arguments: ["worktree", "add", "-b", "topic", "--", linked.path], directory: folder)
        XCTAssertEqual(add.exitCode, 0)
        let reader = LocalRepositoryReader(runner: runner)
        let repo = try await reader.discover(directory: linked, authorizedRoots: [folder])
        XCTAssertEqual(repo.worktrees.count, 2)
        let status = try await reader.status(directory: linked, authorizedRoots: [folder])
        XCTAssertEqual(status.branch, "topic"); XCTAssertTrue(status.entries.isEmpty)
    }
    func testStandardInputIsDeliveredLiterallyAndBounded() async throws {
        let runner = ProcessGitRunner(executableURL: URL(fileURLWithPath: "/bin/cat"))
        let bytes = Data("password=fixture;$(touch injected)\n雪\n".utf8)
        let result = try await runner.run(arguments: [], directory: FileManager.default.temporaryDirectory, standardInput: bytes)
        XCTAssertEqual(result.standardOutput, bytes)
        do {
            _ = try await ProcessGitRunner(executableURL: URL(fileURLWithPath: "/bin/cat"), maximumOutputBytes: 2).run(arguments: [], directory: FileManager.default.temporaryDirectory, standardInput: bytes)
            XCTFail()
        } catch { XCTAssertEqual(error as? GitRunnerError, .inputLimitExceeded(limit: 2)) }
    }
    func testLinkedRepositoryRequiresGrantForCommonGitMetadata() async throws {
        let folder = try makeTemporaryDirectory(prefix: "MergePro-Git")
        let runner = ProcessGitRunner(environment: ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"])
        _ = try await runner.run(arguments: ["init", "-b", "main"], directory: folder)
        _ = try await runner.run(arguments: ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-m", "initial"], directory: folder)
        let linked = folder.appendingPathComponent("linked")
        _ = try await runner.run(arguments: ["worktree", "add", "-b", "topic", "--", linked.path], directory: folder)
        do { _ = try await LocalRepositoryReader(runner: runner).discover(directory: linked, authorizedRoots: [linked]); XCTFail("Common metadata is outside linked folder grant") }
        catch { guard case LocalGitError.authorizationRequired(let target) = error else { return XCTFail("Wrong error: \(error)") }; XCTAssertTrue(target.path.contains(".git")) }
    }
    func testQueuedCancellationDoesNotExecuteOrBlockNextCommand() async throws {
        let folder = try makeTemporaryDirectory(prefix: "MergePro-Git")
        let (script, markers) = try signallingSleep()
        let runner = ProcessGitRunner(executableURL: script)
        // The first command holds the folder until released, so the second stays queued behind it.
        let firstStarted = markers.appendingPathComponent("first"), release = markers.appendingPathComponent("release")
        let queuedStarted = markers.appendingPathComponent("queued")
        let first = Task { try await runner.run(arguments: [firstStarted.path, "wait", release.path], directory: folder) }
        try await waitUntil("the first command runs") { FileManager.default.fileExists(atPath: firstStarted.path) }
        let queued = Task { try await runner.run(arguments: [queuedStarted.path, "sleep", "5"], directory: folder) }
        await ProcessGitRunner.gate.untilWaiting(key: ProcessGitRunner.gateKey(folder)); queued.cancel()
        do { _ = try await queued.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        try Data().write(to: release)
        _ = try await first.value
        let next = try await runner.run(arguments: [markers.appendingPathComponent("next").path, "sleep", "0"], directory: folder)
        XCTAssertEqual(next.exitCode, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: queuedStarted.path), "The cancelled queued command never ran")
    }
    func testAuthorizationRejectsSymlinkParentForNewDestination() throws {
        let grant = try makeTemporaryDirectory(prefix: "MergePro-Git")
        let outside = try makeTemporaryDirectory(prefix: "MergePro-Git")
        let link = grant.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let target = link.appendingPathComponent("new-worktree")
        XCTAssertThrowsError(try LocalGitPathAccess.requireAuthorized(target, roots: [grant]))
        let resolved = try XCTUnwrap(realpath(outside.path, nil)); defer { free(resolved) }
        XCTAssertEqual(try LocalGitPathAccess.canonicalURL(target).path, String(cString: resolved) + "/new-worktree")
    }
    func testCancellationUnblocksChildThatNeverReadsStandardInput() async throws {
        let (script, markers) = try signallingSleep()
        let runner = ProcessGitRunner(executableURL: script)
        let started = markers.appendingPathComponent("started")
        let task = Task { try await runner.run(arguments: [started.path, "sleep", "10"], directory: FileManager.default.temporaryDirectory, standardInput: Data(repeating: 120, count: 1_000_000)) }
        try await waitUntil("the child runs without reading its input") { FileManager.default.fileExists(atPath: started.path) }
        task.cancel()
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testSubfolderAndMetadataGrantsDoNotAuthorizeRepositorySiblings() async throws {
        let folder = try makeTemporaryDirectory(prefix: "MergePro-Git")
        let base = ProcessGitRunner(environment: ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"])
        _ = try await base.run(arguments: ["init", "-b", "main"], directory: folder)
        let child = folder.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try Data("private sibling".utf8).write(to: folder.appendingPathComponent("sibling.txt"))
        let traced = LocalScopeTraceRunner(base: base)
        let reader = LocalRepositoryReader(runner: traced)
        let grants = [child, folder.appendingPathComponent(".git")]
        do { _ = try await reader.discover(directory: child, authorizedRoots: grants); XCTFail("Repository root requires its own grant") }
        catch { guard case LocalGitError.authorizationRequired(let target) = error else { return XCTFail("Wrong error") }; XCTAssertEqual(target.lastPathComponent, folder.lastPathComponent) }
        do { _ = try await reader.status(directory: child, authorizedRoots: grants); XCTFail("Status must not read siblings") }
        catch { guard case LocalGitError.authorizationRequired = error else { return XCTFail("Wrong error") } }
        let calls = await traced.arguments
        XCTAssertFalse(calls.contains(where: { $0.contains("status") || $0.contains("worktree") }))
    }
    func testChildEnvironmentDropsInheritedGitVariablesButKeepsExplicitOverrides() {
        let inherited = ["PATH": "/usr/bin:/bin", "HOME": "/Users/fixture", "SSH_AUTH_SOCK": "/tmp/fixture-agent", "GITHUB_ACTIONS": "true",
                         "GIT_DIR": "/tmp/elsewhere", "GIT_CONFIG_PARAMETERS": "'core.fsmonitor'='touch pwned'", "GIT_EXTERNAL_DIFF": "/tmp/run", "GIT_SSH_COMMAND": "/tmp/run", "GIT_CONFIG_NOSYSTEM": "0"]
        let overrides = ["GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0", "LANG": "C"]
        XCTAssertEqual(ProcessGitRunner.childEnvironment(inherited: inherited, overrides: overrides), [
            "PATH": "/usr/bin:/bin", "HOME": "/Users/fixture", "SSH_AUTH_SOCK": "/tmp/fixture-agent", "GITHUB_ACTIONS": "true",
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0", "LANG": "C"])
    }
    func testInheritedGitVariablesDoNotReachChildProcess() async throws {
        setenv("GIT_MERGEPRO_INHERITED_FIXTURE", "1", 1)
        let runner = ProcessGitRunner(executableURL: URL(fileURLWithPath: "/usr/bin/env"), environment: ["GIT_TERMINAL_PROMPT": "0"])
        unsetenv("GIT_MERGEPRO_INHERITED_FIXTURE")
        let output = String(decoding: try await runner.run(arguments: [], directory: FileManager.default.temporaryDirectory).standardOutput, as: UTF8.self)
        XCTAssertFalse(output.contains("GIT_MERGEPRO_INHERITED_FIXTURE")); XCTAssertTrue(output.contains("GIT_TERMINAL_PROMPT=0\n"))
    }
    func testReadsNeverRunRepositoryConfiguredFSMonitorOrSignatureProgram() async throws {
        let folder = try makeTemporaryDirectory(prefix: "MergePro-Git")
        let repo = folder.appendingPathComponent("repo"), marker = folder.appendingPathComponent("ran")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let runner = ProcessGitRunner(environment: ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"])
        func git(_ arguments: [String], input: Data? = nil) async throws -> String {
            let result: GitResult
            if let input { result = try await runner.run(arguments: arguments, directory: repo, standardInput: input) } else { result = try await runner.run(arguments: arguments, directory: repo) }
            XCTAssertEqual(result.exitCode, 0, arguments.joined(separator: " ")); return String(decoding: result.standardOutput, as: UTF8.self).trimmingCharacters(in: .newlines)
        }
        _ = try await git(["init", "-b", "main"]); _ = try await git(["config", "user.name", "Test"]); _ = try await git(["config", "user.email", "test@example.invalid"])
        try Data("one\n".utf8).write(to: repo.appendingPathComponent("tracked.txt"))
        _ = try await git(["add", "--", "tracked.txt"]); _ = try await git(["commit", "-m", "initial"])
        // A repository-supplied signed stash commit makes `stash list` verify it with the configured program.
        let tree = try await git(["rev-parse", "HEAD^{tree}"]), head = try await git(["rev-parse", "HEAD"])
        let signed = "tree \(tree)\nparent \(head)\nauthor T <t@example.invalid> 1700000000 +0000\ncommitter T <t@example.invalid> 1700000000 +0000\ngpgsig -----BEGIN PGP SIGNATURE-----\n \n AAAA\n -----END PGP SIGNATURE-----\n\nsigned\n"
        let stash = try await git(["hash-object", "-t", "commit", "-w", "--stdin"], input: Data(signed.utf8))
        _ = try await git(["update-ref", "--create-reflog", "-m", "On main: fixture", "refs/stash", stash])
        let program = folder.appendingPathComponent("program")
        try Data("#!/bin/sh\n/usr/bin/touch '\(marker.path)'\nexit 1\n".utf8).write(to: program)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: program.path)
        for (key, value) in [("core.fsmonitor", program.path), ("log.showSignature", "true"), ("gpg.program", program.path)] { _ = try await git(["config", key, value]) }
        try Data("two\n".utf8).write(to: repo.appendingPathComponent("tracked.txt"))
        let status = try await LocalRepositoryReader(runner: runner).status(directory: repo, authorizedRoots: [folder])
        let service = LocalGitService(runner: runner, authorizedRoots: [folder])
        let snapshot = try await service.snapshot(directory: repo)
        _ = try await service.diff(path: "tracked.txt", staged: false, directory: repo); _ = try await service.remotes(directory: repo)
        XCTAssertEqual(status.entries.map(\.path), ["tracked.txt"]); XCTAssertEqual(snapshot.stashes.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "A pure read executed a repository-configured program")
        _ = try await git(["status", "--porcelain=v2"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "Fixture must exercise the configured program without read-only options")
    }
    func testReadOnlyOptionsPrefixReadsButNotMutations() async throws {
        let folder = try makeTemporaryDirectory(prefix: "MergePro-Git")
        let base = ProcessGitRunner(environment: ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"])
        _ = try await base.run(arguments: ["init", "-b", "main"], directory: folder)
        try Data("new\n".utf8).write(to: folder.appendingPathComponent("file.txt"))
        let traced = LocalScopeTraceRunner(base: base)
        let service = LocalGitService(runner: traced, authorizedRoots: [folder])
        _ = try await service.stage(paths: ["file.txt"], directory: folder)
        _ = try await service.diff(path: "file.txt", staged: true, directory: folder)
        let calls = await traced.arguments
        let options = GitReadOnlyOptions.global
        XCTAssertEqual(options, ["-c", "core.fsmonitor=false", "-c", "log.showSignature=false", "--no-optional-locks"])
        let mutations = calls.filter { $0.contains("add") }
        XCTAssertEqual(mutations, [["--literal-pathspecs", "add", "--", "file.txt"]])
        let reads = calls.filter { !$0.contains("add") }
        XCTAssertFalse(reads.isEmpty)
        for read in reads { XCTAssertEqual(Array(read.prefix(options.count)), options, read.joined(separator: " ")) }
        for verb in ["rev-parse", "worktree", "status", "ls-files", "diff", "for-each-ref", "stash", "config"] { XCTAssertTrue(reads.contains { $0.dropFirst(options.count).contains(verb) }, verb) }
    }
    func testEmptyAuthorizationRootsDenyBeforeExecutingGit() async throws {
        let folder = try makeTemporaryDirectory(prefix: "MergePro-Git")
        let traced = LocalScopeTraceRunner(base: ProcessGitRunner())
        do { _ = try await LocalRepositoryReader(runner: traced).discover(directory: folder, authorizedRoots: []); XCTFail("No bookmark grants means no access") }
        catch { guard case LocalGitError.authorizationRequired = error else { return XCTFail("Expected authorization failure") } }
        let calls = await traced.arguments
        XCTAssertTrue(calls.isEmpty)
    }
    func testBoundedParentCatalogFindsReposAndLinkedWorktreesWithoutFollowingEscape() async throws {
        let root = try makeTemporaryDirectory(prefix: "MergePro-Git")
        let outside = try makeTemporaryDirectory(prefix: "MergePro-Git")
        let runner = ProcessGitRunner(environment: ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"])
        let first = root.appendingPathComponent("alpha"), second = root.appendingPathComponent("beta")
        for repository in [first, second, outside] {
            try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
            _ = try await runner.run(arguments: ["init", "-b", "main"], directory: repository)
        }
        _ = try await runner.run(arguments: ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-m", "initial"], directory: first)
        _ = try await runner.run(arguments: ["worktree", "add", "-b", "topic", "--", root.appendingPathComponent("linked").path], directory: first)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
        let reader = LocalRepositoryReader(runner: runner)
        let catalog = try await reader.discoverWithin(root: root, authorizedRoots: [root])
        XCTAssertEqual(catalog.repositories.count, 2); XCTAssertTrue(catalog.issues.isEmpty); XCTAssertFalse(catalog.isTruncated)
        XCTAssertEqual(catalog.repositories.first(where: { $0.directory.lastPathComponent == "alpha" })?.worktrees.count, 2)
        XCTAssertFalse(catalog.repositories.contains(where: { $0.directory == outside }))
        let limited = try await reader.discoverWithin(root: root, authorizedRoots: [root], maximumDirectories: 1)
        XCTAssertTrue(limited.isTruncated); XCTAssertEqual(limited.inspectedDirectories, 1)
    }
    func testCatalogOpensOnlyAnExplicitChoiceOrTheAuthorizedRepositoryItself() async throws {
        let root = try makeTemporaryDirectory(prefix: "MergePro-Git")
        let lone = try makeTemporaryDirectory(prefix: "MergePro-Git")
        let runner = ProcessGitRunner(environment: ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"])
        let alpha = root.appendingPathComponent("alpha"), beta = root.appendingPathComponent("beta"), nested = lone.appendingPathComponent("nested")
        for repository in [alpha, beta, nested] {
            try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
            _ = try await runner.run(arguments: ["init", "-b", "main"], directory: repository)
        }
        let reader = LocalRepositoryReader(runner: runner)
        let parent = try await reader.discoverWithin(root: root, authorizedRoots: [root])
        XCTAssertEqual(parent.repositories.count, 2)
        XCTAssertNil(parent.repositoryToOpen(selected: nil, authorizedFolder: root), "Discovered repositories wait for an explicit choice")
        XCTAssertNil(parent.repositoryToOpen(selected: root.appendingPathComponent("missing"), authorizedFolder: root))
        let chosen = try XCTUnwrap(parent.repositories.first { $0.directory.lastPathComponent == "beta" })
        XCTAssertEqual(parent.repositoryToOpen(selected: chosen.directory, authorizedFolder: root), chosen)
        let single = try await reader.discoverWithin(root: lone, authorizedRoots: [lone])
        XCTAssertEqual(single.repositories.count, 1)
        XCTAssertNil(single.repositoryToOpen(selected: nil, authorizedFolder: lone), "A lone nested repository is still only discovered")
        let itself = try await reader.discoverWithin(root: alpha, authorizedRoots: [alpha])
        XCTAssertEqual(itself.repositoryToOpen(selected: nil, authorizedFolder: alpha)?.directory.lastPathComponent, "alpha")
    }
}

private actor LocalScopeTraceRunner: GitRunner {
    let base: ProcessGitRunner
    var arguments: [[String]] = []
    init(base: ProcessGitRunner) { self.base = base }
    func run(arguments: [String], directory: URL) async throws -> GitResult {
        self.arguments.append(arguments)
        return try await base.run(arguments: arguments, directory: directory)
    }
}
