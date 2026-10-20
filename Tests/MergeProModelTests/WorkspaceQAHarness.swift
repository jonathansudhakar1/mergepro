import AppKit
import Foundation
import MergeProCore
@testable import MergeProFixtures

/// Exercises actual App models and storage against finite offline data, without starting App.main.
@main struct WorkspaceQAHarness {
    @MainActor static func main() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MERGEPRO_UI_TEST_NAMESPACE"].flatMap(UUID.init(uuidString:)) != nil,
              environment["MERGEPRO_PHASE23_FIXTURES"] == "1", NSApp == nil else {
            throw CocoaError(.fileReadNoPermission)
        }
        let storage = SetupStorage()
        let localRepository=LocalRepositoryID(rawValue:"fixture-repository")
        let localWorktree=LocalWorktreeID(rawValue:"fixture-worktree")
        let localOther=LocalWorktreeID(rawValue:"fixture-other-worktree")
        try await storage.saveLocalOperationState(repository:localRepository,worktree:localWorktree,state:.conflicts(operation:"rebase",paths:["fixture.swift"]))
        try await storage.saveLocalOperationState(repository:localRepository,worktree:localOther,state:.running(name:"merge"))
        let reloadedStorage=SetupStorage()
        let recovered=try await reloadedStorage.localOperationState(repository:localRepository,worktree:localWorktree)
        guard recovered == .conflicts(operation:"rebase",paths:["fixture.swift"]) else { throw CocoaError(.coderReadCorrupt) }
        try await reloadedStorage.saveLocalOperationState(repository:localRepository,worktree:localWorktree,state:.idle)
        let cleared=try await storage.localOperationState(repository:localRepository,worktree:localWorktree)
        let other=try await storage.localOperationState(repository:localRepository,worktree:localOther)
        guard cleared == nil,other == .running(name:"merge") else { throw CocoaError(.coderReadCorrupt) }
        print("PASS actual Local recovery hints persist across storage reload and clear only the recovered worktree")
        let snapshots = try await storage.load().0
        let repository = try require(snapshots.first?.repositories.first { $0.key.repositoryID == "7" })
        let prs = PRWorkspaceModel(storage: storage, persistsWorkspace: false, repositoryScope: repository.key)
        await prs.load()
        prs.filterText = ""
        prs.applyFilter()
        prs.state.current.timeScope = .allTime
        guard prs.rows.count == 1, prs.projection.rows.count == 1,
              prs.rows.allSatisfy({ $0.key.repository == repository.key }) else {
            throw CocoaError(.coderReadCorrupt)
        }
        print("PASS actual scoped PR model keeps account/repository when editable filter is cleared")

        let actions = ActionsWorkspaceModel()
        await actions.load(storage: storage, repositories: snapshots.flatMap(\.repositories))
        guard actions.runs.count == 8, actions.runs.filter(\.isActive).count == 4,
              actions.catalogs.count == 4, actions.errors.isEmpty else {
            print("Actions errors: \(actions.errors)")
            throw CocoaError(.coderReadCorrupt)
        }
        let service = try await storage.actionsService()
        let run = try require(actions.runs.first { $0.repository.key == repository.key })
        let detail = try await service.detail(run: run)
        guard detail.jobs.count == 1, detail.annotations.count == 1, detail.artifacts.count == 1,
              detail.unavailableSections.isEmpty else { throw CocoaError(.coderReadCorrupt) }
        let workflow = try require(actions.catalogs[repository.key]?.workflows.first)
        let schema = try await service.schema(repository: repository, workflow: workflow, ref: "main")
        guard schema.inputs.count == 5, Set(schema.inputs.map(\.kind)).count == 5 else {
            throw CocoaError(.coderReadCorrupt)
        }
        print("PASS actual Actions model/service: scoped attempts, detail sections and all five input types")

        var logRequest = ActionsLogRequestState()
        let older = logRequest.begin()
        let newer = logRequest.begin()
        logRequest.finish(older)
        guard logRequest.isLoading, logRequest.accepts(newer), !logRequest.accepts(older) else {
            throw CocoaError(.coderReadCorrupt)
        }
        // A partial run refresh removes the selected job while its download is still pending.
        logRequest.invalidate()
        guard !logRequest.isLoading, !logRequest.accepts(newer) else { throw CocoaError(.coderReadCorrupt) }
        let reselected = logRequest.begin()
        logRequest.finish(newer)
        guard logRequest.isLoading, logRequest.accepts(reselected) else { throw CocoaError(.coderReadCorrupt) }
        logRequest.finish(reselected)
        guard !logRequest.isLoading else { throw CocoaError(.coderReadCorrupt) }
        print("PASS log selection removal and out-of-order downloads cannot strand or hide current loading")

        let repos = ReposModel()
        await repos.load(storage: storage, route: .init(repository: repository.key, ref: "main", path: "Sources/BuildStatus.swift"))
        await repos.open()
        let immutable = try require(repos.ref)
        guard repos.entries.count == 240, immutable.commitSHA == Phase23Fixtures.sha,
              repos.selected == repository.key, repos.error == nil else {
            print("Repos error: \(String(describing: repos.error))")
            throw CocoaError(.coderReadCorrupt)
        }
        let browser = try await storage.repositoryBrowserService()
        let hiddenNode = try require(repos.tree.allNodes.first { $0.repository?.key == repository.key && $0.id.group == "catalog" })
        repos.tree.selection = hiddenNode.id
        repos.tree.scrollAnchor = hiddenNode.id
        repos.tree.expanded = Set(repos.tree.allNodes.filter { $0.repository == nil }.map(\.id))
        repos.filter.search = "library"
        repos.tree.search = repos.filter.search
        let savedTree = repos.tree.persistence
        let visibleEntry = try require(repos.visible.first)
        await repos.pin(visibleEntry)
        guard repos.tree.persistence == savedTree, repos.tree.search == "library",
              repos.tree.allNodes.contains(where: { $0.id == hiddenNode.id }), repos.error == nil else {
            throw CocoaError(.coderReadCorrupt)
        }
        print("PASS pin during catalog search preserves hidden selection, expansion and scroll anchor")
        let tree = RefTreeStore(provider: browser)
        let entry = try require(repos.repository)
        try await tree.switchRef(repository: entry, ref: immutable, preserving: "Sources/BuildStatus.swift")
        try await tree.reveal("Sources/BuildStatus.swift")
        let state = await tree.snapshot()
        guard state.selection == "Sources/BuildStatus.swift", state.entries.contains(where: { $0.path == state.selection }) else {
            throw CocoaError(.coderReadCorrupt)
        }
        guard NSApp == nil else { throw CocoaError(.fileReadNoPermission) }
        print("PASS actual Repos model/service: 240 scoped paginated catalog entries and immutable lazy path reveal")
        print("QA PASS: offline App model checks; no NSApplication, real credentials, provider writes or physical UI claims")
    }

    private static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw CocoaError(.coderReadCorrupt) }
        return value
    }
}
