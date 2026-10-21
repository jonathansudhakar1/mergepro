import Foundation
import Darwin

public struct LocalGitConflictSide: Equatable, Sendable {
    public let stage: Int
    public let objectID: String
    public let mode: String
    public let text: String
}
public struct LocalGitConflictDocument: Equatable, Sendable {
    public let path: String
    public let snapshot: LocalGitSnapshot
    public let base: LocalGitConflictSide?
    public let current: LocalGitConflictSide?
    public let incoming: LocalGitConflictSide?
    public let workingText: String?
    public let workingIdentity: String
}
public enum LocalGitConflictResolution: Equatable, Sendable { case text(String), current, incoming, delete }
public enum LocalGitConflictError: Error, Equatable, Sendable, LocalizedError {
    case binaryOrInvalidText, remainingMarkers
    case savedButNotStaged(String)
    public var errorDescription: String? {
        switch self {
        case .binaryOrInvalidText: "This conflict contains binary or invalid UTF-8 content. Use an editor or Terminal."
        case .remainingMarkers: "Remove remaining conflict marker lines before marking resolved. Deliberate marker lines require editor or Terminal resolution."
        case .savedButNotStaged(let reason): "The result was saved, but staging did not finish. Git may have staged the file before cancellation or a hook failed. Refresh before retrying. \(reason)"
        }
    }
}
public enum LocalTextConflictChoice: String, CaseIterable, Sendable { case current, incoming, both }
public struct LocalTextConflictBlock: Identifiable, Equatable, Sendable {
    public let id: Int
    public let current: String
    public let incoming: String
    fileprivate let range: NSRange
}
public struct LocalTextConflictDocument: Sendable {
    public let text: String
    public let blocks: [LocalTextConflictBlock]
    public init(text: String) {
        self.text = text
        let source = text as NSString
        var lines: [(String, NSRange)] = [], offset = 0
        for line in text.components(separatedBy: "\n") {
            let length = (line as NSString).length
            let count = min(length + 1, source.length - offset)
            lines.append((line, NSRange(location: offset, length: count))); offset += count
        }
        var result: [LocalTextConflictBlock] = [], i = 0
        while i < lines.count {
            guard Self.marker(lines[i].0, character: "<") else { i += 1; continue }
            let start = i; var separator: Int?, base: Int?, end: Int?
            i += 1
            while i < lines.count {
                if Self.marker(lines[i].0, character: "<") { break }
                if Self.marker(lines[i].0, character: "|") && separator == nil { base = i }
                if Self.marker(lines[i].0, character: "=") { separator = i }
                if Self.marker(lines[i].0, character: ">") { end = i; break }
                i += 1
            }
            guard let separator, let end, separator < end else { continue }
            let aStart = NSMaxRange(lines[start].1), aEnd = lines[base ?? separator].1.location
            let bStart = NSMaxRange(lines[separator].1), bEnd = lines[end].1.location
            result.append(.init(id: result.count, current: source.substring(with: NSRange(location: aStart, length: aEnd - aStart)), incoming: source.substring(with: NSRange(location: bStart, length: bEnd - bStart)), range: NSRange(location: lines[start].1.location, length: NSMaxRange(lines[end].1) - lines[start].1.location)))
            i += 1
        }
        blocks = result
    }
    public func resolving(_ choices: [Int: LocalTextConflictChoice]) -> String {
        let result = NSMutableString(string: text)
        for block in blocks.reversed() {
            guard let choice = choices[block.id] else { continue }
            let replacement: String
            switch choice { case .current: replacement = block.current; case .incoming: replacement = block.incoming; case .both: replacement = block.current + block.incoming }
            result.replaceCharacters(in: block.range, with: replacement)
        }
        return result as String
    }
    /// Conservative: standalone marker-shaped lines require editor/Terminal resolution too.
    public static func containsMarkers(_ text: String) -> Bool {
        text.components(separatedBy: "\n").contains { line in ["<", "=", ">", "|"].contains { marker(line, character: $0) } }
    }
    private static func marker(_ line: String, character: Character) -> Bool {
        let prefix = line.prefix { $0 == character }
        guard prefix.count >= 7 else { return false }
        let rest = line.dropFirst(prefix.count)
        return rest.isEmpty || rest.first == " " || rest.first == "\r" || rest.first == "\t"
    }
}
extension LocalGitService {
    public func conflictDocument(path: String, directory: URL) async throws -> LocalGitConflictDocument {
        try await transaction(directory: directory) { service in
            let snapshot = try await service.readSnapshot(directory: directory)
            let document = try await service.readConflictDocument(path: path, snapshot: snapshot)
            try service.checkExpected(snapshot, fresh: try await service.readSnapshot(directory: directory))
            let pathHandle = try ConflictPath(root: snapshot.repository.directory, path: path); defer { pathHandle.close() }
            guard try pathHandle.read().identity == document.workingIdentity else { throw LocalGitMutationError.staleSnapshot }
            return document
        }
    }
    public func resolveConflict(document: LocalGitConflictDocument, resolution: LocalGitConflictResolution, directory: URL) async throws -> LocalGitSnapshot {
        try await transaction(directory: directory) { service in
            let fresh = try await service.readSnapshot(directory: directory)
            try service.checkExpected(document.snapshot, fresh: fresh)
            let current = try await service.readConflictDocument(path: document.path, snapshot: fresh)
            guard current == document else { throw LocalGitMutationError.staleSnapshot }
            let text: String?
            switch resolution {
            case .text(let value): text = value
            case .current: text = document.current?.text
            case .incoming: text = document.incoming?.text
            case .delete: text = nil
            }
            if let text {
                _ = try Self.conflictText(Data(text.utf8))
                guard !LocalTextConflictDocument.containsMarkers(text) else { throw LocalGitConflictError.remainingMarkers }
            }
            // Fail policy admission before touching the user's result, without suppressing hooks.
            try await service.preflightHooks(Self.indexHooks, directory: fresh.repository.directory)
            let unrelated = try await service.unrelatedConflictWorktree(snapshot: fresh, path: document.path)
            try service.checkExpected(fresh, fresh: try await service.readSnapshot(directory: directory))
            guard try await service.readConflictDocument(path: document.path, snapshot: fresh) == current else { throw LocalGitMutationError.staleSnapshot }
            try service.checkExpected(fresh, fresh: try await service.readSnapshot(directory: directory))
            try Task.checkCancellation()
            let root = fresh.repository.directory
            try service.authorize(root.appendingPathComponent(document.path), directory: root)
            let selected = try ConflictPath(root: root, path: document.path)
            defer { selected.close() }
            guard try selected.read().identity == document.workingIdentity else { throw LocalGitMutationError.staleSnapshot }
            let side = resolution == .incoming ? document.incoming : document.current
            try selected.replace(text: text, expected: document.workingIdentity, mode: side?.mode == "100755" ? 0o755 : 0o644)
            do {
                let saved = try selected.read()
                let after = try await service.readSnapshot(directory: directory)
                guard after.repository.id == fresh.repository.id, after.status.head == fresh.status.head,
                      after.status.branch == fresh.status.branch, after.indexToken == fresh.indexToken,
                      after.operation == fresh.operation, after.branches == fresh.branches,
                      after.stashes == fresh.stashes, after.repository.worktrees == fresh.repository.worktrees,
                      try await service.unrelatedConflictWorktree(snapshot: after, path: document.path) == unrelated else { throw LocalGitMutationError.staleSnapshot }
                // Git consumes this pathname; reopen all components before admitting that command.
                let recheck = try ConflictPath(root: root, path: document.path); defer { recheck.close() }
                guard try recheck.read().identity == saved.identity else { throw LocalGitMutationError.staleSnapshot }
                try Task.checkCancellation()
                _ = try await service.command(["--literal-pathspecs", "add", "--", document.path], directory: root)
                let resolved = try await service.readSnapshot(directory: directory)
                guard !resolved.status.entries.contains(where: { $0.path == document.path && $0.isUnmerged }) else { throw LocalGitMutationError.staleSnapshot }
                return resolved
            } catch {
                // No automatic rollback: it could overwrite an external editor's subsequent work.
                let reason = error is CancellationError ? "Cancelled after saving." : (error as? LocalGitMutationError)?.localizedDescription ?? "Inspect Local status or use Terminal to finish staging."
                throw LocalGitConflictError.savedButNotStaged(reason)
            }
        }
    }
    private static let conflictLimit = 2 * 1024 * 1024
    private static func conflictText(_ data: Data) throws -> String {
        guard data.count <= conflictLimit else { throw LocalGitMutationError.oversizedFile }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { throw LocalGitConflictError.binaryOrInvalidText }
        return text
    }
    private func readConflictDocument(path: String, snapshot: LocalGitSnapshot) async throws -> LocalGitConflictDocument {
        try validatePaths([path], snapshot: snapshot)
        guard !path.split(separator: "/").contains(where: { $0.lowercased() == ".git" }), snapshot.status.entries.contains(where: { $0.path == path && $0.isUnmerged }) else { throw LocalGitMutationError.invalidTarget }
        let root = snapshot.repository.directory
        let selected = try ConflictPath(root: root, path: path); defer { selected.close() }
        let working = try selected.read()
        let workingText = try working.data.map { try Self.conflictText($0) }
        let output = try await read(["--literal-pathspecs", "ls-files", "--unmerged", "-z", "--", path], directory: root)
        var sides: [Int: LocalGitConflictSide] = [:]
        for record in output.standardOutput.split(separator: 0) {
            guard let tab = record.firstIndex(of: 9), String(data: Data(record[record.index(after: tab)...]), encoding: .utf8) == path,
                  let header = String(data: Data(record[..<tab]), encoding: .utf8) else { throw LocalGitError.malformedOutput }
            let fields = header.split(separator: " ")
            guard fields.count == 3, let stage = Int(fields[2]), (1...3).contains(stage), sides[stage] == nil,
                  [40, 64].contains(fields[1].count), fields[1].allSatisfy(\.isHexDigit) else { throw LocalGitError.malformedOutput }
            guard fields[0] == "100644" || fields[0] == "100755" else { throw LocalGitMutationError.unsupportedFileType }
            let object = String(fields[1])
            let size = try await text(["cat-file", "-s", object], directory: root)
            guard let count = Int(size), count >= 0 else { throw LocalGitError.malformedOutput }
            guard count <= Self.conflictLimit else { throw LocalGitMutationError.oversizedFile }
            let blob = try await read(["cat-file", "blob", object], directory: root)
            sides[stage] = .init(stage: stage, objectID: object, mode: String(fields[0]), text: try Self.conflictText(blob.standardOutput))
        }
        guard !sides.isEmpty else { throw LocalGitMutationError.staleSnapshot }
        return .init(path: path, snapshot: snapshot, base: sides[1], current: sides[2], incoming: sides[3], workingText: workingText, workingIdentity: working.identity)
    }
    private func unrelatedConflictWorktree(snapshot: LocalGitSnapshot, path: String) async throws -> String {
        let paths = snapshot.status.entries.filter { $0.path != path && !$0.isUntracked }.map(\.path)
        var data = Data()
        if !paths.isEmpty {
            data.append(try await read(["--literal-pathspecs", "diff", "--no-ext-diff", "--no-textconv", "--binary", "--"] + paths, directory: snapshot.repository.directory).standardOutput)
        }
        for entry in snapshot.status.entries where entry.path != path && entry.isUntracked {
            data.append(Data(entry.path.utf8))
            let url = snapshot.repository.directory.appendingPathComponent(entry.path)
            if let link = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) { data.append(Data(link.utf8)) }
            else if !entry.path.hasSuffix("/") { data.append(try readRegularFile(url, directory: snapshot.repository.directory)) }
        }
        data.append(try JSONEncoder.stable.encode(snapshot.status.entries.filter { $0.path != path }))
        return Self.digest(data)
    }
}

/// Anchor at the authorized canonical repository: sandbox grants permit opening that directory,
/// but do not grant directory reads on all its ancestors. Relative parents and the final leaf
/// remain no-follow; canonicalizing a conflict leaf would silently accept symlink conflicts.
private struct ConflictPath {
    let parent: Int32
    let leaf: String
    init(root: URL, path: String) throws {
        var original = stat()
        guard root.isFileURL, lstat(root.path, &original) == 0, original.st_mode & S_IFMT == S_IFDIR else { throw LocalGitMutationError.unsupportedFileType }
        // System ancestors such as /var may be aliases. Resolve those before opening the
        // granted root, while lstat above rejects a symlink at the repository root itself.
        let canonical = try LocalGitPathAccess.canonicalURL(root)
        let components = path.split(separator: "/").dropLast().map(String.init)
        var descriptor = Darwin.open(canonical.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw LocalGitMutationError.unsupportedFileType }
        do {
            var opened = stat()
            guard fstat(descriptor, &opened) == 0, opened.st_dev == original.st_dev, opened.st_ino == original.st_ino else { throw LocalGitMutationError.staleSnapshot }
            for component in components {
                let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw LocalGitMutationError.unsupportedFileType }
                Darwin.close(descriptor); descriptor = next
            }
            parent = descriptor; leaf = String(path.split(separator: "/").last!)
        } catch { Darwin.close(descriptor); throw error }
    }
    func close() { Darwin.close(parent) }
    func read() throws -> (data: Data?, identity: String, mode: mode_t?) {
        let descriptor = openat(parent, leaf, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT { return (nil, "missing", nil) }
            throw LocalGitMutationError.unsupportedFileType
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true); defer { try? handle.close() }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1 else { throw LocalGitMutationError.unsupportedFileType }
        guard before.st_size <= 2 * 1024 * 1024 else { throw LocalGitMutationError.oversizedFile }
        var data = Data()
        while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
            try Task.checkCancellation(); data.append(chunk)
            guard data.count <= 2 * 1024 * 1024 else { throw LocalGitMutationError.oversizedFile }
        }
        var after = stat(); guard fstat(descriptor, &after) == 0, Self.metadata(before) == Self.metadata(after) else { throw LocalGitMutationError.staleSnapshot }
        return (data, Self.metadata(after) + ":" + LocalGitService.digest(data), before.st_mode & 0o777)
    }
    private static func metadata(_ s: stat) -> String {
        "\(s.st_dev):\(s.st_ino):\(s.st_mode):\(s.st_size):\(s.st_mtimespec.tv_sec):\(s.st_mtimespec.tv_nsec):\(s.st_ctimespec.tv_sec):\(s.st_ctimespec.tv_nsec)"
    }
    func replace(text: String?, expected: String, mode: mode_t) throws {
        let original = try read()
        guard original.identity == expected else { throw LocalGitMutationError.staleSnapshot }
        guard let text else {
            if original.data != nil { guard unlinkat(parent, leaf, 0) == 0 else { throw LocalGitMutationError.invalidTarget } }
            return
        }
        let temporary = ".mergepro-resolution-\(UUID().uuidString)"
        let descriptor = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw LocalGitMutationError.invalidTarget }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); unlinkat(parent, temporary, 0) }
        guard fchmod(descriptor, original.mode ?? mode) == 0 else { throw LocalGitMutationError.invalidTarget }
        try handle.write(contentsOf: Data(text.utf8)); try handle.synchronize()
        guard try read().identity == expected else { throw LocalGitMutationError.staleSnapshot }
        try Task.checkCancellation()
        guard renameat(parent, temporary, parent, leaf) == 0 else { throw LocalGitMutationError.invalidTarget }
    }
}
