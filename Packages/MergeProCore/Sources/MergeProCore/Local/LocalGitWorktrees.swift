import Foundation

extension LocalGitService {
    public func stash(message: String, includeUntracked: Bool = true, directory: URL, expected: LocalGitSnapshot? = nil) async throws -> LocalGitSnapshot {
        try await transaction(directory: directory) { service in
            let fresh = try await service.readSnapshot(directory: directory); try service.checkExpected(expected, fresh: fresh); try service.requireIdle(fresh)
            guard !message.contains("\0") else { throw LocalGitMutationError.invalidTarget }
            try await service.preflightHooks(Self.indexHooks, directory: directory)
            _ = try await service.command(["stash", "push"] + (includeUntracked ? ["--include-untracked"] : []) + ["--message", message, "--"], directory: directory)
            return try await service.readSnapshot(directory: directory)
        }
    }
    public func applyStash(reference: String, dropAfterApply: Bool = false, directory: URL, expected: LocalGitSnapshot? = nil) async throws -> LocalGitSnapshot {
        try await transaction(directory: directory) { service in
            let fresh = try await service.readSnapshot(directory: directory); try service.checkExpected(expected, fresh: fresh); try service.requireIdle(fresh); try service.requireClean(fresh)
            guard let stash = fresh.stashes.first(where: { $0.reference == reference }) else { throw LocalGitMutationError.invalidTarget }
            try await service.preflightHooks(Self.indexHooks, directory: directory)
            _ = try await service.command(["stash", "apply", "--", stash.head], directory: directory)
            if dropAfterApply {
                // A concurrent stash may move indices. Re-resolve by immutable SHA before dropping.
                let current = try await service.readStashes(directory: directory)
                guard let match = current.first(where: { $0.head == stash.head }) else { throw LocalGitMutationError.staleSnapshot }
                try await service.dropStashEntry(match, directory: directory)
            }
            return try await service.readSnapshot(directory: directory)
        }
    }
    public func dropStash(reference: String, directory: URL, expected: LocalGitSnapshot? = nil) async throws -> LocalGitSnapshot {
        try await transaction(directory: directory) { service in
            let fresh = try await service.readSnapshot(directory: directory); try service.checkExpected(expected, fresh: fresh); try service.requireIdle(fresh)
            guard let stash = fresh.stashes.first(where: { $0.reference == reference }) else { throw LocalGitMutationError.invalidTarget }
            try await service.dropStashEntry(stash, directory: directory)
            return try await service.readSnapshot(directory: directory)
        }
    }
    /// `git stash drop` only accepts positional references, and a `git stash` outside MergePro shifts them. The
    /// position is re-resolved to the reviewed stash commit immediately before the drop.
    private func dropStashEntry(_ stash: LocalGitStash, directory: URL) async throws {
        let resolved = try await read(["rev-parse", "--verify", "--quiet", "--end-of-options", stash.reference], directory: directory)
        guard String(decoding: resolved.standardOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == stash.head else { throw LocalGitMutationError.staleSnapshot }
        _ = try await command(["stash", "drop", "--", stash.reference], directory: directory)
    }
    public func addWorktree(path: URL, branch: String, createBranch: Bool = true, directory: URL, expected: LocalGitSnapshot? = nil) async throws -> LocalGitSnapshot {
        try await transaction(directory: directory) { service in
            let fresh = try await service.readSnapshot(directory: directory); try service.checkExpected(expected, fresh: fresh); try service.requireIdle(fresh)
            try service.authorize(path, directory: directory); try await service.validateBranch(branch, directory: directory)
            guard !FileManager.default.fileExists(atPath: path.path) else { throw LocalGitMutationError.invalidTarget }
            try await service.preflightHooks(Self.checkoutHooks, directory: directory)
            if createBranch {
                guard !fresh.branches.contains(where: { $0.name == branch }) else { throw LocalGitMutationError.invalidTarget }
                _ = try await service.command(["worktree", "add", "-b", branch, "--", path.path, "HEAD"], directory: directory)
            } else {
                guard fresh.branches.contains(where: { $0.name == branch }), !fresh.repository.worktrees.contains(where: { $0.branch == branch }) else { throw LocalGitMutationError.branchInUse(branch) }
                // A full ref is treated as a commit-ish (detached HEAD); the validated short name checks out the branch.
                _ = try await service.command(["worktree", "add", "--", path.path, branch], directory: directory)
            }
            return try await service.readSnapshot(directory: directory)
        }
    }
    public func removeWorktree(target: URL, directory: URL, expected: LocalGitSnapshot? = nil) async throws -> LocalGitSnapshot {
        try authorize(target, directory: directory)
        return try await transaction(directory: directory, additionalDirectories: [target]) { service in
            let fresh = try await service.readSnapshot(directory: directory); try service.checkExpected(expected, fresh: fresh); try service.requireIdle(fresh)
            let canonical = try LocalGitPathAccess.canonicalURL(target)
            guard let worktree = fresh.repository.worktrees.first(where: { (try? LocalGitPathAccess.canonicalURL($0.directory)) == canonical }), worktree.id != fresh.repository.worktrees.first?.id, !worktree.isLocked, !worktree.isBare else { throw LocalGitMutationError.invalidTarget }
            guard canonical != (try LocalGitPathAccess.canonicalURL(fresh.repository.directory)) else { throw LocalGitMutationError.invalidTarget }
            let targetState = try await service.readSnapshot(directory: target)
            guard targetState.repository.id == fresh.repository.id else { throw LocalGitMutationError.repositoryMismatch }
            try service.requireIdle(targetState); try service.requireClean(targetState)
            // Ignored files (for example .env) still belong to the user. Git remove otherwise deletes them.
            let ignored = try await service.read(["ls-files", "--others", "--ignored", "--exclude-standard", "-z"], directory: target)
            guard ignored.standardOutput.isEmpty else { throw LocalGitMutationError.dirtyWorktree }
            _ = try await service.command(["worktree", "remove", "--", canonical.path], directory: directory)
            return try await service.readSnapshot(directory: directory)
        }
    }
}
