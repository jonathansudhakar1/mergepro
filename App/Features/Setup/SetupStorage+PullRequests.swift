import Foundation
import MergeProCore

/// Pull request detail, reviews, merges, the PR workspace record and review/code preferences. Detail reads come from
/// the fixture app's offline detail when it installs one; writes always run under the active action account's PR row.
extension SetupStorage {
    func detail(_ pr:PullRequest) async throws -> PRDetailSnapshot {
        if let offline = dependencies.fixtures?.detail { return offline.snapshot(pr) }
        return try await detailService().detail(pr)
    }
    func cachedDetail(_ pr:PullRequest) async throws -> PRDetailSnapshot? {
        if dependencies.fixtures?.detail != nil { return nil }
        return try await detailService().cachedDetail(pr)
    }
    /// Background-priority detail reads after a poll cycle, so opening likely PRs is a cache hit. Stops at the
    /// interactive reserve, when an interactive read starts, or on cancellation; never throws.
    func prefetchDetails(_ prs:[PullRequest],limit:Int) async -> PRPrefetchResult {
        guard dependencies.speculativeDetailReads else { return PRPrefetchResult() }
        let service: PRDetailService
        do { service = try detailService() } catch { AppLog.failed(AppLog.storage, "Detail prefetch skipped", error); return PRPrefetchResult() }
        return await service.prefetchDetails(prs,limit:limit)
    }
    func moreDetail(_ pr:PullRequest,snapshot:PRDetailSnapshot) async throws -> PRDetailSnapshot { try await detailService().more(pr,snapshot:snapshot) }
    func detailSection(_ pr:PullRequest,tab:PRDetailTab) async throws -> PRDetailSection { try await detailService().section(pr,tab:tab) }
    func detailBlob(_ pr:PullRequest,path:String,sha:String) async throws -> Data {
        if let offline = dependencies.fixtures?.detail { return offline.blob(pr,path:path,sha:sha) }
        return try await detailService().blob(pr,path:path,sha:sha)
    }
    func actionPR(_ readPR:PullRequest) throws -> PullRequest {
        let database=try stores().0
        guard let account=try database.activeActionAccount(),account.host == readPR.key.host,
              let matching=try database.pullRequest(for:ProviderKey(host:account.host,accountID:account.accountID,repositoryID:readPR.key.repositoryID,objectID:readPR.key.objectID)) else { throw PRWriteFailure.unavailable }
        return matching
    }
    func actionLogin(_ key:ProviderKey) throws -> String { try stores().0.accounts().first { $0.scope == key.account }?.login ?? key.accountID }
    func beginReview(_ key:ProviderKey,revision:PRWriteRevision) throws -> ReviewDraft { try DraftReviewStore(database:stores().0).beginReview(key,revision:revision) }
    func reviewDraft(_ key:ProviderKey) throws -> ReviewDraft? { try DraftReviewStore(database:stores().0).load(key) }
    func saveReviewDraft(_ draft:ReviewDraft,expectedVersion:Int?=nil) throws { try DraftReviewStore(database:stores().0).save(draft,expectedVersion:expectedVersion) }
    func writeOperations(_ key:ProviderKey) throws -> [PRWriteOperation] { try DraftReviewStore(database:stores().0).operations(key) }
    func inspectWrite(_ command:PRWriteCommand) async throws -> PRWriteTruth { try await writeCoordinator().inspect(command) }
    func performWrite(_ command:PRWriteCommand) async throws -> PRWriteOperation { try await writeCoordinator().perform(command) }
    func releaseUnsentWrite(_ id:UUID) throws { try DraftReviewStore(database:stores().0).rejectUnsent(id) }
    func reconcileWrite(_ id:UUID) async throws -> PRWriteOperation {
        if let operation=try DraftReviewStore(database:stores().0).operation(id),case .merge=operation.command.intent { return try await mergeCoordinator().reconcile(id) }
        return try await writeCoordinator().reconcile(id)
    }
    func mergeInspection(_ readPR:PullRequest) async throws -> MergeInspection { try await mergeCoordinator().inspect(actionPR(readPR)) }
    func prepareMerge(_ readPR:PullRequest,action:MergeAction?=nil) async throws -> [MergeInspection] { try await mergeCoordinator().prepare(actionPR(readPR),action:action) }
    func performMerge(_ command:MergeCommand) async throws -> PRWriteOperation { try await mergeCoordinator().perform(command) }
    func mergeDefault(_ key:RepositoryKey) throws -> MergeMethod? { try stores().0.applicationSetting(.mergeMethod(key)).flatMap(MergeMethod.init(rawValue:)) }
    func saveMergeDefault(_ method:MergeMethod,key:RepositoryKey) throws { try stores().0.setApplicationSetting(method.rawValue,for:.mergeMethod(key)) }
    func stackComparison(_ pr:PullRequest,base:String,head:String) async throws -> DiffDocument { try await detailService().compare(pr,base:base,head:head) }

    func requireAllFilesViewed() throws -> Bool { try stores().0.applicationSetting(.requireAllFilesViewedBeforeApprove) == "true" }
    func setRequireAllFilesViewed(_ value:Bool) throws { try stores().0.setApplicationSetting(value ? "true" : "false",for:.requireAllFilesViewedBeforeApprove) }
    func classificationRules(account:AccountScope) throws -> [String:AgentClassifier.Classification] { try PRClassificationStore(database:stores().0).rules(account:account) }
    func saveClassificationRules(_ rules:[String:AgentClassifier.Classification],account:AccountScope) throws { try PRClassificationStore(database:stores().0).save(rules,account:account) }
    /// Merged rows of this repository only. A blocked account contributes no rows, as its session snapshot would.
    func detailBaseline(_ pr:PullRequest) async throws -> RepositorySizeBaseline {
        let available=try await accountSession().authorizationState(for:pr.key.account) == .available
        return RepositorySizeBaseline.calculate(available ? try stores().0.pullRequests(repository:pr.key.repository,states:[.merged]) : [],for:pr)
    }
    func editorPreference() throws -> String { try stores().0.applicationSetting(.editor) ?? "vscode" }
    func editorBookmark(_ repo:RepositoryKey) throws -> Data? {
        try stores().0.applicationSetting(try .editorBookmark(repo)).flatMap { Data(base64Encoded:$0) }
    }
    func saveEditorBookmark(_ data:Data,repo:RepositoryKey) throws {
        try stores().0.setApplicationSetting(data.base64EncodedString(),for:try .editorBookmark(repo))
    }
    func codeAppearance() throws -> CodeAppearance {
        let db=try stores().0
        return CodeAppearance(fontSize:try db.applicationSetting(.codeFontSize).flatMap(Double.init) ?? 12,fontName:try db.applicationSetting(.codeFontName) ?? "",ligatures:try db.applicationSetting(.codeLigatures) == "true",theme:try db.applicationSetting(.codeTheme) ?? "system")
    }

    func snapshotInterdiff(_ pr:PullRequest,old:String,new:String) async throws -> DiffDocument { try await detailService().snapshotInterdiff(pr,old:old,new:new) }
    func snapshotFile(_ pr:PullRequest,document:DiffDocument,file:DiffFile) async throws -> DiffFile { try await detailService().snapshotFile(pr,document:document,file:file) }
    func compareDetail(_ pr:PullRequest,base:String,head:String) async throws -> DiffDocument { try await detailService().compare(pr,base:base,head:head) }
    func detailState(_ pr:PullRequest) throws -> PRDetailState { try PRDetailStore(database:stores().0).load(pr.key,headSHA:pr.headRevision.rawValue) }
    func saveDetailState(_ state:PRDetailState,key:ProviderKey) throws { try PRDetailStore(database:stores().0).save(state,key:key) }
    func prWorkspace() throws -> PRViewState { try PullRequestStore(database:stores().0).load() }
    func savePRWorkspace(_ state: PRViewState) throws { try PullRequestStore(database:stores().0).save(state) }
    func exportPRViews() throws -> Data { try PullRequestStore(database:stores().0).exportViews() }
    func importPRViews(_ data: Data) throws { try PullRequestStore(database:stores().0).importViews(data) }
}
