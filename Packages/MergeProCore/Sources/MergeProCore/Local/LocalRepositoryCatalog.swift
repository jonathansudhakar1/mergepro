import Foundation

public struct LocalRepositoryCatalog: Equatable, Sendable {
    public let repositories: [LocalRepository]
    public let issues: [LocalRepositoryCatalogIssue]
    public let isTruncated: Bool
    public let inspectedDirectories: Int
}
public struct LocalRepositoryCatalogIssue: Identifiable, Equatable, Sendable {
    public var id: String { directory.path }
    public let directory: URL
    public let requiredAccessURL: URL?
    public let message: String
}
public extension LocalRepositoryReader {
    /// Searches only the selected grant, stops at recognized repositories and never follows
    /// directory symlinks. Both directory visits and entry enumeration have fixed budgets.
    func discoverWithin(root: URL, authorizedRoots: [URL], maximumDepth: Int = 4, maximumDirectories: Int = 2000) async throws -> LocalRepositoryCatalog {
        guard maximumDepth >= 0, maximumDirectories > 0 else { throw LocalGitError.invalidPath }
        try LocalGitPathAccess.requireAuthorized(root, roots: authorizedRoots)
        let root = try LocalGitPathAccess.canonicalURL(root)
        let depthLimit = min(maximumDepth, 12), directoryLimit = min(maximumDirectories, 2000)
        var queue: [(URL, Int)] = [(root, 0)], cursor = 0, inspected = 0, entryCount = 0
        var repositories: [LocalRepositoryID: LocalRepository] = [:], issues: [LocalRepositoryCatalogIssue] = []
        var truncated = false
        while cursor < queue.count {
            try Task.checkCancellation()
            guard inspected < directoryLimit else { truncated = true; break }
            let (directory, depth) = queue[cursor]; cursor += 1; inspected += 1
            try LocalGitPathAccess.requireAuthorized(directory, roots: [root])
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) {
                do {
                    let repository = try await discover(directory: directory, authorizedRoots: authorizedRoots)
                    let isPrimary = try LocalGitPathAccess.canonicalURL(repository.gitDirectory) == LocalGitPathAccess.canonicalURL(repository.commonDirectory)
                    if repositories[repository.id] == nil || isPrimary { repositories[repository.id] = repository }
                } catch {
                    let access: URL?
                    if case LocalGitError.authorizationRequired(let target) = error { access = target } else { access = nil }
                    let message = (error as? LocalizedError)?.errorDescription ?? "Repository discovery failed. Open this folder in Terminal."
                    issues.append(.init(directory: directory, requiredAccessURL: access, message: message))
                }
                continue
            }
            var enumerationFailed = false
            guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants], errorHandler: { _, _ in enumerationFailed = true; return false }) else {
                issues.append(.init(directory: directory, requiredAccessURL: directory, message: "This folder could not be enumerated. Renew its folder access.")); continue
            }
            while let child = enumerator.nextObject() as? URL {
                try Task.checkCancellation()
                entryCount += 1
                guard entryCount <= directoryLimit * 10 else { truncated = true; break }
                guard !["node_modules", ".build", ".git", "vendor"].contains(child.lastPathComponent) else { continue }
                do {
                    let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    guard values.isSymbolicLink != true, values.isDirectory == true else { continue }
                    try LocalGitPathAccess.requireAuthorized(child, roots: [root])
                    if depth >= depthLimit || queue.count >= directoryLimit { truncated = true; continue }
                    queue.append((child, depth + 1))
                } catch { enumerationFailed = true }
            }
            if enumerationFailed { issues.append(.init(directory: directory, requiredAccessURL: directory, message: "Some folder metadata could not be read. Renew folder access.")) }
            if entryCount > directoryLimit * 10 { break }
        }
        return .init(repositories: repositories.values.sorted { $0.directory.path.localizedStandardCompare($1.directory.path) == .orderedAscending }, issues: issues, isTruncated: truncated, inspectedDirectories: inspected)
    }
}
public extension LocalRepositoryCatalog {
    /// Reading status can run programs from a repository's own configuration (filters, for example), so a discovered
    /// repository opens only once chosen: the user's explicit selection, or the authorized folder when it is the repository.
    func repositoryToOpen(selected: URL?, authorizedFolder: URL) -> LocalRepository? {
        if let selected, let match = repositories.first(where: { $0.directory == selected }) { return match }
        guard let folder = try? LocalGitPathAccess.canonicalURL(authorizedFolder).path else { return nil }
        return repositories.first { (try? LocalGitPathAccess.canonicalURL($0.directory).path) == folder }
    }
}
