import Foundation

extension LocalGitService {
    public func stage(paths: [String], directory: URL, expected: LocalGitSnapshot? = nil) async throws -> LocalGitSnapshot {
        try await transaction(directory: directory) { service in
            let fresh = try await service.readSnapshot(directory: directory); try service.checkExpected(expected, fresh: fresh)
            try service.validatePaths(paths, snapshot: fresh)
            // `git add` marks a conflicted file resolved, markers and all, so a file that still has markers is refused.
            for entry in fresh.status.entries where entry.isUnmerged && paths.contains(entry.path) {
                let url = fresh.repository.directory.appendingPathComponent(entry.path)
                guard (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil,
                      let data = FileManager.default.contents(atPath: url.path), let text = String(data: data, encoding: .utf8) else { continue }
                if LocalTextConflictDocument.containsMarkers(text) { throw LocalGitMutationError.unresolvedConflict(entry.path) }
            }
            try await service.preflightHooks(Self.indexHooks, directory: directory)
            _ = try await service.command(["--literal-pathspecs", "add", "--"] + paths, directory: fresh.repository.directory)
            return try await service.readSnapshot(directory: directory)
        }
    }
    public func unstage(paths: [String], directory: URL, expected: LocalGitSnapshot? = nil) async throws -> LocalGitSnapshot {
        try await transaction(directory: directory) { service in
            let fresh = try await service.readSnapshot(directory: directory); try service.checkExpected(expected, fresh: fresh)
            try service.validatePaths(paths, snapshot: fresh)
            try await service.preflightHooks(Self.indexHooks, directory: directory)
            // Unborn branch: `rm --cached` refuses index content differing from both HEAD and worktree unless forced; --cached never touches the worktree.
            let args = fresh.status.head == nil ? ["--literal-pathspecs", "rm", "--cached", "-f", "--"] : ["--literal-pathspecs", "restore", "--staged", "--"]
            _ = try await service.command(args + paths, directory: fresh.repository.directory)
            return try await service.readSnapshot(directory: directory)
        }
    }
    public func diff(path: String, staged: Bool, directory: URL) async throws -> LocalFileDiff {
        try await transaction(directory: directory) { service in
            let snapshot = try await service.readSnapshot(directory: directory)
            try service.validatePaths([path], snapshot: snapshot)
            return try await service.fileDiff(path: path, staged: staged, snapshot: snapshot)
        }
    }
    public func stageHunk(patch: Data, expected: LocalGitSnapshot, directory: URL) async throws -> LocalGitSnapshot {
        try await applyHunk(patch: patch, expected: expected, directory: directory, reverse: false)
    }
    public func unstageHunk(patch: Data, expected: LocalGitSnapshot, directory: URL) async throws -> LocalGitSnapshot {
        try await applyHunk(patch: patch, expected: expected, directory: directory, reverse: true)
    }
    private func applyHunk(patch: Data, expected: LocalGitSnapshot, directory: URL, reverse: Bool) async throws -> LocalGitSnapshot {
        try await transaction(directory: directory) { service in
            let fresh = try await service.readSnapshot(directory: directory); try service.checkExpected(expected, fresh: fresh)
            guard !fresh.status.entries.contains(where: \.isUnmerged) else { throw LocalGitMutationError.operationInProgress }
            var matches = false
            for entry in fresh.status.entries where !entry.isUntracked {
                // An undecodable (non-UTF-8) diff cannot contain the selected patch; it must not block other files.
                let diff: LocalFileDiff
                do { diff = try await service.fileDiff(path: entry.path, staged: reverse, snapshot: fresh) } catch LocalGitError.malformedOutput { continue }
                if diff.hunks.contains(where: { $0.patch == patch }) { matches = true; break }
            }
            guard matches else { throw LocalGitMutationError.invalidPatch }
            try await service.preflightHooks(Self.indexHooks, directory: directory)
            let args = ["apply", "--cached", "-p1", "--whitespace=nowarn"] + (reverse ? ["--reverse"] : [])
            _ = try await service.command(args + ["--check", "--", "-"], directory: fresh.repository.directory, input: patch)
            // Recheck both index and worktree after the dry run, immediately before applying.
            try service.checkExpected(fresh, fresh: try await service.readSnapshot(directory: directory))
            _ = try await service.command(args + ["--", "-"], directory: fresh.repository.directory, input: patch)
            return try await service.readSnapshot(directory: directory)
        }
    }
    public func commit(message: String, amend: Bool = false, directory: URL, expected: LocalGitSnapshot? = nil) async throws -> LocalGitSnapshot {
        try await transaction(directory: directory) { service in
            let fresh = try await service.readSnapshot(directory: directory); try service.checkExpected(expected, fresh: fresh)
            guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !message.contains("\0") else { throw LocalGitMutationError.invalidTarget }
            guard !fresh.status.entries.contains(where: \.isUnmerged) else { throw LocalGitMutationError.operationInProgress }
            try await service.preflightHooks(Self.commitHooks + (amend ? ["post-rewrite"] : []), directory: directory)
            if amend { try service.requireIdle(fresh); guard fresh.status.head != nil else { throw LocalGitMutationError.invalidTarget } }
            _ = try await service.command(["commit"] + (amend ? ["--amend"] : []) + ["--file=-"], directory: fresh.repository.directory, input: Data(message.utf8))
            return try await service.readSnapshot(directory: directory)
        }
    }
    public func commitTemplate(directory: URL) async throws -> String {
        try await transaction(directory: directory) { service in
            let output = try await service.runner.runReadOnly(arguments: ["config", "--path", "--get", "commit.template"], directory: directory)
            if output.exitCode == 1 { return "" }
            try LocalRepositoryReader.check(output, arguments: ["config"])
            guard let path = String(data: output.standardOutput, encoding: .utf8)?.trimmingCharacters(in: .newlines), !path.isEmpty else { throw LocalGitError.malformedOutput }
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : directory.appendingPathComponent(path)
            try service.authorize(url, directory: directory)
            guard let content = String(data: try service.readRegularFile(url, directory: directory), encoding: .utf8) else { throw LocalGitError.malformedOutput }
            return content
        }
    }
    func checkExpected(_ expected: LocalGitSnapshot?, fresh: LocalGitSnapshot) throws {
        guard let expected else { return }
        guard expected.repository.id == fresh.repository.id, expected.status == fresh.status, expected.indexToken == fresh.indexToken, expected.worktreeToken == fresh.worktreeToken, expected.operation == fresh.operation, expected.branches == fresh.branches, expected.stashes == fresh.stashes, expected.repository.worktrees == fresh.repository.worktrees else { throw LocalGitMutationError.staleSnapshot }
    }
    func validatePaths(_ paths: [String], snapshot: LocalGitSnapshot) throws {
        guard !paths.isEmpty else { throw LocalGitMutationError.invalidTarget }
        for path in paths {
            guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"), !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." || $0 == ".git" || $0.isEmpty }) else { throw LocalGitMutationError.invalidTarget }
            let url = snapshot.repository.directory.appendingPathComponent(path)
            // Git stages a symlink's link text. Validate the parent, without granting its destination.
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil { try authorize(url.deletingLastPathComponent(), directory: snapshot.repository.directory) }
            else { try authorize(url, directory: snapshot.repository.directory) }
        }
    }
    func fileDiff(path: String, staged: Bool, snapshot: LocalGitSnapshot) async throws -> LocalFileDiff {
        // Fixed a/ b/ prefixes and repository-root paths, whatever diff.noprefix, diff.*Prefix or diff.relative say,
        // so `git apply -p1` stages each hunk into the file it was read from.
        let args = ["--literal-pathspecs", "diff", "--no-ext-diff", "--no-textconv", "--binary", "--no-color", "--src-prefix=a/", "--dst-prefix=b/", "--no-relative"] + (staged ? ["--cached"] : []) + ["--", path]
        let output = try await read(args, directory: snapshot.repository.directory)
        guard let text = String(data: output.standardOutput, encoding: .utf8) else { throw LocalGitError.malformedOutput }
        // Content lines start with " ", "+" or "-"; only Git's own lines can mark a binary diff.
        let binary = text.components(separatedBy: "\n").contains { $0 == "GIT binary patch" || $0.hasPrefix("Binary files ") }
        return .init(path: path, isBinary: binary, patch: output.standardOutput, hunks: binary ? [] : Self.hunks(text), snapshot: snapshot)
    }
    static func hunks(_ text: String) -> [LocalDiffHunk] {
        // Split on the LF scalar: Swift treats CRLF as one Character, which would merge CRLF lines and hunks.
        let lines = text.components(separatedBy: "\n")
        var header: [String] = [], body: [String] = [], result: [LocalDiffHunk] = []
        func append() {
            guard let first = body.first else { return }
            let data = Data((header + body).joined(separator: "\n").appending("\n").utf8)
            result.append(.init(id: digest(data), header: first, patch: data)); body.removeAll()
        }
        for (index, line) in lines.enumerated() {
            if line.hasPrefix("diff --git ") { append(); header = [line] }
            else if line.hasPrefix("@@ ") { append(); body = [line] }
            else if !body.isEmpty { if index != lines.count - 1 || !line.isEmpty { body.append(line) } }
            else { header.append(line) }
        }
        append(); return result
    }
}
