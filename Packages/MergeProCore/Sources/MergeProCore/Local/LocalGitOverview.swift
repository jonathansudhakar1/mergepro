import Foundation

/// Informational browsing state. It cannot supply mutation admission tokens.
public struct LocalGitOverview: Equatable, Sendable {
    public let repository: LocalRepository
    public let status: GitStatusSnapshot
    public let operation: GitOperationState
    public let branches: [LocalGitBranch]
    public let stashes: [LocalGitStash]
    public init(repository: LocalRepository, status: GitStatusSnapshot, operation: GitOperationState, branches: [LocalGitBranch], stashes: [LocalGitStash]) {
        self.repository = repository; self.status = status; self.operation = operation
        self.branches = branches; self.stashes = stashes
    }
    public init(snapshot: LocalGitSnapshot) {
        self.init(repository: snapshot.repository, status: snapshot.status, operation: snapshot.operation, branches: snapshot.branches, stashes: snapshot.stashes)
    }
}

extension LocalGitService {
    /// Read status/ref metadata without a binary worktree diff, index fingerprint or
    /// eager reads of untracked files. A reviewed mutation still requires snapshot().
    public func overview(directory: URL) async throws -> LocalGitOverview {
        let reader = LocalRepositoryReader(runner: runner)
        let repository = try await reader.discover(directory: directory, authorizedRoots: authorizedRoots)
        let status = try await reader.status(directory: repository.directory, authorizedRoots: authorizedRoots)
        let branches = try await readBranches(directory: repository.directory)
        let stashes = try await readStashes(directory: repository.directory)
        let operation = try await recoveryState(repository: repository, directory: repository.directory, status: status)
        try Task.checkCancellation()
        await publish(operation, repository: repository, directory: repository.directory)
        return .init(repository: repository, status: status, operation: operation, branches: branches, stashes: stashes)
    }
}
