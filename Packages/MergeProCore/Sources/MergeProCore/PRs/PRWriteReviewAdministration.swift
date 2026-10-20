import Foundation

public enum PRReviewState:String,Codable,Sendable { case pending="PENDING",commented="COMMENTED",approved="APPROVED",changesRequested="CHANGES_REQUESTED",dismissed="DISMISSED",unknown="UNKNOWN" }
/// One provider review row for reviewer administration (Dismiss, Re-request, Discard pending).
/// Independent of the read-only overview context; read with the selected action account.
public struct PRReviewSummary:Codable,Hashable,Sendable,Identifiable {
    public let id:String
    public let authorLogin:String?
    /// User node ID for re-request through `reviewRequestChanges`; nil for bots, mannequins and ghosts.
    public let authorID:String?
    public let state:PRReviewState
    public let submittedAt:Date?
    public let commitOID:String?
    public let viewerDidAuthor:Bool
    /// GitHub GraphQL exposes no `viewerCanDismiss`. Derived from review state, repository
    /// viewerPermission and classic `restrictsReviewDismissals`; nil is unknown and GitHub decides.
    public let viewerCanDismiss:Bool?
    /// The viewer's own PENDING review with provider `viewerCanDelete`.
    public let viewerCanDiscard:Bool
    public init(id:String,authorLogin:String?,authorID:String?,state:PRReviewState,submittedAt:Date?,commitOID:String?,viewerDidAuthor:Bool,viewerCanDismiss:Bool?,viewerCanDiscard:Bool) { self.id=id;self.authorLogin=authorLogin;self.authorID=authorID;self.state=state;self.submittedAt=submittedAt;self.commitOID=commitOID;self.viewerDidAuthor=viewerDidAuthor;self.viewerCanDismiss=viewerCanDismiss;self.viewerCanDiscard=viewerCanDiscard }
}
/// Credential-free reviewer administration read. Incomplete lists never prove absence.
public struct PRReviewAdministration:Sendable,Equatable {
    public let key:ProviderKey
    public var viewerLogin:String
    /// Chronological, newest 100; `reviewsComplete` is false when older reviews exist.
    public var reviews:[PRReviewSummary]
    public var reviewsComplete:Bool
    public var requestedUsers:[PRUserRef]
    public var requestedTeams:[PRTeamRef]
    public var requestsComplete:Bool
    public var canRequestReviews:Bool
    public var viewerSubscription:PRSubscriptionState?
    public var canSubscribe:Bool
    public var reviewDecision:String?
    public var pendingReview:PRReviewSummary? { reviews.last { $0.state == .pending && $0.viewerDidAuthor } }
    public init(key:ProviderKey,viewerLogin:String,reviews:[PRReviewSummary],reviewsComplete:Bool,requestedUsers:[PRUserRef],requestedTeams:[PRTeamRef],requestsComplete:Bool,canRequestReviews:Bool,viewerSubscription:PRSubscriptionState?,canSubscribe:Bool,reviewDecision:String?) { self.key=key;self.viewerLogin=viewerLogin;self.reviews=reviews;self.reviewsComplete=reviewsComplete;self.requestedUsers=requestedUsers;self.requestedTeams=requestedTeams;self.requestsComplete=requestsComplete;self.canRequestReviews=canRequestReviews;self.viewerSubscription=viewerSubscription;self.canSubscribe=canSubscribe;self.reviewDecision=reviewDecision }
}
/// Node identities for the label/assignee pickers. The App builds deltas from these refs.
public struct PRMetadataOptions:Sendable,Equatable {
    public let key:ProviderKey
    public var labels:[PRLabelRef]
    public var labelsComplete:Bool
    public var availableLabels:[PRLabelRef]
    public var availableLabelsComplete:Bool
    /// Label name → 6-digit hex color for current and available labels.
    public var labelColors:[String:String]
    public var assignees:[PRUserRef]
    public var assigneesComplete:Bool
    public var assignableUsers:[PRUserRef]
    public var assignableUsersComplete:Bool
    public var canLabel:Bool
    public var canAssign:Bool
    public init(key:ProviderKey,labels:[PRLabelRef],labelsComplete:Bool,availableLabels:[PRLabelRef],availableLabelsComplete:Bool,labelColors:[String:String],assignees:[PRUserRef],assigneesComplete:Bool,assignableUsers:[PRUserRef],assignableUsersComplete:Bool,canLabel:Bool,canAssign:Bool) { self.key=key;self.labels=labels;self.labelsComplete=labelsComplete;self.availableLabels=availableLabels;self.availableLabelsComplete=availableLabelsComplete;self.labelColors=labelColors;self.assignees=assignees;self.assigneesComplete=assigneesComplete;self.assignableUsers=assignableUsers;self.assignableUsersComplete=assignableUsersComplete;self.canLabel=canLabel;self.canAssign=canAssign }
}
/// Light reads for review requests, pending-review discard, dismissal and subscription.
/// Schema facts verified against GitHub's public schema: PullRequestReview has viewerDidAuthor,
/// viewerCanDelete and viewerCanUpdate but no viewerCanDismiss; PullRequest has
/// viewerCanSubscribe/viewerSubscription; `reviews` accepts `states:`.
struct GitHubPRReviewAdministrationReader {
    let client:GitHubHTTPClient
    let credential:GitHubCredential
    private typealias L=GitHubPRLightQuery
    typealias Payload=PRWriteReadPayload
    static let reviewFields="id state submittedAt viewerDidAuthor viewerCanDelete author { login ... on User { id } } commit { oid }"
    static let requestSelection="reviewRequests(first:100) { nodes { requestedReviewer { __typename ... on User { id login } ... on Team { id slug name } } } pageInfo { hasNextPage } }"
    static let dismissalSelection="reviewDecision baseRef { branchProtectionRule { restrictsReviewDismissals } }"
    static let latestReviewsSelection="latest: latestReviews(first:100) { nodes { \(reviewFields) } pageInfo { hasNextPage } }"
    static let pendingReviewsSelection="pending: reviews(first:100,states:[PENDING]) { nodes { \(reviewFields) } pageInfo { hasNextPage } }"
    static let dismissedReviewSelection="review: node(id:$review) { ... on PullRequestReview { \(reviewFields) pullRequest { id } } }"
    static let subscriptionSelection="viewerCanSubscribe viewerSubscription"
    static let administrationSelection="""
    \(requestSelection)
    \(dismissalSelection)
    \(subscriptionSelection)
    reviews(last:100) { nodes { \(reviewFields) } pageInfo { hasPreviousPage } }
    """
    /// Triage can request reviews; PR viewerCanUpdate (also true for read-only authors) cannot.
    static let requestRoles:Set<String>=["TRIAGE","WRITE","MAINTAIN","ADMIN"]
    static func requested(_ connection:Payload.Connection<Payload.ReviewRequest>?) -> (users:[PRUserRef],teams:[PRTeamRef]) {
        var users:[PRUserRef]=[],teams:[PRTeamRef]=[]
        for node in connection?.values ?? [] {
            guard let reviewer=node.requestedReviewer,let id=reviewer.id else { continue }
            if reviewer.typename == "Team" { if let slug=reviewer.slug { teams.append(.init(id:id,slug:slug)) } }
            else if let login=reviewer.login { users.append(.init(id:id,login:login)) }
        }
        return (users,teams)
    }
    /// Dismissal capability: only APPROVED/CHANGES_REQUESTED, WRITE+ permission; ADMIN or a
    /// visibly unrestricted classic rule is allowed, a hidden/restricting rule is unknown.
    static func summary(_ node:Payload.Review,permission:String?,restricts:Bool?) -> PRReviewSummary? {
        guard let id=node.id else { return nil }
        let state=PRReviewState(rawValue:node.state ?? "") ?? .unknown,own=node.viewerDidAuthor == true
        let dismiss:Bool?
        if ![.approved,.changesRequested].contains(state) { dismiss=false }
        else if let permission { dismiss = !["WRITE","MAINTAIN","ADMIN"].contains(permission) ? false : permission == "ADMIN" || restricts == false ? true : nil }
        else { dismiss=nil }
        return .init(id:id,authorLogin:node.author?.login,authorID:node.author?.id,state:state,submittedAt:node.submittedAt.flatMap(GitHubDate.parse),commitOID:node.commit?.oid,viewerDidAuthor:own,viewerCanDismiss:dismiss,viewerCanDiscard:state == .pending && own && node.viewerCanDelete == true)
    }
    private static func restricts(_ pr:Payload.PullRequestNode) -> Bool? { pr.baseRef?.branchProtectionRule?.restrictsReviewDismissals }
    func read(_ c:PRWriteCommand,operation:PRWriteOperation?) async throws -> PRWriteTruth {
        let query=GitHubPRLightQuery(client:client,credential:credential)
        switch c.intent {
        case .metadata(.reviewRequestChanges(let users,let teams,let removeUsers,let removeTeams)):
            let result=try await query.run("ReviewRequests",key:c.key,repository:c.repository,number:c.number,pullRequest:Self.requestSelection+" "+Self.latestReviewsSelection)
            var truth=query.truth(c,result);let requests=result.pr.reviewRequests,latest=result.pr.latest,permission=result.repository.viewerPermission
            truth.canRequestReviews=Self.requestRoles.contains(permission ?? "")
            (truth.requestedUsers,truth.requestedTeams)=Self.requested(requests);truth.requestsComplete=L.complete(requests)
            truth.reviews=(latest?.values ?? []).compactMap { Self.summary($0,permission:permission,restricts:nil) };truth.reviewsComplete=L.complete(latest)
            if operation != nil,truth.requestsComplete,L.applied(add:users.map(\.id)+teams.map(\.id),remove:removeUsers.map(\.id)+removeTeams.map(\.id),current:truth.requestedUsers.map(\.id)+truth.requestedTeams.map(\.id)) { truth.matchingOperationIDs=[c.gitHubNodeID] }
            return truth
        case .discardPendingReview(let id):
            // Pending reviews are visible only to their author; the filter needs no head match.
            let result=try await query.run("PendingReviews",key:c.key,repository:c.repository,number:c.number,pullRequest:Self.pendingReviewsSelection)
            var truth=query.truth(c,result);let pending=result.pr.pending
            truth.reviews=(pending?.values ?? []).compactMap { Self.summary($0,permission:nil,restricts:nil) };truth.reviewsComplete=L.complete(pending)
            if truth.reviews.contains(where:{ $0.id == id && $0.viewerCanDiscard }) { truth.allowedObjectIDs.insert(id) }
            truth.pendingReviewID=truth.reviews.first { $0.viewerDidAuthor }?.id;truth.pendingReviewHead=truth.reviews.first { $0.viewerDidAuthor }?.commitOID
            if operation != nil,truth.reviewsComplete,!truth.reviews.contains(where:{ $0.id == id }) { truth.matchingOperationIDs=[id] }
            return truth
        case .dismissReview(let id,_):
            let result=try await query.run("Dismissal",key:c.key,repository:c.repository,number:c.number,pullRequest:Self.dismissalSelection,extra:Self.dismissedReviewSelection,variables:["review":id])
            var truth=query.truth(c,result)
            truth.reviewDecision=result.pr.reviewDecision
            // A review of another PR (or another node type) is never admitted for this command.
            guard let node=result.review,node.pullRequest?.id == c.gitHubNodeID,let review=Self.summary(node,permission:result.repository.viewerPermission,restricts:Self.restricts(result.pr)) else { return truth }
            truth.reviews=[review];truth.reviewsComplete=true
            if review.viewerCanDismiss != false { truth.allowedObjectIDs.insert(id) }
            if operation != nil,review.state == .dismissed { truth.matchingOperationIDs=[id] }
            return truth
        case .subscription(let state):
            let result=try await query.run("Subscription",key:c.key,repository:c.repository,number:c.number,pullRequest:Self.subscriptionSelection)
            var truth=query.truth(c,result)
            truth.canSubscribe=result.pr.viewerCanSubscribe == true;truth.viewerSubscription=result.pr.viewerSubscription.flatMap(PRSubscriptionState.init(rawValue:))
            if operation != nil,truth.viewerSubscription == state { truth.matchingOperationIDs=[c.gitHubNodeID] }
            return truth
        default:throw PRWriteFailure.unavailable
        }
    }
    func administration(_ pr:PullRequest) async throws -> PRReviewAdministration {
        guard let m=pr.metadata else { throw PRWriteFailure.unavailable }
        let query=GitHubPRLightQuery(client:client,credential:credential)
        let result=try await query.run("Administration",key:pr.key,repository:m.repositoryName,number:m.number,pullRequest:Self.administrationSelection)
        let permission=result.repository.viewerPermission,requests=result.pr.reviewRequests,reviews=result.pr.reviews,requested=Self.requested(requests),restricts=Self.restricts(result.pr)
        return .init(key:pr.key,viewerLogin:result.viewer.login ?? "",reviews:(reviews?.values ?? []).compactMap { Self.summary($0,permission:permission,restricts:restricts) },reviewsComplete:L.complete(reviews,backward:true),requestedUsers:requested.users,requestedTeams:requested.teams,requestsComplete:L.complete(requests),canRequestReviews:Self.requestRoles.contains(permission ?? ""),viewerSubscription:result.pr.viewerSubscription.flatMap(PRSubscriptionState.init(rawValue:)),canSubscribe:result.pr.viewerCanSubscribe == true,reviewDecision:result.pr.reviewDecision)
    }
}
