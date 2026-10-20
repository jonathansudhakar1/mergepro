import Foundation
import SwiftUI
import MergeProCore

/// Detail-window reads and writes. Cached reads make no provider request; light provider reads and
/// revision-independent writes always run under the active action account's PR row.
extension SetupStorage {
    func commitDetail(_ pr:PullRequest,sha:String) async throws -> PRCommitDetail {
        try await detailService().commitDetail(pr,sha:sha)
    }
    func moreCommitDetail(_ pr:PullRequest,snapshot:PRCommitDetail) async throws -> PRCommitDetail {
        try await detailService().moreCommitDetail(pr,snapshot:snapshot)
    }
    /// `actionPR(_:)` without decoding the whole account: one repository's rows under the active action account.
    func detailActionPR(_ readPR:PullRequest) throws -> PullRequest {
        let database=try stores().0
        guard let account=try database.activeActionAccount(),account.host == readPR.key.host,
              let matching=try PollCycleStore(database:database).pullRequests(repositories:[RepositoryKey(account:account,repositoryID:readPR.key.repositoryID)]).first(where:{ $0.key.objectID == readPR.key.objectID }) else { throw PRWriteFailure.unavailable }
        return matching
    }
    /// The stored row for `key` (one repository decode), so a route refreshes its workspace only when the row changed.
    func detailStoredRow(_ key:ProviderKey) throws -> PullRequest? {
        try PollCycleStore(database:stores().0).pullRequests(repositories:[key.repository]).first { $0.key == key }
    }
    /// Size baseline from this repository's cached rows only (not the whole account snapshot).
    func detailRepositoryBaseline(_ pr:PullRequest) throws -> RepositorySizeBaseline {
        RepositorySizeBaseline.calculate(try PollCycleStore(database:stores().0).pullRequests(repositories:[pr.key.repository]),for:pr)
    }
    /// Revalidates unless the cached inventory and description were confirmed within `maxAge` seconds.
    func detail(_ pr:PullRequest,maxAge:TimeInterval) async throws -> PRDetailSnapshot {
        if let offline = dependencies.fixtures?.detail { return offline.snapshot(pr) }
        return try await detailService().detail(pr,maxAge:maxAge)
    }
    func detailDescription(_ pr:PullRequest,maxAge:TimeInterval) async throws -> PRDescriptionSnapshot {
        if let offline = dependencies.fixtures?.detail {
            let value=offline.snapshot(pr)
            return .init(body:value.body,headSHA:value.headSHA,fetchedAt:dependencies.clock(),cached:false)
        }
        return try await detailService().description(pr,maxAge:maxAge)
    }
    func cachedDetailDescription(_ pr:PullRequest) async throws -> PRDescriptionSnapshot? {
        if dependencies.fixtures?.detail != nil { return nil }
        return try await detailService().cachedDescription(pr)
    }
    /// No network: the cached overview/checks/conversation for this head, labeled `cached` with `fetchedAt`.
    func cachedDetailSection(_ pr:PullRequest,tab:PRDetailTab) async throws -> PRDetailSection? {
        if dependencies.fixtures?.detail != nil { return nil }
        return try await detailService().cachedSection(pr,tab:tab)
    }
    /// No network: loads persisted detail and sections for the PR's current head into memory.
    func warmDetail(_ pr:PullRequest) async {
        if dependencies.fixtures?.detail != nil { return }
        let service: PRDetailService
        do { service = try detailService() } catch { AppLog.failed(AppLog.storage, "Detail warm-up skipped", error); return }
        await service.warm(pr)
    }
    /// One bounded provider read of the action account's viewed marks, memoized per PR + head.
    func viewedStates(_ actionPR:PullRequest,revision:String,refresh:Bool=false) async throws -> PRViewedStates {
        try await detailService().viewedStates(actionPR,revision:revision,refresh:refresh)
    }
    /// Memory-only: a provider-confirmed viewed write, so other files need no re-read.
    func recordViewedState(_ actionPR:PullRequest,revision:String,path:String,viewed:Bool) throws { try detailService().recordViewedState(actionPR,revision:revision,path:path,viewed:viewed) }
    func invalidateViewedStates(_ actionPR:PullRequest) throws { try detailService().invalidateViewedStates(actionPR) }
    /// Reviewer rows, requests and subscription for the action-account PR: ONE light read.
    func reviewAdministration(_ actionPR:PullRequest) async throws -> PRReviewAdministration { try await writeCoordinator().reviewAdministration(for:actionPR) }
    /// Assignable users and current assignees/labels with node IDs: ONE light read.
    func metadataOptions(_ actionPR:PullRequest) async throws -> PRMetadataOptions { try await writeCoordinator().metadataOptions(for:actionPR) }
    /// A revision-independent delta (assignees, review requests, discard, dismiss, subscription) on the action-account row.
    func performLightWrite(_ actionPR:PullRequest,intent:PRWriteIntent) async throws -> PRWriteOperation {
        try await performWrite(.revisionIndependent(actionPR:actionPR,intent:intent))
    }

    // MARK: Reviews and re-review

    /// A quick review (Approve from the PR window) through the review service and the durable write ledger.
    /// Only a `.confirmed` operation succeeded; any other state is reported, never resent.
    func submitQuickReview(_ actionPR:PullRequest,revision:PRWriteRevision,decision:ReviewDecision,summary:String) async throws -> PRWriteOperation {
        try await GitHubReviewService(coordinator:writeCoordinator(),database:stores().0).submitQuick(pr:actionPR.key,revision:revision,decision:decision,summary:summary)
    }
    /// Records the head a provider-confirmed review by `key`'s account covered.
    func recordReviewedHead(_ key:ProviderKey,head:String) throws { try PRDetailStore(database:stores().0).recordReview(key,headSHA:head) }
    /// "Changes since your review" for the action account: its local record, its confirmed review writes and
    /// the provider's review list. Nil when no review by this account is known.
    func reReview(_ actionKey:ProviderKey,currentHead:String,administration:PRReviewAdministration?) throws -> PRReReviewState? {
        let database=try stores().0
        let local=try PRDetailStore(database:database).reviewedHead(actionKey)
        let ledger=try DraftReviewStore(database:database).operations(actionKey)
        let provider=administration?.key == actionKey ? administration?.reviews : nil
        return PRReReviewState.resolve(currentHead:currentHead,local:local,ledger:ledger,providerReviews:provider,viewerRequested:administration?.key == actionKey ? PRReReviewState.viewerRequested(administration) : nil)
    }
    /// Draft comment from the diff's inline popover: appended to the action account's review draft for `revision`.
    /// A draft on another revision is never relocated here; the full composer does that explicitly.
    func addDraftComment(_ readPR:PullRequest,comment:ReviewDraftComment) throws -> ReviewDraft {
        let actionPR=try detailActionPR(readPR),store=DraftReviewStore(database:try stores().0)
        guard let revision=comment.revision else { throw PRWriteFailure.invalidAnchor }
        guard var draft=try store.load(actionPR.key) else {
            let fresh=ReviewDraft(key:actionPR.key,revision:revision,comments:[comment]);try store.save(fresh);return fresh
        }
        guard draft.revision == revision else { throw PRWriteFailure.revisionChanged }
        let expected=draft.editVersion;draft.comments.append(comment);draft.editVersion=expected+1
        try store.save(draft,expectedVersion:expected)
        return draft
    }

    // MARK: Repository actions for merged/closed pull requests

    /// The action account's repository entry. Repository writes never borrow another account's identity.
    func detailRepository(_ key:RepositoryKey) async throws -> RepoCatalogEntry {
        let database=try stores().0
        guard let account=try database.accounts().first(where:{ $0.scope == key.account }) else { throw RepositoryBrowserFailure.permissionDenied }
        if let entry=try? await repositoryBrowserService().cachedCatalog().first(where:{ $0.key == key }) { return entry }
        guard let repository=try database.snapshot(for:key.account).repositories.first(where:{ $0.key == key }) else { throw RepositoryBrowserFailure.permissionDenied }
        return RepoCatalogEntry(repository:repository,accountLogin:account.login)
    }
    func detailHeadBranch(_ actionPR:PullRequest) async throws -> RepositoryBranch? {
        try await repositoryBrowserService().headBranch(repository:detailRepository(actionPR.key.repository),pr:actionPR)
    }
    func deleteDetailHeadBranch(_ actionPR:PullRequest) async throws { try await repositoryBrowserService().deleteHeadBranch(repository:detailRepository(actionPR.key.repository),pr:actionPR) }
    func restoreDetailHeadBranch(_ actionPR:PullRequest) async throws { try await repositoryBrowserService().restoreHeadBranch(repository:detailRepository(actionPR.key.repository),pr:actionPR) }
    func revertDetailPullRequest(_ actionPR:PullRequest,title:String,body:String,draft:Bool) async throws -> RepositoryRevertResult {
        guard let number=actionPR.metadata?.number else { throw PRWriteFailure.unavailable }
        return try await repositoryBrowserService().revertPullRequest(repository:detailRepository(actionPR.key.repository),pullRequestNodeID:actionPR.key.objectID,number:number,title:title,body:body,draft:draft)
    }
    func reconcileDetailRevert(_ actionPR:PullRequest) async throws -> RepositoryBranchReconciliation {
        guard let number=actionPR.metadata?.number else { throw PRWriteFailure.unavailable }
        return try await repositoryBrowserService().reconcileRevert(repository:detailRepository(actionPR.key.repository),number:number)
    }
    func reconcileDetailBranch(_ actionPR:PullRequest,mutation:RepositoryBranchMutation) async throws -> RepositoryBranchReconciliation {
        try await repositoryBrowserService().reconcileBranch(repository:detailRepository(actionPR.key.repository),mutation:mutation)
    }
    /// Unresolved repository writes for this PR: its revert, or a create/delete of its head branch.
    func detailPendingWrites(_ actionPR:PullRequest) async throws -> [RepositoryPendingWrite] {
        guard let metadata=actionPR.metadata else { return [] }
        let repositoryID=actionPR.key.repositoryID,branch=metadata.headBranch
        return try await repositoryBrowserService().pendingWrites(repository:detailRepository(actionPR.key.repository)).filter { write in
            write.identity == "pr-revert|\(repositoryID)|\(metadata.number)" || !branch.isEmpty && (write.identity == "branch-create|\(repositoryID)|\(branch)" || write.identity.hasPrefix("branch-delete|\(repositoryID)|\(branch)|"))
        }
    }
    func releaseDetailPendingWrite(_ actionPR:PullRequest,identity:String) async throws {
        try await repositoryBrowserService().releaseUnsentWrite(repository:detailRepository(actionPR.key.repository),identity:identity)
    }
}
