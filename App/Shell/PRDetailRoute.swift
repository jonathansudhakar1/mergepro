import MergeProCore
import SwiftUI

/// Next/Previous through the main workspace's current order, and in-place opening (stack layers),
/// so one PR window serves the whole review session. A nil step is unavailable.
struct PRDetailNavigation {
    var previous:(() -> Void)?
    var next:(() -> Void)?
    var open:(ProviderKey) -> Void
    /// "3 of 12" in the main workspace's order; nil when this pull request isn't in it.
    var position:String?
}
/// A newer head the window has not applied. It applies only through `apply`, an explicit click.
struct PRDetailPendingUpdate {
    let head:String
    let apply:() -> Void
}
/// Which pull request and row a detail route shows, apart from SwiftUI: same-head row changes show at once, a new
/// head waits for the explicit Update, and Next/Previous moves through the workspace order in place.
struct PRDetailRouteState:Equatable {
    /// The pull request on screen after Next/Previous or a stack layer; nil shows the scene's key.
    private(set) var current:ProviderKey?
    /// The row whose head is on screen. Same-head metadata changes replace it at once; a new head waits.
    private(set) var shown:PullRequest?
    func shownKey(_ sceneKey:ProviderKey) -> ProviderKey { current ?? sceneKey }
    /// The row to display for the workspace's latest row.
    func display(_ latest:PullRequest) -> PullRequest { shown.flatMap { $0.key == latest.key ? $0 : nil } ?? latest }
    /// The newer head waiting for Update; nil while the display is the latest head.
    func pendingHead(_ latest:PullRequest) -> String? { display(latest).headRevision == latest.headRevision ? nil : latest.headRevision.rawValue }
    /// Same pull request and head: show the fresh row (labels, state, checks). A new head is held back.
    mutating func adopt(_ latest:PullRequest?) {
        guard let latest else { return }
        if shown == nil || shown?.key != latest.key || shown?.headRevision == latest.headRevision { shown=latest }
    }
    /// The explicit Update: the window moves to the latest head, keeping its tab, file and search.
    mutating func applyUpdate(_ latest:PullRequest) { shown=latest }
    /// The scene's value changed (restoration or the navigation callback): show it.
    mutating func sceneKeyChanged() { current=nil;shown=nil }
    /// Navigates in place; false when `target` is already on screen.
    mutating func go(_ target:ProviderKey,from sceneKey:ProviderKey) -> Bool {
        guard target != shownKey(sceneKey) else { return false }
        current=target;shown=nil
        return true
    }
    /// Previous/next in the workspace order and "3 of 12"; all nil when the pull request isn't in it.
    static func steps(_ keys:[ProviderKey],at key:ProviderKey) -> (previous:ProviderKey?,next:ProviderKey?,position:String?) {
        guard let index=keys.firstIndex(of:key) else { return (nil,nil,nil) }
        return (index > 0 ? keys[index-1] : nil,index+1 < keys.count ? keys[index+1] : nil,"\(index+1) of \(keys.count)")
    }
}

/// The canonical account-scoped detail route. Invalidating workspace availability removes
/// the entire loaded private subtree immediately and cancels its structured view tasks.
/// A repository-scoped workspace is built and loaded only when the main workspace lacks the PR
/// (an untracked repository); once the main workspace has it, the scoped one is released.
/// The window keeps showing the head it opened on: a push shows "New commits — Update" instead of
/// rebuilding the window, so tab, selected file and search survive the explicit update.
struct PRDetailRoute: View {
    let key:ProviderKey
    @Bindable var workspace:PRWorkspaceModel
    /// Lets the scene's value follow in-place navigation; nil keeps the scene value fixed.
    var navigated:((ProviderKey) -> Void)?
    @State private var repositoryWorkspace:PRWorkspaceModel?
    @State private var resolving=true
    /// Which pull request and row are on screen; see `PRDetailRouteState`.
    @State private var state=PRDetailRouteState()
    init(key:ProviderKey,workspace:PRWorkspaceModel,navigated:((ProviderKey) -> Void)? = nil) { self.key=key;self.workspace=workspace;self.navigated=navigated }
    private var shownKey:ProviderKey { state.shownKey(key) }
    private var listedInWorkspace:Bool { workspace.cached(shownKey) != nil }
    /// Until the main workspace has loaded its accounts, the scoped workspace (already loaded by `resolve`) decides,
    /// so a window opened at launch doesn't flash "unavailable".
    private var available:Bool {
        let source=workspace.hasLoadedRows ? workspace : (repositoryWorkspace ?? workspace)
        return source.accounts.contains { $0.scope == shownKey.account } && !source.revoked.contains(shownKey.account)
    }
    /// One source of truth per route; the window keeps its identity when the source switches.
    private var resolved:(pr:PullRequest,workspace:PRWorkspaceModel)? {
        if let pr=workspace.cached(shownKey) { return (pr,workspace) }
        if let scoped=repositoryWorkspace,let pr=scoped.cached(shownKey) { return (pr,scoped) }
        return nil
    }
    var body: some View {
        Group {
            if available,let resolved {
                let latest=resolved.pr
                PRDetailWindow(pr:state.display(latest),storage:workspace.storage,workspace:resolved.workspace,didLoad:{ await refreshRow(in:resolved.workspace) },
                               update:state.pendingHead(latest).map { head in PRDetailPendingUpdate(head:head) { state.applyUpdate(latest) } },
                               navigation:navigation)
                    .id(shownKey)
            } else if resolving {
                ProgressView("Opening pull request…").frame(maxWidth:.infinity,maxHeight:.infinity)
            } else {
                ContentUnavailableView("Pull request unavailable in this account",systemImage:"exclamationmark.triangle",description:Text("Reconnect this account in Setup or refresh the repository."))
            }
        }.task(id:shownKey) { await resolve() }
        .onChange(of:resolved?.pr,initial:true) { _,latest in state.adopt(latest) }
        // The scene's value changed (restoration or the navigation callback): show it.
        .onChange(of:key) { state.sceneKeyChanged() }
        .onChange(of:listedInWorkspace) { _,present in if present { repositoryWorkspace=nil } }
        // Gone from the main workspace: resolve through a scoped one, cancelled if it returns or the window closes.
        .onChangeTask(of:listedInWorkspace) { present in if !present { await resolve() } }
        .onChange(of:workspace.revoked) { _,revoked in
            guard let scoped=repositoryWorkspace else { return }
            if revoked.contains(shownKey.account) { scoped.invalidateAccount(shownKey.account) } else { scoped.acceptAuthorization(shownKey.account);Task { await scoped.reload() } }
        }
        .onChange(of:workspace.accounts.map(\.scope)) { _,accounts in if !accounts.contains(shownKey.account) { repositoryWorkspace?.invalidateAccount(shownKey.account,removed:true) } }
        .onChange(of:workspace.requestedDetailTabs[shownKey],initial:true) { forwardTabRequest() }
        // The scoped model only rereads the action account on reload; follow sidebar switches immediately.
        .onChange(of:workspace.activeActionAccount) { _,account in repositoryWorkspace?.activeActionAccount = account }
        .frame(minWidth:900,minHeight:540).accessibilityIdentifier("prDetailWindow")
    }
    private var navigation:PRDetailNavigation {
        let steps=PRDetailRouteState.steps(workspace.navigationKeys,at:shownKey)
        return PRDetailNavigation(previous:steps.previous.map { target in { go(target) } },next:steps.next.map { target in { go(target) } },open:{ go($0) },position:steps.position)
    }
    /// Navigates this window in place; the main workspace records the visit like any other open.
    private func go(_ target:ProviderKey) {
        guard target != shownKey else { return }
        workspace.recordOpen(target)
        _ = state.go(target,from:key);resolving=true
        navigated?(target)
    }
    private func resolve() async {
        defer { resolving=false }
        let target=shownKey
        guard workspace.cached(target) == nil else { repositoryWorkspace=nil;return }
        let scoped=repositoryWorkspace.flatMap { $0.repositoryScope == target.repository ? $0 : nil } ?? PRWorkspaceModel(storage:workspace.storage,persistsWorkspace:false,repositoryScope:target.repository)
        scoped.activeActionAccount=workspace.activeActionAccount
        repositoryWorkspace=scoped
        await scoped.load()
        forwardTabRequest()
    }
    /// A section request recorded on the main workspace reaches a window served by the repository-scoped one.
    private func forwardTabRequest() {
        guard workspace.cached(shownKey) == nil,let scoped=repositoryWorkspace,scoped.cached(shownKey) != nil,
              let requested=workspace.takeRequestedDetailTab(shownKey) else { return }
        scoped.requestDetailTab(requested,for:shownKey)
    }
    /// After a detail load or light write, reload only the workspace that supplies this row, and only
    /// when its stored row (one repository decode) differs from the displayed one.
    private func refreshRow(in source:PRWorkspaceModel) async {
        let target=shownKey
        if let stored=try? await source.storage.detailStoredRow(target),let current=source.cached(target),stored == current { return }
        await source.reload()
    }
}
