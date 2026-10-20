import Foundation

public protocol ReviewService:Sendable {
    /// Returns the ledger operation; only `.confirmed` is a provider-confirmed review. Nothing is ever resent.
    @discardableResult func submit(pr:ProviderKey,expectedHeadSHA:String,decision:ReviewDecision,summary:String) async throws -> PRWriteOperation
}
public struct GitHubReviewService:ReviewService {
    public let coordinator:PRWriteCoordinator
    public let database:DatabaseStore
    public init(coordinator:PRWriteCoordinator,database:DatabaseStore) { self.coordinator=coordinator;self.database=database }
    @discardableResult public func submit(pr:ProviderKey,expectedHeadSHA:String,decision:ReviewDecision,summary:String) async throws -> PRWriteOperation {
        guard let current=try database.pullRequest(for:pr),let metadata=current.metadata,let draft=try DraftReviewStore(database:database).load(pr),draft.revision.head == expectedHeadSHA else { throw PRWriteFailure.revisionChanged }
        guard !draft.comments.contains(where:{ $0.postedCommentID == nil || $0.hasUnsentEdit }) else { throw PRWriteFailure.unsentComments }
        let intent:PRWriteIntent=draft.pendingReviewID.map { .submitPending(id:$0,decision:decision,summary:summary) } ?? .review(decision,summary)
        let command=PRWriteCommand(key:pr,repository:metadata.repositoryName,number:metadata.number,revision:draft.revision,intent:intent,requireAllViewed:try database.applicationSetting(.requireAllFilesViewedBeforeApprove) == "true" && !(metadata.riskFlags ?? []).isEmpty)
        let result=try await coordinator.perform(command)
        // The reviewed head is recorded only for a provider-confirmed review; a failed record never hides the confirmation.
        if result.state == .confirmed {
            do { try PRDetailStore(database:database).recordReview(pr,headSHA:draft.revision.head) }
            catch { Log.writes.error("A confirmed review's head could not be recorded locally: \(Log.kind(error), privacy: .public)") }
        }
        return result
    }
    /// A quick review (e.g. Approve from the PR window) for `revision`: the account's draft is aligned to
    /// that revision first, then the review goes through `submit` and the write ledger like any other.
    @discardableResult public func submitQuick(pr:ProviderKey,revision:PRWriteRevision,decision:ReviewDecision,summary:String) async throws -> PRWriteOperation {
        try Self.prepareDraft(DraftReviewStore(database:database),key:pr,revision:revision)
        return try await submit(pr:pr,expectedHeadSHA:revision.head,decision:decision,summary:summary)
    }
    /// A missing draft starts at `revision`. A draft on another revision moves only when it holds no
    /// comments and no pending review (its summary text and prior revision are kept); otherwise the
    /// relocation stays an explicit choice in the full composer.
    static func prepareDraft(_ store:DraftReviewStore,key:ProviderKey,revision:PRWriteRevision) throws {
        guard var draft=try store.load(key) else { try store.save(ReviewDraft(key:key,revision:revision));return }
        guard draft.revision != revision else { return }
        guard draft.comments.isEmpty,draft.pendingReviewID == nil else { throw PRWriteFailure.revisionChanged }
        let expected=draft.editVersion
        draft.priorRevisions.append(draft.revision);draft.revision=revision;draft.editVersion=expected+1
        try store.save(draft,expectedVersion:expected)
    }
}
