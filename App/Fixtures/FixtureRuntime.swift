import AppKit
import Foundation
import SwiftUI
import MergeProCore
import MergeProRendering

/// The fixture app's storage and workspace hooks (see `FixtureHooks`). Offline: seeds, scripted transports and
/// fixture detail only; it never reaches URLSession or the Keychain.
final class FixtureRuntime: FixtureHooks {
    /// Shared by the Phase 1 session and the fixture controls that release, confirm or deny its scripted reads.
    let phase1Transport = PRPhase1FixtureTransport()
    private let phase1Preparation = Phase1Preparation()
    /// Native PR detail fixtures replace the detail service unless Phase 1 scripts the provider instead.
    let detail: (any OfflinePRDetail)? = PRNativeFixtures.enabled && !PRPhase1Fixtures.enabled ? PRDetailFixtureSource() : nil
    var launchDestination: String? {
        Phase23Fixtures.enabled ? ProcessInfo.processInfo.environment["MERGEPRO_PHASE23_DESTINATION"] : nil
    }
    func seed(_ database: DatabaseStore) throws {
        if Phase23Fixtures.enabled { try Phase23Fixtures.seed(database) }
        else if PRPhase1Fixtures.enabled { try PRPhase1Fixtures.seedAccounts(database) } else { try PRNativeFixtures.seed(database) }
    }
    func prepare(database: DatabaseStore, session: GitHubAccountSession, budget: RateBudget) async throws {
        guard PRPhase1Fixtures.enabled else { return }
        try await phase1Preparation.run(database:database, session:session, budget:budget, transport:phase1Transport)
    }
    func manualRefresh(_ database: DatabaseStore) throws { try PRNativeFixtures.refresh(database) }
    @MainActor func makeWorkspaceInstrumentation() -> (any WorkspaceInstrumentation)? { FixtureWorkspaceInstrumentation() }
    let detailInstrumentation: (any PRDetailInstrumentation)? = FixtureDetailInstrumentation()
    let codeSurfaceInstrumentation: (any CodeSurfaceInstrumentation)? = FixtureCodeSurfaceInstrumentation()
}

/// Phase 1's scripted provider preparation runs once per store; later callers wait for that run.
private actor Phase1Preparation {
    private var task: Task<Void,Error>?
    func run(database: DatabaseStore, session: GitHubAccountSession, budget: RateBudget, transport: PRPhase1FixtureTransport) async throws {
        if task == nil {
            task = Task {
                await PRPhase1NativeVerification.mark("preparation-begin")
                try await PRPhase1Fixtures.prepare(database,session:session,budget:budget)
                await transport.holdFreshDetail()
                await PRPhase1NativeVerification.mark("preparation-end",["scopedRows":20,"selectedLines":500,"files":2,"cache":"payloads/blobs warmed; no predecoded snapshot or token warmth claim"])
            }
        }
        try await task!.value
    }
}

private struct PRDetailFixtureSource: OfflinePRDetail {
    func snapshot(_ pr: PullRequest) -> PRDetailSnapshot { PRDetailFixtures.snapshot(pr) }
    func blob(_ pr: PullRequest, path: String, sha: String) -> Data { PRDetailFixtures.blob(pr,path:path,sha:sha) }
}

/// Phase 1 fixture controls (`PRPhase1FixtureControls`): scripted provider events of the shared Phase 1 transport.
extension SetupStorage {
    private var phase1Transport: PRPhase1FixtureTransport? {
        PRPhase1Fixtures.enabled ? (dependencies.fixtures as? FixtureRuntime)?.phase1Transport : nil
    }
    func releasePhase1Refresh() async { await phase1Transport?.releaseRefresh() }
    func confirmPhase1Merge() async { await phase1Transport?.confirmMerge() }
    func movePhase1Revision() async { await phase1Transport?.moveHeadOnIdentity() }
    func denyPhase1B() async throws {
        guard let transport = phase1Transport else { return }
        let database=try stores().0,account=PRPhase1Fixtures.accounts[1]
        try database.installPhase1AuthorizationPersistenceFailure(account:account)
        await transport.denyAccountB()
        guard let pr=try database.snapshot(for:account).pullRequests.first(where:{ $0.metadata?.number == 1 }) else { return }
        do { _ = try await detailService().section(pr,tab:.overview) } catch {
            let state=try await accountSession().authorizationState(for:account)
            await PRPhase1NativeVerification.mark("owner-denial",["account":account.accountID,"localPersistenceFailed":state == .authorizationRequired(localPersistenceFailed:true)])
        }
    }
}

/// Per-workspace fixture measurements: TASK5 timings on standard error, Phase 1 marks, the refresh status line
/// the UI tests read (`fixtureRefreshStatus`) and the Phase 1 window probe.
@MainActor @Observable final class FixtureWorkspaceInstrumentation: WorkspaceInstrumentation {
    /// Comments of the highest-numbered fixture row; each manual fixture refresh adds one.
    private(set) var refreshRevision = 0
    private(set) var projectionRevision = 0
    @ObservationIgnored private var cacheStart = ContinuousClock.now
    @ObservationIgnored private var projectStart = ContinuousClock.now
    func loadWillBegin() async {
        await PRPhase1NativeVerification.shared.waitForRelease()
        cacheStart = .now
        PRPhase1NativeVerification.mark("workspace-load-begin")
    }
    func loadDidFinish(rows: Int) -> String? {
        let seconds = cacheStart.duration(to: .now).components
        let milliseconds = Double(seconds.seconds) * 1000 + Double(seconds.attoseconds) / 1e15
        let status = String(format: "Fixture cache + projection: %.1f ms · %d PRs · API: offline", milliseconds, rows)
        FileHandle.standardError.write(Data("TASK5 \(status)\n".utf8))
        return status
    }
    func rowsDidReload(_ rows: [PullRequest]) {
        refreshRevision = rows.max { ($0.metadata?.number ?? 0) < ($1.metadata?.number ?? 0) }?.metadata?.comments ?? 0
    }
    func projectionWillBegin() { projectStart = .now }
    func projectionDidFinish(rows: Int) {
        let elapsed = projectStart.duration(to: .now).components
        FileHandle.standardError.write(
            Data("TASK5 materialized projection/cells: \(Double(elapsed.seconds)*1000+Double(elapsed.attoseconds)/1e15) ms · \(rows) PRs\n".utf8))
    }
    func didPublish(rows: Int, visibleRows: Int) {
        projectionRevision += 1
        PRPhase1NativeVerification.mark("workspace-projection-publication",["generation":projectionRevision,"rows":rows,"visibleRows":visibleRows])
    }
    func willOpen(_ key: ProviderKey) { if PRPhase1Fixtures.enabled { PRPhase1NativeVerification.shared.open(key) } }
    var footer: AnyView? {
        AnyView(Text("Fixture refresh \(refreshRevision)").font(.caption2).accessibilityIdentifier("fixtureRefreshStatus"))
    }
    var probe: AnyView? {
        PRPhase1Fixtures.enabled ? AnyView(PRPhase1WindowProbe(tag:"workspace",generation:projectionRevision)) : nil
    }
}

/// PR detail measurements: detail-metrics windows open on Files; Phase 1 holds each load at its readiness barrier,
/// opens Files and marks the load's checkpoints, presentation publications and source reads.
struct FixtureDetailInstrumentation: PRDetailInstrumentation {
    @MainActor func windowWillOpen(_ model: PRDetailModel) {
        if PRDetailFixtureMetrics.enabled { model.tab = .files }
    }
    @MainActor func loadWillBegin(_ key: ProviderKey, model: PRDetailModel) async {
        guard PRPhase1Fixtures.enabled else { return }
        PRPhase1NativeVerification.shared.route(key)
        await PRPhase1NativeVerification.shared.waitForRelease()
        model.tab = .files
        PRPhase1NativeVerification.mark("detail-settings-progress-baseline-begin",["account":key.accountID,"object":key.objectID])
    }
    @MainActor func loadTrace(_ key: ProviderKey) -> PRDetailLoadTrace {
        var trace=PRDetailLoadTrace()
        trace.cachedReadBegin={ PRPhase1NativeVerification.mark("cached-detail-read-begin",["account":key.accountID,"object":key.objectID]) }
        trace.cachedApplied={ PRPhase1NativeVerification.shared.cached(key) }
        trace.freshReadBegin={ PRPhase1NativeVerification.mark("fresh-detail-read-begin",["account":key.accountID,"object":key.objectID]) }
        trace.freshReadEnd={ PRPhase1NativeVerification.mark("fresh-detail-read-end",["account":key.accountID,"object":key.objectID]) }
        return trace
    }
    @MainActor func presentationPublished(_ presentation: CodePresentationIdentity, duration: Duration) {
        PRPhase1NativeVerification.mark("presentation-worker-publication",presentation.fields.merging(["durationMs":PRPhase1NativeVerification.seconds(duration)*1000,"scope":"worker scheduling/presentations/markers/main publication; excludes native viewport"],uniquingKeysWith:{ _,new in new }))
    }
    @MainActor func sourceRead(_ key: ProviderKey, path: String, side: DiffSide, bytes: Int, duration: Duration) {
        PRPhase1NativeVerification.mark("selected-source-read",["account":key.accountID,"path":path,"side":side.rawValue,"bytes":bytes,"durationMs":PRPhase1NativeVerification.seconds(duration)*1000,"scope":"actual immutable lazy service/cache read; dispatch proven separately"])
    }
    @MainActor func sourceTokenized(_ key: ProviderKey, path: String, side: DiffSide, duration: Duration) {
        PRPhase1NativeVerification.mark("selected-source-tokenized",["account":key.accountID,"path":path,"side":side.rawValue,"durationMs":PRPhase1NativeVerification.seconds(duration)*1000,"scope":"tokenizer scheduling plus mapping; may reuse worker cache"])
    }
}

/// Code surface measurements: Phase 1 viewport and installation marks, otherwise the detail-metrics records.
struct FixtureCodeSurfaceInstrumentation: CodeSurfaceInstrumentation {
    @MainActor func surfaceCreated(_ surface: NativeCodeSurface) -> AnyObject? {
        PRPhase1Fixtures.enabled ? ViewportObservation(surface) : nil
    }
    @MainActor func documentInstalled(_ surface: NativeCodeSurface, presentation: CodePresentationIdentity?, duration: Duration) {
        if PRPhase1Fixtures.enabled { PRPhase1NativeVerification.observe(surface,identity:presentation,installation:duration) }
        else { PRDetailFixtureMetrics.observe(surface,setDocumentDuration:duration) }
    }
}

/// Reports each clip-bounds change of one surface while its view lives.
@MainActor private final class ViewportObservation {
    weak var surface:NativeCodeSurface?
    var observation:NSObjectProtocol?
    init(_ surface:NativeCodeSurface) {
        self.surface=surface
        observation=NotificationCenter.default.addObserver(forName:NSView.boundsDidChangeNotification,object:surface.contentView,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated { if let surface=self?.surface { PRPhase1NativeVerification.viewportChanged(surface) } }
        }
    }
    isolated deinit { if let observation { NotificationCenter.default.removeObserver(observation) } }
}

/// The main window's fixture chrome: detail-window metrics launches and the Phase 1 probe and controls.
struct ShellFixtureChrome: ViewModifier, Sendable {
    let model: SetupModel
    func body(content: Content) -> some View {
        content
            .modifier(PRDetailFixtureLauncher(model:model))
            .background { if PRPhase1Fixtures.enabled { PRPhase1WindowProbe(tag:"shell") } }
            .safeAreaInset(edge:.bottom) { if PRPhase1Fixtures.enabled { PRPhase1FixtureControls(model:model) } }
    }
}
