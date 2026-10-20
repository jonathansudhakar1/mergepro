import Foundation

public struct GitStatusEntry: Identifiable, Equatable, Codable, Sendable {
    public var id: String { path }
    public let path: String
    public let originalPath: String?
    public let indexStatus: String
    public let worktreeStatus: String
    public let isUntracked: Bool
    public let isUnmerged: Bool
    public var isStaged: Bool { !isUntracked && indexStatus != "." && indexStatus != " " }
    public init(path: String, originalPath: String? = nil, indexStatus: String, worktreeStatus: String, isUntracked: Bool = false, isUnmerged: Bool = false) {
        self.path = path; self.originalPath = originalPath; self.indexStatus = indexStatus; self.worktreeStatus = worktreeStatus; self.isUntracked = isUntracked; self.isUnmerged = isUnmerged
    }
}
public struct GitStatusSnapshot: Equatable, Codable, Sendable {
    public let branch: String?
    public let head: String?
    public let upstream: String?
    public let ahead: Int
    public let behind: Int
    public let entries: [GitStatusEntry]
    public var isClean: Bool { entries.isEmpty }
    public init(branch: String? = nil, head: String? = nil, upstream: String? = nil, ahead: Int = 0, behind: Int = 0, entries: [GitStatusEntry] = []) {
        self.branch = branch; self.head = head; self.upstream = upstream; self.ahead = ahead; self.behind = behind; self.entries = entries
    }
}
public enum GitStatusParser {
    public static func parse(_ data: Data) throws -> GitStatusSnapshot {
        guard data.isEmpty || data.last == 0, let text = String(data: data, encoding: .utf8) else { throw LocalGitError.malformedOutput }
        let records = text.split(separator: "\0", omittingEmptySubsequences: false)
        var branch: String?, head: String?, upstream: String?, ahead = 0, behind = 0, entries: [GitStatusEntry] = []
        var index = 0
        while index < records.count {
            let record = records[index]; index += 1
            if record.isEmpty { continue }
            if record.hasPrefix("# ") {
                if record.hasPrefix("# branch.oid ") { let value = String(record.dropFirst(13)); head = value == "(initial)" ? nil : value }
                else if record.hasPrefix("# branch.head ") { let value = String(record.dropFirst(14)); branch = value == "(detached)" ? nil : value }
                else if record.hasPrefix("# branch.upstream ") { upstream = String(record.dropFirst(18)) }
                else if record.hasPrefix("# branch.ab ") {
                    let parts = record.dropFirst(12).split(separator: " ")
                    guard parts.count == 2, parts[0].hasPrefix("+"), parts[1].hasPrefix("-"), let a = Int(parts[0].dropFirst()), let b = Int(parts[1].dropFirst()), a >= 0, b >= 0 else { throw LocalGitError.malformedOutput }
                    ahead = a; behind = b
                }
                continue
            }
            if record.hasPrefix("? ") || record.hasPrefix("! ") {
                let path = String(record.dropFirst(2)); guard !path.isEmpty else { throw LocalGitError.malformedOutput }
                if record.hasPrefix("? ") { entries.append(.init(path: path, indexStatus: "?", worktreeStatus: "?", isUntracked: true)) }
                continue
            }
            let count: Int
            switch record.first { case "1": count = 8; case "2": count = 9; case "u": count = 10; default: throw LocalGitError.malformedOutput }
            let parts = record.split(separator: " ", maxSplits: count, omittingEmptySubsequences: false)
            guard parts.count == count + 1, parts[1].count == 2, !parts[count].isEmpty else { throw LocalGitError.malformedOutput }
            let xy = Array(parts[1]); var original: String?
            if record.first == "2" {
                guard index < records.count, !records[index].isEmpty else { throw LocalGitError.malformedOutput }
                original = String(records[index]); index += 1
            }
            entries.append(.init(path: String(parts[count]), originalPath: original, indexStatus: String(xy[0]), worktreeStatus: String(xy[1]), isUnmerged: record.first == "u"))
        }
        return .init(branch: branch, head: head, upstream: upstream, ahead: ahead, behind: behind, entries: entries)
    }
}
