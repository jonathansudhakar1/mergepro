import Foundation

/// Safe to persist. This is a UI hint; after relaunch the service always re-reads Git's metadata.
public enum GitOperationState: Equatable, Codable, Sendable {
    case idle
    case running(name: String)
    case conflicts(operation: String, paths: [String])
    case failed(message: String)
}
public enum LocalGitOperation: String, Codable, Sendable { case merge, rebase; case cherryPick = "cherry-pick" }
public struct LocalGitBranch: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public let name: String
    public let head: String
    public let isCurrent: Bool
    public let isProtected: Bool
    public let upstream: String?
}
public struct LocalGitStash: Identifiable, Equatable, Sendable {
    public var id: String { head }
    public let reference: String
    public let head: String
    public let message: String
}
public struct LocalGitSnapshot: Equatable, Sendable {
    public let repository: LocalRepository
    public let status: GitStatusSnapshot
    public let operation: GitOperationState
    public let branches: [LocalGitBranch]
    public let stashes: [LocalGitStash]
    public let indexToken: String
    public let worktreeToken: String
    /// Set only on the snapshot a fetch or pull returns, when that remote uses a plaintext transport.
    public internal(set) var transportWarnings: [LocalGitTransportWarning] = []
}
public struct LocalGitTransportWarning: Equatable, Sendable {
    public let remote: String
    public let scheme: String
    public var message: String { "Remote \(remote) was fetched over unencrypted \(scheme)://, so its contents could have been altered in transit. Change it to an https or ssh URL." }
}
public struct LocalDiffHunk: Identifiable, Equatable, Sendable {
    public let id: String
    public let header: String
    public let patch: Data
}
public struct LocalFileDiff: Equatable, Sendable {
    public let path: String
    public let isBinary: Bool
    public let patch: Data
    public let hunks: [LocalDiffHunk]
    public let snapshot: LocalGitSnapshot
}
public enum LocalGitMutationError: Error, Equatable, Sendable, LocalizedError {
    case dirtyWorktree
    case invalidReference
    case protectedBranch(String)
    case branchInUse(String)
    case staleSnapshot
    case invalidPatch
    case noOperation
    case operationInProgress
    case repositoryMismatch
    case revisionMismatch
    case invalidRemote
    case invalidTarget
    case unsupportedFileType
    case unsupportedHooks
    case oversizedFile
    case unsupportedPushRemote
    case unresolvedConflict(String)
    public var errorDescription: String? {
        switch self {
        case .unresolvedConflict(let path): "\(path) still contains conflict markers. Finish resolving it, or use the conflict resolver, before staging."
        case .dirtyWorktree: "This worktree has changes. Commit or stash them before this operation."
        case .invalidReference: "Choose a valid branch or immutable commit reference."
        case .protectedBranch(let name): "The branch \(name) is protected from deletion or renaming."
        case .branchInUse(let name): "The branch \(name) is checked out in a worktree."
        case .staleSnapshot: "The repository changed since this diff was loaded. Refresh the diff before staging."
        case .invalidPatch: "This patch does not match a current individual hunk. Refresh the diff."
        case .noOperation: "Git has no merge, rebase or cherry-pick operation to recover."
        case .operationInProgress: "Finish or abort the current Git operation first."
        case .repositoryMismatch: "The configured remote does not match this pull request's repository."
        case .revisionMismatch: "The pull request revision changed. Refresh it before checkout."
        case .invalidRemote: "Choose an existing configured remote without embedded credentials."
        case .invalidTarget: "The requested Git target is unavailable or unsafe."
        case .unsupportedFileType: "This repository contains a nonregular file. Open the repository in Terminal."
        case .unsupportedHooks: "Configured Git hooks cannot reliably run in this sandbox. Open this operation in Terminal; the hook configuration has been preserved."
        case .oversizedFile: "A file is too large for a guarded local diff. Open this repository in Terminal."
        case .unsupportedPushRemote: "Push only to https, ssh or user@host:path remotes. This remote's push URL uses an unencrypted (http, git://), local or custom transport; change it or push from Terminal."
        }
    }
}
public struct LocalPRCheckoutMapping: Equatable, Sendable {
    public let repository: RepositoryKey
    public let repositoryName: String
    public let number: Int
    public let expectedHeadSHA: String
    public let remote: String
    public let destination: URL
    public let branch: String
    public init(repository: RepositoryKey, repositoryName: String, number: Int, expectedHeadSHA: String, remote: String, destination: URL, branch: String) {
        self.repository = repository; self.repositoryName = repositoryName; self.number = number; self.expectedHeadSHA = expectedHeadSHA; self.remote = remote; self.destination = destination; self.branch = branch
    }
}
