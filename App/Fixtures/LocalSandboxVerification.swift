import AppKit
import Foundation
import MergeProCore

/// Runs only in the separate fixture bundle and its own disposable container directory.
@MainActor enum LocalSandboxVerification {
    static var enabled:Bool {
        ProcessInfo.processInfo.environment["MERGEPRO_LOCAL_SANDBOX_VERIFY"] == "1"
            && ProcessInfo.processInfo.environment["MERGEPRO_UI_TEST_NAMESPACE"].flatMap(UUID.init(uuidString:)) != nil
    }
    static func run() async {
        guard enabled else { return }
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("LocalSandbox-"+UUID().uuidString,isDirectory:true)
        var checks:[String:String]=[:]
        defer { try? FileManager.default.removeItem(at:root);NSApp.terminate(nil) }
        do {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            checks["container"]=FileManager.default.homeDirectoryForCurrentUser.path.contains("/Library/Containers/") ? "active":"not observed"
            let executable=URL(fileURLWithPath:ProcessInfo.processInfo.environment["MERGEPRO_LOCAL_GIT_PATH"] ?? "/usr/bin/git")
            let runner=ProcessGitRunner(executableURL:executable)
            checks["git executable"]=executable.path
            let repo=root.appendingPathComponent("repo",isDirectory:true)
            func git(_ arguments:[String],at directory:URL) async throws -> GitResult {
                let value=try await runner.run(arguments:arguments,directory:directory)
                guard value.exitCode == 0 else {
                    // This fixture has no real credentials or provider transport. Record only
                    // known platform error classes; raw Git diagnostics remain unlogged.
                    let diagnostic=String(decoding:value.standardError,as:UTF8.self).lowercased()
                    if diagnostic.contains("xcrun") { checks["platform diagnostic"]="xcrun invocation failed inside the signed sandbox" }
                    if diagnostic.contains("sandbox") { checks["platform diagnostic"]="Git tool reports sandbox restriction" }
                    throw LocalGitError.commandFailed(command:arguments.first ?? "git",exitCode:value.exitCode)
                }
                return value
            }
            _=try await git(["init","--initial-branch=main",repo.path],at:root)
            for pair in [("user.name","Local fixture"),("user.email","fixture@example.invalid"),("commit.gpgsign","false"),("core.hooksPath",repo.appendingPathComponent(".git/hooks").path)] {
                _=try await git(["config","--local",pair.0,pair.1],at:repo)
            }
            let file=repo.appendingPathComponent("status file Ω.txt")
            try Data("fixture\n".utf8).write(to:file)
            let snapshot=try await LocalRepositoryReader(runner:runner).status(directory:repo,authorizedRoots:[root])
            guard snapshot.entries.contains(where:{ $0.path == file.lastPathComponent && $0.isUntracked }) else { throw CocoaError(.coderReadCorrupt) }
            checks["status"]="passed"
            let hooks=repo.appendingPathComponent(".git/hooks",isDirectory:true)
            try FileManager.default.createDirectory(at:hooks,withIntermediateDirectories:true)
            let hook=hooks.appendingPathComponent("pre-commit")
            try Data("#!/bin/sh\nprintf 'hook-called' > .git/probe-hook\n".utf8).write(to:hook)
            try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:hook.path)
            let hookMode=(try FileManager.default.attributesOfItem(atPath:hook.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
            checks["hook executable mode"]=hookMode & 0o111 != 0 ? "set":"missing"
            let configuredHooks=try await git(["config","--get","core.hooksPath"],at:repo)
            checks["hook configuration"]=String(decoding:configuredHooks.standardOutput,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines) == hooks.path ? "matched":"mismatch"
            _=try await git(["add","--",file.lastPathComponent],at:repo)
            _=try await git(["commit","-m","Offline sandbox fixture"],at:repo)
            checks["hook"]=FileManager.default.fileExists(atPath:repo.appendingPathComponent(".git/probe-hook").path) ? "passed":"configured hook did not run; use Terminal"
            let guarded=LocalGitService(runner:runner,authorizedRoots:[root],requiresTerminalForHooks:true)
            let beforeGuard=try await guarded.snapshot(directory:repo)
            do {
                _=try await guarded.commit(message:"Must require Terminal for configured hook",directory:repo,expected:beforeGuard)
                checks["hook guard"]="failed: mutation was not blocked"
            } catch LocalGitMutationError.unsupportedHooks {
                let afterGuard=try await guarded.snapshot(directory:repo)
                checks["hook guard"]=afterGuard.status.head == beforeGuard.status.head ? "blocked before mutation":"failed: HEAD changed"
            }
            let helper=root.appendingPathComponent("credential-helper")
            try Data("#!/bin/sh\ncat >/dev/null\nprintf 'username=offline-fixture\\npassword=offline-fixture\\n'\n".utf8).write(to:helper)
            try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:helper.path)
            _=try await git(["config","--local","credential.helper",helper.path],at:repo)
            let credential=try await runner.run(arguments:["credential","fill"],directory:repo,standardInput:Data("protocol=https\nhost=fixture.invalid\n\n".utf8))
            checks["configured helper"]=credential.exitCode == 0 && String(decoding:credential.standardOutput,as:UTF8.self).contains("username=offline-fixture") ? "passed":"unsupported (exit \(credential.exitCode)); use Terminal"
            let signingKey=root.appendingPathComponent("fixture-signing-key")
            let keygen=ProcessGitRunner(executableURL:URL(fileURLWithPath:"/usr/bin/ssh-keygen"))
            let generated=try await keygen.run(arguments:["-q","-t","ed25519","-N","","-f",signingKey.path],directory:root)
            if generated.exitCode == 0 {
                for pair in [("gpg.format","ssh"),("user.signingkey",signingKey.path),("commit.gpgsign","true")] { _=try await git(["config","--local",pair.0,pair.1],at:repo) }
                let signed=try await runner.run(arguments:["commit","--allow-empty","-m","Disposable SSH signing fixture"],directory:repo)
                checks["configured signing"]=signed.exitCode == 0 ? "passed":"unsupported; use Terminal"
            } else { checks["configured signing"]="unsupported; use Terminal" }
            let bare=root.appendingPathComponent("remote.git",isDirectory:true)
            _=try await git(["init","--bare",bare.path],at:root)
            _=try await git(["remote","add","origin",bare.path],at:repo)
            _=try await git(["push","origin","main"],at:repo)
            checks["local bare push"]="passed"
            let bookmark=try repo.bookmarkData(options:.withSecurityScope,includingResourceValuesForKeys:nil,relativeTo:nil)
            var stale=false
            let resolved=try URL(resolvingBookmarkData:bookmark,options:[.withSecurityScope,.withoutUI],relativeTo:nil,bookmarkDataIsStale:&stale)
            let lease=resolved.startAccessingSecurityScopedResource()
            defer { if lease { resolved.stopAccessingSecurityScopedResource() } }
            checks["container bookmark"]=resolved.resolvingSymlinksInPath() == repo.resolvingSymlinksInPath() ? "resolved":"failed"
            try await verifyRichWorkspace(root: root, executable: executable, progress: { checks["rich stage"] = $0 })
            checks["rich workspace"]="overview, history, immutable diff, comparison, conflict save/stage and recovery passed"
            checks["external picker/relaunch"]="manual acceptance pending"
        } catch { checks["failure"]=error.localizedDescription }
        if let data=try? JSONSerialization.data(withJSONObject:checks,options:[.sortedKeys]),let value=String(data:data,encoding:.utf8) {
            FileHandle.standardOutput.write(Data(("LOCAL_SANDBOX_RESULT "+value+"\n").utf8))
        }
    }
    private static func verifyRichWorkspace(root: URL, executable: URL, progress: (String) -> Void) async throws {
        let repo = try LocalGitPathAccess.canonicalURL(root).appendingPathComponent("rich-workspace")
        let runner = ProcessGitRunner(executableURL: executable, environment: ["GIT_CONFIG_NOSYSTEM":"1", "GIT_CONFIG_GLOBAL":"/dev/null", "GIT_EDITOR":"/usr/bin/true", "GIT_TERMINAL_PROMPT":"0"])
        func git(_ arguments: [String], at directory: URL) async throws {
            let value = try await runner.run(arguments: arguments, directory: directory)
            guard value.exitCode == 0 else { throw LocalGitError.commandFailed(command: arguments.first ?? "fixture", exitCode: value.exitCode) }
        }
        try await git(["init", "-b", "main", repo.path], at: root)
        try await git(["config", "user.name", "Workspace fixture"], at: repo)
        try await git(["config", "user.email", "fixture@example.invalid"], at: repo)
        let file = repo.appendingPathComponent("conflict.txt")
        try Data("base\n".utf8).write(to: file)
        try await git(["add", "--", "conflict.txt"], at: repo)
        try await git(["commit", "-m", "Initial workspace"], at: repo)
        let service = LocalGitService(runner: runner, authorizedRoots: [root], requiresTerminalForHooks: true)
        progress("overview")
        let overview = try await service.overview(directory: repo)
        progress("history")
        let history = try await service.history(directory: repo)
        guard overview.status.isClean, let first = history.commits.first else { throw LocalGitError.malformedOutput }
        progress("details")
        let details = try await service.commitDetails(commit: first.id, directory: repo)
        progress("diff")
        let diff = try await service.commitDiff(commit: first.id, path: "conflict.txt", directory: repo)
        guard details.files.first?.path == "conflict.txt", diff.patch?.contains("+base") == true else { throw LocalGitError.malformedOutput }
        try await git(["switch", "-c", "topic"], at: repo)
        try Data("incoming\n".utf8).write(to: file)
        try await git(["commit", "-am", "Incoming change"], at: repo)
        try await git(["switch", "main"], at: repo)
        try Data("current\n".utf8).write(to: file)
        try await git(["commit", "-am", "Current change"], at: repo)
        progress("comparison")
        let comparison = try await service.compare(target: "topic", directory: repo)
        guard comparison.ahead == 1, comparison.behind == 1 else { throw LocalGitError.malformedOutput }
        progress("snapshot")
        let before = try await service.snapshot(directory: repo)
        progress("merge")
        let merged = try await service.begin(operation: .merge, target: "topic", directory: repo, expected: before, reviewedHead: comparison.head, reviewedTarget: comparison.target)
        guard merged.status.entries.contains(where: \.isUnmerged) else { throw LocalGitError.malformedOutput }
        progress("conflict read")
        let document = try await service.conflictDocument(path: "conflict.txt", directory: repo)
        guard document.current?.text == "current\n", document.incoming?.text == "incoming\n" else { throw LocalGitError.malformedOutput }
        progress("conflict resolve")
        let resolved = try await service.resolveConflict(document: document, resolution: .text("resolved\n"), directory: repo)
        guard !resolved.status.entries.contains(where: \.isUnmerged) else { throw LocalGitError.malformedOutput }
        progress("continue")
        let completed = try await service.continueOperation(directory: repo, expected: resolved)
        guard completed.operation == .idle, completed.status.isClean else { throw LocalGitError.malformedOutput }
    }

}
