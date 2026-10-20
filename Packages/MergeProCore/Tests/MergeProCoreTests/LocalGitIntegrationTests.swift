import XCTest
import Darwin
@testable import MergeProCore

final class LocalGitIntegrationTests: XCTestCase, @unchecked Sendable {
    func testLiteralPathStageUnstageCommitAmendAndConfiguredHook() async throws {
        let f = try await fixture()
        let path = "--雪;$(touch injected).txt"
        try f.write(path, "literal\n")
        let service = f.service()
        let staged = try await service.stage(paths: [path], directory: f.repo)
        XCTAssertTrue(try XCTUnwrap(staged.status.entries.first(where: { $0.path == path })).isStaged)
        let unstaged = try await service.unstage(paths: [path], directory: f.repo)
        XCTAssertTrue(try XCTUnwrap(unstaged.status.entries.first(where: { $0.path == path })).isUntracked)
        let hook = f.repo.appendingPathComponent(".git/hooks/pre-commit")
        try Data("#!/bin/sh\nprintf invoked > hook-invoked\n".utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
        _ = try await service.stage(paths: [path], directory: f.repo)
        let committed = try await service.commit(message: "literal commit", amend: false, directory: f.repo)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.repo.appendingPathComponent("hook-invoked").path))
        let oldHead = committed.status.head
        _ = try await service.commit(message: "amended message", amend: true, directory: f.repo)
        let amendedHead = try await f.git(["rev-parse", "HEAD"]); let subject = try await f.git(["log", "-1", "--format=%s"])
        XCTAssertNotEqual(amendedHead, oldHead); XCTAssertEqual(subject, "amended message")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.repo.appendingPathComponent("injected").path))
    }
    func testHunkStageIgnoresConfiguredDiffPrefixes() async throws {
        let f = try await fixture()
        let initial = (1...30).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try FileManager.default.createDirectory(at: f.repo.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try f.write("sub/hunks.txt", initial); try f.write("hunks.txt", initial)
        _ = try await f.git(["add", "--", "sub/hunks.txt", "hunks.txt"]); _ = try await f.git(["commit", "-m", "hunks"])
        _ = try await f.git(["config", "diff.noprefix", "true"])
        try f.write("sub/hunks.txt", initial.replacingOccurrences(of: "line 2\n", with: "changed two\n"))
        let service = f.service(); let diff = try await service.diff(path: "sub/hunks.txt", staged: false, directory: f.repo)
        _ = try await service.stageHunk(patch: diff.hunks[0].patch, expected: diff.snapshot, directory: f.repo)
        let names = try await f.git(["diff", "--cached", "--name-only"])
        XCTAssertEqual(names.trimmingCharacters(in: .whitespacesAndNewlines), "sub/hunks.txt")
    }
    func testHunkStageStagesOnlyChosenHunkAndRejectsStaleWorktree() async throws {
        let f = try await fixture()
        let initial = (1...30).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try f.write("hunks.txt", initial); _ = try await f.git(["add", "--", "hunks.txt"]); _ = try await f.git(["commit", "-m", "hunks"])
        let modified = initial.replacingOccurrences(of: "line 2\n", with: "changed two\n").replacingOccurrences(of: "line 28\n", with: "changed twenty eight\n")
        try f.write("hunks.txt", modified)
        let service = f.service(); let diff = try await service.diff(path: "hunks.txt", staged: false, directory: f.repo)
        XCTAssertEqual(diff.hunks.count, 2)
        _ = try await service.stageHunk(patch: diff.hunks[0].patch, expected: diff.snapshot, directory: f.repo)
        let staged = try await f.git(["diff", "--cached", "--", "hunks.txt"])
        XCTAssertTrue(staged.contains("+changed two")); XCTAssertFalse(staged.contains("+changed twenty eight"))
        let stale = try await service.diff(path: "hunks.txt", staged: false, directory: f.repo)
        try f.write("hunks.txt", modified + "another edit\n")
        do { _ = try await service.stageHunk(patch: stale.hunks[0].patch, expected: stale.snapshot, directory: f.repo); XCTFail() }
        catch { XCTAssertEqual(error as? LocalGitMutationError, .staleSnapshot) }
    }
    func testBranchesValidateRefsProtectMainAndRejectDirtySwitch() async throws {
        let f = try await fixture(); let service = f.service()
        _ = try await service.createBranch(name: "topic", startPoint: nil, directory: f.repo)
        try f.write("tracked.txt", "dirty\n")
        do { _ = try await service.switchBranch(name: "topic", directory: f.repo); XCTFail() }
        catch { XCTAssertEqual(error as? LocalGitMutationError, .dirtyWorktree) }
        _ = try await f.git(["restore", "--", "tracked.txt"])
        _ = try await service.switchBranch(name: "topic", directory: f.repo)
        _ = try await service.renameBranch(oldName: "topic", newName: "renamed", directory: f.repo)
        _ = try await service.switchBranch(name: "main", directory: f.repo)
        _ = try await service.deleteBranch(name: "renamed", directory: f.repo)
        do { _ = try await service.deleteBranch(name: "main", directory: f.repo); XCTFail() }
        catch { XCTAssertEqual(error as? LocalGitMutationError, .protectedBranch("main")) }
        do { _ = try await service.createBranch(name: "--force", startPoint: nil, directory: f.repo); XCTFail() }
        catch { XCTAssertEqual(error as? LocalGitMutationError, .invalidReference) }
    }
    func testStashAndLinkedWorktreeNeverRemoveDirtyChanges() async throws {
        let f = try await fixture(); let service = f.service()
        try f.write("tracked.txt", "stash me\n")
        let stashed = try await service.stash(message: "save changes", includeUntracked: true, directory: f.repo)
        XCTAssertTrue(stashed.status.isClean); XCTAssertEqual(stashed.stashes.count, 1)
        let restored = try await service.applyStash(reference: "stash@{0}", dropAfterApply: true, directory: f.repo)
        XCTAssertFalse(restored.status.isClean); XCTAssertTrue(restored.stashes.isEmpty)
        _ = try await service.stash(message: "save again", includeUntracked: true, directory: f.repo)
        let linked = f.root.appendingPathComponent("linked 雪")
        _ = try await service.addWorktree(path: linked, branch: "worktree-topic", createBranch: true, directory: f.repo)
        try f.write("dirty.txt", "keep me", directory: linked)
        do { _ = try await service.removeWorktree(target: linked, directory: f.repo); XCTFail() }
        catch { XCTAssertEqual(error as? LocalGitMutationError, .dirtyWorktree) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: linked.appendingPathComponent("dirty.txt").path))
        try FileManager.default.removeItem(at: linked.appendingPathComponent("dirty.txt"))
        let removed = try await service.removeWorktree(target: linked, directory: f.repo)
        XCTAssertEqual(removed.repository.worktrees.count, 1)
    }
    func testFetchPullAndPushUseBareRemoteWithoutForcing() async throws {
        let f = try await fixture()
        let remote = f.root.appendingPathComponent("remote.git")
        _ = try await f.git(["init", "--bare", "--", remote.path])
        _ = try await f.git(["remote", "add", "origin", remote.path])
        let service = f.service()
        do { _ = try await service.push(remote: "origin", branch: "main", directory: f.repo); XCTFail("A local push URL is not an encrypted network transport") }
        catch { XCTAssertEqual(error as? LocalGitMutationError, .unsupportedPushRemote) }
        // Pushes use an scp-style URL whose configured SSH command serves the local bare fixture.
        let transport = f.root.appendingPathComponent("fixture-ssh")
        try Data(("#!/bin/sh\nexec /usr/bin/git receive-pack '" + remote.path + "'\n").utf8).write(to: transport)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: transport.path)
        _ = try await f.git(["config", "core.sshCommand", transport.path]); _ = try await f.git(["config", "ssh.variant", "simple"])
        _ = try await f.git(["remote", "set-url", "--push", "origin", "git@example.invalid:remote.git"])
        _ = try await service.push(remote: "origin", branch: "main", directory: f.repo)
        let other = f.root.appendingPathComponent("other")
        _ = try await f.git(["clone", "-b", "main", "--", remote.path, other.path])
        _ = try await f.git(["config", "user.name", "Test"], directory: other); _ = try await f.git(["config", "user.email", "test@example.invalid"], directory: other)
        try f.write("remote.txt", "remote\n", directory: other)
        _ = try await f.git(["add", "--", "remote.txt"], directory: other); _ = try await f.git(["commit", "-m", "remote"], directory: other); _ = try await f.git(["push", "origin", "main"], directory: other)
        _ = try await service.fetch(remote: "origin", directory: f.repo)
        let pulled = try await service.pull(remote: "origin", branch: "main", directory: f.repo)
        XCTAssertTrue(pulled.status.isClean); XCTAssertTrue(FileManager.default.fileExists(atPath: f.repo.appendingPathComponent("remote.txt").path))
        _ = try await f.git(["commit", "--allow-empty", "-m", "divergent"], directory: other); _ = try await f.git(["push", "origin", "main"], directory: other)
        _ = try await f.git(["commit", "--allow-empty", "-m", "local divergent"])
        do { _ = try await service.push(remote: "origin", branch: "main", directory: f.repo); XCTFail("Push must never force") } catch { XCTAssertTrue(error is LocalGitError) }
    }
    func testMergeConflictRecoveredByFreshServiceAndAbort() async throws {
        let f = try await fixture()
        _ = try await f.git(["switch", "-c", "topic"]); try f.write("tracked.txt", "topic\n"); _ = try await f.git(["commit", "-am", "topic"])
        _ = try await f.git(["switch", "main"]); try f.write("tracked.txt", "main\n"); _ = try await f.git(["commit", "-am", "main"])
        let conflicted = try await f.service().begin(operation: .merge, target: "topic", directory: f.repo)
        XCTAssertEqual(conflicted.operation, .conflicts(operation: "merge", paths: ["tracked.txt"]))
        let recovered = try await f.service().snapshot(directory: f.repo)
        XCTAssertEqual(recovered.operation, conflicted.operation)
        let aborted = try await f.service().abortOperation(directory: f.repo)
        XCTAssertEqual(aborted.operation, .idle); XCTAssertTrue(aborted.status.isClean)
        XCTAssertEqual(try String(contentsOf: f.repo.appendingPathComponent("tracked.txt"), encoding: .utf8), "main\n")
    }
    func testRebaseAndCherryPickConflictContinueAndAbort() async throws {
        for operation in [LocalGitOperation.rebase, .cherryPick] {
            let f = try await fixture()
            _ = try await f.git(["switch", "-c", "topic"]); try f.write("tracked.txt", "topic\n"); _ = try await f.git(["commit", "-am", "topic"])
            let topicSHA = try await f.git(["rev-parse", "HEAD"])
            _ = try await f.git(["switch", "main"]); try f.write("tracked.txt", "main\n"); _ = try await f.git(["commit", "-am", "main"])
            let result = try await f.service().begin(operation: operation, target: operation == .rebase ? "topic" : topicSHA, directory: f.repo)
            XCTAssertEqual(result.operation, .conflicts(operation: operation.rawValue, paths: ["tracked.txt"]))
            try f.write("tracked.txt", "resolved\n")
            _ = try await f.service().stage(paths: ["tracked.txt"], directory: f.repo)
            let continued = try await f.service().continueOperation(directory: f.repo)
            XCTAssertEqual(continued.operation, .idle); XCTAssertTrue(continued.status.isClean)
        }
    }
    func testCheckoutPRRejectsUnmappedRepositoryBeforeNetwork() async throws {
        let f = try await fixture()
        let mapping = LocalPRCheckoutMapping(repository: .init(account: .init(host: "github.com", accountID: "fixture"), repositoryID: "1"), repositoryName: "owner/repo", number: 42, expectedHeadSHA: String(repeating: "a", count: 40), remote: "origin", destination: f.root.appendingPathComponent("pr42"), branch: "pr42")
        _ = try await f.git(["remote", "add", "origin", "https://github.com/other/repo.git"])
        do { _ = try await f.service().checkoutPullRequest(mapping: mapping, directory: f.repo); XCTFail() }
        catch { XCTAssertEqual(error as? LocalGitMutationError, .repositoryMismatch) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: mapping.destination.path))
    }
    func testUnchangedRepositoryProducesStableSnapshotTokens() async throws {
        let f = try await fixture()
        try f.write("tracked.txt", "modified\n")
        let service = f.service()
        let first = try await service.snapshot(directory: f.repo)
        let second = try await service.snapshot(directory: f.repo)
        XCTAssertEqual(first.indexToken, second.indexToken)
        XCTAssertEqual(first.worktreeToken, second.worktreeToken)
    }
    func testReviewedCommitRejectsChangedIndexWithoutCreatingCommit() async throws {
        let f = try await fixture()
        try f.write("tracked.txt", "reviewed\n")
        let reviewed = try await f.service().stage(paths: ["tracked.txt"], directory: f.repo)
        try f.write("tracked.txt", "unreviewed\n"); _ = try await f.git(["add", "--", "tracked.txt"])
        do { _ = try await f.service().commit(message: "should not commit", directory: f.repo, expected: reviewed); XCTFail() }
        catch { XCTAssertEqual(error as? LocalGitMutationError, .staleSnapshot) }
        let head = try await f.git(["rev-parse", "HEAD"])
        XCTAssertEqual(head, reviewed.status.head)
    }
    func testIndividualUnstageHunkAndUnrelatedPatchRejection() async throws {
        let f = try await fixture()
        try f.write("tracked.txt", "changed\n")
        _ = try await f.service().stage(paths: ["tracked.txt"], directory: f.repo)
        let diff = try await f.service().diff(path: "tracked.txt", staged: true, directory: f.repo)
        XCTAssertEqual(diff.hunks.count, 1)
        let unstaged = try await f.service().unstageHunk(patch: diff.hunks[0].patch, expected: diff.snapshot, directory: f.repo)
        XCTAssertFalse(unstaged.status.entries[0].isStaged)
        let forged = Data("diff --git a/other.txt b/other.txt\n--- a/other.txt\n+++ b/other.txt\n@@ -1 +1 @@\n-old\n+new\n".utf8)
        do { _ = try await f.service().stageHunk(patch: forged, expected: unstaged, directory: f.repo); XCTFail() }
        catch { XCTAssertEqual(error as? LocalGitMutationError, .invalidPatch) }
    }
    func testPositivePRCheckoutUsesExpectedImmutableSHAAndConfiguredSSHTransport() async throws {
        let f = try await fixture()
        let bare = f.root.appendingPathComponent("pull-remote.git")
        _ = try await f.git(["init", "--bare", "--", bare.path]); _ = try await f.git(["remote", "add", "origin", bare.path])
        let sha = try await f.git(["rev-parse", "HEAD"])
        _ = try await f.git(["push", "origin", sha + ":refs/pull/42/head"])
        let transport = f.root.appendingPathComponent("fixture-ssh")
        try Data(("#!/bin/sh\nexec /usr/bin/git upload-pack '" + bare.path + "'\n").utf8).write(to: transport)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: transport.path)
        _ = try await f.git(["config", "core.sshCommand", transport.path]); _ = try await f.git(["config", "ssh.variant", "simple"])
        _ = try await f.git(["remote", "set-url", "origin", "git@github.com:owner/repo.git"])
        let destination = f.root.appendingPathComponent("pr42")
        let mapping = LocalPRCheckoutMapping(repository: .init(account: .init(host: "github.com", accountID: "fixture"), repositoryID: "1"), repositoryName: "owner/repo", number: 42, expectedHeadSHA: sha, remote: "origin", destination: destination, branch: "pr42")
        let checked = try await f.service().checkoutPullRequest(mapping: mapping, directory: f.repo)
        XCTAssertEqual(checked.repository.worktrees.count, 2)
        let checkedSHA = try await f.git(["rev-parse", "HEAD"], directory: destination)
        XCTAssertEqual(checkedSHA, sha)
        let original = try await f.git(["symbolic-ref", "--short", "HEAD"])
        XCTAssertEqual(original, "main")
    }
    func testCommitTemplateReadsOnlyAuthorizedConfiguredFileAndRemoteDisplayRedactsSecrets() async throws {
        let f = try await fixture()
        let template = f.root.appendingPathComponent("commit-template.txt")
        try Data("Subject\n\nBody\n".utf8).write(to: template)
        _ = try await f.git(["config", "commit.template", template.path])
        let content = try await f.service().commitTemplate(directory: f.repo)
        XCTAssertEqual(content, "Subject\n\nBody\n")
        _ = try await f.git(["remote", "add", "private", "https://secret-token@github.com/owner/repo.git?secret=value"])
        let remotes = try await f.service().remotes(directory: f.repo)
        XCTAssertEqual(remotes.first?.fetchURL, "https://github.com/owner/repo.git")
        do { _ = try await f.service().fetch(remote: "private", directory: f.repo); XCTFail() }
        catch { XCTAssertEqual(error as? LocalGitMutationError, .invalidRemote) }
    }
    func testReviewedBranchDeletionRejectsChangedTargetCommit() async throws {
        let f = try await fixture()
        let reviewed = try await f.service().createBranch(name: "topic", directory: f.repo)
        let moved = try await f.git(["commit-tree", "HEAD^{tree}", "-p", "HEAD", "-m", "new target"])
        _ = try await f.git(["update-ref", "refs/heads/topic", moved])
        do { _ = try await f.service().deleteBranch(name: "topic", directory: f.repo, expected: reviewed); XCTFail() }
        catch { XCTAssertEqual(error as? LocalGitMutationError, .staleSnapshot) }
        let actual = try await f.git(["rev-parse", "topic"])
        XCTAssertEqual(actual, moved)
    }
    func testWorktreeRemovalPreservesIgnoredLocalFiles() async throws {
        let f = try await fixture()
        try f.write(".gitignore", "private.env\n"); _ = try await f.git(["add", "--", ".gitignore"]); _ = try await f.git(["commit", "-m", "ignore private env"])
        let linked = f.root.appendingPathComponent("ignored-worktree")
        _ = try await f.service().addWorktree(path: linked, branch: "ignored-topic", directory: f.repo)
        try f.write("private.env", "keep private ignored file", directory: linked)
        do { _ = try await f.service().removeWorktree(target: linked, directory: f.repo); XCTFail() }
        catch { XCTAssertEqual(error as? LocalGitMutationError, .dirtyWorktree) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: linked.appendingPathComponent("private.env").path))
    }
    func testShiftedStashReferenceCannotDeleteUnreviewedStash() async throws {
        let f = try await fixture()
        try f.write("tracked.txt", "first stash\n")
        let reviewed = try await f.service().stash(message: "first", directory: f.repo)
        try f.write("tracked.txt", "second stash\n")
        _ = try await f.git(["stash", "push", "-m", "second"])
        do { _ = try await f.service().dropStash(reference: "stash@{0}", directory: f.repo, expected: reviewed); XCTFail() }
        catch { XCTAssertEqual(error as? LocalGitMutationError, .staleSnapshot) }
        let remaining = try await f.service().snapshot(directory: f.repo)
        XCTAssertEqual(remaining.stashes.count, 2)
        XCTAssertTrue(remaining.stashes[0].message.contains("second"))
    }
    func testUntrackedFIFOIsRejectedWithoutBlockingOnContents() async throws {
        let f = try await fixture()
        let pipe = f.repo.appendingPathComponent("untracked-pipe")
        try f.write("untracked-pipe", "regular before status\n")
        let racing = LocalFIFOReplacementRunner(base: f.runner, path: pipe)
        // Allow a broken implementation's blocking read to finish so RED does not hang the suite.
        DispatchQueue.global().async {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                var metadata = stat()
                guard lstat(pipe.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFIFO else { usleep(20_000); continue }
                let descriptor = open(pipe.path, O_WRONLY | O_NONBLOCK)
                if descriptor >= 0 { var byte: UInt8 = 120; _ = Darwin.write(descriptor, &byte, 1); close(descriptor); return }
                usleep(20_000)
            }
        }
        do { _ = try await LocalGitService(runner: racing, authorizedRoots: [f.root]).snapshot(directory: f.repo); XCTFail("Snapshot must never read FIFO contents") }
        catch { XCTAssertEqual(error as? LocalGitMutationError, .unsupportedFileType) }
    }
    func testUnsupportedSandboxHookPolicyBlocksConfiguredHookBeforeCommit() async throws {
        let f = try await fixture()
        let hooks = f.root.appendingPathComponent("configured-hooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        let hook = hooks.appendingPathComponent("pre-commit")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
        _ = try await f.git(["config", "core.hooksPath", hooks.path])
        try f.write("tracked.txt", "changed\n")
        let staged = try await f.service().stage(paths: ["tracked.txt"], directory: f.repo)
        let policy = LocalGitService(runner: f.runner, authorizedRoots: [f.root], requiresTerminalForHooks: true)
        do { _ = try await policy.commit(message: "blocked", directory: f.repo, expected: staged); XCTFail() }
        catch { XCTAssertEqual(error as? LocalGitMutationError, .unsupportedHooks) }
        let unchanged = try await f.git(["rev-parse", "HEAD"])
        XCTAssertEqual(unchanged, staged.status.head)
    }
    func testConfiguredRemoteDefaultBranchIsProtectedFromDeletionAndRename() async throws {
        let f = try await fixture()
        _ = try await f.git(["branch", "develop"])
        _ = try await f.git(["update-ref", "refs/remotes/origin/develop", "HEAD"])
        _ = try await f.git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/develop"])
        let snapshot = try await f.service().snapshot(directory: f.repo)
        XCTAssertEqual(snapshot.branches.first(where: { $0.name == "develop" })?.isProtected, true)
        do { _ = try await f.service().deleteBranch(name: "develop", directory: f.repo); XCTFail() }
        catch { XCTAssertEqual(error as? LocalGitMutationError, .protectedBranch("develop")) }
        // Re-create only if RED deleted it, so both behaviors are independently exercised.
        let present = try await f.runner.run(arguments: ["show-ref", "--verify", "refs/heads/develop"], directory: f.repo)
        if present.exitCode != 0 { _ = try await f.git(["branch", "develop"]) }
        do { _ = try await f.service().renameBranch(oldName: "develop", newName: "renamed-default", directory: f.repo); XCTFail() }
        catch { XCTAssertEqual(error as? LocalGitMutationError, .protectedBranch("develop")) }
    }
    func testUnsupportedReferenceHookBlocksBranchFetchAndStashDrop() async throws {
        let f = try await fixture()
        try f.write("tracked.txt", "stash contents\n")
        _ = try await f.service().stash(message: "preserve", directory: f.repo)
        let remote = f.root.appendingPathComponent("hook-remote.git")
        _ = try await f.git(["init", "--bare", "--", remote.path]); _ = try await f.git(["remote", "add", "origin", remote.path])
        _ = try await f.git(["push", "origin", "main"])
        let hook = f.repo.appendingPathComponent(".git/hooks/reference-transaction")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
        let policy = LocalGitService(runner: f.runner, authorizedRoots: [f.root], requiresTerminalForHooks: true)
        do { _ = try await policy.createBranch(name: "blocked-topic", directory: f.repo); XCTFail() }
        catch { XCTAssertEqual(error as? LocalGitMutationError, .unsupportedHooks) }
        do { _ = try await policy.fetch(remote: "origin", directory: f.repo); XCTFail() }
        catch { XCTAssertEqual(error as? LocalGitMutationError, .unsupportedHooks) }
        do { _ = try await policy.dropStash(reference: "stash@{0}", directory: f.repo); XCTFail() }
        catch { XCTAssertEqual(error as? LocalGitMutationError, .unsupportedHooks) }
        let fresh = try await policy.snapshot(directory: f.repo)
        XCTAssertFalse(fresh.branches.contains(where: { $0.name == "blocked-topic" })); XCTAssertEqual(fresh.stashes.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.repo.appendingPathComponent(".git/FETCH_HEAD").path))
    }
    func testSubfolderSnapshotCapturesWholeIndexAndUsesActualWorktreeID() async throws {
        let f = try await fixture()
        let child = f.repo.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try f.write("tracked.txt", "staged first\n")
        _ = try await f.service().stage(paths: ["tracked.txt"], directory: f.repo)
        let receipt = LocalRecoveryIdentityReceipt()
        let service = LocalGitService(runner: f.runner, authorizedRoots: [f.root], operationStateSink: { _, worktree, _ in await receipt.append(worktree) })
        let scoped = try await service.snapshot(directory: child)
        let full = try await f.service().snapshot(directory: f.repo)
        XCTAssertEqual(scoped.indexToken, full.indexToken)
        let ids = await receipt.ids
        XCTAssertEqual(ids.last, scoped.repository.worktrees.first?.id)
        try f.write("tracked.txt", "staged second\n"); _ = try await f.git(["add", "--", "tracked.txt"])
        let changed = try await service.snapshot(directory: child)
        XCTAssertNotEqual(changed.indexToken, scoped.indexToken)
    }
    private func fixture() async throws -> LocalGitFixture {
        let root = try makeTemporaryDirectory(prefix: "MergePro-Local")
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let f = LocalGitFixture(root: root, repo: repo, runner: ProcessGitRunner(environment: ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_EDITOR": "/usr/bin/true", "GIT_SEQUENCE_EDITOR": "/usr/bin/true", "GIT_TERMINAL_PROMPT": "0"]))
        _ = try await f.git(["init", "-b", "main"]); _ = try await f.git(["config", "user.name", "Test"]); _ = try await f.git(["config", "user.email", "test@example.invalid"])
        try f.write("tracked.txt", "initial\n"); _ = try await f.git(["add", "--", "tracked.txt"]); _ = try await f.git(["commit", "-m", "initial"])
        return f
    }
}
private struct LocalGitFixture: Sendable {
    let root: URL
    let repo: URL
    let runner: ProcessGitRunner
    func service() -> LocalGitService { LocalGitService(runner: runner, authorizedRoots: [root]) }
    func write(_ path: String, _ text: String, directory: URL? = nil) throws { try Data(text.utf8).write(to: (directory ?? repo).appendingPathComponent(path)) }
    func git(_ arguments: [String], directory: URL? = nil) async throws -> String {
        let result = try await runner.run(arguments: arguments, directory: directory ?? repo)
        guard result.exitCode == 0 else { throw LocalGitFixtureError.failed(arguments, String(decoding: result.standardError, as: UTF8.self)) }
        return String(decoding: result.standardOutput, as: UTF8.self).trimmingCharacters(in: .newlines)
    }
}
private enum LocalGitFixtureError: Error { case failed([String], String) }

private actor LocalFIFOReplacementRunner: GitRunner {
    let base: ProcessGitRunner
    let path: URL
    var replaced = false
    init(base: ProcessGitRunner, path: URL) { self.base = base; self.path = path }
    func run(arguments: [String], directory: URL) async throws -> GitResult {
        let result = try await base.run(arguments: arguments, directory: directory)
        if arguments.contains("status"), !replaced {
            // A real concurrent filesystem change after Git emitted its real untracked record.
            replaced = true; try FileManager.default.removeItem(at: path)
            guard mkfifo(path.path, 0o600) == 0 else { throw LocalGitFixtureError.failed([], "mkfifo failed") }
        }
        return result
    }
}

private actor LocalRecoveryIdentityReceipt {
    var ids: [LocalWorktreeID] = []
    func append(_ id: LocalWorktreeID) { ids.append(id) }
}

extension LocalGitIntegrationTests {
    func testCRLFFileHunksStaySeparateAndStageIndependently() async throws {
        let f = try await fixture()
        let initial = (1...30).map { "line \($0)" }.joined(separator: "\r\n") + "\r\n"
        try f.write("crlf.txt", initial); _ = try await f.git(["add", "--", "crlf.txt"]); _ = try await f.git(["commit", "-m", "crlf"])
        try f.write("crlf.txt", initial.replacingOccurrences(of: "line 2\r\n", with: "changed two\r\n").replacingOccurrences(of: "line 28\r\n", with: "changed twenty eight\r\n"))
        let service = f.service(); let diff = try await service.diff(path: "crlf.txt", staged: false, directory: f.repo)
        XCTAssertEqual(diff.hunks.count, 2)
        _ = try await service.stageHunk(patch: try XCTUnwrap(diff.hunks.first).patch, expected: diff.snapshot, directory: f.repo)
        let staged = try await f.git(["diff", "--cached", "--", "crlf.txt"])
        XCTAssertTrue(staged.contains("+changed two")); XCTAssertFalse(staged.contains("+changed twenty eight"))
    }
    func testContentMentioningBinaryFilesKeepsTextHunks() async throws {
        let f = try await fixture()
        try f.write("tracked.txt", "initial\nBinary files are stored in LFS\n")
        let diff = try await f.service().diff(path: "tracked.txt", staged: false, directory: f.repo)
        XCTAssertFalse(diff.isBinary); XCTAssertEqual(diff.hunks.count, 1)
    }
    func testUndecodableTextFileDoesNotBlockHunkStagingOfOtherFiles() async throws {
        let f = try await fixture()
        let latin = f.repo.appendingPathComponent("a-latin1.txt")
        try Data([0x63, 0x61, 0x66, 0x0A]).write(to: latin); _ = try await f.git(["add", "--", "a-latin1.txt"]); _ = try await f.git(["commit", "-m", "latin"])
        try Data([0x63, 0x61, 0x66, 0xE9, 0x0A]).write(to: latin)
        try f.write("tracked.txt", "changed\n")
        let service = f.service(); let diff = try await service.diff(path: "tracked.txt", staged: false, directory: f.repo)
        _ = try await service.stageHunk(patch: try XCTUnwrap(diff.hunks.first).patch, expected: diff.snapshot, directory: f.repo)
        let staged = try await f.git(["diff", "--cached", "--name-only"])
        XCTAssertEqual(staged, "tracked.txt")
    }
    func testBranchSharingTagNameIsListedByItsBranchName() async throws {
        let f = try await fixture()
        _ = try await f.git(["tag", "main"])
        let snapshot = try await f.service().snapshot(directory: f.repo)
        XCTAssertEqual(snapshot.branches.map(\.name), ["main"])
        XCTAssertTrue(try XCTUnwrap(snapshot.branches.first).isCurrent)
    }
    func testWorktreeForExistingBranchChecksOutBranchInsteadOfDetachedHead() async throws {
        let f = try await fixture(); let service = f.service()
        _ = try await service.createBranch(name: "topic", startPoint: nil, directory: f.repo)
        let snapshot = try await service.addWorktree(path: f.root.appendingPathComponent("topic-worktree"), branch: "topic", createBranch: false, directory: f.repo)
        let added = try XCTUnwrap(snapshot.repository.worktrees.first { $0.directory.lastPathComponent == "topic-worktree" })
        XCTAssertFalse(added.isDetached); XCTAssertEqual(added.branch, "topic")
    }
    func testUnstageBeforeFirstCommitAfterFurtherEditKeepsWorktreeContent() async throws {
        let f = try await fixture()
        let unborn = f.root.appendingPathComponent("unborn"); try FileManager.default.createDirectory(at: unborn, withIntermediateDirectories: true)
        _ = try await f.git(["init", "-b", "main"], directory: unborn)
        try f.write("a.txt", "first\n", directory: unborn)
        let service = f.service()
        _ = try await service.stage(paths: ["a.txt"], directory: unborn)
        try f.write("a.txt", "second\n", directory: unborn)
        let unstaged = try await service.unstage(paths: ["a.txt"], directory: unborn)
        XCTAssertTrue(try XCTUnwrap(unstaged.status.entries.first { $0.path == "a.txt" }).isUntracked)
        XCTAssertEqual(try String(contentsOf: unborn.appendingPathComponent("a.txt"), encoding: .utf8), "second\n")
    }
    func testUntrackedNestedRepositoryDoesNotBreakSnapshot() async throws {
        let f = try await fixture()
        let nested = f.repo.appendingPathComponent("nested"); try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        _ = try await f.git(["init", "-b", "main"], directory: nested); try f.write("inner.txt", "x\n", directory: nested)
        let snapshot = try await f.service().snapshot(directory: f.repo)
        XCTAssertTrue(snapshot.status.entries.contains { $0.path == "nested/" && $0.isUntracked })
    }
    func testLocalRemotePathContainingColonStillRequiresAuthorization() async throws {
        let f = try await fixture()
        let outside = try makeTemporaryDirectory(prefix: "MergePro-Outside")
        let remote = outside.appendingPathComponent("re:mote"); try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        _ = try await f.git(["init", "--bare"], directory: remote)
        _ = try await f.git(["remote", "add", "origin", remote.path])
        do { _ = try await f.service().fetch(remote: "origin", directory: f.repo); XCTFail("an unauthorized local remote must not be read") }
        catch { guard case LocalGitError.authorizationRequired = error else { return XCTFail("\(error)") } }
    }
    func testPushAllowsOnlyEncryptedNetworkRemotesAndRefusesOthersBeforeRunningGit() async throws {
        let f = try await fixture()
        let stub = LocalTransportStubRunner(base: f.runner)
        let service = LocalGitService(runner: stub, authorizedRoots: [f.root])
        let bare = f.root.appendingPathComponent("remote.git")
        _ = try await f.git(["init", "--bare", "--", bare.path]); _ = try await f.git(["remote", "add", "origin", "https://example.invalid/owner/repo.git"])
        for url in ["http://example.invalid/owner/repo.git", "git://example.invalid/owner/repo.git", "file://" + bare.path, bare.path, "ext::sh -c true", "ftp://example.invalid/repo.git"] {
            _ = try await f.git(["remote", "set-url", "--push", "origin", url])
            do { _ = try await service.push(remote: "origin", branch: "main", directory: f.repo); XCTFail(url) }
            catch { XCTAssertEqual(error as? LocalGitMutationError, .unsupportedPushRemote, url) }
        }
        let refused = await stub.transports
        XCTAssertTrue(refused.isEmpty)
        XCTAssertTrue(LocalGitMutationError.unsupportedPushRemote.errorDescription?.contains("https, ssh") == true)
        for url in ["https://example.invalid/owner/repo.git", "ssh://git@example.invalid/owner/repo.git", "git@example.invalid:owner/repo.git"] {
            _ = try await f.git(["remote", "set-url", "--push", "origin", url])
            _ = try await service.push(remote: "origin", branch: "main", directory: f.repo)
        }
        let pushed = await stub.transports
        XCTAssertEqual(pushed.compactMap(\.first), ["push", "push", "push"])
    }
    func testPlaintextFetchAndPullSucceedWithExplicitTransportWarning() async throws {
        let f = try await fixture()
        let stub = LocalTransportStubRunner(base: f.runner)
        let service = LocalGitService(runner: stub, authorizedRoots: [f.root])
        _ = try await f.git(["remote", "add", "origin", "https://example.invalid/owner/repo.git"])
        let secure = try await service.fetch(remote: "origin", directory: f.repo)
        XCTAssertTrue(secure.transportWarnings.isEmpty)
        for (url, scheme) in [("http://example.invalid/owner/repo.git", "http"), ("git://example.invalid/owner/repo.git", "git")] {
            _ = try await f.git(["remote", "set-url", "origin", url])
            let fetched = try await service.fetch(remote: "origin", directory: f.repo)
            XCTAssertEqual(fetched.transportWarnings, [LocalGitTransportWarning(remote: "origin", scheme: scheme)])
            XCTAssertTrue(try XCTUnwrap(fetched.transportWarnings.first).message.contains("unencrypted \(scheme)://"))
            let pulled = try await service.pull(remote: "origin", branch: "main", directory: f.repo)
            XCTAssertEqual(pulled.transportWarnings, fetched.transportWarnings)
            let refreshed = try await service.snapshot(directory: f.repo)
            XCTAssertTrue(refreshed.transportWarnings.isEmpty)
        }
        let transports = await stub.transports
        XCTAssertEqual(transports.compactMap(\.first), ["fetch", "fetch", "pull", "fetch", "pull"])
    }
}

/// Records network transports instead of contacting fixture hosts; every other command runs for real.
private actor LocalTransportStubRunner: GitRunner {
    let base: ProcessGitRunner
    var transports: [[String]] = []
    init(base: ProcessGitRunner) { self.base = base }
    func run(arguments: [String], directory: URL) async throws -> GitResult {
        if ["fetch", "pull", "push"].contains(arguments.first ?? "") { transports.append(arguments); return GitResult(exitCode: 0) }
        return try await base.run(arguments: arguments, directory: directory)
    }
}
