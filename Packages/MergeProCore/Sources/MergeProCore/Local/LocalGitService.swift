import Foundation
import CryptoKit

/// Owns guarded transactions per worktree. External Git processes can still change a repository;
/// Git's own lockfiles and operation checks remain authoritative at command execution time.
public actor LocalGitService {
    let runner: any GitRunner
    let authorizedRoots: [URL]
    let protectedBranches: Set<String>
    let requiresTerminalForHooks: Bool
    let mainBranch: String?
    let operationStateSink: (@Sendable (LocalRepositoryID, LocalWorktreeID, GitOperationState) async -> Void)?
    private static let transactions = GitDirectoryGate()
    public init(runner: any GitRunner = ProcessGitRunner(), authorizedRoots: [URL] = [], protectedBranches: Set<String> = ["main", "master"], mainBranch: String? = nil, requiresTerminalForHooks: Bool = false, operationStateSink: (@Sendable (LocalRepositoryID, LocalWorktreeID, GitOperationState) async -> Void)? = nil) {
        self.runner = runner; self.authorizedRoots = authorizedRoots; self.protectedBranches = protectedBranches
        self.mainBranch = mainBranch; self.requiresTerminalForHooks = requiresTerminalForHooks; self.operationStateSink = operationStateSink
    }
    public func snapshot(directory: URL) async throws -> LocalGitSnapshot {
        try await transaction(directory: directory) { service in try await service.readSnapshot(directory: directory) }
    }
    func transaction<T: Sendable>(directory: URL, additionalDirectories: [URL] = [], _ body: (isolated LocalGitService) async throws -> T) async throws -> T {
        let repository = try await LocalRepositoryReader(runner: runner).discover(directory: directory, authorizedRoots: authorizedRoots)
        let keys = try Set(([repository.directory, repository.commonDirectory] + additionalDirectories).map { try LocalGitPathAccess.canonicalURL($0).path }).sorted()
        let token = UUID(); var acquired: [String] = []
        do {
            for key in keys {
                try await withTaskCancellationHandler {
                    try await Self.transactions.acquire(key: key, token: token)
                } onCancel: { Task { await Self.transactions.cancel(key: key, token: token) } }
                acquired.append(key)
            }
            try Task.checkCancellation()
            let value = try await body(self)
            for key in acquired.reversed() { await Self.transactions.release(key: key, token: token) }
            return value
        } catch {
            // Cancellation does not imply Git aborted. Publish freshly read, sanitized recovery state.
            let recovered = await Task.detached(operation: { () -> GitOperationState? in
                do { return try await self.recoveryState(repository: repository, directory: directory, status: nil) } catch {
                    Log.localGit.info("Recovery state unavailable after a failed operation: \(Log.kind(error), privacy: .public)")
                    return nil
                }
            }).value
            if let state = recovered { await publish(state, repository: repository, directory: directory) }
            for key in acquired.reversed() { await Self.transactions.release(key: key, token: token) }
            throw error
        }
    }
    func command(_ arguments: [String], directory: URL, input: Data? = nil) async throws -> GitResult {
        try await preflightCommandHooks(arguments, directory: directory)
        let result: GitResult
        if let input { result = try await runner.run(arguments: arguments, directory: directory, standardInput: input) }
        else { result = try await runner.run(arguments: arguments, directory: directory) }
        try LocalRepositoryReader.check(result, arguments: arguments)
        return result
    }
    /// Pure reads need no hook preflight and run with `GitReadOnlyOptions`; `text` is only used for reads.
    func read(_ arguments: [String], directory: URL) async throws -> GitResult {
        let result = try await runner.runReadOnly(arguments: arguments, directory: directory)
        try LocalRepositoryReader.check(result, arguments: arguments)
        return result
    }
    func text(_ arguments: [String], directory: URL) async throws -> String {
        let result = try await read(arguments, directory: directory)
        guard let value = String(data: result.standardOutput, encoding: .utf8) else { throw LocalGitError.malformedOutput }
        return value.hasSuffix("\n") ? String(value.dropLast()) : value
    }
    func readSnapshot(directory: URL) async throws -> LocalGitSnapshot {
        let reader = LocalRepositoryReader(runner: runner)
        let repository = try await reader.discover(directory: directory, authorizedRoots: authorizedRoots)
        // Git ls-files scopes itself to cwd. Snapshot guards must cover the entire index.
        let directory = repository.directory
        let status = try await reader.status(directory: directory, authorizedRoots: authorizedRoots)
        let branches = try await readBranches(directory: directory)
        let stashes = try await readStashes(directory: directory)
        let index = try await read(["ls-files", "--stage", "-z"], directory: directory)
        let diff = try await read(["diff", "--no-ext-diff", "--no-textconv", "--binary", "--"], directory: directory)
        var hasher = SHA256(); hasher.update(data: diff.standardOutput)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        hasher.update(data: try encoder.encode(status))
        for entry in status.entries where entry.isUntracked {
            let url = repository.directory.appendingPathComponent(entry.path)
            // A symlink's content is the link text, never the contents of its target.
            if let link = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) {
                try authorize(url.deletingLastPathComponent(), directory: directory)
                hasher.update(data: Data(link.utf8))
            } else if entry.path.hasSuffix("/") {
                // Git reports an untracked nested repository as one directory entry; its files belong to that repository.
                try authorize(url, directory: directory)
                hasher.update(data: Data(entry.path.utf8))
            } else {
                try authorize(url, directory: directory)
                hasher.update(data: try readRegularFile(url, directory: directory))
            }
        }
        let operation = try await recoveryState(repository: repository, directory: directory, status: status)
        let snapshot = LocalGitSnapshot(repository: repository, status: status, operation: operation, branches: branches, stashes: stashes, indexToken: Self.digest(index.standardOutput), worktreeToken: hasher.finalize().map { String(format: "%02x", $0) }.joined())
        await publish(operation, repository: repository, directory: directory)
        return snapshot
    }
    func readBranches(directory: URL) async throws -> [LocalGitBranch] {
        let protection = try await knownProtectedBranches(directory: directory)
        let output = try await text(["for-each-ref", "--format=%(refname:lstrip=2)%00%(objectname)%00%(HEAD)%00%(upstream:short)%00", "refs/heads/"], directory: directory)
        return try output.split(separator: "\n").map { record in
            let parts = record.split(separator: "\0", omittingEmptySubsequences: false)
            guard parts.count == 5 else { throw LocalGitError.malformedOutput }
            let name = String(parts[0])
            return .init(name: name, head: String(parts[1]), isCurrent: parts[2] == "*", isProtected: protection.contains(name), upstream: parts[3].isEmpty ? nil : String(parts[3]))
        }
    }
    func knownProtectedBranches(directory: URL) async throws -> Set<String> {
        var result = protectedBranches
        if let mainBranch { result.insert(mainBranch) }
        let defaults = try await text(["for-each-ref", "--format=%(refname)%00%(symref)", "refs/remotes/"], directory: directory)
        for line in defaults.split(separator: "\n") {
            let parts = line.split(separator: "\0", omittingEmptySubsequences: false)
            guard parts.count == 2 else { throw LocalGitError.malformedOutput }
            guard parts[0].hasSuffix("/HEAD"), !parts[1].isEmpty else { continue }
            let prefix = parts[0].dropLast(4)
            if parts[1].hasPrefix(prefix) { result.insert(String(parts[1].dropFirst(prefix.count))) }
        }
        let config = try await runner.runReadOnly(arguments: ["config", "--get", "init.defaultBranch"], directory: directory)
        if config.exitCode == 0, let value = String(data: config.standardOutput, encoding: .utf8) {
            result.insert(value.trimmingCharacters(in: .newlines))
        } else if config.exitCode != 1 { try LocalRepositoryReader.check(config, arguments: ["config"]) }
        return result
    }
    func readStashes(directory: URL) async throws -> [LocalGitStash] {
        let output = try await text(["stash", "list", "-z", "--format=%gd%x00%H%x00%gs"], directory: directory)
        let fields = output.split(separator: "\0", omittingEmptySubsequences: false)
        guard !output.isEmpty else { return [] }
        var result: [LocalGitStash] = [], index = 0
        while index + 2 < fields.count {
            result.append(.init(reference: String(fields[index]), head: String(fields[index + 1]), message: String(fields[index + 2])))
            index += 3
        }
        guard fields.dropFirst(index).allSatisfy(\.isEmpty) else { throw LocalGitError.malformedOutput }
        return result
    }
    func authorize(_ target: URL, directory: URL) throws { try LocalRepositoryReader.requireAuthorized(target, directory: directory, roots: authorizedRoots) }
    func isProtected(_ name: String) -> Bool { protectedBranches.contains(name) || name == mainBranch }
    func requireIdle(_ snapshot: LocalGitSnapshot) throws { guard snapshot.operation == .idle else { throw LocalGitMutationError.operationInProgress } }
    func requireClean(_ snapshot: LocalGitSnapshot) throws { guard snapshot.status.isClean else { throw LocalGitMutationError.dirtyWorktree } }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    func publish(_ state: GitOperationState, repository: LocalRepository, directory _: URL) async {
        let root = repository.directory.standardizedFileURL.resolvingSymlinksInPath()
        let id = repository.worktrees.first(where: { $0.directory.standardizedFileURL.resolvingSymlinksInPath() == root })?.id ?? .init(rawValue: root.path)
        await operationStateSink?(repository.id, id, state)
    }
}
