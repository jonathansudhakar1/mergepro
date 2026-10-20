import Foundation

public enum GitWorktreeParser {
    public static func parse(_ data: Data, repositoryID: LocalRepositoryID) throws -> [LocalWorktree] {
        guard data.isEmpty || data.last == 0, let text = String(data: data, encoding: .utf8) else { throw LocalGitError.malformedOutput }
        var result: [LocalWorktree] = [], fields: [String] = []
        func append() throws {
            guard !fields.isEmpty else { return }
            guard fields[0].hasPrefix("worktree "), fields[0].count > 9 else { throw LocalGitError.malformedOutput }
            let rawPath = String(fields[0].dropFirst(9))
            guard rawPath.hasPrefix("/") else { throw LocalGitError.malformedOutput }
            let directory = URL(fileURLWithPath: rawPath)
            guard directory.path.hasPrefix("/") else { throw LocalGitError.malformedOutput }
            func value(_ prefix: String) -> String? { fields.first(where: { $0.hasPrefix(prefix + " ") }).map { String($0.dropFirst(prefix.count + 1)) } }
            let branch = value("branch").map { $0.hasPrefix("refs/heads/") ? String($0.dropFirst(11)) : $0 }
            result.append(.init(id: .init(rawValue: directory.standardizedFileURL.resolvingSymlinksInPath().path), repositoryID: repositoryID, directory: directory, head: value("HEAD"), branch: branch, isBare: fields.contains("bare"), isDetached: fields.contains("detached"), isLocked: fields.contains("locked") || value("locked") != nil, lockReason: value("locked"), isPrunable: fields.contains("prunable") || value("prunable") != nil))
            fields.removeAll()
        }
        for record in text.split(separator: "\0", omittingEmptySubsequences: false) {
            if record.isEmpty { try append() } else { fields.append(String(record)) }
        }
        try append()
        return result
    }
}
