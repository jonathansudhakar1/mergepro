import Foundation
import MergeProCore

/// The reads and local writes behind a PR window: `SetupStorage` in the app, fakes in tests.
protocol PRDetailServices:Sendable {
    func codeAppearance() async throws -> CodeAppearance
    func detailState(_ pr:PullRequest) async throws -> PRDetailState
    func saveDetailState(_ state:PRDetailState,key:ProviderKey) async throws
    func detailRepositoryBaseline(_ pr:PullRequest) async throws -> RepositorySizeBaseline
    func cachedDetailDescription(_ pr:PullRequest) async throws -> PRDescriptionSnapshot?
    func cachedDetail(_ pr:PullRequest) async throws -> PRDetailSnapshot?
    func detailDescription(_ pr:PullRequest,maxAge:TimeInterval) async throws -> PRDescriptionSnapshot
    func detail(_ pr:PullRequest,maxAge:TimeInterval) async throws -> PRDetailSnapshot
    func detail(_ pr:PullRequest) async throws -> PRDetailSnapshot
    func moreDetail(_ pr:PullRequest,snapshot:PRDetailSnapshot) async throws -> PRDetailSnapshot
    func cachedDetailSection(_ pr:PullRequest,tab:PRDetailTab) async throws -> PRDetailSection?
    func detailSection(_ pr:PullRequest,tab:PRDetailTab) async throws -> PRDetailSection
    func compareDetail(_ pr:PullRequest,base:String,head:String) async throws -> DiffDocument
    func snapshotInterdiff(_ pr:PullRequest,old:String,new:String) async throws -> DiffDocument
    func snapshotFile(_ pr:PullRequest,document:DiffDocument,file:DiffFile) async throws -> DiffFile
    func stackComparison(_ pr:PullRequest,base:String,head:String) async throws -> DiffDocument
    func reReview(_ actionKey:ProviderKey,currentHead:String,administration:PRReviewAdministration?) async throws -> PRReReviewState?
}
extension SetupStorage:PRDetailServices {}

/// What the window's model asks of the workspace listing its pull request. A standalone window (no workspace)
/// is always available and has no stack.
struct PRDetailWorkspaceLink {
    /// False once the workspace no longer lists the PR for its account (account removed or access revoked).
    var available:@MainActor (ProviderKey) -> Bool = { _ in true }
    /// The head the workspace lists now; newer than the window's while an update waits for the explicit Update.
    var listedHead:@MainActor (ProviderKey) -> RevisionID? = { _ in nil }
    /// The stack the workspace currently infers for the PR, to drop a combined comparison of a stack that changed.
    var stackSignature:@MainActor (PullRequest) -> String? = { _ in nil }
    @MainActor static func workspace(_ workspace:PRWorkspaceModel?) -> PRDetailWorkspaceLink {
        guard let workspace else { return .init() }
        return .init(available:{ [weak workspace] key in workspace.map { $0.cached(key) != nil } ?? true },
                     listedHead:{ [weak workspace] key in workspace?.cached(key)?.headRevision },
                     stackSignature:{ [weak workspace] pr in workspace?.stack(for:pr)?.signature })
    }
}

/// Writes from a PR window act only on the head it shows. A newer head (an update waiting for the window's explicit
/// Update, or a push the action account's row or GitHub already has) is refused before anything is sent, so a merge or
/// review never covers commits the reviewer hasn't seen.
enum PRDisplayedHead {
    /// Merging, queueing and enabling auto-merge land the head; the Merge button (nil) merges or queues. Disabling
    /// auto-merge, leaving the queue and updating the branch don't, and stay available: a push may call for them.
    static func guards(_ action:MergeAction?) -> Bool { [.direct,.queue,.enableAutoMerge].contains(action ?? .direct) }
    /// Nil when nothing is pinned or `actual` is the shown head; otherwise why the action was refused.
    static func refusal(shown:String?,actual:String,acting:String) -> String? {
        guard let shown,shown.lowercased() != actual.lowercased() else { return nil }
        return "The pull request is now at \(actual.prefix(8)), but this window shows \(shown.prefix(8)). Choose Update in the pull request window and review the new commits before \(acting). Nothing was sent."
    }
    struct Refusal:LocalizedError {
        let message:String
        var errorDescription:String? { message }
    }
}

/// Checkpoints inside `PRDetailModel.load`, for builds that measure detail loading; no-ops otherwise.
struct PRDetailLoadTrace {
    var cachedReadBegin:@MainActor () -> Void = {}
    var cachedApplied:@MainActor () -> Void = {}
    var freshReadBegin:@MainActor () -> Void = {}
    var freshReadEnd:@MainActor () -> Void = {}
}

/// One per PR window: loading, paging, comparison, review and merge state and the async work behind them, so
/// `PRDetailWindow` is layout plus bindings. Every read is a "latest request wins" request: a result that arrives
/// after the PR, tab, refresh or comparison moved on is dropped. Nothing here writes to a provider; writes stay in
/// the account, thread and sheet models, which go through the durable ledger.
@MainActor @Observable final class PRDetailModel {
    /// The row on screen. Same-head changes (labels, state) arrive at once; a new head only after the explicit Update.
    private(set) var pr:PullRequest
    @ObservationIgnored let services:any PRDetailServices
    /// For the account, thread and source models and the child views that still read storage directly.
    @ObservationIgnored let storage:SetupStorage
    @ObservationIgnored var link:PRDetailWorkspaceLink
    /// The action account's row and light reads, shared by header, reviewers, pickers and viewed controls.
    private(set) var account:PRDetailAccountModel
    /// Writable review threads at this head, shared by every file's diff.
    private(set) var threads:PRThreadModel
    /// `.gitattributes` once per head, blob LRU and next-file prefetch for every RichDiffView in this window.
    @ObservationIgnored let sources=PRDiffSourceCache()

    // MARK: Where the reviewer is

    var tab:PRDetailTab = .overview
    var selectedFile:String?
    /// A requested line belongs to one file; other files never inherit its scroll/selection.
    private(set) var requestedPath:String?
    private(set) var requestedLine:Int?
    private(set) var requestedSide:DiffSide?
    /// Bumped by every Jump/search/comment-location request so a repeated target scrolls again.
    private(set) var requestToken=0
    var search=""
    var split=false
    var wrap=false
    var whitespace=false

    // MARK: Detail load

    private(set) var loading=true
    private(set) var detail:PRDetailSnapshot?
    private(set) var description:PRDescriptionSnapshot?
    private(set) var progress:PRDetailState
    private(set) var baseline:RepositorySizeBaseline?
    private(set) var appearance=CodeAppearance()
    /// The detail load's failure: cleared when each load starts and when it succeeds.
    private(set) var loadError:String?
    /// Changes on every explicit refresh; every read keyed on it starts over.
    private(set) var refresh=UUID()
    @ObservationIgnored private var validatedRefresh:UUID?
    @ObservationIgnored private var initialRefresh:UUID?
    @ObservationIgnored private let loads=LatestRequest()

    // MARK: Provider context (checks, conversation, overview) and other sections

    private(set) var checksSource=PRContextSource()
    private(set) var conversationSource=PRContextSource()
    private(set) var overviewSource=PRContextSource()
    private(set) var checksRetry=UUID()
    private(set) var conversationRetry=UUID()
    private(set) var overviewRetry=UUID()
    @ObservationIgnored private var loadedContextRequests:[PRDetailTab:String]=[:]
    private(set) var section:PRDetailSection?
    private(set) var sectionTab:PRDetailTab?
    private(set) var sectionReadLoading=false
    /// Section read failures belong to the tab that failed, not the window-wide status banner.
    private(set) var sectionError:String?
    private(set) var sectionRetry=UUID()
    @ObservationIgnored private let sectionReads=LatestRequest()

    // MARK: Paging

    private(set) var pageRequest:LatestRequest.Token?
    private(set) var paging=false
    /// "Load next 100 files" failures; cleared on the next page request or refresh.
    private(set) var pagingStatus:String?
    @ObservationIgnored private let pages=LatestRequest()

    // MARK: Comparisons (commit compare, snapshot interdiff, combined stack)

    var compareBase=""
    var compareHead=""
    private(set) var compareSnapshots=false
    private(set) var compareRequest:LatestRequest.Token?
    private(set) var comparison:DiffDocument?
    /// Comparison outcomes; cleared with the comparison.
    private(set) var comparisonStatus:String?
    /// One generation for every producer of the comparison: aggregate, commit compare, refresh and Return to current PR.
    @ObservationIgnored private let comparisons=LatestRequest()
    private(set) var snapshotRetry=UUID()
    private(set) var snapshotStatus:String?
    private(set) var snapshotLoading=false
    @ObservationIgnored private let snapshotReads=LatestRequest()

    // MARK: Review and merge

    /// Risk evidence is computed off the main actor once per detail/viewed/baseline change; nil while scanning.
    private(set) var risks:[RiskEvidence]?
    @ObservationIgnored private let riskReads=LatestRequest()
    /// "Changes since your review" for the action account; nil when no review by it is known.
    private(set) var reReview:PRReReviewState?
    /// Reviewed head and current head the window already opened the interdiff for (re-requested reviews).
    @ObservationIgnored private var openedInterdiff:String?
    private(set) var reviewSignal=0
    @ObservationIgnored private let reReviewReads=LatestRequest()
    var composing=false
    private(set) var composeDecision:ReviewDecision = .comment
    private(set) var composeSelection:ReviewDraftComment?
    var merging=false
    private(set) var mergeAction:MergeAction?
    /// The newer head waiting for the window's explicit Update (the route's pending update), if any.
    var pendingHead:String?
    /// Approve, Request changes, Comment, Merge and auto-merge wait for Update, so they never act on unseen commits.
    var actionsWaitForUpdate:Bool { pendingHead.map { $0 != pr.headRevision.rawValue } ?? false }

    init(pr:PullRequest,storage:SetupStorage,services:(any PRDetailServices)? = nil,link:PRDetailWorkspaceLink = .init()) {
        self.pr=pr;self.storage=storage;self.services=services ?? storage;self.link=link
        progress=PRDetailState(headSHA:pr.headRevision.rawValue)
        account=PRDetailAccountModel(readPR:pr,storage:storage)
        threads=PRThreadModel(readPR:pr,storage:storage)
    }

    // MARK: Identities the window's tasks are keyed on

    var loadIdentity:String { refresh.uuidString+":"+String(tab == .files)+":"+pr.headRevision.rawValue }
    func contextIdentity(_ kind:PRDetailTab) -> String { pr.headRevision.rawValue+":"+refresh.uuidString+":"+tab.rawValue+":"+String(loading)+retry(kind).uuidString }
    var sectionIdentity:String { tab.rawValue+refresh.uuidString+sectionRetry.uuidString }
    var snapshotIdentity:String { (comparison?.comparison.rawValue ?? "")+":"+(comparison?.baseSHA ?? "")+":"+(comparison?.headSHA ?? "")+":"+(selectedFile ?? "")+":"+snapshotRetry.uuidString }
    var prefetchIdentity:String { (selectedFile ?? "")+":"+(comparison?.headSHA ?? detail?.headSHA ?? "") }
    struct RiskInput:Equatable { let head:String;let base:String;let files:Int;let viewed:Set<String>;let usualSize:Int? }
    var riskInput:RiskInput? { detail.map { RiskInput(head:$0.headSHA,base:$0.baseSHA,files:$0.files.count,viewed:progress.viewed,usualSize:baseline?.usualSize) } }
    /// The action account's review state; the window adds the account identity.
    var reReviewIdentity:String {
        let administration=account.administration.map { "\($0.reviews.count):\($0.requestedUsers.map(\.id).joined(separator:","))" } ?? "none"
        return (account.actionPR?.key.objectID ?? "")+":"+administration+":"+String(reviewSignal)
    }
    private func retry(_ kind:PRDetailTab) -> UUID { kind == .checks ? checksRetry : kind == .conversation ? conversationRetry : overviewRetry }

    // MARK: Derived

    var annotations:[PRDetailEvent] { checksSource.section?.events.filter { $0.anchor != nil } ?? [] }
    var commentLocations:[PRDetailEvent] { conversationSource.section?.events.filter { $0.providerComment != nil } ?? [] }
    /// The document on screen in Files: a comparison when one is shown, else the canonical PR diff.
    var shownDocument:DiffDocument? { comparison ?? detail?.document }
    var available:Bool { link.available(pr.key) }
    var eventSource:PRContextSource? { tab == .checks ? checksSource : tab == .conversation ? conversationSource : nil }
    var eventSection:PRDetailSection? { eventSource.map { $0.section } ?? (sectionTab == tab ? section : nil) }
    var eventLoading:Bool { eventSource.map { $0.phase == .loading } ?? (sectionReadLoading || sectionTab != tab || section == nil && sectionError == nil) }
    var eventFailed:Bool { eventSource?.phase == .failed }
    var eventError:String? { eventSource.map { $0.phase == .failed && $0.section == nil ? "GitHub didn’t return this information. Try again, or open this tab on GitHub." : nil } ?? (sectionTab == tab ? sectionError : nil) }
    /// Matches the Files list: grouped by directory, then by path.
    static func displayOrder(_ files:[DiffFile]) -> [DiffFile] { files.map { (($0.path as NSString).deletingLastPathComponent,$0) }.sorted { ($0.0,$0.1.path) < ($1.0,$1.1.path) }.map(\.1) }
    func jumpFiles(_ query:String) -> [DiffFile] { Self.displayOrder(comparison?.files ?? detail?.files ?? []).filter { query.isEmpty || $0.path.localizedCaseInsensitiveContains(query) } }
    /// The next unviewed file after the selection in list order, wrapping around.
    func nextUnviewed(_ document:DiffDocument) -> String? {
        let ordered=Self.displayOrder(document.files),start=(ordered.firstIndex { $0.path == selectedFile } ?? -1)+1
        return (ordered[start...]+ordered[..<start]).first { !progress.viewed.contains($0.path) && $0.path != selectedFile }?.path
    }

    // MARK: The row on screen

    /// Adopts the route's row. A new head (only ever after the explicit Update) rereads everything account-bound
    /// and the detail itself; tab, file and search stay as they are.
    func show(_ new:PullRequest) {
        let moved=new.headRevision != pr.headRevision
        pr=new
        guard moved else { return }
        account=PRDetailAccountModel(readPR:new,storage:storage);threads=PRThreadModel(readPR:new,storage:storage)
        refreshDetail()
    }
    /// A different action account (or head) rereads everything account-bound.
    func actionAccountChanged() async { account.reset();threads.reset();await account.resolve() }

    // MARK: Detail

    /// Reads settings, progress, baseline and the cached detail locally, then revalidates the description (any tab)
    /// or the files inventory (Files). True when a fresh files inventory was applied.
    @discardableResult func load(trace:PRDetailLoadTrace = .init()) async -> Bool {
        if initialRefresh == nil { initialRefresh=refresh }
        let request=loads.begin(),pr=pr,services=services
        let needsFiles=tab == .files
        let maxAge:TimeInterval=initialRefresh == refresh || validatedRefresh == refresh ? 30 : 0
        loading=true;loadError=nil
        defer { if loads.isCurrent(request) { loading=false } }
        do {
            // Tab changes preserve the user's immutable comparison; only an explicit refresh resets it.
            // The window is identified by head, so same-head content stays visible while it revalidates.
            if detail?.headSHA != pr.headRevision.rawValue { detail=nil }
            trace.cachedReadBegin()
            // Settings, reading progress, the size baseline and the cached detail are independent local reads.
            async let appearanceRead=Self.tolerated("Code appearance could not be read",fallback:CodeAppearance()) { try await services.codeAppearance() }
            async let progressRead=services.detailState(pr)
            async let baselineRead=Self.tolerated("Repository size baseline could not be read",fallback:nil) { try await services.detailRepositoryBaseline(pr) }
            async let descriptionRead=Self.tolerated("Cached PR description could not be read",fallback:nil,cached:true) { try await services.cachedDetailDescription(pr) }
            if let cached=await descriptionRead { try current(request);description=cached }
            let cachedValue=needsFiles ? await Self.tolerated("Cached PR detail could not be read",fallback:nil,cached:true) { try await services.cachedDetail(pr) } : nil
            try current(request)
            let state=try await progressRead
            try current(request);progress=state
            if let detail { reconcileProgress(detail) }
            appearance=await appearanceRead
            if detail == nil,let cached=cachedValue {
                try current(request);detail=cached;selectedFile=selectedFile ?? Self.displayOrder(cached.files).first?.path;reconcileProgress(cached)
                trace.cachedApplied()
            }
            let size=await baselineRead
            try current(request);baseline=size
            if !needsFiles {
                let value=try await services.detailDescription(pr,maxAge:maxAge)
                try current(request);description=value;validatedRefresh=refresh;loadError=nil
                return false
            }
            trace.freshReadBegin()
            var value=try await services.detail(pr,maxAge:maxAge)
            trace.freshReadEnd()
            if let cached=detail,cached.cached,cached.baseSHA == value.baseSHA,cached.baseBranchSHA == value.baseBranchSHA,cached.files.count > value.files.count {
                value=PRDetailSnapshot(body:value.body,baseSHA:value.baseSHA,headSHA:value.headSHA,files:cached.files,expectedFiles:cached.expectedFiles,baseBranchSHA:value.baseBranchSHA,nextPage:cached.nextPage,fetchedAt:value.fetchedAt,bodyFetchedAt:value.bodyFetchedAt)
            }
            try current(request);detail=value;selectedFile=selectedFile ?? Self.displayOrder(value.files).first?.path;reconcileProgress(value)
            description = .init(body:value.body,headSHA:value.headSHA,fetchedAt:value.bodyFetchedAt ?? Date(),cached:value.cached)
            validatedRefresh=refresh;loadError=nil
            return true
        } catch {
            guard !Task.isCancelled,loads.isCurrent(request),available else { return false }
            let moved=error as? PRDetailFailure == .revisionChanged
            // A newer head the workspace already knows: keep what's on screen; the Update banner explains.
            if moved,let latest=link.listedHead(pr.key),latest != pr.headRevision { return false }
            if moved { detail=nil;description=nil }
            loadError=moved ? "The pull request changed on GitHub. Refresh the workspace before reviewing." : "Detail unavailable. Reconnect or open this pull request on GitHub."
            return false
        }
    }
    /// Cancelled, or superseded by a newer load (another head, tab or refresh): its results must not land.
    private func current(_ request:LatestRequest.Token) throws {
        try Task.checkCancellation()
        guard loads.isCurrent(request) else { throw CancellationError() }
    }
    /// "Load next 100 files" asks for the next page; the window's task runs `loadMore`.
    func requestNextPage() { pagingStatus=nil;pageRequest=pages.begin() }
    /// True when another page was applied.
    @discardableResult func loadMore() async -> Bool {
        guard let request=pageRequest,let snapshot=detail,!paging else { return false }
        let pr=pr
        paging=true
        defer { paging=false }
        do {
            let value=try await services.moreDetail(pr,snapshot:snapshot);try Task.checkCancellation()
            guard pages.isCurrent(request),detail?.headSHA == snapshot.headSHA else { return false }
            detail=value;pagingStatus=nil;reconcileProgress(value)
            return true
        } catch { if !Task.isCancelled,pages.isCurrent(request) { pagingStatus="Additional files unavailable or base/head changed. Refresh before reviewing further." };return false }
    }
    /// Checks, conversation and overview context: the cached section (no network) at once, labeled with its age,
    /// while the provider revalidates. Files needs checks and conversation for its gutter and threads.
    func loadContext(_ kind:PRDetailTab) async {
        guard !loading else { return }
        let needed=kind == .overview ? tab == .overview : tab == kind || tab == .files
        guard needed else { return }
        let identity=refresh.uuidString+retry(kind).uuidString,pr=pr
        guard loadedContextRequests[kind] != identity else { return }
        let cached=await Self.tolerated("Cached PR section could not be read",fallback:nil,cached:true) { [services] in try await services.cachedDetailSection(pr,tab:kind) }
        guard !Task.isCancelled else { return }
        let request=withSource(kind) { $0.begin(cached:cached) }
        do {
            let value=try await services.detailSection(pr,tab:kind);try Task.checkCancellation()
            loadedContextRequests[kind]=identity
            withSource(kind) { $0.succeed(value,request:request) }
        } catch {
            let failure:any Error=Task.isCancelled ? CancellationError() : error
            withSource(kind) { $0.fail(failure,request:request) }
        }
    }
    private func withSource<T>(_ kind:PRDetailTab,_ body:(inout PRContextSource) -> T) -> T {
        switch kind {
        case .checks:return body(&checksSource)
        case .conversation:return body(&conversationSource)
        default:return body(&overviewSource)
        }
    }
    func retryContext(_ kind:PRDetailTab) {
        switch kind {
        case .checks:checksRetry=UUID()
        case .conversation:conversationRetry=UUID()
        case .overview:overviewRetry=UUID()
        default:sectionRetry=UUID()
        }
    }
    /// Commits and deployments only: checks and conversation reuse the window's context sources.
    func loadSection() async {
        guard ![.overview,.files,.checks,.conversation].contains(tab) else { return }
        let requestedTab=tab,pr=pr
        let request=sectionReads.begin();sectionReadLoading=true
        if sectionTab != requestedTab { section=nil }
        sectionTab=requestedTab;sectionError=nil
        defer { if sectionReads.isCurrent(request) { sectionReadLoading=false } }
        do {
            let value=try await services.detailSection(pr,tab:requestedTab);try Task.checkCancellation()
            guard tab == requestedTab,sectionReads.isCurrent(request) else { return }
            section=value
        } catch { if !Task.isCancelled,tab == requestedTab,sectionReads.isCurrent(request) { sectionError=error as? PRDetailFailure == .revisionChanged ? "The PR revision changed. Refresh the PR workspace." : providerErrorMessage(error) } }
    }

    // MARK: Explicit actions

    /// A confirmed write or an applied update: reread the detail and drop any comparison or pending page.
    func refreshDetail() {
        comparisons.cancel();compareRequest=nil;comparison=nil
        comparisonStatus=nil;pagingStatus=nil;pages.cancel();pageRequest=nil;refresh=UUID()
    }
    func returnToCanonical() { if comparison != nil { comparisons.cancel();compareRequest=nil;comparison=nil;snapshotStatus=nil;comparisonStatus=nil } }
    /// Risk review always opens the canonical PR diff: a comparison may not contain the file.
    func openFile(_ path:String) { returnToCanonical();selectedFile=path;tab = .files }
    /// Jump lists the shown document's files; a comparison keeps them, so there's nothing to leave.
    func openJump(_ path:String) {
        if let comparison,!comparison.files.contains(where:{ $0.path == path }) { returnToCanonical() }
        selectedFile=path;tab = .files
    }
    /// Scrolls to a line, even when the same line was requested before.
    func reveal(path:String,line:Int?,side:DiffSide?) { selectedFile=path;requestedPath=path;requestedLine=line;requestedSide=side;requestToken &+= 1 }
    /// Provider threads map only onto the canonical PR diff, so leave any comparison first.
    func showCommentLocation(_ location:PRProviderCommentLocation) {
        returnToCanonical()
        reveal(path:location.path,line:location.startLine,side:DiffSide(rawValue:location.side));tab = .files
    }
    /// N in Files: the next unviewed file of the canonical diff.
    @discardableResult func selectNextUnviewed() -> Bool {
        guard tab == .files,comparison == nil,let document=detail?.document,let next=nextUnviewed(document) else { return false }
        selectedFile=next;return true
    }
    /// Local viewed mark for the canonical diff; never available on a comparison.
    func setViewed(_ path:String,viewed:Bool,displayed:DiffDocument) {
        guard let canonical=detail?.document,progress.markViewed(path,viewed:viewed,displayed:displayed,canonical:canonical) else { return }
        saveProgress()
    }
    /// Carried viewed marks meet this head's inventory: unchanged files keep their mark.
    private func reconcileProgress(_ snapshot:PRDetailSnapshot) {
        guard progress.reconcile(snapshot.document) else { return }
        saveProgress()
    }
    /// Saves reading progress in the background. A failure leaves it in this window only, and is logged.
    private func saveProgress() {
        let value=progress,key=pr.key,services=services
        Task {
            do { try await services.saveDetailState(value,key:key) }
            catch { AppLog.failed(AppLog.workspace,"Reading progress could not be saved",error) }
        }
    }
    /// Opens the review composer; nothing while newer commits wait for Update.
    func compose(_ decision:ReviewDecision,selection:ReviewDraftComment? = nil) {
        guard !actionsWaitForUpdate else { return }
        composeDecision=decision;composeSelection=selection;composing=true
    }
    func canOpenMerge(_ action:MergeAction?) -> Bool { !actionsWaitForUpdate || !PRDisplayedHead.guards(action) }
    /// Opens the merge sheet; an action that lands the head waits while newer commits wait for Update.
    func openMerge(_ action:MergeAction?) {
        guard canOpenMerge(action) else { return }
        mergeAction=action;merging=true
    }
    /// A review or comment was confirmed: reread what it changed, including "Changes since your review".
    func reviewWritten() { refreshDetail();reviewSignal += 1 }

    // MARK: Comparisons

    func startComparison(snapshots:Bool) { compareSnapshots=snapshots;compareRequest=comparisons.begin() }
    /// Exact snapshot interdiff from the reviewed head to the head shown here.
    func showChangesSinceReview(_ state:PRReReviewState) {
        compareBase=state.reviewedHead;compareHead=pr.headRevision.rawValue;compareSnapshots=true;compareRequest=comparisons.begin()
    }
    private func accepts(_ request:LatestRequest.Token) -> Bool { available && comparisons.isCurrent(request) }
    func compare(request:LatestRequest.Token) async {
        let base=compareBase,head=compareHead,snapshots=compareSnapshots,pr=pr
        do {
            let value=try await snapshots ? services.snapshotInterdiff(pr,old:base,new:head) : services.compareDetail(pr,base:base,head:head)
            try Task.checkCancellation()
            guard accepts(request) else { return }
            comparison=value;selectedFile=Self.displayOrder(value.files).first?.path;tab = .files;comparisonStatus=nil
        } catch {
            if !Task.isCancelled,accepts(request) { comparisonStatus="Original or target revision is unavailable. No replacement comparison was substituted." }
        }
    }
    func combinedStack(_ stack:PRStack) async {
        let request=comparisons.begin(),pr=pr;comparison=nil;compareRequest=nil
        do {
            guard stack.warnings.isEmpty,let bottom=stack.layers.first,let top=stack.layers.last else { throw PRWriteFailure.unavailable }
            var snapshots:[PRDetailSnapshot]=[]
            for layer in stack.layers {
                let snapshot=try await services.detail(layer)
                guard snapshot.headSHA == layer.headRevision.rawValue else { throw PRWriteFailure.revisionChanged };snapshots.append(snapshot)
            }
            if stack.kind == .inferred {
                for index in 1..<snapshots.count { guard snapshots[index].baseBranchSHA == snapshots[index-1].headSHA else { throw PRWriteFailure.revisionChanged } }
            }
            guard let base=snapshots.first?.baseSHA,let head=snapshots.last?.headSHA,bottom.key.repository == top.key.repository else { throw PRWriteFailure.unavailable }
            let value=try await services.stackComparison(pr,base:base,head:head)
            guard link.stackSignature(pr) == stack.signature,accepts(request) else { return }
            comparison=value;selectedFile=Self.displayOrder(value.files).first?.path;tab = .files;comparisonStatus="Combined immutable stack comparison; comments remain on individual PR layers."
        } catch { if accepts(request) { comparisonStatus=error.localizedDescription } }
    }
    func retrySnapshot() { snapshotRetry=UUID() }
    func loadSnapshotFile() async {
        guard let document=comparison,document.comparison == .snapshot,let file=document.files.first(where:{ $0.path == selectedFile }),file.patch == nil else { snapshotStatus=nil;snapshotLoading=false;return }
        let request=snapshotReads.begin(),pr=pr
        snapshotLoading=true;snapshotStatus="Loading exact old/new source snapshots…"
        defer { if !Task.isCancelled,snapshotReads.isCurrent(request) { snapshotLoading=false } }
        do {
            let value=try await services.snapshotFile(pr,document:document,file:file);try Task.checkCancellation()
            guard snapshotReads.isCurrent(request),comparison?.baseSHA == document.baseSHA,comparison?.headSHA == document.headSHA,comparison?.comparison == .snapshot else { return }
            comparison=comparison?.replacing(value);snapshotStatus=value.status == .unchanged ? "Selected snapshots are identical." : "Selected diff verified against exact snapshots."
        } catch { if !Task.isCancelled,snapshotReads.isCurrent(request) { snapshotStatus="Exact snapshot diff unavailable: source unavailable, non-UTF-8/binary, or 2 MB / 100k-line / 1M-cell work bound exceeded. No merge-base patch substituted." } }
    }

    // MARK: Background work

    func computeRisks() async {
        guard let detail else { risks=nil;return }
        let files=detail.files,viewed=progress.viewed,usualSize=baseline?.usualSize,request=riskReads.begin()
        let value=await Task.detached(priority:.utility) { RiskRules.evaluate(files:files,viewed:viewed,usualSize:usualSize) }.value
        guard !Task.isCancelled,riskReads.isCurrent(request) else { return }
        risks=value
    }
    /// After the selected file settles, read the next file's sources at background priority.
    func prefetchNextFile() async {
        try? await Task.sleep(for:.milliseconds(700))
        guard !Task.isCancelled,tab == .files,let document=shownDocument,document.comparison != .snapshot else { return }
        let ordered=Self.displayOrder(document.files)
        guard let index=ordered.firstIndex(where:{ $0.path == selectedFile }),index+1 < ordered.count else { return }
        sources.prefetch(storage:storage,pr:pr,file:ordered[index+1],document:document)
    }
    func loadReReview() async {
        guard let actionKey=account.actionPR?.key else { reReviewReads.cancel();reReview=nil;return }
        let head=pr.headRevision.rawValue,request=reReviewReads.begin(),administration=account.administration
        let value=await Self.tolerated("Re-review state could not be read",fallback:nil) { [services] in try await services.reReview(actionKey,currentHead:head,administration:administration) }
        guard !Task.isCancelled,reReviewReads.isCurrent(request),pr.headRevision.rawValue == head else { return }
        reReview=value
        // Re-requested with new commits: open on the interdiff once per reviewed/current head pair.
        if let value,value.opensOnInterdiff,comparison == nil,openedInterdiff != value.reviewedHead+":"+head {
            openedInterdiff=value.reviewedHead+":"+head;showChangesSinceReview(value)
        }
    }

    // MARK: Tolerated failures

    /// `body`'s value, or `fallback` after logging why it failed: a read the window does without (a default, no cached
    /// content). Cancellation is not logged. Nor are a `cached` read's expected failures: it runs under the account's
    /// session, so the account's authorization or the PR's state (unavailable, moved) fail it, and the fresh read that
    /// follows reports them.
    nonisolated private static func tolerated<T:Sendable>(_ what:StaticString,fallback:T,cached:Bool=false,_ body:@Sendable () async throws -> T) async -> T {
        do { return try await body() } catch {
            let expected=cached && (error is PRDetailFailure || error is GitHubFailure)
            if !expected,!Task.isCancelled { AppLog.failed(AppLog.workspace,what,error) }
            return fallback
        }
    }

    // MARK: Text

    static func phaseText(_ source:PRContextSource) -> String {
        let cached=source.showingCached ? " · showing "+prCachedAge(source.section?.fetchedAt) : ""
        switch source.phase {
        case .loaded:return "Loaded"
        case .partial:return "Partial — more context may exist"
        case .failed:return source.showingCached ? "Refresh failed"+cached : "Failed — context unavailable"
        case .loading:return "Loading…"+cached
        case .idle:return "Not loaded"+cached
        }
    }
}
