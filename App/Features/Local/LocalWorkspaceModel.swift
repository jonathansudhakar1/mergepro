import AppKit
import Foundation
import Observation
import MergeProCore

@MainActor @Observable final class LocalWorkspaceModel {
    var selectedFolder: UUID?
    var selectedWorktree: LocalWorktreeID?
    var selectedRepositoryDirectory: URL?
    var catalogRepositories: [LocalRepository] = []
    var catalogIssues: [LocalRepositoryCatalogIssue] = []
    var catalogIsTruncated = false
    var selectedPath: String?
    var previewStaged: Bool?
    var overview: LocalGitOverview?
    var preparingCommand = false
    var preparationID = UUID()
    var commitSuccessToken: UUID?
    var repository: LocalRepository?
    var status: GitStatusSnapshot?
    var snapshot: LocalGitSnapshot?
    var fileDiff: LocalFileDiff?
    var fileDiffStaged = false
    var hunkGeneration = UUID()
    var commandPresentation: LocalCommandPresentation?
    var mutating = false
    var message: String?
    var operationStateSink: (@Sendable (LocalRepositoryID, LocalWorktreeID, GitOperationState) async -> Void)?
    var preview = ""
    var error: String?
    var requiredAuthorizationPath: String?
    var loading = false
    var previewLoading = false
    private var generation = UUID()
    private var previewGeneration = UUID()
    private var previewTask: Task<String, Error>?
    private var cachedPreviewDirectory: URL?
    private var cachedPreviewPath: String?
    private var cachedPreviewStaged: Bool?
    private var failedDirectory: URL?
    private var catalogFolder: UUID?
    /// Selections the model already loaded or assigned itself. `LocalView` refreshes only for other values, so
    /// programmatic updates and the resets they cascade into don't start duplicate Git reads.
    private(set) var appliedFolder: UUID?
    private(set) var appliedWorktree: LocalWorktreeID?
    private(set) var appliedRepositoryDirectory: URL?
    private(set) var previewPath: String?
    private(set) var appliedPreviewStaged: Bool?
    var branches: [LocalGitBranch] { overview?.branches ?? snapshot?.branches ?? [] }
    var operation: GitOperationState { overview?.operation ?? snapshot?.operation ?? .idle }

    func markSelectionApplied() { appliedFolder = selectedFolder; appliedWorktree = selectedWorktree; appliedRepositoryDirectory = selectedRepositoryDirectory }

    var directory: URL? {
        repository?.worktrees.first(where: { $0.id == selectedWorktree })?.directory ?? repository?.directory ?? failedDirectory
    }
    /// Discovered repositories inside an authorized parent stay closed (no status read) until the user picks one.
    var needsRepositorySelection: Bool { repository == nil && selectedRepositoryDirectory == nil && !catalogRepositories.isEmpty }

    func load(folderStore: SecurityScopedFolderStore, runner: any GitRunner) async {
        do {
            try await folderStore.load()
            if selectedFolder == nil { selectedFolder = folderStore.folders.first?.id }
            await refresh(folderStore: folderStore, runner: runner)
        } catch { self.error = Self.message(for: error) }
    }

    func refresh(folderStore: SecurityScopedFolderStore, runner: any GitRunner) async {
        let token = UUID(); generation = token; previewGeneration = UUID(); previewTask?.cancel(); previewTask = nil
        markSelectionApplied()
        previewLoading = false
        fileDiff = nil; hunkGeneration = UUID()
        // A same-folder refresh keeps its catalog until the new one arrives, so the repository picker doesn't flicker.
        if catalogFolder != selectedFolder { catalogFolder = nil; catalogRepositories = []; catalogIssues = []; catalogIsTruncated = false }
        loading = true; error = nil; requiredAuthorizationPath = nil
        defer { if generation == token { loading = false } }
        guard let id = selectedFolder else { failedDirectory = nil; repository = nil; status = nil; snapshot = nil; overview = nil; catalogRepositories = []; catalogIssues = []; catalogIsTruncated = false; preview = ""; return }
        failedDirectory = folderStore.folders.first(where: { $0.id == id }).map { URL(fileURLWithPath: $0.path) }
        do {
            let preferred = selectedWorktree
            let preferredRepository = selectedRepositoryDirectory
            let sink = operationStateSink
            let value = try await folderStore.withAccess(id: id) { root in
                try await folderStore.withAllAccess { roots in
                    let reader = LocalRepositoryReader(runner: runner)
                    let catalog = try await reader.discoverWithin(root: root, authorizedRoots: roots)
                    // Status can run programs from repository configuration: never open the first discovery implicitly.
                    let chosen = catalog.repositoryToOpen(selected: preferredRepository, authorizedFolder: root)
                    await MainActor.run {
                        guard self.generation == token, !Task.isCancelled else { return }
                        self.catalogRepositories = catalog.repositories
                        self.catalogIssues = catalog.issues
                        self.catalogIsTruncated = catalog.isTruncated
                        self.catalogFolder = id
                        self.selectedRepositoryDirectory = chosen?.directory; self.appliedRepositoryDirectory = chosen?.directory
                        self.failedDirectory = chosen?.directory ?? root
                    }
                    guard let repository = chosen else {
                        return (catalog, nil as LocalWorktreeID?, nil as LocalGitOverview?)
                    }
                    let worktree = repository.worktrees.first(where: { $0.id == preferred }) ?? repository.worktrees.first(where: { $0.directory.standardizedFileURL == repository.directory.standardizedFileURL })
                    let directory = worktree?.directory ?? repository.directory
                    try Self.requireAuthorization(directory, roots: roots)
                    return (catalog, worktree?.id, try await LocalGitService(runner: runner, authorizedRoots: roots, requiresTerminalForHooks: true, operationStateSink: sink).overview(directory: directory))
                }
            }
            guard generation == token, !Task.isCancelled else { return }
            catalogRepositories = value.0.repositories; catalogIssues = value.0.issues; catalogIsTruncated = value.0.isTruncated; catalogFolder = id
            selectedWorktree = value.1; appliedWorktree = value.1; snapshot = nil; overview = value.2; repository = value.2?.repository; status = value.2?.status
            selectedRepositoryDirectory = value.0.repositories.first(where: { $0.id == repository?.id })?.directory; appliedRepositoryDirectory = selectedRepositoryDirectory
            guard let snapshot = value.2 else {
                preview = ""
                if let issue = value.0.issues.first { error = issue.message; requiredAuthorizationPath = issue.requiredAccessURL?.path }
                else if value.0.repositories.isEmpty { error = "No Git repositories were found inside this authorized folder. Select a repository folder or choose a closer parent folder." }
                return
            }
            failedDirectory = nil
            if !snapshot.status.entries.contains(where: { $0.path == selectedPath }) { selectedPath = snapshot.status.entries.first?.path; previewStaged = nil }
            if let entry = snapshot.status.entries.first(where: { $0.path == selectedPath }) {
                if previewStaged == nil { previewStaged = entry.isStaged && !entry.isUnmerged && (entry.worktreeStatus == "." || entry.worktreeStatus == " ") }
                let staged = previewStaged == true
                if staged && (!entry.isStaged || entry.isUnmerged) { previewStaged = false }
                if !staged && entry.worktreeStatus == "." && entry.isStaged { previewStaged = true }
            }
            await loadPreview(folderStore: folderStore, runner: runner)
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            self.error = Self.message(for: error); repository = nil; status = nil; snapshot = nil; overview = nil; preview = ""
            if case LocalFolderAccessError.unavailablePath(let path) = error { requiredAuthorizationPath = path }
            if case LocalGitError.authorizationRequired(let url) = error { requiredAuthorizationPath = url.path }
        }
    }

    func loadPreview(folderStore: SecurityScopedFolderStore, runner: any GitRunner) async {
        if previewLoading, previewPath == selectedPath, appliedPreviewStaged == previewStaged, cachedPreviewDirectory == directory { return }
        previewTask?.cancel()
        let token = UUID(); previewGeneration = token; previewPath = selectedPath; appliedPreviewStaged = previewStaged
        previewLoading = false
        fileDiff = nil; hunkGeneration = UUID()
        guard let directory, let path = selectedPath, let entry = status?.entries.first(where: { $0.path == path }) else { preview = ""; return }
        let mode = previewStaged
        if cachedPreviewDirectory != directory || cachedPreviewPath != path || cachedPreviewStaged != mode { preview = "" }
        cachedPreviewDirectory = directory; cachedPreviewPath = path; cachedPreviewStaged = mode
        previewLoading = true
        defer { if previewGeneration == token { previewLoading = false } }
        do {
            let task = Task {
              try await folderStore.withAllAccess { roots in
                try Self.requireAuthorization(directory, roots: roots)
                try await Self.validateMetadata(directory: directory, roots: roots, runner: runner)
                let file = directory.appendingPathComponent(path)
                try Self.requireAuthorization(file, roots: roots)
                if entry.isUntracked {
                    let service = LocalGitService(runner: runner, authorizedRoots: roots, requiresTerminalForHooks: true)
                    let data = try await service.readRegularFile(file, directory: directory, maximumBytes: 1_048_576)
                    guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { return "Binary or non-UTF-8 file. Open it in your editor." }
                    return text
                }
                var pieces: [String] = []
                if entry.isStaged && mode != false {
                    let result = try await runner.runReadOnly(arguments: ["--literal-pathspecs", "diff", "--cached", "--no-ext-diff", "--no-textconv", "--", path], directory: directory)
                    try Self.check(result)
                    guard result.standardOutput.count <= 1_048_576 else { return "This diff exceeds the 1 MB preview limit. Open it in your editor or Terminal." }
                    pieces.append("STAGED CHANGES\n" + String(decoding: result.standardOutput, as: UTF8.self))
                }
                if mode != true && entry.worktreeStatus != "." && entry.worktreeStatus != " " {
                    let result = try await runner.runReadOnly(arguments: ["--literal-pathspecs", "diff", "--no-ext-diff", "--no-textconv", "--", path], directory: directory)
                    try Self.check(result)
                    guard result.standardOutput.count <= 1_048_576 else { return "This diff exceeds the 1 MB preview limit. Open it in your editor or Terminal." }
                    pieces.append("WORKING TREE CHANGES\n" + String(decoding: result.standardOutput, as: UTF8.self))
                }
                return pieces.joined(separator: "\n\n")
              }
            }
            previewTask = task
            let output = try await task.value
            guard previewGeneration == token, self.directory == directory, selectedPath == path, previewStaged == mode, !Task.isCancelled else { return }; preview = output
        } catch { if previewGeneration == token, !Task.isCancelled { preview = ""; self.error = Self.message(for: error) } }
    }

    func cancelPreview() {
        previewGeneration = UUID(); previewTask?.cancel(); previewTask = nil; previewLoading = false
    }

    func openDirectory(terminal: Bool, folderStore: SecurityScopedFolderStore, target: URL? = nil) async {
        guard let directory = target ?? directory else { return }
        do {
            try await folderStore.withAllAccess { roots in
                try Self.requireAuthorization(directory, roots: roots)
                if terminal { try await Self.open([directory], application: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")) }
                else { await MainActor.run { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directory.path) } }
            }
        } catch { self.error = Self.message(for: error) }
    }

    func openEditor(_ editor: EditorLocation.Editor, folderStore: SecurityScopedFolderStore, target: URL? = nil, folderOnly: Bool = false, path: String? = nil) async {
        guard let directory = target ?? directory else { return }
        let selectedPath = folderOnly ? nil : (path ?? self.selectedPath)
        do {
            try await folderStore.withAllAccess { roots in
                let target = selectedPath.map { directory.appendingPathComponent($0) } ?? directory
                try Self.requireAuthorization(target, roots: roots)
                let location = try selectedPath.map { try EditorLocation(root: directory, path: $0, line: 1) }
                if editor == .xcode {
                    guard let application = await MainActor.run(body: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode") }) else { throw LocalEditorError.unavailable(editor.rawValue) }
                    try await Self.open([target], application: application)
                } else {
                    try await MainActor.run {
                        var components = URLComponents()
                        components.scheme = editor == .vscode ? "vscode" : editor == .cursor ? "cursor" : editor == .zed ? "zed" : "jetbrains"
                        components.host = editor == .jetbrains ? "idea" : "file"
                        if editor == .jetbrains { components.path = "/navigate/reference"; components.queryItems = [.init(name: "path", value: target.path)] }
                        else { components.path = target.path }
                        guard let url = location?.editorURL(editor) ?? components.url, NSWorkspace.shared.open(url) else { throw LocalEditorError.unavailable(editor.rawValue) }
                    }
                }
            }
        } catch { self.error = Self.message(for: error) }
    }

    private static func open(_ urls: [URL], application: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.open(urls, withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    nonisolated private static func requireAuthorization(_ url: URL, roots: [URL]) throws {
        guard roots.contains(where: { SecurityScopedFolderStore.contains(url, in: $0) }) else { throw LocalFolderAccessError.unavailablePath(url.path) }
    }
    nonisolated private static func validateMetadata(directory: URL, roots: [URL], runner: any GitRunner) async throws {
        try requireAuthorization(directory, roots: roots)
        for arguments in [["rev-parse", "--absolute-git-dir"], ["rev-parse", "--path-format=absolute", "--git-common-dir"]] {
            let result = try await runner.runReadOnly(arguments: arguments, directory: directory)
            try check(result)
            guard let path = String(data: result.standardOutput, encoding: .utf8), path.hasSuffix("\n") else { throw LocalGitError.malformedOutput }
            try requireAuthorization(URL(fileURLWithPath: String(path.dropLast())), roots: roots)
        }
    }
    nonisolated private static func check(_ result: GitResult) throws {
        guard result.exitCode == 0 else { throw LocalGitError.commandFailed(command: "read", exitCode: result.exitCode) }
    }
    nonisolated static func message(for error: Error) -> String {
        if error is CancellationError { return "Git command cancelled. Review the refreshed recovery state before continuing; cancellation does not abort a merge, rebase or cherry-pick." }
        if case LocalGitError.commandFailed(let command, let code) = error {
            return "Git \(command) failed (exit \(code)). Open this repository in Terminal to inspect the Git error using your existing configuration."
        }
        return error.localizedDescription
    }
}

private enum LocalEditorError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self { case .unavailable(let editor): "\(editor.capitalized) could not open this path. Verify the editor is installed or choose another editor in Settings." }
    }
}
