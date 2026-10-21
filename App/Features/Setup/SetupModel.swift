import AppKit
import Foundation
import Observation
import UserNotifications
import MergeProCore

@Observable @MainActor
final class SetupModel {
    var snapshots: [LocalSnapshot] = []
    var clientID = ""
    var activeAccount: AccountScope?
    var notificationsEnabled = false
    var notificationStatus = "Notifications are optional. Your in-app updates remain available."
    var loginEnabled = LoginItemService().enabled
    var loginNeedsApproval = LoginItemService().needsApproval
    var isLoading = true
    var isConnecting = false
    var discovering: Set<AccountScope> = []
    var retryDeadlines: [AccountScope:Date] = [:]
    private var discoveryGenerations: [AccountScope:UUID] = [:]
    private var reconnecting: Set<AccountScope> = []
    var authorizationState: DeviceFlowState?
    var userCode: String?
    var verificationURL: URL?
    var message: String?
    var accountProblems: [AccountScope:String] = [:]
    enum Destination: String { case setup, activity, pullRequests, actions, repos, local }
    var destination: Destination = .setup { didSet { if oldValue != destination { restartPolling() } } }
    var inboxEvents: [InboxEvent] = []
    /// False until the stored inbox has been read once, so the inbox never claims "No activity yet" while loading.
    private(set) var inboxLoaded = false
    var inboxOperations:[String:NotificationThreadOperation]=[:]
    var inboxPending:Set<String>=[]
    var inboxFailures:[String:String]=[:]
    var summaryEventKeys: [String]?
    var pollStatus: String?
    var pollRevision = UUID()
    var visibleActionViews = 0 { didSet { if (oldValue > 0) != (visibleActionViews > 0) { restartPolling() } } }
    private var refreshesInFlight = 0
    var isRefreshing: Bool { refreshesInFlight > 0 }
    let statusItem = PRStatusItemController()
    let globalHotkeys: GlobalHotkeyService
    var globalHotkeyStatus = ""
    let prs: PRWorkspaceModel
    let localFolders:SecurityScopedFolderStore
    var localCheckout:LocalPRCheckoutRequest?
    private let storage: SetupStorage
    var featureStorage: SetupStorage { storage }
    var featureRepositories: [Repository] { snapshots.filter { $0.settings[.authorizationProblem] != "true" }.flatMap(\.repositories) }
    var actionRepositories:[Repository] {
        let tracked=Set(snapshots.flatMap(\.trackedRepositories))
        return featureRepositories.filter { tracked.contains($0.key) || $0.key == actionsRepository }
    }
    var featureGeneration = UUID()
    var repoRoute: RepoNavigationRoute?
    /// Bumped when the current route is requested again. An equal route does not change `repoRoute`, so the
    /// repository browser is rebuilt (AppShell's view identity) to navigate to it once more.
    private(set) var repoRouteRepeat = 0
    var actionsRepository: RepositoryKey?
    var actionRunID: Int64?
    var actionWorkflowID: Int64?
    var actionPresetID: UUID?
    var cachedRuns:[WorkflowRun] = []
    var cachedWorkflows:[FeatureWorkflowEntry] = []
    var cachedPresets:[WorkflowPreset] = []
    var cachedRepoEntries:[RepoPaletteEntry] = []
    /// Cached Actions catalogs behind `cachedRuns`/`cachedWorkflows`, per repository, for `catalogGeneration`.
    private var featureCatalogs:[RepositoryKey:ActionsCatalog] = [:]
    private var featureCatalogsRead:Set<RepositoryKey> = []
    private var catalogGeneration:UUID?
    var featureRouteChoices:[RepositoryKey] = []
    var pendingFeatureURL:URL?
    func showActions(repository:RepositoryKey? = nil,runID:Int64? = nil,workflowID:Int64? = nil,presetID:UUID? = nil) {
        actionsRepository = repository; actionRunID = runID; actionWorkflowID = workflowID;actionPresetID = presetID
        destination = .actions
    }
    func showRepository(_ route:RepoNavigationRoute) {
        if repoRoute == route { repoRouteRepeat &+= 1 }
        repoRoute = route; destination = .repos
    }
    /// Menu bar and palette entries must not outlive an account's access until the next poll.
    private func purgeFeatureCaches(_ account:AccountScope) {
        cachedRuns.removeAll { $0.repository.key.account == account }
        cachedWorkflows.removeAll { $0.repository.key.account == account }
        cachedPresets.removeAll { $0.repository.account == account }
        cachedRepoEntries.removeAll { $0.route.repository.account == account }
        featureCatalogs = featureCatalogs.filter { $0.key.account != account };featureCatalogsRead = featureCatalogsRead.filter { $0.account != account }
    }
    /// Menu bar and palette caches. `changed` names repositories whose Actions data a cycle changed: only they
    /// (plus the repository on screen and any not read yet) are re-read; nil re-reads every repository. Palette rows
    /// are rebuilt by the browser service only when their cached sources changed.
    func refreshFeatureCaches(changed:Set<RepositoryKey>? = nil) async {
        let generation = featureGeneration
        do {
            let service = try await storage.actionsService()
            let repositories = featureRepositories, wanted = Set(repositories.map(\.key))
            let current = catalogGeneration == generation
            var reread = current ? (changed ?? wanted).union(wanted.subtracting(featureCatalogsRead)) : wanted
            if let actionsRepository { reread.insert(actionsRepository) }
            reread.formIntersection(wanted)
            let catalogs = await service.cachedCatalogs(repositories:Array(reread))
            let presets = await AppLog.value(AppLog.actions, "Workflow presets could not be read", fallback:[]) { try await service.presets() }
            let entries = await AppLog.value(AppLog.repositories, "Palette entries could not be read", fallback:[]) { try await storage.repositoryBrowserService().paletteEntries() }
            guard generation == featureGeneration,!Task.isCancelled else { return }
            if !current { featureCatalogs = [:];featureCatalogsRead = [];catalogGeneration = generation }
            for key in reread { featureCatalogs[key] = catalogs[key] }
            featureCatalogsRead.formUnion(reread)
            featureCatalogs = featureCatalogs.filter { wanted.contains($0.key) };featureCatalogsRead.formIntersection(wanted)
            cachedRuns = repositories.flatMap { featureCatalogs[$0.key]?.runs ?? [] }
            cachedWorkflows = repositories.flatMap { repository in featureCatalogs[repository.key]?.workflows.map { FeatureWorkflowEntry(repository:repository,workflow:$0) } ?? [] }
            cachedPresets = presets;cachedRepoEntries = entries
        } catch {
            // Menu bar and palette keep their previous entries until the next cycle.
            AppLog.failed(AppLog.sync, "Menu bar and palette caches could not refresh", error)
        }
    }
    @discardableResult func navigateFeatureURL(_ url:URL,account:AccountScope? = nil) async -> Bool {
        let parts = url.path.split(separator:"/")
        guard url.scheme == "https",url.host?.lowercased() == "github.com",
              parts.count == 2 || parts.count > 2 && ["actions","blob","tree","releases","branches","tags","commits","pulls"].contains(String(parts[2])) else { return false }
        let entries = await AppLog.value(AppLog.repositories, "Palette entries could not be read", fallback:[]) { try await storage.repositoryBrowserService().paletteEntries() }
        var refs:[RepositoryKey:Set<String>] = [:]
        for entry in entries { if let ref = entry.route.ref { refs[entry.route.repository,default:[]].insert(ref) } }
        switch FeatureRouteResolver.resolve(url,repositories:featureRepositories,activeAccount:account ?? activeAccount,refs:refs) {
        case .repository(let key,let ref,let path,let section,let line):showRepository(.init(repository:key,ref:ref,path:path,section:section,line:line))
        case .actions(let repository,let runID):showActions(repository:repository,runID:runID)
        case .chooseAccount(let keys):featureRouteChoices = keys;pendingFeatureURL = url
        case .web(let url):NSWorkspace.shared.open(url)
        case .unavailable:message = "This destination is unavailable in the selected account."
        }
        return true
    }
    private let notificationSink: SystemNotificationSink
    private var availabilityTask: Task<Void,Never>?
    private var pollingTask: Task<Void,Never>?
    /// The single background detail prefetch; each new poll cycle cancels it.
    private var prefetchTask: Task<Void,Never>?
    private let dependencies: AppDependencies
    /// The fixture app's code surface hooks, for every window's environment; nil in the shipped app.
    var codeSurfaceInstrumentation: (any CodeSurfaceInstrumentation)? { dependencies.fixtures?.codeSurfaceInstrumentation }
    init(dependencies: AppDependencies) {
        // Before any view reads a renamed @AppStorage name.
        SettingsMigration.migrateDefaults(.standard)
        self.dependencies = dependencies
        let storage = SetupStorage(dependencies:dependencies); self.storage = storage; prs = PRWorkspaceModel(storage:storage)
        localFolders=SecurityScopedFolderStore(load:{ try await storage.localFolderData() },save:{ try await storage.saveLocalFolderData($0) })
        notificationSink = dependencies.makeNotificationSink({
            await AppLog.value(AppLog.storage, "The notification setting could not be read", fallback:false) { try await storage.notificationsEnabled() }
        })
        globalHotkeys = GlobalHotkeyService(unavailableReason:dependencies.globalHotkeysUnavailable)
    }
    func showLocalCheckout(_ pr:PullRequest) {
        guard pr.key.host == "github.com",let metadata=pr.metadata,metadata.number>0 else { return }
        let parts=metadata.repositoryName.split(separator:"/")
        guard parts.count==2 else { return }
        var clone=URL(string:"https://github.com")!
        for part in parts { clone.appendPathComponent(String(part)) }
        clone.appendPathExtension("git")
        localCheckout=LocalPRCheckoutRequest(requestID:UUID(),repository:pr.key.repository,
            repositoryName:metadata.repositoryName,number:metadata.number,
            expectedHeadSHA:pr.headRevision.rawValue,headBranch:metadata.headBranch ?? "",cloneWebURL:clone)
        destination = .local
    }
    private var authorization: DeviceFlowClient?
    private var authorizationTask: Task<Void,Never>?
    private var sessionID = UUID()

    func load() async {
        if availabilityTask == nil {
            do {
                let changes = try await storage.authorizationChanges()
                availabilityTask = Task { [weak self] in
                    for await change in changes {
                        guard let self, !Task.isCancelled else { return }
                        if case .authorizationRequired(let failed) = change.state {
                            self.cancelPrefetch()
                            self.featureGeneration = UUID()
                            self.purgeFeatureCaches(change.account)
                            self.prs.invalidateAccount(change.account)
                            self.snapshots = self.snapshots.map {
                                $0.account?.scope == change.account ? change.state.applying(to:$0) : $0
                            }
                            self.accountProblems[change.account] = failed
                                ? "GitHub access expired or was revoked. Reconnect this account. Local cleanup could not finish."
                                : "GitHub access expired or was revoked. Reconnect this account."
                        } else {
                            self.prs.acceptAuthorization(change.account)
                            self.accountProblems[change.account] = nil
                        }
                    }
                }
            } catch { message = "Account availability could not be loaded." }
        }
        var loaded = false
        // Taken before the read: rows read while an account is invalidated or removed are never shown.
        let token = prs.reloadToken()
        do {
            // Open and recent PRs first; the rest of the history is decoded below, after the board is drawn.
            let (snapshots, configuredID, active, notifications) = try await storage.loadFirstPass()
            self.snapshots = snapshots; self.activeAccount = active; self.notificationsEnabled = notifications
            clientID = configuredID ?? (Bundle.main.object(forInfoDictionaryKey:"MergeProGitHubOAuthClientID") as? String ?? "")
            if configuredID == nil, !clientID.isEmpty { try await storage.setting(clientID, for:.githubClientID) }
            if activeAccount == nil, let first = snapshots.first?.account?.scope { await selectAccount(first) }
            for snapshot in snapshots {
                if let account = snapshot.account, let epoch = snapshot.settings[.discoveryRetryAt].flatMap(Double.init) { retryDeadlines[account.scope] = Date(timeIntervalSince1970:epoch) }
                if let account = snapshot.account, snapshot.settings[.authorizationProblem] == "true" { accountProblems[account.scope] = "GitHub access expired or was revoked. Reconnect this account." }
            }
            loaded = true
        } catch { message = "Local setup could not be loaded. Check access to MergePro’s application support directory." }
        isLoading = false
        notificationSink.onAction = { [weak self] action in await self?.receiveNotification(action) }
        notificationSink.onPullRequestAction = { [weak self] action in await self?.receivePullRequestNotification(action) }
        // The board is drawn from the cached rows just read (no second account-wide decode); nothing below delays it.
        if loaded { await prs.load(snapshots:snapshots,activeAccount:activeAccount,token:token) } else { await prs.load() }
        // Reopening the main window reloads too; keep a destination chosen meanwhile (navigation, URL or notification).
        if !snapshots.isEmpty, destination == .setup { destination = .pullRequests }
        if let requested = dependencies.fixtures?.launchDestination, let target = Destination(rawValue:requested) { destination = target }
        if pollingTask == nil {
            startPolling()
        }
        // Activity, menu/palette caches, notification permission and the rest of the PR history load alongside the first poll.
        async let activity: Void = reloadActivity()
        async let features: Void = refreshFeatureCaches()
        async let permission: Void = refreshNotificationStatus()
        async let history: Void = loadHistory()
        _ = await (activity, features, permission, history)
    }
    /// Decodes the PR history the launch's first pass skipped (merged and closed PRs outside the default window).
    private func loadHistory() async {
        guard await storage.historyPending else { return }
        // The board keeps its first-pass rows; the next reload fills in history.
        do { try await reloadSnapshots() } catch { AppLog.failed(AppLog.workspace, "PR history could not be read", error) }
    }
    private func refreshNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        updateNotificationStatus(settings.authorizationStatus)
    }
    private var pollingIsActive: Bool { visibleActionViews > 0 || destination == .actions }
    private var pollingSleepsSlowly = false
    /// The last cycle left due work behind: the loop starts the next one right away until the backlog clears.
    private(set) var pollBacklogged = false
    /// Navigation only wakes a loop waiting on the slow cadence. An in-flight refresh is never cancelled (that surfaced a
    /// spurious failure) and the loop re-reads its cadence before every sleep, so other changes need no restart.
    private func restartPolling() {
        guard pollingTask != nil, pollingSleepsSlowly, pollingIsActive else { return }
        pollingTask?.cancel();startPolling()
    }
    private func startPolling() {
        pollingSleepsSlowly = false
        pollingTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    await self.refreshActivity(reason:self.pollingIsActive ? .activeRun : .scheduled)
                    guard !Task.isCancelled else { return }
                    let active = self.pollingIsActive
                    self.pollingSleepsSlowly = !active && !self.pollBacklogged
                    do { try await Task.sleep(for:.seconds(self.pollBacklogged ? 1 : active ? 15 : 60)) } catch { return }
                    self.pollingSleepsSlowly = false
                }
        }
    }
    func reloadActivity() async {
        do {
            inboxEvents = try await storage.inbox()
            inboxOperations=Dictionary(try await storage.notificationThreadOperations().map { ($0.command.eventKey,$0) },uniquingKeysWith:{ _,new in new })
        }
        catch { pollStatus = "Activity could not be loaded from local storage." }
        inboxLoaded = true
    }
    func refreshActivity(reason: PollRequest.Reason = .manual) async {
        refreshesInFlight += 1
        defer { refreshesInFlight -= 1 }
        // A new cycle supersedes the previous cycle's prefetch; the next completion schedules a fresh one.
        cancelPrefetch()
        pollStatus = "Refreshing repositories…"
        do {
            let cycle = try await storage.refreshActivity(sink:notificationSink,reason:reason)
            pollBacklogged = cycle.backlogged
            // Only what the cycle committed is re-read: new events, changed PR rows and statuses, changed Actions data.
            if cycle.changes.map({ $0.events > 0 }) ?? true || !inboxLoaded { await reloadActivity() }
            switch await storage.snapshotRefresh(after:cycle.changes) {
            case .none: break
            case .repositories(let changed): try await reloadSnapshots(refreshing:changed)
            case .all: try await reloadSnapshots()
            }
            // Cycle-complete signal (repository tabs, Actions) before the slower feature-cache pass.
            pollRevision = UUID()
            let freshness = prs.cache.freshness(account:nil)
            let failed = freshness.filter(\.needsAttention).count, syncing = freshness.filter(\.isSyncing).count
            pollStatus = failed > 0
                ? "Refresh finished · \(failed) \(failed == 1 ? "repository needs" : "repositories need") attention"
                : syncing > 0 ? "Syncing \(freshness.count - syncing) of \(freshness.count) repositories…"
                : "Last checked " + Date().formatted(date:.omitted,time:.shortened)
            schedulePrefetch()
            await refreshFeatureCaches(changed:cycle.changes?.repositories(feature:GitHubActionsFetcher().featureID))
        } catch { pollStatus = "Activity could not refresh. Saved events remain available." }
    }
    private func cancelPrefetch() { prefetchTask?.cancel(); prefetchTask = nil }
    /// After a completed cycle: the focused card plus the top five "Needs me" PRs of the active account, read at
    /// background budget priority so opening them is a cache hit. Never another account's PRs.
    private func schedulePrefetch() {
        cancelPrefetch()
        guard let account = activeAccount, accountProblems[account] == nil, !prs.revoked.contains(account) else { return }
        var candidates: [PullRequest] = []
        if let key = prs.selection.focused, key.account == account, let pr = prs.cached(key) { candidates.append(pr) }
        let focused = candidates.first?.key
        candidates += prs.menuQueue(mine:false).lazy.filter { $0.key.account == account && $0.key != focused }.prefix(5)
        guard !candidates.isEmpty else { return }
        let storage = storage, selected = candidates
        prefetchTask = Task(priority:.background) { _ = await storage.prefetchDetails(selected,limit:selected.count) }
    }
    func acknowledgeActivity(_ key: String) async {
        do { try await storage.acknowledgeActivity(key); await reloadActivity() }
        catch { pollStatus = "This event could not be marked read." }
    }
    func changeNotification(_ item:InboxEvent,intent:NotificationThreadIntent) async {
        guard !inboxPending.contains(item.id) else { return }
        inboxPending.insert(item.id);inboxFailures[item.id]=nil
        defer { inboxPending.remove(item.id) }
        do { inboxOperations[item.id]=try await storage.changeNotificationThread(item.event,intent:intent);await reloadActivity() }
        catch { inboxFailures[item.id]=error.localizedDescription;await reloadActivity() }
    }
    func releaseUnsentNotification(_ operation:NotificationThreadOperation) async {
        let key=operation.command.eventKey
        guard !inboxPending.contains(key) else { return }
        inboxPending.insert(key);defer { inboxPending.remove(key) }
        do { try await storage.releaseUnsentNotificationThread(operation.id);await reloadActivity() }
        catch { inboxFailures[key]=error.localizedDescription }
    }
    func reconcileNotification(_ operation:NotificationThreadOperation) async {
        let key=operation.command.eventKey
        guard !inboxPending.contains(key) else { return }
        inboxPending.insert(key);inboxFailures[key]=nil
        defer { inboxPending.remove(key) }
        do { inboxOperations[key]=try await storage.reconcileNotificationThread(operation.id);await reloadActivity() }
        catch { inboxFailures[key]=error.localizedDescription }
    }
    private func receiveNotification(_ action: SystemNotificationSink.Action) async {
        do {
            switch action {
            case .open(let id):
                guard let summary = try await storage.summary(id) else { return }
                summaryEventKeys = summary.eventKeys; destination = .activity
                await reloadActivity()
                // AppShell may not exist when the main window is closed; the status item can always reopen it.
                statusItem.showMain()
                NSApplication.shared.activate()
            case .snooze(let id):
                guard try await storage.summary(id) != nil else { return }
                let until = try await storage.snoozeNotifications()
                pollStatus = "Notifications snoozed until " + until.formatted(date:.omitted,time:.shortened) + "."
            }
        } catch { pollStatus = "The notification action could not load local activity." }
    }
    /// One account-wide read per call, shared with the PR workspace. The token is taken BEFORE the read: rows read
    /// before an account was removed or invalidated could restore it, so they are discarded and read once more.
    /// `refreshing` limits PR row reads to those repositories (the rest come from the storage row cache).
    private func reloadSnapshots(refreshing:Set<RepositoryKey>? = nil) async throws {
        for _ in 0..<2 {
            let token = prs.reloadToken()
            let stored = if let refreshing { try await storage.load(refreshing:refreshing) } else { try await storage.load() }
            guard prs.isCurrent(token) else { continue }
            snapshots = stored.0
            await prs.reload(snapshots:stored.0,activeAccount:stored.2,token:token)
            return
        }
    }
    func saveClientID() async {
        cancelAuthorization()
        clientID = clientID.trimmingCharacters(in:.whitespacesAndNewlines)
        do { try await storage.setting(clientID, for:.githubClientID); message = "GitHub OAuth App configuration saved." }
        catch { message = "The client ID could not be saved locally." }
    }
    func connect(replacing account: AccountScope? = nil) {
        cancelAuthorization()
        guard !clientID.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { message = "Configure your GitHub OAuth App client ID in Settings."; return }
        if let account { invalidateUIOperations(account); reconnecting.insert(account) }
        let id = UUID(); sessionID = id
        let client = DeviceFlowClient(clientID:clientID, transport:dependencies.signInTransport)
        authorization = client; isConnecting = true; message = nil
        authorizationTask = Task { [weak self] in
            guard let self else { return }
            do {
                if let account { try await self.storage.invalidateOperations(account) }
                guard self.sessionID == id, !Task.isCancelled else { return }
                let result = try await client.authorize { [weak self] state in
                    await self?.receive(state, session:id)
                }
                guard self.sessionID == id, !Task.isCancelled else { return }
                self.invalidateUIOperations(result.scope)
                try await self.storage.save(result,replacing:account)
                guard self.sessionID == id, !Task.isCancelled else { return }
                // The account is saved: leaving Setup or Settings (cancelAuthorization) must no longer abort its first discovery.
                self.authorization = nil; self.authorizationTask = nil
                if let account { self.reconnecting.remove(account) }
                self.isConnecting = false; self.userCode = nil; self.verificationURL = nil
                self.prs.acceptAuthorization(result.scope)
                self.accountProblems[result.scope] = nil
                try await self.reloadSnapshots()
                guard self.snapshots.contains(where:{ $0.account?.scope == result.scope }) else { return } // removed meanwhile
                await self.selectAccount(result.scope)
                await self.discover(result.scope)
            } catch {
                guard self.sessionID == id else { return }
                if let account { self.reconnecting.remove(account) }
                self.isConnecting = false
                if case .accountMismatch = error as? SetupError { self.message = "That browser signed into a different GitHub account. Reconnect using the account selected here." }
                else if !(error is CancellationError), (error as? DeviceFlowFailure)?.isCancellation != true, self.message == nil {
                    self.message = "The account could not be saved. Check Keychain access and try again."
                }
            }
        }
    }
    private func receive(_ state: DeviceFlowState, session: UUID) {
        guard sessionID == session else { return }
        authorizationState = state
        switch state {
        case .awaitingUser(let code, let url): userCode = code; verificationURL = url
        case .failed(let text): message = text; userCode = nil; verificationURL = nil
        case .expired: message = "The GitHub code expired. Connect again to get a new code."; userCode = nil; verificationURL = nil
        case .cancelled: message = "GitHub connection cancelled."; userCode = nil; verificationURL = nil
        default: break
        }
    }
    func cancelAuthorization() {
        sessionID = UUID(); authorizationTask?.cancel()
        if let authorization { Task { await authorization.cancel() } }
        authorization = nil; authorizationTask = nil; isConnecting = false; userCode = nil; verificationURL = nil
        reconnecting.removeAll()
    }
    func openVerification() { if let verificationURL { NSWorkspace.shared.open(verificationURL) } }
    private func invalidateUIOperations(_ account: AccountScope) {
        discoveryGenerations[account] = UUID(); discovering.remove(account)
    }
    func discoveryBlocked(_ account: AccountScope, at date: Date) -> Bool {
        discovering.contains(account) || reconnecting.contains(account) || (retryDeadlines[account].map { $0 > date } ?? false)
    }
    func discover(_ account: AccountScope) async {
        guard !discoveryBlocked(account,at:Date()), accountProblems[account] == nil else { return }
        let id = UUID(); discoveryGenerations[account] = id
        discovering.insert(account)
        defer { if discoveryGenerations[account] == id { discovering.remove(account) } }
        let outcome = await storage.discover(account,clientID:clientID)
        guard discoveryGenerations[account] == id else { return }
        switch outcome {
        case .updated(let result):
            retryDeadlines[account] = result.retryAt
            do {
                let token = prs.reloadToken(), stored = try await storage.load()
                guard discoveryGenerations[account] == id else { return }
                // Read before another account was removed or invalidated: read again rather than restore it.
                guard prs.isCurrent(token) else { try await reloadSnapshots(); return }
                self.snapshots = stored.0; await prs.reload(snapshots:stored.0,activeAccount:stored.2,token:token)
            } catch { message = "GitHub discovery finished, but local setup could not be loaded. Check access to MergePro’s application support directory." }
        case .authorizationRequired(let localPersistenceFailed):
            prs.invalidateAccount(account)
            accountProblems[account] = "GitHub access expired or was revoked. Reconnect this account to continue. Your drafts remain local."
            if localPersistenceFailed { message = "The invalid account state could not be saved locally. Check local file access; this account remains disabled in the current session." }
        case .retryable:
            accountProblems[account] = "GitHub discovery could not complete. Check your connection and retry. Your saved access and local data remain available."
        case .throttled(let until): retryDeadlines[account] = until
        case .stale: break
        }
    }
    func retryDiscovery(_ account: AccountScope) async {
        guard !discoveryBlocked(account,at:Date()), accountProblems[account]?.contains("revoked") != true else { return }
        accountProblems[account] = nil; await discover(account)
    }
    func selectAccount(_ account: AccountScope) async {
        do { try await storage.setting(KeychainTokenStore.reference(for:account),for:.activeActionAccount); if activeAccount != account { cancelPrefetch() }; activeAccount = account; prs.activeActionAccount=account; featureGeneration = UUID() }
        catch { message = "The active account could not be saved." }
    }
    func setTracked(_ repository: Repository, enabled: Bool) async {
        await setRepositorySelection([repository.key],enabled:enabled,owner:RepositoryScopeConfiguration.owner(of:repository),account:repository.key.account)
    }
    func setRepositoryScope(_ mode:RepositoryScopeMode,owner:String,account:AccountScope) async {
        guard canEditRepositoryScope(account) else { return }
        do {
            try await storage.repositoryScope(mode,owner:owner,account:account)
            guard canEditRepositoryScope(account) else { return }
            try await reloadSnapshots()
        } catch {
            guard activeAccount == account else { return }
            message = "Repository tracking could not be saved."
        }
    }
    func setRepositorySelection(_ keys:Set<RepositoryKey>,enabled:Bool,owner:String,account:AccountScope) async {
        guard canEditRepositoryScope(account) else { return }
        do {
            try await storage.repositorySelection(keys,enabled:enabled,owner:owner,account:account)
            guard canEditRepositoryScope(account) else { return }
            try await reloadSnapshots()
        } catch {
            guard activeAccount == account else { return }
            message = "Repository tracking could not be saved."
        }
    }
    private func canEditRepositoryScope(_ account:AccountScope) -> Bool {
        activeAccount == account && !reconnecting.contains(account) && snapshots.contains {
            $0.account?.scope == account && $0.settings[.authorizationProblem] != "true"
        }
    }
    func setPinned(_ repository: Repository, enabled: Bool) async {
        do { try await storage.pinned(repository.key,enabled:enabled); try await reloadSnapshots() }
        catch { message = "The pin could not be saved." }
    }
    func remove(_ account: AccountScope) async {
        cancelAuthorization(); invalidateUIOperations(account); featureGeneration = UUID(); cancelPrefetch()
        do {
            try await storage.remove(account); prs.invalidateAccount(account,removed:true); accountProblems[account] = nil; retryDeadlines[account] = nil
            purgeFeatureCaches(account)
            if actionsRepository?.account == account { actionsRepository = nil; actionRunID = nil; actionWorkflowID = nil; actionPresetID = nil }
            if repoRoute?.repository.account == account { repoRoute = nil }
            if localCheckout?.repository.account == account { localCheckout = nil }
            try await reloadSnapshots()
            if activeAccount == account {
                activeAccount = nil
                try await storage.setting(nil,for:.activeActionAccount)
                if let next = snapshots.first?.account?.scope { await selectAccount(next) }
            }
        } catch { message = "The account could not be fully removed. Check Keychain and local file access, then retry. Your drafts remain local." }
    }
    func setNotifications(_ enabled: Bool) async {
        do {
            if enabled {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(options:[.alert,.sound,.badge])
                notificationsEnabled = granted
            } else { notificationsEnabled = false }
            try await storage.setting(notificationsEnabled ? "true" : "false",for:.notificationsEnabled)
            let settings = await UNUserNotificationCenter.current().notificationSettings(); updateNotificationStatus(settings.authorizationStatus)
        } catch { message = "Notification permission could not be updated. In-app updates remain available." }
    }
    private func updateNotificationStatus(_ status: UNAuthorizationStatus) {
        switch status {
        case .denied: notificationStatus = "Notifications are disabled in macOS. In-app updates remain available."
        case .authorized, .provisional: notificationStatus = notificationsEnabled ? "System summaries are enabled for future updates." : "System summaries are off. In-app updates remain available."
        default: notificationStatus = "Enable system summaries for reviews and repository updates. You can keep using the in-app inbox without them."
        }
    }
    func setLoginEnabled(_ enabled: Bool) {
        do { try LoginItemService().setEnabled(enabled); loginEnabled = LoginItemService().enabled; loginNeedsApproval = LoginItemService().needsApproval }
        catch { message = "Launch at login could not be changed. Review MergePro in System Settings → General → Login Items." }
    }
}
struct FeatureWorkflowEntry:Identifiable {
    let repository:Repository
    let workflow:ActionsWorkflow
    var id:String { repository.key.account.host+":"+repository.key.account.accountID+":"+repository.key.repositoryID+":"+String(workflow.id) }
}
private extension DeviceFlowFailure {
    var isCancellation: Bool { if case .cancelled = self { true } else { false } }
}
