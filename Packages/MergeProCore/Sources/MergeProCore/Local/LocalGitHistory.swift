import Foundation

public struct LocalHistoryCursor: Equatable, Sendable {
    public let head: String
    public let offset: Int
    public let search: String
    public init(head: String, offset: Int, search: String) { self.head = head; self.offset = offset; self.search = search }
}
public struct LocalHistoryPage: Equatable, Sendable {
    public let commits: [LocalHistoryCommit]
    public let nextCursor: LocalHistoryCursor?
}
public struct LocalHistoryCommit: Identifiable, Equatable, Sendable {
    public let id: String
    public let parents: [String]
    public var subject: String { message.components(separatedBy: "\n").first ?? "" }
    public let message: String
    public let authorName: String
    public let authorEmail: String
    public let authoredAt: Date
    public let committerName: String
    public let committerEmail: String
    public let committedAt: Date
    public let refs: [String]
}
public struct LocalHistoryFile: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public let path: String
    public let status: String
}
public struct LocalCommitDetails: Equatable, Sendable {
    public let commit: LocalHistoryCommit
    /// Changes relative to the first parent, or the empty tree for a root commit.
    public let files: [LocalHistoryFile]
}
public enum LocalHistoryDiffUnavailable: String, Equatable, Sendable {
    case binary, oversized, invalidUTF8
}
public struct LocalHistoryFileDiff: Equatable, Sendable {
    public let commit: String
    public let path: String
    public let firstParent: String?
    public let patch: String?
    public let unavailable: LocalHistoryDiffUnavailable?
}
public struct LocalGitComparison: Equatable, Sendable {
    public let head: String
    public let target: String
    public let targetReference: String
    /// Commits reachable only from HEAD.
    public let ahead: Int
    /// Commits reachable only from target.
    public let behind: Int
    /// Direct HEAD-to-target tree changes. This is not a conflict prediction.
    public let files: [LocalHistoryFile]
}

extension LocalGitService {
    private static let historyPageSize = 50
    private static let historyMetadataLimit = 2 * 1024 * 1024
    private static let historyPatchLimit = 1024 * 1024
    private static let historyFormat = "%H%x00%P%x00%an%x00%ae%x00%at%x00%cn%x00%ce%x00%ct%x00%D%x00%B"

    /// Pages remain attached to the original immutable HEAD. Search is a literal, case-insensitive message match.
    public func history(directory: URL, cursor: LocalHistoryCursor? = nil, search: String = "") async throws -> LocalHistoryPage {
        let root = try await historyRepository(directory)
        let query = cursor?.search ?? search
        guard query.utf8.count <= 4096, !query.contains("\0"), !query.contains("\n"), !query.contains("\r") else { throw LocalGitMutationError.invalidTarget }
        let head: String
        let offset = cursor?.offset ?? 0
        guard offset >= 0, offset <= 1_000_000 else { throw LocalGitMutationError.invalidTarget }
        if let cursor { try Self.requireHistoryOID(cursor.head); head = cursor.head }
        else {
            let result = try await runner.runReadOnly(arguments: ["rev-parse", "--verify", "--quiet", "HEAD^{commit}"], directory: root)
            if result.exitCode == 1 { return .init(commits: [], nextCursor: nil) }
            try LocalRepositoryReader.check(result, arguments: ["rev-parse"])
            guard let value = String(data: result.standardOutput, encoding: .utf8) else { throw LocalGitError.malformedOutput }
            head = value.trimmingCharacters(in: .newlines); try Self.requireHistoryOID(head)
        }
        let searchArguments = query.isEmpty ? [] : ["--fixed-strings", "--regexp-ignore-case", "--grep=" + query]
        let arguments = ["log", "--no-show-signature", "--no-notes", "--no-color", "--decorate=short", "--date-order", "-z", "--format=" + Self.historyFormat, "--max-count=51", "--skip=\(offset)"] + searchArguments + [head, "--"]
        let commits = try Self.historyCommits(try await historyOutput(arguments, directory: root))
        return .init(commits: Array(commits.prefix(Self.historyPageSize)), nextCursor: commits.count > Self.historyPageSize ? .init(head: head, offset: offset + Self.historyPageSize, search: query) : nil)
    }
    public func commitDetails(commit: String, directory: URL) async throws -> LocalCommitDetails {
        try Self.requireHistoryOID(commit)
        let root = try await historyRepository(directory)
        let metadata = try await historyCommit(commit, directory: root)
        let files = try await historyFiles(from: metadata.parents.first, to: commit, directory: root)
        return .init(commit: metadata, files: files)
    }
    /// Historical paths refer to tree objects, never filesystem targets (including historical symlinks).
    public func commitDiff(commit: String, path: String, directory: URL) async throws -> LocalHistoryFileDiff {
        try Self.requireHistoryOID(commit); try Self.requireHistoryPath(path)
        let root = try await historyRepository(directory)
        let metadata = try await historyCommit(commit, directory: root)
        let parent = metadata.parents.first
        func unavailable(_ reason: LocalHistoryDiffUnavailable) -> LocalHistoryFileDiff { .init(commit: commit, path: path, firstParent: parent, patch: nil, unavailable: reason) }
        // Inspect just the selected tree entry before asking Git to materialize a patch.
        for oid in [parent, commit].compactMap({ $0 }) {
            let entry = try await historyOutput(["--literal-pathspecs", "ls-tree", "-z", "--long", oid, "--", path], directory: root)
            guard entry.count <= 16_384 else { return unavailable(.oversized) }
            if !entry.isEmpty {
                guard let record = String(data: entry, encoding: .utf8), let tab = record.firstIndex(of: "\t") else { throw LocalGitError.malformedOutput }
                let fields = record[..<tab].split(whereSeparator: { $0 == " " })
                guard fields.count == 4 else { throw LocalGitError.malformedOutput }
                if let size = Int(fields[3]), size > Self.historyPatchLimit { return unavailable(.oversized) }
            }
        }
        let args = Self.historyDiffArguments(from: parent, to: commit) + ["-p", "--", path]
        let output: Data
        do { output = try await historyOutput(args, directory: root, limit: Self.historyPatchLimit) }
        catch GitRunnerError.outputLimitExceeded { return unavailable(.oversized) }
        guard let patch = String(data: output, encoding: .utf8) else { return unavailable(.invalidUTF8) }
        if patch.components(separatedBy: "\n").contains(where: { $0.hasPrefix("Binary files ") || $0 == "GIT binary patch" }) { return unavailable(.binary) }
        return .init(commit: commit, path: path, firstParent: parent, patch: patch, unavailable: nil)
    }
    public func compare(target: String, directory: URL) async throws -> LocalGitComparison {
        let root = try await historyRepository(directory)
        let head = try await resolveCommit("HEAD", directory: root)
        let resolved = try await resolveCommit(target, directory: root)
        let counts = try await historyOutput(["rev-list", "--left-right", "--count", head + "..." + resolved, "--"], directory: root)
        guard let text = String(data: counts, encoding: .utf8) else { throw LocalGitError.malformedOutput }
        let fields = text.split(whereSeparator: { $0.isWhitespace })
        guard fields.count == 2, let ahead = Int(fields[0]), let behind = Int(fields[1]), ahead >= 0, behind >= 0 else { throw LocalGitError.malformedOutput }
        return .init(head: head, target: resolved, targetReference: target, ahead: ahead, behind: behind, files: try await historyFiles(from: head, to: resolved, directory: root))
    }
    /// Informational read validation; mutations must also validate inside their transaction immediately before execution.
    public func validateComparison(_ comparison: LocalGitComparison, directory: URL) async throws {
        let root = try await historyRepository(directory)
        let head = try await resolveCommit("HEAD", directory: root)
        let target = try await resolveCommit(comparison.targetReference, directory: root)
        guard head == comparison.head, target == comparison.target else { throw LocalGitMutationError.staleSnapshot }
    }
    private func historyRepository(_ directory: URL) async throws -> URL {
        try Task.checkCancellation()
        return try await LocalRepositoryReader(runner: runner).discover(directory: directory, authorizedRoots: authorizedRoots).directory
    }
    private func historyOutput(_ arguments: [String], directory: URL, limit: Int = historyMetadataLimit) async throws -> Data {
        try Task.checkCancellation()
        let result = try await read(arguments, directory: directory)
        try Task.checkCancellation()
        guard result.standardOutput.count <= limit else { throw GitRunnerError.outputLimitExceeded(stream: .standardOutput, limit: limit) }
        return result.standardOutput
    }
    private func historyCommit(_ oid: String, directory: URL) async throws -> LocalHistoryCommit {
        let data = try await historyOutput(["log", "-1", "--no-show-signature", "--no-notes", "--no-color", "--decorate=short", "-z", "--format=" + Self.historyFormat, oid, "--"], directory: directory)
        let commits = try Self.historyCommits(data)
        guard commits.count == 1, let commit = commits.first, commit.id == oid else { throw LocalGitError.malformedOutput }
        return commit
    }
    private func historyFiles(from parent: String?, to commit: String, directory: URL) async throws -> [LocalHistoryFile] {
        let output = try await historyOutput(Self.historyDiffArguments(from: parent, to: commit) + ["--name-status", "-z", "--"], directory: directory)
        guard let text = String(data: output, encoding: .utf8) else { throw LocalGitError.malformedOutput }
        if text.isEmpty { return [] }
        var fields = text.components(separatedBy: "\0")
        guard fields.removeLast().isEmpty, fields.count.isMultiple(of: 2), fields.count <= 10_000 else { throw LocalGitError.malformedOutput }
        return try stride(from: 0, to: fields.count, by: 2).map { index in
            let status = fields[index], path = fields[index + 1]
            guard status.count == 1, "ACDMRTUXB".contains(status) else { throw LocalGitError.malformedOutput }
            try Self.requireHistoryPath(path)
            return .init(path: path, status: status)
        }
    }
    private static func historyDiffArguments(from parent: String?, to commit: String) -> [String] {
        // Disable rename detection for bounded comparisons. Renames appear as delete/add pairs.
        ["--literal-pathspecs", "diff-tree", "--no-commit-id", "--root", "-r", "--no-renames", "--no-ext-diff", "--no-textconv", "--no-color"] + (parent.map { [$0, commit] } ?? [commit])
    }
    private static func requireHistoryOID(_ oid: String) throws {
        guard [40, 64].contains(oid.utf8.count), oid.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw LocalGitMutationError.invalidTarget }
    }
    private static func requireHistoryPath(_ path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"), !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.lowercased() == ".git" }) else { throw LocalGitMutationError.invalidTarget }
    }
    private static func historyCommits(_ data: Data) throws -> [LocalHistoryCommit] {
        guard let text = String(data: data, encoding: .utf8) else { throw LocalGitError.malformedOutput }
        if text.isEmpty { return [] }
        var fields = text.components(separatedBy: "\0")
        guard fields.removeLast().isEmpty, fields.count.isMultiple(of: 10), fields.count <= 510 else { throw LocalGitError.malformedOutput }
        return try stride(from: 0, to: fields.count, by: 10).map { index in
            let values = Array(fields[index..<index + 10]); try requireHistoryOID(values[0])
            let parents = values[1].split(separator: " ").map(String.init)
            for parent in parents { try requireHistoryOID(parent) }
            guard let authored = TimeInterval(values[4]), let committed = TimeInterval(values[7]), authored.isFinite, committed.isFinite else { throw LocalGitError.malformedOutput }
            return .init(id: values[0], parents: parents, message: values[9], authorName: values[2], authorEmail: values[3], authoredAt: Date(timeIntervalSince1970: authored), committerName: values[5], committerEmail: values[6], committedAt: Date(timeIntervalSince1970: committed), refs: values[8].isEmpty ? [] : values[8].components(separatedBy: ", "))
        }
    }
}
