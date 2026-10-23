import Foundation

/// The provider services of one local store: a database and payload cache in one folder, one account session over
/// one transport and credential store, and one rate budget. Each is built on first use and kept; services that
/// capture the OAuth client ID are rebuilt after `clientIDChanged()`.
///
/// Not thread-safe: confine an instance to one owner (the App's storage actor). The services it returns are Sendable.
public final class AppServices {
    public struct Configuration: Sendable {
        /// The store's folder. Called on first use; a throw fails that store access (and the next one retries).
        public var directory: @Sendable () throws -> URL
        public var credentials: any GitHubCredentialStore
        /// Every provider request of the session and the services built on it.
        public var transport: any GitHubTransport
        public var pollFetchers: [any PollFeatureFetcher]
        public var mergeAdapter: @Sendable (DatabaseStore) -> any MergeAdapter
        /// Runs once after the database opens and migrates (including renamed settings), before any service reads it.
        public var prepareDatabase: @Sendable (DatabaseStore) throws -> Void
        public init(directory: @escaping @Sendable () throws -> URL, credentials: any GitHubCredentialStore,
                    transport: any GitHubTransport, pollFetchers: [any PollFeatureFetcher] = Configuration.providerFetchers,
                    mergeAdapter: @escaping @Sendable (DatabaseStore) -> any MergeAdapter = { _ in GitHubMergeAdapter() },
                    prepareDatabase: @escaping @Sendable (DatabaseStore) throws -> Void = { _ in }) {
            self.directory = directory; self.credentials = credentials; self.transport = transport
            self.pollFetchers = pollFetchers; self.mergeAdapter = mergeAdapter; self.prepareDatabase = prepareDatabase
        }
        /// GitHub notifications, PR inventory and Actions: what a poll cycle reads in the shipped app.
        public static var providerFetchers: [any PollFeatureFetcher] {
            [GitHubNotificationFeedFetcher(), GitHubPRInventoryFetcher(), GitHubActionsFetcher()]
        }
        /// `name` inside the user's Application Support folder.
        public static func applicationSupport(_ name: String) -> @Sendable () throws -> URL {
            { try FileManager.default.url(for:.applicationSupportDirectory, in:.userDomainMask, appropriateFor:nil, create:true).appendingPathComponent(name, isDirectory:true) }
        }
    }

    public let budget: RateBudget
    private let configuration: Configuration
    private var database: DatabaseStore?
    private var cache: CacheStore?
    private var session: GitHubAccountSession?
    private var pollStore: PollCycleStore?
    private var coordinator: PollCoordinator?
    private var actions: ActionsService?
    private var repositoryBrowser: RepositoryBrowserService?

    /// Three requests per account in flight (background GraphQL still one at a time): the sync of an account with
    /// hundreds of repositories is bound by request latency, not by its hourly quota.
    public init(_ configuration: Configuration, budget: RateBudget = RateBudget(concurrency: 3)) {
        self.configuration = configuration; self.budget = budget
    }

    /// Opens the store on first use: an owner-only folder holding `mergepro.sqlite` and the `Payloads` cache.
    public func stores() throws -> (DatabaseStore, CacheStore) {
        if let database, let cache { return (database, cache) }
        let directory = try configuration.directory()
        try FileManager.default.createDirectory(at:directory, withIntermediateDirectories:true, attributes:[.posixPermissions:0o700])
        let database = try DatabaseStore(path:directory.appendingPathComponent("mergepro.sqlite").path)
        let cache = try CacheStore(directory:directory.appendingPathComponent("Payloads", isDirectory:true), database:database)
        try configuration.prepareDatabase(database)
        self.database = database; self.cache = cache
        return (database, cache)
    }
    public func accountSession() throws -> GitHubAccountSession {
        if let session { return session }
        let (database, cache) = try stores()
        let session = GitHubAccountSession(storage:AccountSessionStore(database:database, cache:cache, credentials:configuration.credentials),
                                           transport:configuration.transport)
        self.session = session
        return session
    }
    /// The configured OAuth client ID; empty when none is set.
    public func clientID() throws -> String { try stores().0.applicationSetting(.githubClientID) ?? "" }
    /// Drops cached services that captured the previous client ID; the next request builds them again.
    public func clientIDChanged() { actions = nil; repositoryBrowser = nil }

    public func actionsService() throws -> ActionsService {
        if let actions { return actions }
        let database = try stores().0
        let service = ActionsService(session:try accountSession(), budget:budget, database:database, clientID:try clientID(),
                                     activeAccount:Self.activeAccount(database))
        actions = service
        return service
    }
    public func repositoryBrowserService() throws -> RepositoryBrowserService {
        if let repositoryBrowser { return repositoryBrowser }
        let database = try stores().0
        let service = RepositoryBrowserService(session:try accountSession(), budget:budget, database:database, clientID:try clientID(),
                                               activeAccount:Self.activeAccount(database))
        repositoryBrowser = service
        return service
    }
    /// A new service per call, so it reads the current client ID.
    public func repositoryPRInventory() throws -> RepositoryPRInventoryService {
        RepositoryPRInventoryService(session:try accountSession(), budget:budget, database:try stores().0, clientID:try clientID())
    }
    public func pollingStore() throws -> PollCycleStore {
        if let pollStore { return pollStore }
        let store = PollCycleStore(database:try stores().0)
        pollStore = store
        return store
    }
    /// The single poll coordinator. `sink` and `policy` are used only by the call that builds it. The coordinator
    /// reads the client ID at every cycle and asks `policy` for the notification policy when a cycle closes.
    public func pollCoordinator(sink: any NotificationSink, policy: @escaping @Sendable () async throws -> NotificationPolicy) throws -> PollCoordinator {
        if let coordinator { return coordinator }
        let store = try pollingStore(), database = try stores().0
        let coordinator = PollCoordinator(store:store, publisher:PollNotificationPublisher(store:store, sink:sink),
            fetchers:configuration.pollFetchers, budget:budget, session:try accountSession(),
            clientID:{ try database.applicationSetting(.githubClientID) ?? "" }, policyProvider:policy)
        self.coordinator = coordinator
        return coordinator
    }
    public func notificationThreadCoordinator() throws -> NotificationThreadCoordinator {
        let database = try stores().0
        return NotificationThreadCoordinator(database:database, session:try accountSession(), budget:budget, clientID:try clientID(),
                                             activeAccount:Self.activeAccount(database))
    }
    public func detailService() throws -> PRDetailService {
        PRDetailService(session:try accountSession(), budget:budget, clientID:try clientID())
    }
    public func writeCoordinator() throws -> PRWriteCoordinator {
        let database = try stores().0
        return PRWriteCoordinator(session:try accountSession(), budget:budget, database:database, clientID:try clientID(),
                                  activeAccount:Self.activeAccount(database))
    }
    public func mergeCoordinator() throws -> MergeCoordinator {
        let database = try stores().0
        return MergeCoordinator(session:try accountSession(), budget:budget, database:database, clientID:try clientID(),
                                activeAccount:Self.activeAccount(database), adapter:configuration.mergeAdapter(database))
    }
    /// Read at each use, so a later account switch applies to services built before it.
    private static func activeAccount(_ database: DatabaseStore) -> @Sendable () async throws -> AccountScope? {
        { try database.activeActionAccount() }
    }
}
