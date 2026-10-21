import Foundation
import Synchronization
import SwiftUI
import MergeProCore
import MergeProRendering

/// What differs between the shipped app and the offline fixture app, built once at the app's entry point and
/// handed to `SetupModel` and `SetupStorage`. The shipped app uses `production()`; the MergeProFixtures target
/// builds its own in App/Fixtures (compiled only by that target), so production files need no fixture switches.
struct AppDependencies: Sendable {
    /// The store's folder inside Application Support; nil when this launch has no usable store (every store access fails).
    var storageDirectoryName: String?
    var credentials: any GitHubCredentialStore
    /// Provider reads and writes of the account session and every service built on it.
    var transport: any GitHubTransport
    /// Device-flow sign-in requests.
    var signInTransport: any GitHubTransport
    var pollFetchers: [any PollFeatureFetcher]
    var mergeAdapter: @Sendable (DatabaseStore) -> any MergeAdapter
    var clock: @Sendable () -> Date
    var makeNotificationSink: @MainActor @Sendable (_ isEnabled: @escaping @Sendable () async -> Bool) -> SystemNotificationSink
    /// Background PR detail reads: the post-cycle prefetch and warming the focused card. Off where measurements need cold reads.
    var speculativeDetailReads: Bool
    /// Poll cycles report what they committed, so the workspace re-reads only that. Off when rows also change outside the poller.
    var reportsCycleChanges: Bool
    /// Why this app registers no global shortcuts (shown in Settings); nil registers them.
    var globalHotkeysUnavailable: String?
    /// Offline hooks: the fixture app's, or the shipped app's sample-data mode (`SampleMode`); nil otherwise.
    var fixtures: (any FixtureHooks)?

    /// The shipped app. A Debug build launched with `MERGEPRO_UI_TEST_NAMESPACE` (UI tests) uses a disposable store
    /// and Keychain service named by it; a Release build ignores it. With `MERGEPRO_DISABLE_REAL_STORE=1` (set by the
    /// MergePro scheme's test action) the real store fails closed, so a unit-test host `MergeProApp` failed to detect
    /// still opens no database and never reaches an account's Keychain item or GitHub.
    static func production(environment: [String:String] = ProcessInfo.processInfo.environment) -> AppDependencies {
        #if DEBUG
        let namespace = environment["MERGEPRO_UI_TEST_NAMESPACE"].flatMap(UUID.init(uuidString:))?.uuidString
        #else
        let namespace: String? = nil
        #endif
        let realStore = environment[disableRealStoreVariable] == "1" ? nil : "MergePro"
        return AppDependencies(
            storageDirectoryName:namespace.map { "MergeProUIFixtures/" + $0 } ?? realStore,
            credentials:KeychainTokenStore(service:namespace.map { KeychainTokenStore.service + ".uitests." + $0 } ?? KeychainTokenStore.service),
            transport:URLSessionGitHubTransport(), signInTransport:URLSessionGitHubTransport(),
            pollFetchers:AppServices.Configuration.providerFetchers, mergeAdapter:{ _ in GitHubMergeAdapter() },
            clock:{ Date() }, makeNotificationSink:{ SystemNotificationSink(isEnabled:$0) },
            speculativeDetailReads:true, reportsCycleChanges:true, globalHotkeysUnavailable:nil, fixtures:nil)
    }
    static let disableRealStoreVariable = "MERGEPRO_DISABLE_REAL_STORE"

    /// The shipped app hosting MergeProAppTests (`MergeProApp` detects XCTest): no store (every store access fails),
    /// credentials kept only in memory, every request refused, no poll fetchers, no notification delivery and no
    /// global shortcuts. Tests that need their own dependencies build them with `TestDependencies`.
    static func unitTestHost() -> AppDependencies {
        AppDependencies(
            storageDirectoryName:nil, credentials:InMemoryCredentialStore(),
            transport:OfflineTransport(), signInTransport:OfflineTransport(),
            pollFetchers:[], mergeAdapter:{ _ in GitHubMergeAdapter() },
            clock:{ Date() }, makeNotificationSink:{ _ in SystemNotificationSink(isEnabled:{ false }, showsTitles:{ false }) },
            speculativeDetailReads:false, reportsCycleChanges:true,
            globalHotkeysUnavailable:"Global shortcuts are disabled while unit tests run.", fixtures:nil)
    }
}

/// Credentials of one unit-test process; never the Keychain.
final class InMemoryCredentialStore: GitHubCredentialStore {
    private let credentials = Mutex<[AccountScope:GitHubCredential]>([:])
    func credential(for account: AccountScope) throws -> GitHubCredential? { credentials.withLock { $0[account] } }
    func save(_ credential: GitHubCredential, account: AccountScope) throws { credentials.withLock { $0[account] = credential } }
    func remove(account: AccountScope) throws { _ = credentials.withLock { $0.removeValue(forKey:account) } }
}

/// Refuses every request without reaching the network.
struct OfflineTransport: GitHubTransport {
    func send(_ request: URLRequest) async throws -> GitHubResponse { throw URLError(.notConnectedToInternet) }
}

/// Hooks of the offline fixture app (App/Fixtures). The shipped app installs none, so each use is a no-op there.
protocol FixtureHooks: Sendable {
    /// Seeds a newly opened store.
    func seed(_ database: DatabaseStore) throws
    /// Runs before each snapshot load and poll cycle (scripted provider preparation, at most once).
    func prepare(database: DatabaseStore, session: GitHubAccountSession, budget: RateBudget) async throws
    /// A manual refresh's local change: fixture rows change outside the poller.
    func manualRefresh(_ database: DatabaseStore) throws
    /// Offline PR detail. While set, detail reads never reach the detail service or its caches.
    var detail: (any OfflinePRDetail)? { get }
    /// The destination a launch opens (`SetupModel.Destination` raw value); nil keeps the usual one.
    var launchDestination: String? { get }
    /// Measurement hooks of one PR workspace.
    @MainActor func makeWorkspaceInstrumentation() -> (any WorkspaceInstrumentation)?
    /// Measurement hooks of PR detail windows and their diffs.
    var detailInstrumentation: (any PRDetailInstrumentation)? { get }
    /// Measurement hooks of native code surfaces, in every window's environment (`codeSurfaceInstrumentation`).
    var codeSurfaceInstrumentation: (any CodeSurfaceInstrumentation)? { get }
}

/// Offline PR detail content.
protocol OfflinePRDetail: Sendable {
    func snapshot(_ pr: PullRequest) -> PRDetailSnapshot
    func blob(_ pr: PullRequest, path: String, sha: String) -> Data
}

/// Measurement hooks of one `PRWorkspaceModel`, with the views it adds to its `PRWorkspaceView`.
@MainActor protocol WorkspaceInstrumentation: AnyObject {
    func loadWillBegin() async
    /// The status the workspace shows after its first load; nil keeps the current one.
    func loadDidFinish(rows: Int) -> String?
    /// Every stored row after a reload, including rows outside the workspace's repository scope.
    func rowsDidReload(_ rows: [PullRequest])
    func projectionWillBegin()
    func projectionDidFinish(rows: Int)
    func didPublish(rows: Int, visibleRows: Int)
    func willOpen(_ key: ProviderKey)
    /// A line under the board.
    var footer: AnyView? { get }
    /// A background of the whole workspace.
    var probe: AnyView? { get }
}

/// Measurement hooks of PR detail windows (`PRDetailWindow`) and their diffs (`RichDiffView`).
protocol PRDetailInstrumentation: Sendable {
    /// A new window's model, before its first render.
    @MainActor func windowWillOpen(_ model: PRDetailModel)
    /// Runs before each load of `key`'s window; it may hold the load or change the model (e.g. its tab).
    @MainActor func loadWillBegin(_ key: ProviderKey, model: PRDetailModel) async
    /// Checkpoints of that load.
    @MainActor func loadTrace(_ key: ProviderKey) -> PRDetailLoadTrace
    /// A diff published `presentation`, `duration` after it began preparing it.
    @MainActor func presentationPublished(_ presentation: CodePresentationIdentity, duration: Duration)
    /// One side of a diff read its immutable source (`bytes` long) in `duration`.
    @MainActor func sourceRead(_ key: ProviderKey, path: String, side: DiffSide, bytes: Int, duration: Duration)
    /// That source was tokenized and its tokens mapped in `duration`.
    @MainActor func sourceTokenized(_ key: ProviderKey, path: String, side: DiffSide, duration: Duration)
}

/// Measurement hooks of native code surfaces (`CodeTextView`).
protocol CodeSurfaceInstrumentation: Sendable {
    /// A new surface; the returned object lives as long as the surface's view.
    @MainActor func surfaceCreated(_ surface: NativeCodeSurface) -> AnyObject?
    /// `surface` installed its document in `duration`; `presentation` is the diff presentation it shows, if known.
    @MainActor func documentInstalled(_ surface: NativeCodeSurface, presentation: CodePresentationIdentity?, duration: Duration)
}
