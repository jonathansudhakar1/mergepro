import Foundation

/// Bounded fresh reads used for permission admission and write reconciliation. Partial lists
/// cannot prove absence, current placement, or every file viewed.
struct GitHubPRWriteReader {
    let client:GitHubHTTPClient
    let credential:GitHubCredential
    private typealias Payload=PRWriteReadPayload
    private typealias Connection=Payload.Connection
    static let commentFields="id body url createdAt author { login } viewerDidAuthor viewerCanUpdate viewerCanDelete viewerCanReact viewerCanMinimize viewerCanUnminimize isMinimized reactionGroups { content viewerHasReacted }"
    static let pageFields="pageInfo { hasNextPage endCursor }"
    static let reviewSelection="id body state createdAt submittedAt author { login } commit { oid }"
    static let threadSelection="""
    id path subjectType line startLine diffSide startDiffSide originalLine originalStartLine isOutdated isResolved
    viewerCanReply viewerCanResolve viewerCanUnresolve
    comments(first:100) {
      nodes { \(commentFields) commit { oid } originalCommit { oid } diffHunk line startLine originalLine originalStartLine pullRequestReview { id } }
      \(pageFields)
    }
    """
    static let fileSelection="path viewerViewedState"
    static let requestSelection="requestedReviewer { __typename ... on User { id login } ... on Team { id slug name } }"
    static let identityQuery="""
    query WriteIdentity($id:ID!) {
      viewer { id databaseId login }
      node(id:$id) { ... on PullRequest {
        id number url title body state isDraft headRefOid baseRefOid baseRefName headRefName locked
        author { login } viewerDidAuthor viewerCanUpdate viewerCanReopen viewerCanClose viewerCanAssign viewerCanLabel
        reviewDecision changedFiles additions deletions updatedAt mergedAt
        repository { databaseId nameWithOwner viewerPermission }
        baseRef { branchProtectionRule { requiresCodeOwnerReviews requiredApprovingReviewCount } }
        milestone { number title } labels(first:100) { nodes { name color } pageInfo { hasNextPage } }
        assignees(first:100) { nodes { login } pageInfo { hasNextPage } }
      } }
      rateLimit { cost remaining resetAt }
    }
    """
    static func connectionQuery(_ field:String,_ selection:String) -> String {
        """
        query WriteConnection($id:ID!,$after:String) {
          node(id:$id) { ... on PullRequest {
            id headRefOid baseRefOid
            \(field)(first:100,after:$after) {
              nodes { \(selection) }
              \(pageFields)
            }
          } }
          rateLimit { cost remaining resetAt }
        }
        """
    }
    static let afterQuery="""
    query WriteAfter($id:ID!) {
      viewer { databaseId }
      node(id:$id) { ... on PullRequest { id headRefOid baseRefOid } }
    }
    """
    /// The effective-rules CODEOWNERS note for the base branch ("" without a branch); a failed read is noted, not thrown.
    private func effectiveCodeOwnerRules(repository:String,branch:String?) async throws -> String {
        guard let branch else { return "" }
        do {
            let url=client.origin.appendingPathComponent("repos/\(repository)/rules/branches").appendingPathComponent(branch).appending(queryItems:[.init(name:"per_page",value:"100")])
            let response=try await client.get(url,token:credential.accessToken)
            let rules=try JSONDecoder().decode([Payload.BranchRule].self,from:response.data)
            let values=rules.filter { $0.type == "pull_request" }.map { $0.parameters?.require_code_owner_review.map(String.init(describing:)) ?? "unknown" }
            var note="; effective rules CODEOWNERS: " + (values.isEmpty ? "none returned" : values.joined(separator:", "))
            if GitHubPagination.hasNext(response.header("Link")) { note += " (partial; more rules unavailable)" }
            return note
        } catch {
            if error as? GitHubFailure == .invalidAuthentication { throw error }
            Log.writes.info("Effective branch rules unavailable for write admission: \(Log.kind(error), privacy: .public)")
            return "; effective rules unavailable"
        }
    }
    private func query(_ query:String,_ variables:[String:String?]) async throws -> (data:Payload.QueryData,bytes:Int) {
        let response=try await client.readQuery(query,variables:variables,token:credential.accessToken)
        return (try GitHubGraphQLResponse.data(Payload.QueryData.self,from:response),response.data.count)
    }
    private func connection<Node>(_ field:String,_ selection:String,_ command:PRWriteCommand,_ path:KeyPath<Payload.PullRequestNode,Connection<Node>?>) async throws -> (nodes:[Node],complete:Bool) {
        var values:[Node]=[];var cursor:String?;var bytes=0;var dropped=false
        for _ in 0..<30 {
            let response=try await query(Self.connectionQuery(field,selection),["id":command.gitHubNodeID,"after":cursor])
            bytes += response.bytes
            guard bytes <= 12_000_000 else { return (values,false) }
            let pr=response.data.node
            // A postflight revision race is evidence, not an unsent request. Caller records it.
            guard pr?.id == command.gitHubNodeID else { throw PRWriteFailure.unavailable }
            let connection=pr?[keyPath:path];values += connection?.values ?? []
            // A dropped null entry leaves the list partial even once every page was read.
            if connection?.droppedNulls == true { dropped=true }
            let page=connection?.pageInfo
            if page?.hasNextPage != true { return (values,page != nil && !dropped) }
            guard let next=page?.endCursor,next != cursor else { return (values,false) };cursor=next
        }
        return (values,false)
    }
    func read(_ c:PRWriteCommand,operation:PRWriteOperation?) async throws -> PRWriteTruth {
        guard c.key.host == "github.com" else { throw PRWriteFailure.unavailable }
        // Validate repository syntax before constructing a read or any mutation path.
        _ = try GitHubPRWriteAdapter.request(PRWriteOperation(command:c))
        let data=try await query(Self.identityQuery,["id":c.gitHubNodeID]).data
        guard let viewer=data.viewer,let pr=data.node,let repo=pr.repository,
              viewer.databaseId?.text == c.key.accountID,
              pr.id == c.gitHubNodeID,pr.number == c.number,
              repo.databaseId?.text == c.key.repositoryID,
              repo.nameWithOwner?.lowercased() == c.repository.lowercased(),let head=pr.headRefOid,let target=pr.baseRefOid,let login=viewer.login else { throw PRWriteFailure.accountChanged }
        // Once the identity is proven, the independent reads run in parallel (interactive reads have their own
        // request slots): one after another they took most of the 5–15 s the review sheet waited on.
        async let detailRead=GitHubPRDetailFetcher(client:client).detail(repository:c.repository,number:c.number,headSHA:head,token:credential.accessToken,maxPages:30)
        async let reviewsRead=connection("reviews",Self.reviewSelection,c,\.reviews)
        async let threadsRead=connection("reviewThreads",Self.threadSelection,c,\.reviewThreads)
        async let conversationRead=connection("comments",Self.commentFields,c,\.comments)
        async let viewedRead=connection("files",Self.fileSelection,c,\.files)
        async let requestsRead=connection("reviewRequests",Self.requestSelection,c,\.reviewRequests)
        let baseBranch=pr.baseRefName
        async let rulesRead=effectiveCodeOwnerRules(repository:c.repository,branch:baseBranch)
        let detail=try await detailRead
        guard detail.baseBranchSHA == target else { throw PRWriteFailure.revisionChanged }
        let reviews=try await reviewsRead,threads=try await threadsRead,conversation=try await conversationRead
        let viewed=try await viewedRead,requests=try await requestsRead
        let pending=reviews.nodes.filter { $0.state == "PENDING" && $0.author?.login == login }
        guard pending.count <= 1 else { throw PRWriteFailure.pendingExists }
        let revision=PRWriteRevision(detail)
        let locked=pr.locked == true,canUpdate=pr.viewerCanUpdate == true
        var truth=PRWriteTruth(key:c.key,revision:revision,viewerIsAuthor:pr.viewerDidAuthor == true,canReview:reviews.complete && (!locked || canUpdate),canComment:!locked || canUpdate,canUpdate:canUpdate,canReopen:pr.viewerCanReopen == true,canLabel:pr.viewerCanLabel == true,isOpen:pr.state == "OPEN",pendingReviewID:pending.first?.id,pendingReviewHead:pending.first?.commit?.oid,files:Set(detail.files.map(\.path)),viewed:Set(viewed.nodes.filter { $0.viewerViewedState == "VIEWED" }.compactMap(\.path)),filesComplete:detail.document.missingFileCount == 0 && viewed.complete && viewed.nodes.count == detail.expectedFiles,document:detail.document)
        truth.riskFlagged=detail.document.missingFileCount != 0 || RiskRules.evaluate(files:detail.files,viewed:[],usualSize:nil).contains { $0.kind != .unviewed }
        // Endpoint scope does not substitute for object permissions. Close/assign use their own
        // provider capabilities rather than generic update-object permission.
        switch c.intent {
        case .metadata(.closed(true)):truth.canUpdate=pr.viewerCanClose == true
        case .metadata(.assignees):truth.canUpdate=pr.viewerCanAssign == true
        default:break
        }
        var comments=conversation.nodes
        var complete=reviews.complete && threads.complete && conversation.complete
        for thread in threads.nodes {
            comments += thread.comments?.values ?? []
            if thread.comments?.knownPartial == true { complete=false }
            if let id=thread.id { truth.threadIDs.insert(id) }
        }
        func writable(_ value:Payload.Comment,kind:PRCommentKind,thread:Payload.Thread?=nil) -> PRWritableComment {
            let coordinates:PRCommentCoordinates?=kind == .review ? .init(path:thread?.path,current:.init(reviewedHeadSHA:value.commit?.oid,startLine:value.startLine,endLine:value.line,side:thread?.diffSide,startSide:thread?.startDiffSide),original:.init(reviewedHeadSHA:value.originalCommit?.oid,startLine:value.originalStartLine,endLine:value.originalLine,side:thread?.diffSide,startSide:thread?.startDiffSide)) : nil
            return .init(id:value.id ?? "",body:value.body ?? "",author:value.author?.login,url:value.url.flatMap(URL.init(string:)),kind:kind,own:value.viewerDidAuthor == true,canEdit:value.viewerCanUpdate == true,canDelete:value.viewerCanDelete == true,canReact:value.viewerCanReact == true,canModerate:value.viewerCanMinimize == true,canUnminimize:value.viewerCanUnminimize == true,minimized:value.isMinimized == true,coordinates:coordinates,diffHunk:value.diffHunk,reviewID:value.pullRequestReview?.id)
        }
        truth.conversation=conversation.nodes.map { writable($0,kind:.conversation) }
        truth.threads=threads.nodes.map { thread in
            .init(id:thread.id ?? "",path:thread.path ?? "",resolved:thread.isResolved == true,outdated:thread.isOutdated == true,canReply:thread.viewerCanReply == true,canResolve:thread.viewerCanResolve == true,canUnresolve:thread.viewerCanUnresolve == true,comments:(thread.comments?.values ?? []).map { writable($0,kind:.review,thread:thread) },complete:thread.comments?.knownPartial != true)
        }
        truth.canClose=pr.viewerCanClose == true;truth.canAssign=pr.viewerCanAssign == true
        truth.canRequestReviews=GitHubPRReviewAdministrationReader.requestRoles.contains(repo.viewerPermission ?? "")
        truth.canChangeDraft=truth.isOpen && (pr.viewerDidAuthor == true || ["WRITE","MAINTAIN","ADMIN"].contains(repo.viewerPermission ?? ""))
        truth.threadsComplete=complete
        truth.ownCommentIDs=Set(comments.filter { $0.viewerDidAuthor == true }.compactMap(\.id))
        truth.existingObjectIDs=Set(reviews.nodes.compactMap(\.id)+threads.nodes.compactMap(\.id)+comments.compactMap(\.id))
        switch c.intent {
        case .editComment(let id,_,_):if comments.contains(where:{ $0.id == id && $0.viewerCanUpdate == true }) { truth.allowedObjectIDs.insert(id) }
        case .deleteComment(let id,_):if comments.contains(where:{ $0.id == id && $0.viewerCanDelete == true }) { truth.allowedObjectIDs.insert(id) }
        case .resolve(let id,let resolved):if threads.nodes.contains(where:{ $0.id == id && (resolved ? $0.viewerCanResolve : $0.viewerCanUnresolve) == true }) { truth.allowedObjectIDs.insert(id) }
        case .reaction(let id,_,_):if comments.contains(where:{ $0.id == id && $0.viewerCanReact == true }) { truth.allowedObjectIDs.insert(id) }
        case .reply(let id,_,_):if threads.nodes.contains(where:{ $0.id == id && $0.viewerCanReply == true }) { truth.allowedObjectIDs.insert(id) }
        case .moderate(let id,let classifier):if comments.contains(where:{ $0.id == id && (classifier == nil ? $0.viewerCanUnminimize : $0.viewerCanMinimize) == true }) { truth.allowedObjectIDs.insert(id) }
        default:break
        }
        let protection=pr.baseRef?.branchProtectionRule
        let codeOwner=protection?.requiresCodeOwnerReviews.map { "Classic protection requires CODEOWNERS: \($0)" } ?? "Classic CODEOWNERS requirement unavailable"
        truth.codeOwnerRequirements=codeOwner + (try await rulesRead)
        var metadata=PRMetadata(number:c.number,webURL:URL(string:pr.url ?? "https://github.com/\(c.repository)/pull/\(c.number)")!,repositoryName:c.repository)
        metadata.viewerID=viewer.id;metadata.viewerIsAuthor=truth.viewerIsAuthor;metadata.authorLogin=pr.author?.login
        metadata.headBranch=pr.headRefName ?? "";metadata.baseBranch=pr.baseRefName ?? "";metadata.baseRevision=target
        metadata.labels=(pr.labels?.values ?? []).compactMap(\.name);metadata.assignees=(pr.assignees?.values ?? []).compactMap(\.login)
        metadata.reviewDecision=pr.reviewDecision;metadata.files=pr.changedFiles;metadata.additions=pr.additions;metadata.deletions=pr.deletions
        metadata.fetchedAt=Date();metadata.updatedAt=pr.updatedAt.flatMap(GitHubDate.parse);metadata.mergedAt=pr.mergedAt.flatMap(GitHubDate.parse)
        metadata.partial = !complete || !requests.complete || pr.labels?.knownPartial == true || pr.assignees?.knownPartial == true
        metadata.requiredReviewCount=protection?.requiredApprovingReviewCount
        truth.requestsComplete=requests.complete
        if case .metadata(.reviewers(let users,let teams,let remove)) = c.intent,!remove {
            truth.affectedReviewRequestIDs=Set(requests.nodes.compactMap { item in
                let reviewer=item.requestedReviewer
                guard users.contains(reviewer?.login ?? "") || teams.contains(reviewer?.slug ?? "") else { return nil }
                return reviewer?.id
            })
        }
        truth.labelsComplete=pr.labels?.complete() == true
        if truth.labelsComplete { metadata.labelColors=GitHubPRLightQuery.labels(pr.labels).colors }
        truth.assigneesComplete=pr.assignees?.complete() == true
        metadata.requests=requests.nodes.compactMap { item in let reviewer=item.requestedReviewer;guard let id=reviewer?.id else { return nil };let team=reviewer?.typename == "Team";let own=id == viewer.id;return PRReviewRequest(id:id,name:reviewer?.login ?? reviewer?.name ?? reviewer?.slug ?? "Unknown",kind:team ? .team : .direct,isForViewer:own,viewerStatus:team ? .unknown : own ? .needsReview : .notForViewer) }
        metadata.reviewers=Array(Set(metadata.requests.map(\.name)+reviews.nodes.compactMap { $0.author?.login })).sorted()
        truth.normalized=PullRequest(key:c.key,headRevision:.init(head),title:pr.title ?? "",state:pr.state == "MERGED" ? .merged : pr.state == "CLOSED" ? .closed : .open,isDraft:pr.isDraft == true,metadata:metadata)
        // Verify identity/revision once more after all mutable paginated connections.
        let after=try await query(Self.afterQuery,["id":c.gitHubNodeID]).data
        guard after.viewer?.databaseId?.text == c.key.accountID,after.node?.id == c.gitHubNodeID,after.node?.headRefOid == head,after.node?.baseRefOid == target else { throw PRWriteFailure.revisionChanged }
        if let operation,complete {
            truth.matchingOperationIDs=matches(operation,pr:pr,reviews:reviews.nodes,threads:threads.nodes,comments:comments,requests:requests.nodes,viewed:truth,actor:login)
            if case .thread(let draft,_) = c.intent,truth.matchingOperationIDs.count == 1 {
                let id=truth.matchingOperationIDs[0]
                let thread=threads.nodes.first { ($0.comments?.values ?? []).contains { $0.id == id } }
                truth.placementOutdated=thread?.isOutdated == true
                if let location=draft.location {
                    truth.placementConfirmed = !truth.placementOutdated && thread?.line == location.endLine && (thread?.startLine ?? thread?.line) == location.startLine && thread?.diffSide == location.side && (thread?.startDiffSide == nil || thread?.startDiffSide == location.side)
                } else { truth.placementConfirmed = !truth.placementOutdated && thread?.subjectType == "FILE" }
            }
        }
        return truth
    }
    private func matches(_ op:PRWriteOperation,pr:Payload.PullRequestNode,reviews:[Payload.Review],threads:[Payload.Thread],comments:[Payload.Comment],requests:[Payload.ReviewRequest],viewed:PRWriteTruth,actor:String) -> [String] {
        let c=op.command
        func candidate(_ id:String?,_ author:Payload.Actor?,_ createdAt:String?) -> Bool {
            guard let id,!op.beforeIDs.contains(id),author?.login == actor else { return false }
            if !op.providerIDs.isEmpty { return op.providerIDs.contains(id) }
            guard let date=createdAt.flatMap(GitHubDate.parse),date >= op.createdAt.addingTimeInterval(-1) else { return false };return true
        }
        func candidate(_ review:Payload.Review) -> Bool { candidate(review.id,review.author,review.createdAt) }
        func candidate(_ comment:Payload.Comment) -> Bool { candidate(comment.id,comment.author,comment.createdAt) }
        func reviewMatch(_ value:Payload.Review,body:String,state:String) -> Bool { value.body == body && value.state == state && value.commit?.oid == c.revision.head && value.author?.login == actor }
        func success(_ value:Bool,_ id:String?=nil) -> [String] { value ? [id ?? c.gitHubNodeID] : [] }
        func state(_ d:ReviewDecision) -> String { d == .approve ? "APPROVED" : d == .requestChanges ? "CHANGES_REQUESTED" : "COMMENTED" }
        switch c.intent {
        case .merge:return []
        case .review(let d,let body):return reviews.filter { candidate($0) && reviewMatch($0,body:body,state:state(d)) }.compactMap(\.id)
        case .createPending(let body):return reviews.filter { candidate($0) && reviewMatch($0,body:body,state:"PENDING") }.compactMap(\.id)
        case .submitPending(let id,let d,let body):return reviews.filter { $0.id == id && reviewMatch($0,body:body,state:state(d)) }.compactMap(\.id)
        // Review comments always carry the `pullRequestReview` field (possibly null); conversation comments never do.
        case .conversation(let body):return comments.filter { candidate($0) && $0.body == body && !$0.hasReviewField }.compactMap(\.id)
        case .thread(let draft,let pending):
            return threads.flatMap { thread -> [String] in
                guard thread.path == draft.providerPath,thread.subjectType == (draft.location == nil ? "FILE" : "LINE") else { return [] }
                let matches=(thread.comments?.values ?? []).filter { comment in
                    guard candidate(comment),comment.body == draft.body,comment.originalCommit?.oid == c.revision.head || comment.commit?.oid == c.revision.head else { return false }
                    if let pending, comment.pullRequestReview?.id != pending { return false }
                    guard let location=draft.location else { return true }
                    let end=thread.originalLine ?? thread.line,start=thread.originalStartLine ?? thread.startLine ?? end
                    return end == location.endLine && start == location.startLine && thread.diffSide == location.side
                }
                return matches.compactMap(\.id)
            }
        case .reply(let threadID,let body,let pending):
            return threads.filter { $0.id == threadID }.flatMap { ($0.comments?.values ?? []).filter { candidate($0) && $0.body == body && (pending == nil || $0.pullRequestReview?.id == pending) }.compactMap(\.id) }
        case .editComment(let id,_,let body):return success(comments.contains { $0.id == id && $0.body == body },id)
        case .deleteComment(let id,_):return success(op.beforeIDs.contains(id) && !comments.contains { $0.id == id },id)
        case .resolve(let id,let resolved):return success(threads.contains { $0.id == id && ($0.isResolved == true) == resolved },id)
        case .reaction(let id,let content,let remove):return success(comments.contains { comment in comment.id == id && ((comment.reactionGroups ?? []).first { $0.content == content.rawValue }.map { $0.viewerHasReacted == true } ?? false) == !remove },id)
        case .moderate(let id,let classifier):return success(comments.contains { $0.id == id && ($0.isMinimized == true) == (classifier != nil) },id)
        case .viewed(let path,let mark):return success(viewed.filesComplete && viewed.files.contains(path) && viewed.viewed.contains(path) == mark)
        case .metadata(let mutation):
            switch mutation {
            case .title(let value):return success(pr.title == value)
            case .body(let value):return success(pr.body == value)
            case .base(let value):return success(pr.baseRefName == value)
            case .draft(let value):return success((pr.isDraft == true) == value)
            case .closed(let value):return success(pr.state == (value ? "CLOSED" : "OPEN"))
            case .labels(let values):return success(Set((pr.labels?.values ?? []).compactMap(\.name)) == Set(values) && pr.labels?.knownPartial != true)
            case .assignees(let values):return success(Set((pr.assignees?.values ?? []).compactMap(\.login)) == Set(values) && pr.assignees?.knownPartial != true)
            case .milestone(let value):return success(pr.milestone?.number == value)
            case .reviewers(let users,let teams,let remove):
                let actualUsers=Set(requests.compactMap { $0.requestedReviewer?.login }),actualTeams=Set(requests.compactMap { $0.requestedReviewer?.slug })
                return success(remove ? Set(users).isDisjoint(with:actualUsers) && Set(teams).isDisjoint(with:actualTeams) : Set(users).isSubset(of:actualUsers) && Set(teams).isSubset(of:actualTeams))
            // Revision-independent deltas are routed to the light readers, never confirmed here.
            case .labelChanges,.assigneeChanges,.reviewRequestChanges:return []
            }
        case .discardPendingReview,.dismissReview,.subscription:return []
        }
    }
}
