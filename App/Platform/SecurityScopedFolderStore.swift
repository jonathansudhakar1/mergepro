import AppKit
import Foundation
import Observation
import MergeProCore

struct AuthorizedLocalFolder: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var path: String
    var bookmarkData: Data
}

/// The platform boundary for opaque bookmarks and balanced access leases.
@MainActor struct FolderBookmarkAccess {
    var resolve: (Data) throws -> (url: URL, stale: Bool)
    var bookmark: (URL) throws -> Data
    var start: (URL) -> Bool
    var stop: (URL) -> Void
    static let system = FolderBookmarkAccess(
        resolve: { data in
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
            return (url, stale)
        },
        bookmark: { try $0.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) },
        start: { $0.startAccessingSecurityScopedResource() },
        stop: { $0.stopAccessingSecurityScopedResource() })
}

enum LocalFolderAccessError: LocalizedError {
    case missingFolder, reauthorize(String), unavailablePath(String)
    var errorDescription: String? {
        switch self {
        case .missingFolder: "Choose an authorized local folder first."
        case .reauthorize(let path): "Access to \(path) is unavailable. Select that folder again to renew permission."
        case .unavailablePath(let path): "Git also requires access to \(path). Select that exact folder, then refresh."
        }
    }
}

@MainActor @Observable final class SecurityScopedFolderStore {
    private(set) var folders: [AuthorizedLocalFolder] = []
    private(set) var authorizationIssues: [UUID: String] = [:]
    private let loadData: @Sendable () async throws -> Data?
    private let saveData: @Sendable (Data) async throws -> Void
    private let access: FolderBookmarkAccess
    private var loaded = false
    private var persistenceOwner: UUID?
    private var persistenceWaiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    init(load: @escaping @Sendable () async throws -> Data?, save: @escaping @Sendable (Data) async throws -> Void,
         access: FolderBookmarkAccess = .system) {
        loadData = load; saveData = save; self.access = access
    }

    func load() async throws {
        let token = UUID()
        try await acquirePersistence(token)
        defer { releasePersistence(token) }
        guard !loaded else { return }
        try Task.checkCancellation()
        let data = try await loadData()
        folders = try data.map { try JSONDecoder().decode([AuthorizedLocalFolder].self, from: $0) } ?? []
        loaded = true
    }

    /// A picker grant is retained only after its opaque bookmark is durably saved.
    func chooseFolder(replacing id: UUID? = nil, message: String? = nil) async throws -> UUID? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.prompt = id == nil ? "Add folder" : "Authorize folder"
        panel.message = message ?? "Select a local Git repository or a parent folder you want MergePro to access."
        if let existing = folders.first(where: { $0.id == id }) { panel.directoryURL = URL(fileURLWithPath: existing.path) }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let started = access.start(url)
        defer { if started { access.stop(url) } }
        let canonical = try LocalGitPathAccess.canonicalURL(url)
        let existing = folders.first(where: { (try? LocalGitPathAccess.canonicalURL(URL(fileURLWithPath: $0.path))) == canonical })
        let folder = AuthorizedLocalFolder(id: existing?.id ?? id ?? UUID(), name: url.lastPathComponent, path: canonical.path, bookmarkData: try access.bookmark(url))
        try await persistFolder(folder)
        authorizationIssues[folder.id] = nil
        return folder.id
    }

    func authorizationIssue(for id: UUID) -> String? { authorizationIssues[id] }

    func withAccess<T: Sendable>(id: UUID, operation: @Sendable (URL) async throws -> T) async throws -> T {
        guard let folder = folders.first(where: { $0.id == id }) else { throw LocalFolderAccessError.missingFolder }
        let url = try await acquire(folder)
        defer { access.stop(url) }
        return try await operation(url)
    }

    /// Linked worktrees may require several separately granted roots. Hold every valid
    /// lease for the entire command; invalid grants never become authorized paths.
    func withAllAccess<T: Sendable>(operation: @Sendable ([URL]) async throws -> T) async throws -> T {
        var roots: [URL] = []
        defer { for url in roots.reversed() { access.stop(url) } }
        for folder in folders {
            try Task.checkCancellation()
            do { roots.append(try await acquire(folder)) }
            catch is CancellationError { throw CancellationError() }
            catch { authorizationIssues[folder.id] = error.localizedDescription }
        }
        try Task.checkCancellation()
        return try await operation(roots)
    }

    private func acquire(_ folder: AuthorizedLocalFolder) async throws -> URL {
        do {
            let resolved = try access.resolve(folder.bookmarkData)
            guard access.start(resolved.url) else { throw LocalFolderAccessError.reauthorize(folder.path) }
            do {
                if resolved.stale {
                    let bookmark = try access.bookmark(resolved.url)
                    var renewed = folder
                    renewed.bookmarkData = bookmark
                    renewed.path = try LocalGitPathAccess.canonicalURL(resolved.url).path
                    try await persistFolder(renewed, replacingBookmark: folder.bookmarkData)
                }
                try Task.checkCancellation()
                authorizationIssues[folder.id] = nil
                return resolved.url
            } catch { access.stop(resolved.url); throw error }
        } catch {
            authorizationIssues[folder.id] = error.localizedDescription
            throw error
        }
    }

    /// Only durable grant updates are serialized. Long-running Git leases remain independent.
    private func persistFolder(_ folder: AuthorizedLocalFolder, replacingBookmark: Data? = nil) async throws {
        let token = UUID()
        try await acquirePersistence(token)
        defer { releasePersistence(token) }
        try Task.checkCancellation()
        var next = folders
        if let index = next.firstIndex(where: { $0.id == folder.id }) {
            // Another renewal or picker may already have replaced this exact bookmark.
            if let replacingBookmark, next[index].bookmarkData != replacingBookmark { return }
            next[index] = folder
        } else { next.append(folder) }
        try await saveData(JSONEncoder.stable.encode(next))
        folders = next
    }

    private func acquirePersistence(_ token: UUID) async throws {
        try Task.checkCancellation()
        if persistenceOwner == nil { persistenceOwner = token; return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { persistenceWaiters.append((token, continuation)) }
            }
        } onCancel: {
            Task { @MainActor in
                if let index = self.persistenceWaiters.firstIndex(where: { $0.id == token }) {
                    let waiter = self.persistenceWaiters.remove(at: index)
                    waiter.continuation.resume(throwing: CancellationError())
                }
            }
        }
    }

    private func releasePersistence(_ token: UUID) {
        guard persistenceOwner == token else { return }
        if persistenceWaiters.isEmpty { persistenceOwner = nil }
        else {
            let next = persistenceWaiters.removeFirst()
            persistenceOwner = next.id
            next.continuation.resume()
        }
    }

    nonisolated static func contains(_ url: URL, in root: URL) -> Bool {
        guard let path = try? LocalGitPathAccess.canonicalURL(url).pathComponents,
              let parent = try? LocalGitPathAccess.canonicalURL(root).pathComponents else { return false }
        return path.count >= parent.count && Array(path.prefix(parent.count)) == parent
    }
}
