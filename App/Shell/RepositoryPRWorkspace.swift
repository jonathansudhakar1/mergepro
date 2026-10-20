import MergeProCore
import SwiftUI

/// Reuses the review workspace while keeping a repository tab's scope separate from the main board.
struct RepositoryPRWorkspace: View {
    let setup: SetupModel
    let repository: RepositoryKey
    @State private var workspace: PRWorkspaceModel
    init(setup:SetupModel,repository:RepositoryKey) {
        self.setup = setup; self.repository = repository
        _workspace = State(initialValue:PRWorkspaceModel(storage:setup.featureStorage,persistsWorkspace:false,repositoryScope:repository))
    }
    var body:some View {
        PRWorkspaceView(setup:setup,workspace:workspace,embedded:true)
            .task(id:repository) {
                // Cached rows first: a repository-scoped read, no network.
                await workspace.load()
                workspace.state = PRViewState()
                workspace.state.accountFilter = repository.account
                // Always replace the filter text load() copied from the main workspace.
                workspace.filterText = workspace.repositories.first(where:{ $0.key == repository }).map { "repo:\($0.name)" } ?? ""
                workspace.applyFilter()
                // A fresh stored inventory returns without a request; progress appears only while a provider read runs.
                let progress=Task { @MainActor in
                    try? await Task.sleep(for:.milliseconds(300))
                    if !Task.isCancelled { workspace.status = "Refreshing repository pull requests…" }
                }
                defer { progress.cancel() }
                do {
                    let result=try await setup.featureStorage.refreshRepositoryPRs(repository)
                    progress.cancel()
                    guard !Task.isCancelled else { return }
                    if result.didFetch { await workspace.reload() }
                    workspace.status=result.status.failureMessage ?? (result.status.complete ? nil : "Partial repository inventory; more results will load on the next refresh.")
                    // Only a fetched or failed read is news; a fresh cache returns silently.
                    if let status=workspace.status { AccessibilityNotification.Announcement(status).post() }
                    else if result.didFetch { AccessibilityNotification.Announcement("Repository pull requests refreshed.").post() }
                } catch {
                    progress.cancel()
                    if !Task.isCancelled {
                        workspace.status="Repository pull requests could not refresh. Cached rows remain available."
                        AccessibilityNotification.Announcement("Repository pull requests could not refresh. Cached rows remain available.").post()
                    }
                }
            }
            // On screen: keeps this repository on the faster polling cadence while the tab is visible.
            .modifier(FocusedRepositories(storage:setup.featureStorage,repositories:[repository]))
            // Only a completed poll cycle can change the stored rows; a newer cycle or leaving the tab cancels the reload.
            .onChangeTask(of:setup.pollRevision) { _ in await workspace.reload() }
    }
}

struct RepositoryActionsWorkspace:View {
    let setup:SetupModel
    let repository:RepositoryKey
    @State private var repositories:[Repository] = []
    @State private var visibilityID=UUID()
    var body:some View {
        ActionsView(storage:setup.featureStorage,repositories:repositories,accountFilter:repository.account,repositoryFilter:repository,embedded:true,
            onOpenAnnotation:{ repo,ref,path,line in setup.showRepository(.init(repository:repo.key,ref:ref,path:path,section:"code",line:line)) },refreshID:setup.pollRevision)
            .task(id:repository) {
                let snapshots = await AppLog.value(AppLog.storage, "Repositories for the Actions tab could not be read", fallback:[]) { try await setup.featureStorage.load().0 }
                repositories = snapshots.flatMap(\.repositories).filter { $0.key == repository }
            }
            .task(id:repository) { await setup.featureStorage.registerVisibleActions(visibilityID,repository:repository) }
            .onAppear { setup.visibleActionViews += 1 }
            .onDisappear { setup.visibleActionViews = max(0,setup.visibleActionViews-1);Task { await setup.featureStorage.registerVisibleActions(visibilityID,repository:nil) } }
    }
}

/// Lifetime-scoped browsing reads join the existing collector without changing tracked repositories.
struct VisibleActionsRepository:ViewModifier {
    let storage:SetupStorage
    let repository:RepositoryKey?
    @State private var id=UUID()
    func body(content:Content)->some View {
        content.task(id:repository) { await storage.registerVisibleActions(id,repository:repository) }
            .onDisappear { Task { await storage.registerVisibleActions(id,repository:nil) } }
    }
}

/// Repositories on screen keep the fast polling cadence (PollRequest.focusedRepositories) while the view is visible.
/// Cadence only: unlike `VisibleActionsRepository`, an untracked repository is never added to the collector.
struct FocusedRepositories:ViewModifier {
    let storage:SetupStorage
    let repositories:Set<RepositoryKey>
    @State private var id=UUID()
    func body(content:Content)->some View {
        content.task(id:repositories) { await storage.registerFocusedRepositories(id,repositories:repositories) }
            .onDisappear { Task { await storage.registerFocusedRepositories(id,repositories:[]) } }
    }
}
