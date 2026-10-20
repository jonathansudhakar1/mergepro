import Foundation
import MergeProCore
@testable import MergeProFixtures

@main struct LocalWorkspaceQAHarness {
    @MainActor static func main() async throws {
        let temporaryCandidate = FileManager.default.temporaryDirectory.appendingPathComponent("mergepro-local-model-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporaryCandidate, withIntermediateDirectories: true)
        let temporary = try LocalGitPathAccess.canonicalURL(temporaryCandidate)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let first = AuthorizedLocalFolder(id: UUID(), name: "First", path: temporary.appendingPathComponent("first").path, bookmarkData: Data([1]))
        let second = AuthorizedLocalFolder(id: UUID(), name: "Second", path: temporary.appendingPathComponent("second").path, bookmarkData: Data([2]))
        for folder in [first, second] { try FileManager.default.createDirectory(at: URL(fileURLWithPath: folder.path).appendingPathComponent(".git"), withIntermediateDirectories: true) }
        let data = try JSONEncoder().encode([first, second])
        let store = SecurityScopedFolderStore(load: { data }, save: { _ in }, access: .init(
            resolve: { data in (URL(fileURLWithPath: data == Data([1]) ? first.path : second.path), false) },
            bookmark: { _ in Data([1]) }, start: { _ in true }, stop: { _ in }))
        try await store.load()
        let runner = ControlledLocalGitRunner()
        let model = LocalWorkspaceModel()
        model.selectedFolder = first.id
        await runner.blockStatus(in: first.path)
        let oldRead = Task { @MainActor in await model.refresh(folderStore: store, runner: runner) }
        await runner.waitUntilBlocked()
        model.selectedFolder = second.id; model.selectedWorktree = nil
        await model.refresh(folderStore: store, runner: runner)
        await runner.release()
        await oldRead.value
        precondition(model.repository?.directory.path == second.path && model.status?.branch == "second")
        precondition(!model.loading && model.error == nil, "Late status cannot replace selected folder or strand loading")
        print("PASS actual Local model rejects a delayed prior-folder status response")

        await runner.blockDiff(path: "first.swift")
        model.selectedPath = "first.swift"
        let oldPreview = Task { @MainActor in await model.loadPreview(folderStore: store, runner: runner) }
        await runner.waitUntilBlocked()
        model.selectedPath = "second.swift"
        await model.loadPreview(folderStore: store, runner: runner)
        await runner.release()
        await oldPreview.value
        precondition(model.preview.contains("second.swift") && !model.preview.contains("first.swift") && !model.previewLoading)
        print("PASS actual Local model rejects a delayed prior-file diff response")

        model.selectedPath = "first.swift"
        await runner.blockDiff(path: "first.swift")
        let oldHunks = Task { @MainActor in await model.loadHunks(staged: false, folderStore: store, runner: runner) }
        await runner.waitUntilBlocked()
        await model.loadPreview(folderStore: store, runner: runner)
        await runner.release()
        await oldHunks.value
        precondition(model.fileDiff == nil, "A preview refresh invalidates hunks still loading for that file")
        print("PASS actual Local model invalidates hunk responses when a newer preview starts")
        model.selectedPath = "file[1].txt"
        await model.loadPreview(folderStore: store, runner: runner)
        precondition(model.preview.contains("change in file[1].txt") && !model.preview.contains("UNRELATED PATH"), "Native preview must treat tracked filenames as literal Git pathspecs")
        print("PASS actual Local native preview treats Git pathspec metacharacters as literal filenames")

        model.selectedPath = "partial.swift"; model.previewStaged = true
        await model.loadPreview(folderStore: store, runner: runner)
        precondition(model.preview.contains("STAGED CHANGES") && !model.preview.contains("WORKING TREE CHANGES"))
        await runner.blockDiff(path: "partial.swift")
        let oldMode = Task { @MainActor in await model.loadPreview(folderStore: store, runner: runner) }
        await runner.waitUntilBlocked()
        model.previewStaged = false
        await model.loadPreview(folderStore: store, runner: runner)
        await runner.release(); await oldMode.value
        precondition(model.preview.contains("WORKING TREE CHANGES") && !model.preview.contains("STAGED CHANGES"))
        print("PASS actual Local model rejects delayed prior staged-mode preview")
        await runner.failDiff(path: "first.swift")
        model.selectedPath = "first.swift"
        await model.loadPreview(folderStore: store, runner: runner)
        precondition(model.preview.isEmpty && model.error != nil, "A failed different-file preview cannot render the previously selected file")
        print("PASS actual Local model clears a prior file preview after a new-file read fails")
        model.previewStaged = nil; model.error = nil

        let catalogRoot = temporary.appendingPathComponent("catalog")
        let repoA = catalogRoot.appendingPathComponent("repo-a")
        let repoB = catalogRoot.appendingPathComponent("repo-b")
        for repo in [repoA, repoB] { try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true) }
        let parentFolder = AuthorizedLocalFolder(id: UUID(), name: "Catalog", path: catalogRoot.path, bookmarkData: Data([7]))
        let parentData = try JSONEncoder().encode([parentFolder])
        let parentStore = SecurityScopedFolderStore(load: { parentData }, save: { _ in }, access: .init(resolve: { _ in (catalogRoot, false) }, bookmark: { _ in Data([7]) }, start: { _ in true }, stop: { _ in }))
        try await parentStore.load()
        let catalogRunner = ControlledLocalGitRunner(knownRepositories: [repoA.path, repoB.path])
        let catalogModel = LocalWorkspaceModel(); catalogModel.selectedFolder = parentFolder.id
        await catalogModel.refresh(folderStore: parentStore, runner: catalogRunner)
        precondition(catalogModel.catalogRepositories.map { $0.directory.path } == [repoA.path, repoB.path], "Both child repositories must be available for explicit selection")
        let discoveryOnly = await catalogRunner.readCounts()
        precondition(catalogModel.repository == nil && catalogModel.selectedRepositoryDirectory == nil && catalogModel.needsRepositorySelection && discoveryOnly.status == 0,
                     "Discovery inside a parent folder must not open (or read the status of) a child repository the user has not selected")
        catalogModel.selectedRepositoryDirectory = catalogModel.catalogRepositories.first(where: { $0.directory.path == repoB.path })?.directory; catalogModel.selectedWorktree = nil
        await catalogModel.refresh(folderStore: parentStore, runner: catalogRunner)
        precondition(catalogModel.repository?.directory.path == repoB.path && catalogModel.status?.branch == "repo-b")
        print("PASS actual Local model discovers repositories inside an authorized parent folder")

        let failingSnapshotRunner = ControlledLocalGitRunner(knownRepositories: [repoA.path, repoB.path], snapshotFailure: repoA.path)
        let resilientCatalog = LocalWorkspaceModel(); resilientCatalog.selectedFolder = parentFolder.id
        await resilientCatalog.refresh(folderStore: parentStore, runner: failingSnapshotRunner)
        resilientCatalog.selectedRepositoryDirectory = resilientCatalog.catalogRepositories.first(where: { $0.directory.path == repoA.path })?.directory; resilientCatalog.selectedWorktree = nil
        await resilientCatalog.refresh(folderStore: parentStore, runner: failingSnapshotRunner)
        precondition(resilientCatalog.catalogRepositories.map { $0.directory.path } == [repoA.path, repoB.path] && resilientCatalog.selectedRepositoryDirectory?.path == repoA.path && resilientCatalog.error != nil, "A failed selected snapshot must preserve the catalog so another child can be selected")
        resilientCatalog.selectedRepositoryDirectory = resilientCatalog.catalogRepositories.first(where: { $0.directory.path == repoB.path })?.directory; resilientCatalog.selectedWorktree = nil
        await resilientCatalog.refresh(folderStore: parentStore, runner: failingSnapshotRunner)
        precondition(resilientCatalog.repository?.directory.path == repoB.path && resilientCatalog.error == nil)
        print("PASS actual Local model preserves healthy repository selection after another snapshot fails")

        await catalogRunner.blockDiscovery(in: repoA.path)
        catalogModel.selectedRepositoryDirectory = catalogModel.catalogRepositories.first(where: { $0.directory.path == repoA.path })?.directory; catalogModel.selectedWorktree = nil
        let oldCatalog = Task { @MainActor in await catalogModel.refresh(folderStore: parentStore, runner: catalogRunner) }
        await catalogRunner.waitUntilBlocked()
        let otherRoot = temporary.appendingPathComponent("other-catalog")
        let repoC = otherRoot.appendingPathComponent("repo-c")
        try FileManager.default.createDirectory(at: repoC.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let otherFolder = AuthorizedLocalFolder(id: UUID(), name: "Other", path: otherRoot.path, bookmarkData: Data([8]))
        let bothData = try JSONEncoder().encode([parentFolder, otherFolder])
        let bothStore = SecurityScopedFolderStore(load: { bothData }, save: { _ in }, access: .init(resolve: { data in (data == Data([7]) ? catalogRoot : otherRoot, false) }, bookmark: { _ in Data([7]) }, start: { _ in true }, stop: { _ in }))
        try await bothStore.load()
        catalogModel.selectedFolder = otherFolder.id; catalogModel.selectedRepositoryDirectory = nil; catalogModel.selectedWorktree = nil
        let otherRunner = ControlledLocalGitRunner(knownRepositories: [repoC.path])
        await catalogModel.refresh(folderStore: bothStore, runner: otherRunner)
        await catalogRunner.release()
        await oldCatalog.value
        precondition(catalogModel.catalogRepositories.map { $0.directory.path } == [repoC.path] && catalogModel.repository == nil && catalogModel.selectedRepositoryDirectory == nil && !catalogModel.loading,
                     "The delayed catalog of the previous folder must not replace the new catalog or select one of its repositories")
        catalogModel.selectedRepositoryDirectory = catalogModel.catalogRepositories.first?.directory; catalogModel.selectedWorktree = nil
        await catalogModel.refresh(folderStore: bothStore, runner: otherRunner)
        precondition(catalogModel.repository?.directory.path == repoC.path && !catalogModel.loading)
        print("PASS actual Local model rejects a delayed catalog after switching authorized folders")

        let unavailableStore = SecurityScopedFolderStore(load: { bothData }, save: { _ in }, access: .init(resolve: { data in (data == Data([7]) ? catalogRoot : otherRoot, false) }, bookmark: { _ in Data([7]) }, start: { _ in false }, stop: { _ in }))
        try await unavailableStore.load()
        let unavailableRunner = ControlledLocalGitRunner(knownRepositories: [repoC.path])
        await catalogModel.stageFile(path: "first.swift", unstage: false, folderStore: unavailableStore, runner: unavailableRunner)
        let unavailableCounts = await unavailableRunner.readCounts()
        precondition(unavailableCounts.mutations == 0 && unavailableCounts.status == 0, "Failed bookmark grants must stop commands before Core's default empty-root fallback")
        print("PASS actual Local model rejects mutation when every bookmark grant is unavailable")

        let ungranted = temporary.appendingPathComponent("ungranted/.git")
        let unauthorizedRunner = ControlledLocalGitRunner(metadata: ungranted.path)
        let denied = LocalWorkspaceModel(); denied.selectedFolder = first.id
        await denied.refresh(folderStore: store, runner: unauthorizedRunner)
        let requiredPath = try LocalGitPathAccess.canonicalURL(ungranted).path
        precondition(denied.repository == nil && denied.status == nil && denied.requiredAuthorizationPath == requiredPath)
        let counts = await unauthorizedRunner.readCounts()
        precondition(counts.worktrees == 0 && counts.status == 0, "Unrequested external metadata must stop discovery before worktree/status reads")
        print("PASS actual Local model asks for exact linked metadata permission before reading worktrees or status")
    }
}

private actor ControlledLocalGitRunner: GitRunner {
    private let metadata: String?
    private let knownRepositories: Set<String>?
    private let snapshotFailure: String?
    private var diffFailure: String?
    func failDiff(path: String) { diffFailure = path }
    private var statusBlock: String?
    private var discoveryBlock: String?
    private var diffBlock: String?
    private var gate: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var worktreesRead = 0
    private var statusRead = 0
    private var mutations = 0
    init(metadata: String? = nil, knownRepositories: Set<String>? = nil, snapshotFailure: String? = nil) { self.metadata = metadata; self.knownRepositories = knownRepositories; self.snapshotFailure = snapshotFailure }
    func blockStatus(in directory: String) { statusBlock = directory }
    func blockDiff(path: String) { diffBlock = path }
    func blockDiscovery(in directory: String) { discoveryBlock = directory }
    func waitUntilBlocked() async { if gate != nil { return }; await withCheckedContinuation { waiters.append($0) } }
    func release() { let continuation = gate; gate = nil; continuation?.resume() }
    func readCounts() -> (worktrees: Int, status: Int, mutations: Int) { (worktreesRead, statusRead, mutations) }
    private func pause() async {
        await withCheckedContinuation { continuation in
            gate = continuation
            let pending = waiters; waiters = []; for waiter in pending { waiter.resume() }
        }
    }
    /// Separates the global options in front of the subcommand: `GitReadOnlyOptions.global` on every read
    /// (`-c name=value` pairs and `--no-optional-locks`) and `--literal-pathspecs`.
    private static func split(_ arguments: [String]) -> (globals: [String], subcommand: ArraySlice<String>) {
        var index = arguments.startIndex
        while index < arguments.endIndex {
            if arguments[index] == "-c", index + 1 < arguments.endIndex { index += 2 }
            else if ["--no-optional-locks", "--literal-pathspecs"].contains(arguments[index]) { index += 1 }
            else { break }
        }
        return (Array(arguments[..<index]), arguments[index...])
    }
    func run(arguments: [String], directory: URL) async throws -> GitResult {
        let sha = String(repeating: "a", count: 40)
        var output = ""
        let (globals, subcommand) = Self.split(arguments)
        let literalPathspecs = globals.contains("--literal-pathspecs")
        let command = subcommand.first
        switch command {
        case "rev-parse":
            if discoveryBlock == directory.path { discoveryBlock = nil; await pause() }
            if let knownRepositories, !knownRepositories.contains(directory.path) { return GitResult(exitCode: 1, standardOutput: Data(), standardError: Data()) }
            output = arguments.contains("--show-toplevel") ? directory.path + "\n" : (metadata ?? directory.appendingPathComponent(".git").path) + "\n"
        case "worktree": worktreesRead += 1; output = "worktree \(directory.path)\0HEAD \(sha)\0branch refs/heads/main\0\0"
        case "status":
            if snapshotFailure == directory.path { return GitResult(exitCode: 1, standardOutput: Data(), standardError: Data()) }
            statusRead += 1
            if statusBlock == directory.path { statusBlock = nil; await pause() }
            output = "# branch.oid \(sha)\0# branch.head \(directory.lastPathComponent)\0"
            output += "1 MM N... 100644 100644 100644 \(sha) \(sha) partial.swift\0"
            for path in ["first.swift", "second.swift", "file[1].txt"] { output += "1 .M N... 100644 100644 100644 \(sha) \(sha) \(path)\0" }
        case "diff":
            let path = arguments.last ?? ""
            if diffFailure == path { diffFailure = nil; return GitResult(exitCode: 1, standardOutput: Data(), standardError: Data()) }
            if diffBlock == path { diffBlock = nil; await pause() }
            output = path == "file[1].txt" && !literalPathspecs ? "UNRELATED PATH: wildcard expansion\n" : "diff --git a/\(path) b/\(path)\n+change in \(path)\n"
        case "for-each-ref": output = arguments.contains("refs/remotes/") ? "" : "main\0\(sha)\0*\0\0\n"
        case "config":
            if arguments.contains("init.defaultBranch") { output = "main\n" }
            else { return GitResult(exitCode: 1, standardOutput: Data(), standardError: Data()) }
        case "ls-files": if snapshotFailure == directory.path { return GitResult(exitCode: 1, standardOutput: Data(), standardError: Data()) }; output = ""
        case "stash": output = ""
        case "add": mutations += 1; output = ""
        default: preconditionFailure("Unexpected fixture Git operation: \(arguments)")
        }
        return GitResult(exitCode: 0, standardOutput: Data(output.utf8), standardError: Data())
    }
}
