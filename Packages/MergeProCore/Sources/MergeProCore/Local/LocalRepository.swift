import Foundation

/// Local filesystem identities deliberately cannot be substituted for provider repository keys.
public struct LocalRepositoryID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}
public struct LocalWorktreeID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}
public struct LocalWorktree: Identifiable, Equatable, Codable, Sendable {
    public let id: LocalWorktreeID
    public let repositoryID: LocalRepositoryID
    public let directory: URL
    public let head: String?
    public let branch: String?
    public let isBare: Bool
    public let isDetached: Bool
    public let isLocked: Bool
    public let lockReason: String?
    public let isPrunable: Bool
    public init(id: LocalWorktreeID, repositoryID: LocalRepositoryID, directory: URL, head: String? = nil, branch: String? = nil, isBare: Bool = false, isDetached: Bool = false, isLocked: Bool = false, lockReason: String? = nil, isPrunable: Bool = false) {
        self.id = id; self.repositoryID = repositoryID; self.directory = directory; self.head = head; self.branch = branch
        self.isBare = isBare; self.isDetached = isDetached; self.isLocked = isLocked; self.lockReason = lockReason; self.isPrunable = isPrunable
    }
}
public struct LocalRepository: Identifiable, Equatable, Codable, Sendable {
    public let id: LocalRepositoryID
    public let directory: URL
    public let gitDirectory: URL
    public let commonDirectory: URL
    public let worktrees: [LocalWorktree]
    public init(id: LocalRepositoryID, directory: URL, gitDirectory: URL, commonDirectory: URL, worktrees: [LocalWorktree]) {
        self.id = id; self.directory = directory; self.gitDirectory = gitDirectory; self.commonDirectory = commonDirectory; self.worktrees = worktrees
    }
}
public enum LocalGitError: Error, Equatable, Sendable, LocalizedError {
    case commandFailed(command: String, exitCode: Int32)
    case authorizationRequired(URL)
    case invalidPath
    case malformedOutput
    public var errorDescription: String? {
        switch self {
        case .commandFailed(let command, let code): "Git \(command) failed (\(code)). Check repository access, hooks, credentials or signing in Terminal."
        case .authorizationRequired(let url): "Authorize access to \(url.path) before reading this repository."
        case .invalidPath: "The repository path is invalid or contains a symlink cycle."
        case .malformedOutput: "Git returned malformed output or a filename that cannot be represented as UTF-8. Open this repository in Terminal."
        }
    }
}
public struct LocalRepositoryReader: Sendable {
    private let runner: any GitRunner
    public init(runner: any GitRunner = ProcessGitRunner()) { self.runner = runner }
    public func discover(directory: URL, authorizedRoots: [URL] = []) async throws -> LocalRepository {
        try Self.requireAuthorized(directory, directory: directory, roots: authorizedRoots)
        let git = try await output(["rev-parse", "--absolute-git-dir"], directory)
        let common = try await output(["rev-parse", "--path-format=absolute", "--git-common-dir"], directory)
        try Self.requireAuthorized(URL(fileURLWithPath: git), directory: directory, roots: authorizedRoots)
        try Self.requireAuthorized(URL(fileURLWithPath: common), directory: directory, roots: authorizedRoots)
        let root = try await output(["rev-parse", "--show-toplevel"], directory)
        try Self.requireAuthorized(URL(fileURLWithPath: root), directory: directory, roots: authorizedRoots)
        let commonURL = URL(fileURLWithPath: common).standardizedFileURL.resolvingSymlinksInPath()
        let identity = LocalRepositoryID(rawValue: commonURL.path)
        let result = try await runner.runReadOnly(arguments: ["worktree", "list", "--porcelain", "-z"], directory: directory)
        try Self.check(result, arguments: ["worktree", "list"])
        return .init(id: identity, directory: URL(fileURLWithPath: root), gitDirectory: URL(fileURLWithPath: git), commonDirectory: commonURL, worktrees: try GitWorktreeParser.parse(result.standardOutput, repositoryID: identity))
    }
    public func status(directory: URL, authorizedRoots: [URL] = []) async throws -> GitStatusSnapshot {
        try Self.requireAuthorized(directory, directory: directory, roots: authorizedRoots)
        let git = try await output(["rev-parse", "--absolute-git-dir"], directory)
        let common = try await output(["rev-parse", "--path-format=absolute", "--git-common-dir"], directory)
        try Self.requireAuthorized(URL(fileURLWithPath: git), directory: directory, roots: authorizedRoots)
        try Self.requireAuthorized(URL(fileURLWithPath: common), directory: directory, roots: authorizedRoots)
        let root = try await output(["rev-parse", "--show-toplevel"], directory)
        try Self.requireAuthorized(URL(fileURLWithPath: root), directory: directory, roots: authorizedRoots)
        let arguments = ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"]
        let result = try await runner.runReadOnly(arguments: arguments, directory: directory)
        try Self.check(result, arguments: arguments)
        return try GitStatusParser.parse(result.standardOutput)
    }
    private func output(_ arguments: [String], _ directory: URL) async throws -> String {
        let result = try await runner.runReadOnly(arguments: arguments, directory: directory)
        try Self.check(result, arguments: arguments)
        guard let value = String(data: result.standardOutput, encoding: .utf8), value.hasSuffix("\n") else { throw LocalGitError.malformedOutput }
        return String(value.dropLast())
    }
    static func requireAuthorized(_ target: URL, directory: URL, roots: [URL]) throws {
        try LocalGitPathAccess.requireAuthorized(target, roots: roots)
    }
    static func check(_ result: GitResult, arguments: [String]) throws {
        guard result.exitCode == 0 else { throw LocalGitError.commandFailed(command: arguments.first ?? "command", exitCode: result.exitCode) }
    }
}
