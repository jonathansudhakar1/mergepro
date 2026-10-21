import AppKit
import Foundation
import MergeProCore
import Observation

@Observable @MainActor
final class PRWorkspaceModel {
  let storage: SetupStorage
  private let persistsWorkspace: Bool
  let repositoryScope:RepositoryKey?
  private var persistence: Task<Void, Never>?
  private var loaded = false
  private var loading = false
  private var loadWaiters: [CheckedContinuation<Void, Never>] = []
  private var preparedFreshness:[PRRepositoryFreshness]=[]
  private(set) var previousLookCutoff=Date.distantFuture
  /// Set only while a debounced filter edit assigns `state`, so that projection runs off the main actor.
  @ObservationIgnored private var deferProjection=false
  /// Every projection bumps the revision; an off-main result is published only if it is still the latest.
  @ObservationIgnored private var projectionRevision=0
  @ObservationIgnored private var projectionTask:Task<Void,Never>?
  @ObservationIgnored private var filterTask:Task<Void,Never>?
  @ObservationIgnored private var countsInput:CountsInput?
  /// Saved-view counts run off the main actor; a result is published only if no newer count started.
  @ObservationIgnored private var countsRevision=0
  @ObservationIgnored private var countsTask:Task<Void,Never>?
  /// Navigation history is saved to its own record, debounced, so opening a PR never re-encodes the workspace and
  /// saving settings or selection never re-encodes up to 1,000 visits. False until that record was read or written.
  @ObservationIgnored private var historyStoredSeparately=false
  @ObservationIgnored private var historyPersistence:Task<Void,Never>?
  private struct CountsInput:Equatable { let rows:Int;let views:[PRSavedView];let account:AccountScope?;let pinned:Set<RepositoryKey> }
  /// Menu-bar queues, built once per row revision, default view and pins rather than on every render.
  @ObservationIgnored private var menuQueues:(input:MenuQueueInput,needs:[PullRequest],mine:[PullRequest])?
  private struct MenuQueueInput:Equatable { let rows:Int;let view:PRViewConfiguration;let pinned:Set<RepositoryKey> }
  /// Focus changes warm the focused PR's persisted detail into memory (no network) so opening it is instant.
  @ObservationIgnored private var warmTask:Task<Void,Never>?
  /// Re-evaluates `eligibility` when the soonest shown merge evidence goes stale (or becomes fresh).
  @ObservationIgnored private var eligibilityTick:Task<Void,Never>?
  /// Views, configuration and history. Selection, focus and scroll position live in `selection` and `scrollAnchor`,
  /// so a j/k move or a scroll doesn't invalidate every view that reads `state` (sidebar, toolbar, filter bar).
  /// `state.selection`/`state.scrollAnchor` keep the stored snapshot: a state assigned wholesale (load, import, a
  /// repository tab's reset) brings a different one, which becomes the live selection.
  var state = PRViewState() {
    didSet {
      if oldValue.selection != state.selection || oldValue.scrollAnchor != state.scrollAnchor {
        selection = state.selection
        scrollAnchor = state.scrollAnchor
      }
      if oldValue.current != state.current || oldValue.accountFilter != state.accountFilter
        || oldValue.views != state.views
      {
        if deferProjection { projectInBackground() } else { project() }
      }
      let historyChanged = oldValue.navigationHistory != state.navigationHistory
      if historyChanged { persistHistorySoon() }
      if !historyChanged || Self.differsBesidesHistory(oldValue, state) { persistSoon() }
    }
  }
  /// The live board/list selection and keyboard focus (j/k). In list mode it is the table's selection.
  var selection = PRSelection() {
    didSet {
      guard oldValue != selection else { return }
      if oldValue.focused != selection.focused { warmFocusedSoon() }
      persistSoon(after: .seconds(1))
    }
  }
  var scrollAnchor: ProviderKey? { didSet { if oldValue != scrollAnchor { persistSoon(after: .seconds(1)) } } }
  private static func differsBesidesHistory(_ a: PRViewState, _ b: PRViewState) -> Bool {
    var a = a, b = b
    a.navigationHistory = nil
    b.navigationHistory = nil
    return a != b
  }
  /// Requested PR window tab per PR (e.g. Checks from a "Checks failing" badge). The PR window takes it once.
  private(set) var requestedDetailTabs: [ProviderKey: PRDetailTab] = [:]
  func requestDetailTab(_ tab: PRDetailTab, for key: ProviderKey) { requestedDetailTabs[key] = tab }
  /// Returns and clears the tab requested for `key`, if any.
  func takeRequestedDetailTab(_ key: ProviderKey) -> PRDetailTab? { requestedDetailTabs.removeValue(forKey: key) }
  private(set) var cache = PRWorkspaceSnapshot()
  /// Bumped by every account invalidation, removal or reauthorization; reads that began before it are stale.
  private var cacheRevision = 0
  /// Taken by a caller BEFORE its storage read, then passed to `reload(snapshots:activeAccount:token:)`.
  struct ReloadToken: Equatable { fileprivate let revision: Int }
  func reloadToken() -> ReloadToken { ReloadToken(revision: cacheRevision) }
  /// False once an account was invalidated, removed or reauthorized after the token was taken.
  func isCurrent(_ token: ReloadToken) -> Bool { token.revision == cacheRevision }
  /// Rows in this workspace's repository scope plus their stacks; stacks are rebuilt only when rows change.
  private(set) var pipeline = PRBoardPipeline()
  var rows: [PullRequest] { pipeline.rows }
  /// False until the first cached load finishes, so an empty board is never presented as "no matching PRs" early.
  private(set) var hasLoadedRows = false
  private(set) var listRows: [PRListDisplayRow] = []
  private(set) var projection = BoardProjection(rows: [], view: PRViewConfiguration())
  /// Collapsed cards, lanes and keyboard order, stored once per projection rather than per view update.
  private(set) var board = PRBoardLayout()
  private(set) var viewCounts: [UUID: Int] = [:]
  /// Per-card (or, in the list, per-row) merge eligibility precomputed with each projection and refreshed when
  /// shown evidence ages out; cards and table rows read these instead of scanning rows.
  private(set) var eligibility:[ProviderKey:MergeEligibility]=[:]
  private(set) var freshnessByRepository:[RepositoryKey:PRRepositoryFreshness]=[:]
  private(set) var repositoryFreshness:[PRRepositoryFreshness]=[]
  var repositories: [Repository] { cache.repositories.filter { repositoryScope == nil || $0.key == repositoryScope } }
  var pinned: Set<RepositoryKey> { cache.pinned }
  var accounts: [Account] { cache.accounts.filter { repositoryScope == nil || $0.scope == repositoryScope?.account } }
  var inventory: [RepositoryKey: PRInventoryStatus] { cache.inventory.filter { repositoryScope == nil || $0.key == repositoryScope } }
  var revoked: Set<AccountScope> { cache.revoked }
  /// The fixture app's measurements of this workspace; nil in the shipped app.
  let instrumentation: (any WorkspaceInstrumentation)?
  var filterText = ""
  var filterError: String?
  var status: String?
  var activeActionAccount:AccountScope? { didSet { if oldValue != activeActionAccount { refreshEligibility() } } }
  var actionPresentation:PRActionPresentation?
  /// A card dropped on the Draft column, waiting for confirmation (conversion leaves any merge queue).
  var pendingDraftConversion:PullRequest?
  /// A merge request refused before the sheet opened, with the blockers to explain.
  var blockedMerge:(pr:PullRequest,reason:String)?
  var stateActionRequest:UUID?
  var expandedStacks:Set<String>=[] { didSet { if oldValue != expandedStacks { board=pipeline.layout(projection:projection,view:state.current,expanded:expandedStacks);refreshEligibility() } } }
  var palettePresented = false
  var viewEditorPresented = false
  var importPresented = false
  var exportPresented = false
  var routeChoices: [ProviderKey] = []
  init(storage: SetupStorage,persistsWorkspace:Bool = true,repositoryScope:RepositoryKey? = nil) {
    self.storage = storage; self.persistsWorkspace = persistsWorkspace;self.repositoryScope=repositoryScope
    instrumentation = storage.dependencies.fixtures?.makeWorkspaceInstrumentation()
  }
  /// `snapshots` (with the active account) are rows the caller has just read, sparing a second account-wide decode.
  /// With a `token` taken before that read, rows read before an account changed are replaced by a fresh read.
  func load(snapshots: [LocalSnapshot]? = nil, activeAccount: AccountScope? = nil, token: ReloadToken? = nil) async {
    guard !loaded else { return }
    // Concurrent callers (view task, scoped tab, URL routing) wait for the in-flight load so
    // their follow-up state changes are not overwritten when the stored workspace arrives.
    if loading { await withCheckedContinuation { loadWaiters.append($0) }; return }
    loading = true
    defer { loading = false; let waiters = loadWaiters; loadWaiters = []; waiters.forEach { $0.resume() } }
    await instrumentation?.loadWillBegin()
    do {
      var stored = try await storage.prWorkspace()
      // Unreadable separate history falls back to any history still in the workspace record.
      if let history = await AppLog.value(AppLog.workspace, "PR navigation history could not be read", fallback: nil, { try await storage.prNavigationHistory() }) {
        stored.navigationHistory = history
        historyStoredSeparately = true
      }
      _ = stored.migrateLegacyBuiltins()
      state = stored
      previousLookCutoff=state.beginLook(at:Date())
      filterText = state.current.filter.serialized
      loaded = true
      persistSoon()
      // Legacy history still lives in the workspace record; copy it to its own record before the next save drops it.
      if !historyStoredSeparately, state.navigationHistory != nil { persistHistorySoon() }
    } catch { status = "Saved views could not be loaded." }
    if let snapshots, token.map({ isCurrent($0) }) ?? true { await reload(snapshots: snapshots, activeAccount: activeAccount, token: token) } else { await reload() }
    if let measured = instrumentation?.loadDidFinish(rows: rows.count) { status = measured }
  }
  func invalidateAccount(_ account: AccountScope, removed: Bool = false) {
    cacheRevision += 1
    stateActionRequest=nil
    var next = cache
    var nextState = liveState
    var routes = routeChoices
    if removed {
      next.remove(account, state: &nextState, pendingRoutes: &routes)
    } else {
      next.invalidate(account, state: &nextState, pendingRoutes: &routes)
    }
    cache = next
    pipeline.update(rows: scopedRows(cache))
    adoptLive(nextState)
    routeChoices = routes
    project()
  }
  func acceptAuthorization(_ account: AccountScope) {
    // Only releasing a revoked account changes the cache. Routine "available" signals (one per account at
    // launch) must not make an in-flight read stale, or the launch board would be read twice.
    guard cache.revoked.contains(account) else { return }
    cacheRevision += 1
    cache.acceptAuthorization(account)
    refreshFreshness()
  }
  private func scopedRows(_ snapshot: PRWorkspaceSnapshot) -> [PullRequest] { repositoryScope.map { snapshot.rows(in: $0) } ?? snapshot.rows }
  private func scopedFreshness(_ snapshot: PRWorkspaceSnapshot) -> [PRRepositoryFreshness] { snapshot.freshness(account: state.accountFilter).filter { repositoryScope == nil || $0.repository == repositoryScope } }
  func reload() async { await reload(using: nil) }
  /// Reprojects from rows the caller has just read (e.g. after a poll cycle) instead of reading them again.
  /// Pass the `token` taken before that read: if an account was invalidated or removed meanwhile, the rows are
  /// dropped (they could restore that account) and the caller reads again.
  func reload(snapshots: [LocalSnapshot], activeAccount: AccountScope?, token: ReloadToken? = nil) async {
    // A repository-scoped workspace uses only its repository's rows; its own scoped read is cheaper.
    if repositoryScope == nil { await reload(using: (snapshots, activeAccount), token: token) } else { await reload(using: nil) }
  }
  private func reload(using stored: ([LocalSnapshot], AccountScope?)?, token: ReloadToken? = nil) async {
    let revision = token?.revision ?? cacheRevision
    defer { if !hasLoadedRows { hasLoadedRows = true } }
    do {
      guard revision == cacheRevision else { return }
      let snapshots: [LocalSnapshot]
      let active: AccountScope?
      let statuses: [RepositoryKey: PRInventoryStatus]
      if let stored {
        snapshots = stored.0
        active = stored.1
        statuses = try await storage.prInventoryStatuses()
      } else if let repositoryScope {
        // One repository's rows and status, without decoding every account's history.
        let scoped = try await storage.load(repository: repositoryScope)
        snapshots = scoped.snapshots
        active = scoped.activeAccount
        statuses = try await storage.prInventoryStatuses(repository: repositoryScope)
      } else {
        let loaded = try await storage.load()
        snapshots = loaded.0
        active = loaded.2
        statuses = try await storage.prInventoryStatuses()
      }
      guard revision == cacheRevision else { return }
      activeActionAccount = active
      var next = cache
      next.refresh(snapshots: snapshots, inventory: statuses,repositoryScope:repositoryScope)
      // Compare like with like (scoped rows and freshness), so an unchanged poll does not re-project.
      let rowsChanged = pipeline.update(rows: scopedRows(next))
      let changed =
        rowsChanged || pinned != next.pinned
        || Set(cache.inventory.keys) != Set(next.inventory.keys)
        || preparedFreshness != scopedFreshness(next)
      var nextState = liveState
      var routes = routeChoices
      next.reconcile(state: &nextState, pendingRoutes: &routes)
      cache = next
      adoptLive(nextState)
      if routeChoices != routes { routeChoices = routes }
      // The first load projects at once (no empty-board flash); poll-driven reloads project off the main actor.
      if changed { if hasLoadedRows { projectInBackground() } else { project() } }
      instrumentation?.rowsDidReload(next.rows)
    } catch { status = "Cached PRs remain available; local reload failed." }
  }
  /// Synchronous projection for row, scope and view changes. Stacks are row-derived and never rebuilt here.
  func project() {
    projectionRevision &+= 1
    instrumentation?.projectionWillBegin()
    publish(pipeline.layout(view: state.current, accountFilter: state.accountFilter, pinned: pinned, expanded: expandedStacks), listRows: nil)
    instrumentation?.projectionDidFinish(rows: rows.count)
  }
  /// `state` with the live selection and scroll position, for reconcile and invalidation.
  private var liveState: PRViewState {
    var value = state
    value.selection = selection
    value.scrollAnchor = scrollAnchor
    return value
  }
  /// Applies a reconciled `liveState`: settings to `state` (only if changed), selection to the live properties.
  private func adoptLive(_ next: PRViewState) {
    var settings = next
    settings.selection = state.selection
    settings.scrollAnchor = state.scrollAnchor
    if state != settings { state = settings }
    if selection != next.selection { selection = next.selection }
    if scrollAnchor != next.scrollAnchor { scrollAnchor = next.scrollAnchor }
  }
  /// Filter edits and poll-driven reloads project off the main actor; a result is dropped if any newer projection
  /// started meanwhile.
  private func projectInBackground() {
    projectionRevision &+= 1
    let revision = projectionRevision, pipeline = pipeline, view = state.current, account = state.accountFilter
    let pinned = pinned, expanded = expandedStacks, labels = freshnessLabels, logins = accountLogins
    projectionTask?.cancel()
    projectionTask = Task { [weak self] in
      let result = await Task.detached(priority: .userInitiated) {
        let layout = pipeline.layout(view: view, accountFilter: account, pinned: pinned, expanded: expanded)
        return (layout, view.mode == .list ? PRListDisplayRow.make(projection: layout.projection, view: view, freshness: labels, logins: logins) : [])
      }.value
      guard let self, revision == self.projectionRevision else { return }
      // A stack expanded while this projection ran keeps its expansion.
      let layout = expanded == self.expandedStacks ? result.0 : self.pipeline.layout(projection: result.0.projection, view: view, expanded: self.expandedStacks)
      self.publish(layout, listRows: result.1)
    }
  }
  private func publish(_ layout: PRBoardLayout, listRows prepared: [PRListDisplayRow]?) {
    projection = layout.projection
    board = layout
    refreshFreshness()
    listRows = prepared ?? (state.current.mode == .list ? PRListDisplayRow.make(projection: projection, view: state.current, freshness: freshnessLabels, logins: accountLogins) : [])
    refreshEligibility()
    // Saved-view badges depend on rows, views, account scope and pins, never on the current filter text.
    let input = CountsInput(rows: pipeline.stackRevision, views: state.views, account: state.accountFilter, pinned: pinned)
    if input != countsInput {
      countsInput = input
      refreshCounts()
    }
    instrumentation?.didPublish(rows: rows.count, visibleRows: projection.rows.count)
  }
  /// Counts every saved view off the main actor (one projection per view over every row).
  private func refreshCounts() {
    countsRevision &+= 1
    let revision = countsRevision, pipeline = pipeline, views = state.views, account = state.accountFilter, pinned = pinned
    countsTask?.cancel()
    countsTask = Task { [weak self] in
      let counts = await Task.detached(priority: .utility) {
        pipeline.counts(views: views, accountFilter: account, pinned: pinned)
      }.value
      guard let self, revision == self.countsRevision else { return }
      self.viewCounts = counts
    }
  }
  /// Account logins shown instead of numeric account IDs when several accounts are connected.
  var accountLogins: [AccountScope: String] {
    Dictionary(cache.accounts.map { ($0.scope, $0.login) }, uniquingKeysWith: { first, _ in first })
  }
  func login(_ account: AccountScope) -> String { accountLogins[account] ?? "Account \(account.accountID)" }
  private func refreshFreshness() {
    repositoryFreshness = scopedFreshness(cache)
    preparedFreshness = repositoryFreshness
    freshnessByRepository = cache.freshnessByRepository()
  }
  private var freshnessLabels: [RepositoryKey: String] {
    Dictionary(repositoryFreshness.filter(\.needsAttention).map { ($0.repository, $0.label) }, uniquingKeysWith: { first, _ in first })
  }
  /// Display eligibility for the current cards or table rows: the action account's evaluation, as `mergeEligibility`
  /// gives menus and keys. Merge evidence ages out after `MergePolicy.maximumAge`, so this is evaluated again the
  /// moment any shown value would change (a blocker from now-stale evidence stops hiding Merge). Merge, batch and
  /// drop actions still evaluate fresh evidence when chosen.
  private func refreshEligibility() {
    let now = Date()
    let shown = state.current.mode == .list ? projection.rows : board.cards.rows
    var values: [ProviderKey: MergeEligibility] = [:]
    values.reserveCapacity(shown.count)
    for pr in shown { values[pr.key] = actionPRCached(pr).map { MergePolicy.evaluate(pr: $0, now: now) } ?? MergePolicy.unverified(pr) }
    if values != eligibility { eligibility = values }
    eligibilityTick?.cancel()
    guard let next = MergeEligibility.nextEvidenceChange(values.values, after: now) else { eligibilityTick = nil; return }
    eligibilityTick = Task { [weak self] in
      // A little past the boundary, so the next evaluation sees it; an early wake simply schedules again.
      try? await Task.sleep(for: .seconds(max(0, next.timeIntervalSince(now)) + 0.05))
      guard !Task.isCancelled else { return }
      self?.refreshEligibility()
    }
  }
  /// Typing re-projects after a short pause, off the main actor. Programmatic `applyFilter()` stays immediate.
  func filterTextChanged() {
    filterTask?.cancel()
    filterTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(150))
      guard !Task.isCancelled, let self else { return }
      self.applyFilter(deferred: true)
    }
  }
  func applyFilter() { applyFilter(deferred: false) }
  private func applyFilter(deferred: Bool) {
    filterTask?.cancel()
    do {
      let filter = try FilterExpression.parse(filterText)
      filterError = nil
      deferProjection = deferred
      defer { deferProjection = false }
      state.current.filter = filter
    } catch {
      filterError =
        "Use field:value tokens or quoted text. Unknown fields and unclosed quotes are rejected."
    }
  }
  func chooseView(_ id: UUID) {
    guard let view = state.views.first(where: { $0.id == id }) else { return }
    state.currentViewID = id
    state.current = view.configuration
    filterText = view.configuration.filter.serialized
  }
  func saveCurrent(name: String) {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    let view = PRSavedView(name: name, configuration: state.current)
    state.views.append(view)
    state.currentViewID = view.id
  }
  func updateCurrentView(name: String, icon: String) {
    guard let index = state.views.firstIndex(where: { $0.id == state.currentViewID }), !name.isEmpty
    else { return }
    state.views[index].name = name
    state.views[index].icon = icon
    state.views[index].configuration = state.current
  }
  func defaultView(_ id: UUID) {
    for index in state.views.indices { state.views[index].isDefault = state.views[index].id == id }
  }
  func moveView(_ id: UUID, direction: Int) {
    guard let index = state.views.firstIndex(where: { $0.id == id }),
      state.views.indices.contains(index + direction)
    else { return }
    state.views.swapAt(index, index + direction)
  }
  func hideView(_ id: UUID) {
    guard let i = state.views.firstIndex(where: { $0.id == id }) else { return }
    state.views[i].hidden.toggle()
  }
  /// Keys in the order the current layout shows them: list rows, or board lanes → columns → closed
  /// cards with collapsed stacks and lanes omitted. Keyboard focus never lands on a hidden card.
  var navigationKeys: [ProviderKey] { state.current.mode == .board ? board.navigationKeys : listRows.map(\.id) }
  /// The focused PR only while it is visible; keyboard commands never act on filtered-out rows.
  var visibleFocus: ProviderKey? { selection.focused.flatMap { navigationKeys.contains($0) ? $0 : nil } }
  func select(_ key: ProviderKey, modifiers: NSEvent.ModifierFlags = []) {
    let order = modifiers.contains(.shift) ? navigationKeys : []
    var next = selection
    if modifiers.contains(.shift), let focused = next.focused,
      let start = order.firstIndex(of: focused), let end = order.firstIndex(of: key)
    {
      next.selected.formUnion(order[min(start, end)...max(start, end)])
    } else if modifiers.contains(.command) {
      if !next.selected.insert(key).inserted { next.selected.remove(key) }
    } else {
      next.selected = [key]
    }
    next.focused = key
    selection = next
  }
  /// j/k. In the list the moved-to row becomes the table selection, so A/M/Return act on the highlighted row;
  /// on the board focus moves and a multi-selection is kept.
  func moveFocus(_ direction: Int) {
    var next = selection
    guard let key = next.move(direction, in: navigationKeys, selecting: state.current.mode == .list) else { return }
    selection = next
    scrollAnchor = key
  }
  func toggleSelection() {
    guard let key = visibleFocus else { return }
    if !selection.selected.insert(key).inserted { selection.selected.remove(key) }
  }
  func markSeen() { let now=Date();state.lastSeenAt=now;previousLookCutoff=now }
  func widen() {
    state.current.timeScope = .allTime
    state.current.mergedDays = 36500
  }
  func cycleTime() {
    let scopes = PRTimeScope.allCases.filter { $0 != .custom }
    state.current.timeScope =
      scopes[((scopes.firstIndex(of: state.current.timeScope) ?? 0) + 1) % scopes.count]
  }
  func recordOpen(_ key: ProviderKey) {
    guard cached(key) != nil else { return }
    state.recordVisit(key)
    state.recentRoutes.removeAll { $0 == key }
    state.recentRoutes.insert(key, at: 0)
    state.recentRoutes = Array(state.recentRoutes.prefix(100))
  }
  func cached(_ key: ProviderKey) -> PullRequest? { guard repositoryScope == nil || key.repository == repositoryScope else { return nil };return cache.cached(key) }
  func web(_ pr: PullRequest) { if let url = pr.metadata?.webURL { ExternalLinkPolicy.open(url) } }
  func copyLink(_ pr: PullRequest) { copyLinks([pr]) }
  /// One link per line for several pull requests.
  func copyLinks(_ prs: [PullRequest]) {
    let links = prs.compactMap { $0.metadata?.webURL.absoluteString }
    guard !links.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(links.joined(separator: "\n"), forType: .string)
  }
  func freshness(for repository: RepositoryKey) -> PRRepositoryFreshness? { freshnessByRepository[repository] }
  var freshness: String {
    let scopedRevoked = revoked.filter { state.accountFilter == nil || $0 == state.accountFilter }
    if !scopedRevoked.isEmpty {
      return "Access revoked for \(scopedRevoked.count) account(s). Reconnect in Setup."
    }
    let evidence = repositoryFreshness
    guard !evidence.isEmpty else { return "Choose tracked repositories in Setup." }
    let affected = evidence.filter(\.needsAttention)
    if !affected.isEmpty {
      return affected.map { "\($0.name): \($0.label)" }.joined(separator: " · ")
    }
    let syncing = evidence.filter(\.isSyncing).count
    if syncing > 0 {
      return "Syncing \(syncing) of \(evidence.count) repositories. Pull requests appear as each one finishes."
    }
    guard let oldest = evidence.compactMap(\.lastSuccessAt).min() else {
      return "Inventory has not refreshed yet."
    }
    return
      "All \(evidence.count) repositories current · Oldest success \(oldest.formatted(.relative(presentation:.named))) · Merge eligibility unknown"
  }
  var defaultConfiguration: PRViewConfiguration {
    state.views.first(where: \.isDefault)?.configuration ?? state.current
  }
  /// Reads `pipeline`, `state` and `cache` on every call (so views observe them) but projects only when the
  /// rows, default view or pins changed since the last call.
  func menuQueue(mine: Bool) -> [PullRequest] {
    let input = MenuQueueInput(rows: pipeline.stackRevision, view: defaultConfiguration, pinned: pinned)
    if let queues = menuQueues, queues.input == input { return mine ? queues.mine : queues.needs }
    let rows = BoardProjection(rows: self.rows, view: input.view, pinned: input.pinned).rows
    let queues = (input: input, needs: rows.filter(\.needsViewer), mine: rows.filter { $0.metadata?.viewerIsAuthor == true })
    menuQueues = queues
    return mine ? queues.mine : queues.needs
  }
  private func warmFocusedSoon() {
    // Fixture verification measures cold detail opens, so the fixture app never pre-decodes on focus.
    guard storage.dependencies.speculativeDetailReads else { return }
    warmTask?.cancel()
    guard let key = selection.focused, let pr = cached(key), !revoked.contains(key.account) else { return }
    let storage = storage
    warmTask = Task {
      // Keyboard focus moves pass through cards quickly; warm only where focus settles.
      try? await Task.sleep(for: .milliseconds(150))
      guard !Task.isCancelled else { return }
      await storage.warmDetail(pr)
    }
  }
  func importViews(_ data: Data) async {
    do {
      try await storage.importPRViews(data)
      var imported = try await storage.prWorkspace()
      // Import replaces views only: the live selection and the separately stored history stay.
      imported.selection = state.selection
      imported.scrollAnchor = state.scrollAnchor
      imported.navigationHistory = state.navigationHistory
      state = imported
      previousLookCutoff=state.beginLook(at:Date())
      // Import can replace the current configuration; keep the editable filter text in step.
      filterText = state.current.filter.serialized
      filterError = nil
    } catch { status = "That file is not a valid saved-view export." }
  }
  /// Nil when the views could not be exported (the caller reports it).
  func exportViews() async -> Data? { await AppLog.value(AppLog.workspace, "Saved views could not be exported", fallback: nil) { try await storage.exportPRViews() } }
  /// Settings save shortly after a change; selection-only changes (j/k, clicks, scrolling) wait a second.
  private func persistSoon(after delay: Duration = .milliseconds(150)) {
    guard persistsWorkspace else { return }
    guard loaded else { return }
    persistence?.cancel()
    persistence = Task { [weak self] in
      do {
        try await Task.sleep(for: delay)
        guard let self else { return }
        try await storage.savePRWorkspace(storedState)
      } catch {
        if !Task.isCancelled { self?.status = "Workspace preferences could not be saved." }
      }
    }
  }
  /// The workspace record: settings plus the live selection. History is left out once it has its own record.
  private var storedState: PRViewState {
    var value = liveState
    if historyStoredSeparately { value.navigationHistory = nil }
    return value
  }
  private func persistHistorySoon() {
    guard persistsWorkspace, loaded else { return }
    historyPersistence?.cancel()
    historyPersistence = Task { [weak self] in
      do {
        try await Task.sleep(for: .seconds(1))
        guard let self else { return }
        try await storage.savePRNavigationHistory(state.navigationHistory ?? [])
        historyStoredSeparately = true
      } catch {
        if !Task.isCancelled { self?.status = "Workspace preferences could not be saved." }
      }
    }
  }
}
