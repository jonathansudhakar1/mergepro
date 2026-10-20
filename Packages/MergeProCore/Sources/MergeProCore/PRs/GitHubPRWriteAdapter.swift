import Foundation

/// Preserve structured provider evidence. Only an allowlisted error with no mutation data
/// proves rejection; partial data/unknown error types retain uncertain effects.
public struct GitHubGraphQLMutationFailure:Error,LocalizedError,Sendable {
    public let response:Data
    public let types:[String]
    public let messages:[String]
    public let definitelyRejected:Bool
    public var errorDescription:String? { zip(types,messages).map { "\($0): \($1)" }.joined(separator:"; ") }
    public var authenticationFailure:GitHubFailure? { definitelyRejected && types.contains("UNAUTHENTICATED") ? .invalidAuthentication : nil }
}
public struct GitHubPRWriteAdapter:PRWriteAdapter {
    public init() {}
    public struct Request:Sendable { public let path:String;public let method:String;public let body:Data }
    /// Every provider request of one ledger operation, in dispatch order. Only a mixed review
    /// request delta has two parts: a GraphQL union add, then the REST removal.
    public static func requests(_ operation:PRWriteOperation) throws -> [Request] {
        let first=try request(operation)
        guard case .metadata(.reviewRequestChanges(let users,let teams,let removeUsers,let removeTeams))=operation.command.intent,!(users.isEmpty && teams.isEmpty),!(removeUsers.isEmpty && removeTeams.isEmpty) else { return [first] }
        return [first,try reviewerRemoval(operation.command,users:removeUsers,teams:removeTeams)]
    }
    /// GraphQL has no additive removal of a review request (requestReviews without union
    /// replaces the set), so removal uses REST DELETE with logins/slugs and a JSON body.
    static func reviewerRemoval(_ c:PRWriteCommand,users:[PRUserRef],teams:[PRTeamRef]) throws -> Request {
        guard !(users.isEmpty && teams.isEmpty) else { throw PRWriteFailure.invalidChange }
        return .init(path:"repos/\(c.repository)/pulls/\(c.number)/requested_reviewers",method:"DELETE",body:try JSONSerialization.data(withJSONObject:["reviewers":users.map(\.login),"team_reviewers":teams.map(\.slug)],options:.sortedKeys))
    }
    /// Host, node, number and repository syntax shared by mutation construction and light reads.
    static func validateTarget(key:ProviderKey,repository:String,number:Int) throws {
        let parts=repository.split(separator:"/",omittingEmptySubsequences:false)
        guard key.host == "github.com",!PRWriteCommand.gitHubNodeID(for:key).isEmpty,number>0,parts.count==2,parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) } }) else { throw PRWriteFailure.unavailable }
    }
    public static func request(_ operation:PRWriteOperation) throws -> Request {
        let c=operation.command
        try validateTarget(key:c.key,repository:c.repository,number:c.number)
        let root="repos/\(c.repository)",pull="\(root)/pulls/\(c.number)",issue="\(root)/issues/\(c.number)"
        func rest(_ path:String,_ method:String,_ body:[String:Any]) throws -> Request { .init(path:path,method:method,body:try JSONSerialization.data(withJSONObject:body,options:.sortedKeys)) }
        func graph(_ name:String,_ type:String,_ input:[String:Any],_ fields:String) throws -> Request {
            var input=input;input["clientMutationId"]=operation.id.uuidString
            return try rest("graphql","POST",["query":"mutation Command($input:\(type)!) { \(name)(input:$input) { clientMutationId \(fields) } }","variables":["input":input]])
        }
        /// One document with aliased add/remove halves; an empty half is omitted entirely.
        func aliased(_ name:String,subject:String,ids key:String,_ halves:[(alias:String,field:String,type:String,ids:[String])]) throws -> Request {
            let used=halves.filter { !$0.ids.isEmpty };guard !used.isEmpty else { throw PRWriteFailure.invalidChange }
            var variables:[String:Any]=[:];for half in used { variables[half.alias]=[subject:c.gitHubNodeID,key:half.ids,"clientMutationId":operation.id.uuidString] }
            let declarations=used.map { "$\($0.alias):\($0.type)!" }.joined(separator:","),fields=used.map { "\($0.alias): \($0.field)(input:$\($0.alias)) { clientMutationId }" }.joined(separator:" ")
            return try rest("graphql","POST",["query":"mutation \(name)(\(declarations)) { \(fields) }","variables":variables])
        }
        switch c.intent {
        case .merge:return try GitHubMergeAdapter.request(operation)
        case .review(let decision,let body):
            return try graph("addPullRequestReview","AddPullRequestReviewInput",["pullRequestId":c.gitHubNodeID,"commitOID":c.revision.head,"body":body,"event":decision.providerEvent],"pullRequestReview { id state commit { oid } }")
        case .createPending(let body):
            return try graph("addPullRequestReview","AddPullRequestReviewInput",["pullRequestId":c.gitHubNodeID,"commitOID":c.revision.head,"body":body],"pullRequestReview { id state commit { oid } }")
        case .submitPending(let id,let decision,let body):
            return try graph("submitPullRequestReview","SubmitPullRequestReviewInput",["pullRequestReviewId":id,"event":decision.providerEvent,"body":body],"pullRequestReview { id state commit { oid } }")
        case .thread(let comment,let pending):
            if let pending {
                var input:[String:Any]=["pullRequestReviewId":pending,"body":comment.body,"path":comment.providerPath,"subjectType":comment.location == nil ? "FILE" : "LINE"]
                if let l=comment.location { input["line"]=l.endLine;input["side"]=l.side;if l.startLine != l.endLine { input["startLine"]=l.startLine;input["startSide"]=l.side } }
                return try graph("addPullRequestReviewThread","AddPullRequestReviewThreadInput",input,"thread { id path subjectType isOutdated comments(first:100) { nodes { id body commit { oid } originalCommit { oid } diffHunk line startLine originalLine originalStartLine } pageInfo { hasNextPage endCursor } } }")
            }
            var body:[String:Any]=["body":comment.body,"commit_id":c.revision.head,"path":comment.providerPath,"subject_type":comment.location == nil ? "file" : "line"]
            if let l=comment.location { body["line"]=l.endLine;body["side"]=l.side;if l.startLine != l.endLine { body["start_line"]=l.startLine;body["start_side"]=l.side } }
            return try rest(pull+"/comments","POST",body)
        case .reply(let thread,let body,let pending):
            var input:[String:Any]=["pullRequestReviewThreadId":thread,"body":body];if let pending { input["pullRequestReviewId"]=pending }
            return try graph("addPullRequestReviewThreadReply","AddPullRequestReviewThreadReplyInput",input,"comment { id body commit { oid } pullRequestReview { id } }")
        case .conversation(let body):
            return try graph("addComment","AddCommentInput",["subjectId":c.gitHubNodeID,"body":body],"commentEdge { node { id body } }")
        case .editComment(let id,let kind,let body):
            return try graph(kind == .review ? "updatePullRequestReviewComment" : "updateIssueComment",kind == .review ? "UpdatePullRequestReviewCommentInput" : "UpdateIssueCommentInput",[kind == .review ? "pullRequestReviewCommentId" : "id":id,"body":body],kind == .review ? "pullRequestReviewComment { id body }" : "issueComment { id body }")
        case .deleteComment(let id,let kind):
            return try graph(kind == .review ? "deletePullRequestReviewComment" : "deleteIssueComment",kind == .review ? "DeletePullRequestReviewCommentInput" : "DeleteIssueCommentInput",["id":id],"")
        case .resolve(let id,let resolved):
            return try graph(resolved ? "resolveReviewThread" : "unresolveReviewThread",resolved ? "ResolveReviewThreadInput" : "UnresolveReviewThreadInput",["threadId":id],"thread { id isResolved }")
        case .reaction(let id,let content,let remove):
            return try graph(remove ? "removeReaction" : "addReaction",remove ? "RemoveReactionInput" : "AddReactionInput",["subjectId":id,"content":content.rawValue],"subject { id }")
        case .moderate(let id,let classifier):
            if let classifier { guard ["ABUSE","OFF_TOPIC","OUTDATED","RESOLVED","SPAM","DUPLICATE"].contains(classifier) else { throw PRWriteFailure.unavailable };return try graph("minimizeComment","MinimizeCommentInput",["subjectId":id,"classifier":classifier],"minimizedComment { isMinimized }") }
            return try graph("unminimizeComment","UnminimizeCommentInput",["subjectId":id],"unminimizedComment { isMinimized }")
        case .viewed(let path,let viewed):
            return try graph(viewed ? "markFileAsViewed" : "unmarkFileAsViewed",viewed ? "MarkFileAsViewedInput" : "UnmarkFileAsViewedInput",["pullRequestId":c.gitHubNodeID,"path":path],"pullRequest { id headRefOid }")
        case .metadata(let mutation):
            switch mutation {
            case .title(let value):return try rest(pull,"PATCH",["title":value])
            case .body(let value):return try rest(pull,"PATCH",["body":value])
            case .base(let value):return try rest(pull,"PATCH",["base":value])
            case .closed(let closed):return try rest(pull,"PATCH",["state":closed ? "closed" : "open"])
            case .labels(let value):return try rest(issue,"PATCH",["labels":value])
            case .assignees(let value):return try rest(issue,"PATCH",["assignees":value])
            case .milestone(let value):return try rest(issue,"PATCH",["milestone":value.map { $0 as Any } ?? NSNull()])
            case .reviewers(let users,let teams,let remove):return try rest(pull+"/requested_reviewers",remove ? "DELETE" : "POST",["reviewers":users,"team_reviewers":teams])
            case .draft(let draft):return try graph(draft ? "convertPullRequestToDraft" : "markPullRequestReadyForReview",draft ? "ConvertPullRequestToDraftInput" : "MarkPullRequestReadyForReviewInput",["pullRequestId":c.gitHubNodeID],"pullRequest { id isDraft }")
            case .labelChanges(let add,let remove):
                return try aliased("PRLabelChanges",subject:"labelableId",ids:"labelIds",[("add","addLabelsToLabelable","AddLabelsToLabelableInput",add.map(\.id)),("remove","removeLabelsFromLabelable","RemoveLabelsFromLabelableInput",remove.map(\.id))])
            case .assigneeChanges(let add,let remove):
                return try aliased("PRAssigneeChanges",subject:"assignableId",ids:"assigneeIds",[("add","addAssigneesToAssignable","AddAssigneesToAssignableInput",add.map(\.id)),("remove","removeAssigneesFromAssignable","RemoveAssigneesFromAssignableInput",remove.map(\.id))])
            case .reviewRequestChanges(let users,let teams,let removeUsers,let removeTeams):
                guard !(users.isEmpty && teams.isEmpty) else { return try Self.reviewerRemoval(c,users:removeUsers,teams:removeTeams) }
                // union:true adds to the current set; re-request is an add of an existing reviewer.
                var input:[String:Any]=["pullRequestId":c.gitHubNodeID,"union":true]
                if !users.isEmpty { input["userIds"]=users.map(\.id) };if !teams.isEmpty { input["teamIds"]=teams.map(\.id) }
                return try graph("requestReviews","RequestReviewsInput",input,"pullRequest { id }")
            }
        case .discardPendingReview(let id):
            return try graph("deletePullRequestReview","DeletePullRequestReviewInput",["pullRequestReviewId":id],"pullRequestReview { id state }")
        case .dismissReview(let id,let message):
            return try graph("dismissPullRequestReview","DismissPullRequestReviewInput",["pullRequestReviewId":id,"message":message],"pullRequestReview { id state }")
        case .subscription(let state):
            return try graph("updateSubscription","UpdateSubscriptionInput",["subscribableId":c.gitHubNodeID,"state":state.rawValue],"subscribable { id viewerSubscription }")
        }
    }
    public func send(_ operation:PRWriteOperation,client:GitHubHTTPClient,credential:GitHubCredential) async throws -> GitHubResponse {
        var receipts:[GitHubResponse]=[]
        let light=operation.command.intent.isRevisionIndependent
        for (part,spec) in try Self.requests(operation).enumerated() {
            // A REST 422 on a light part is a definite validation refusal, not an unknown outcome.
            do { receipts.append(try await Self.dispatch(spec,client:client,credential:credential,refusals:light && spec.path != "graphql" ? [422] : [])) }
            catch {
                // Idempotent light deltas whose parts split DEFINITELY (applied vs refused or never sent) are terminal.
                if light,let partial=Self.partialOutcome(operation,part:part,receipts:receipts,error:error) { throw partial }
                guard let first=receipts.first else { throw error }
                // Otherwise an earlier part may have taken effect and a later ambiguous failure can never prove
                // the operation was rejected; it stays uncertain and is reconciled by a read.
                throw GitHubGraphQLMutationFailure(response:first.data,types:["PARTIAL_EFFECT"],messages:["An earlier part of this change was sent; a later part failed: \(error.localizedDescription)"],definitelyRejected:false)
            }
        }
        guard receipts.count > 1,let last=receipts.last else { return receipts[0] }
        let combined=try JSONSerialization.data(withJSONObject:receipts.map { (try? JSONSerialization.jsonObject(with:$0.data,options:.fragmentsAllowed)) ?? NSNull() })
        return GitHubResponse(status:last.status,headers:last.headers,data:combined,responseURL:last.responseURL)
    }
    /// Allowlisted structured GraphQL denials. With a null payload they prove that field was not applied.
    static let definiteGraphQLDenials:Set<String>=["FORBIDDEN","UNAUTHORIZED","UNAUTHENTICATED","NOT_FOUND","UNPROCESSABLE","GRAPHQL_VALIDATION_FAILED","BAD_USER_INPUT"]
    private static func dispatch(_ spec:Request,client:GitHubHTTPClient,credential:GitHubCredential,refusals:Set<Int>=[]) async throws -> GitHubResponse {
        let response=try await client.mutate(path:spec.path,method:spec.method,body:spec.body,token:credential.accessToken,acceptedStatuses:refusals)
        if refusals.contains(response.status) {
            let message=((try? JSONSerialization.jsonObject(with:response.data)) as? [String:Any])?["message"] as? String ?? "GitHub refused the request (\(response.status))."
            throw GitHubGraphQLMutationFailure(response:response.data,types:["UNPROCESSABLE"],messages:[message],definitelyRejected:true)
        }
        guard response.data.count <= 8_000_000 else { throw PRDetailFailure.oversized }
        if spec.path == "graphql" {
            let envelope=try JSONSerialization.jsonObject(with:response.data) as? [String:Any]
            if let errors=envelope?["errors"] as? [[String:Any]],!errors.isEmpty {
                let types=errors.map { ($0["type"] as? String) ?? (($0["extensions"] as? [String:Any])?["code"] as? String) ?? "UNKNOWN" }
                let data=envelope?["data"] as? [String:Any]
                let noEffects=data == nil || data!.values.allSatisfy { $0 is NSNull }
                throw GitHubGraphQLMutationFailure(response:response.data,types:types,messages:errors.map { $0["message"] as? String ?? "GraphQL mutation failed" },definitelyRejected:noEffects && types.allSatisfy { definiteGraphQLDenials.contains($0) })
            }
            guard envelope?["data"] is [String:Any] else { throw GitHubFailure.invalidResponse }
        }
        return response
    }
    enum Half:Hashable { case add,remove }
    /// Light intents only: per request part, the GraphQL payload fields (aliases) a definite success receipt
    /// carries non-null, and the delta half each applies. An empty field name is the REST requested_reviewers
    /// DELETE part, whose receipt exists only for 2xx. Other intents have none.
    static func receiptFields(_ intent:PRWriteIntent) -> [[(field:String,half:Half)]] {
        func halves(_ add:Bool,_ remove:Bool) -> [(field:String,half:Half)] { (add ? [("add",.add)] : [])+(remove ? [("remove",.remove)] : []) }
        switch intent {
        case .metadata(.labelChanges(let add,let remove)):return [halves(!add.isEmpty,!remove.isEmpty)]
        case .metadata(.assigneeChanges(let add,let remove)):return [halves(!add.isEmpty,!remove.isEmpty)]
        case .metadata(.reviewRequestChanges(let users,let teams,let removeUsers,let removeTeams)):
            return (users.isEmpty && teams.isEmpty ? [] : [[("requestReviews",.add)]])+(removeUsers.isEmpty && removeTeams.isEmpty ? [] : [[("",.remove)]])
        case .discardPendingReview:return [[("deletePullRequestReview",.add)]]
        case .dismissReview:return [[("dismissPullRequestReview",.add)]]
        case .subscription:return [[("updateSubscription",.add)]]
        default:return []
        }
    }
    /// One part's receipt is a definite success: REST (2xx, or it would have thrown) or a clean GraphQL payload.
    private static func partSucceeded(_ body:Any?,part:[(field:String,half:Half)]) -> Bool {
        let fields=part.map(\.field);if fields.allSatisfy(\.isEmpty) { return true }
        guard let envelope=body as? [String:Any],envelope["errors"] == nil || (envelope["errors"] as? [Any])?.isEmpty == true,let data=envelope["data"] as? [String:Any] else { return false }
        return fields.allSatisfy { data[$0] is [String:Any] }
    }
    /// A definite success of EVERY part of a light write: each GraphQL part has no `errors` and a non-null
    /// payload for each of its mutation fields; a REST part returned 2xx. Anything else is no proof and the
    /// operation is reconciled by a read instead.
    public static func receiptConfirms(_ operation:PRWriteOperation,response:GitHubResponse) -> Bool {
        let parts=receiptFields(operation.command.intent)
        guard !parts.isEmpty,(200..<300).contains(response.status) else { return false }
        let root=try? JSONSerialization.jsonObject(with:response.data,options:.fragmentsAllowed)
        let bodies:[Any?]=parts.count == 1 ? [root] : (root as? [Any])?.map { $0 } ?? []
        return bodies.count == parts.count && zip(parts,bodies).allSatisfy { partSucceeded($1,part:$0) }
    }
    /// An idempotent light delta whose halves split DEFINITELY: some applied (definite success) and the rest
    /// refused by GitHub (allowlisted denial with a null payload, or a definite REST refusal) or never sent (the
    /// final admission refused, e.g. after an account switch). Any ambiguity returns nil and stays uncertain.
    static func partialOutcome(_ operation:PRWriteOperation,part:Int,receipts:[GitHubResponse],error:any Error) -> PRWriteRejection? {
        let intent=operation.command.intent,parts=receiptFields(intent)
        guard intent.isIdempotent,part < parts.count else { return nil }
        if part == 0 {
            // One aliased GraphQL document: each alias's payload says which half applied.
            guard let failure=error as? GitHubGraphQLMutationFailure,!failure.definitelyRejected,failure.types.allSatisfy(definiteGraphQLDenials.contains),
                  let data=((try? JSONSerialization.jsonObject(with:failure.response)) as? [String:Any])?["data"] as? [String:Any] else { return nil }
            var applied:[Half]=[],refused:[Half]=[]
            for (field,half) in parts[0] {
                if data[field] is [String:Any] { applied.append(half) } else if data[field] is NSNull { refused.append(half) } else { return nil }
            }
            return partialSummary(intent,applied:applied,failed:refused,outcome:"was refused by GitHub",detail:failure.errorDescription).map { .init(kind:.partial,summary:$0,response:failure.response,cause:failure) }
        }
        // A later part failed after every earlier part returned a definite success receipt.
        guard receipts.count == part,zip(parts.prefix(part),receipts).allSatisfy({ partSucceeded(try? JSONSerialization.jsonObject(with:$1.data,options:.fragmentsAllowed),part:$0) }) else { return nil }
        let outcome:String,detail:String?
        switch error {
        // PRWriteFailure only comes from the final admission, before anything was dispatched.
        case is PRWriteFailure:outcome="was not sent";detail=nil
        case let failure as GitHubFailure:
            switch failure {
            case .invalidAuthentication,.scopeRequired,.organizationRestricted,.resourceDenied:outcome="was refused by GitHub";detail=nil
            case .rateLimited:outcome="was refused by GitHub";detail="rate limited"
            default:return nil
            }
        case let failure as GitHubGraphQLMutationFailure where failure.definitelyRejected:outcome="was refused by GitHub";detail=failure.errorDescription
        default:return nil
        }
        let applied=parts.prefix(part).flatMap { $0.map(\.half) },failed=parts.dropFirst(part).flatMap { $0.map(\.half) }
        return partialSummary(intent,applied:applied,failed:failed,outcome:outcome,detail:detail).map { .init(kind:.partial,summary:$0,response:receipts.first?.data,cause:error) }
    }
    /// "Added ‘bug’; removing ‘wontfix’ was refused by GitHub." Nil unless both sides are non-empty.
    static func partialSummary(_ intent:PRWriteIntent,applied:[Half],failed:[Half],outcome:String,detail:String?) -> String? {
        func quoted(_ names:[String]) -> String { names.map { "‘\($0)’" }.joined(separator:", ") }
        let phrases:[Half:(done:String,doing:String,names:[String])]
        switch intent {
        case .metadata(.labelChanges(let add,let remove)):phrases=[.add:("Added","adding",add.map(\.name)),.remove:("Removed","removing",remove.map(\.name))]
        case .metadata(.assigneeChanges(let add,let remove)):phrases=[.add:("Assigned","assigning",add.map(\.login)),.remove:("Unassigned","unassigning",remove.map(\.login))]
        case .metadata(.reviewRequestChanges(let users,let teams,let removeUsers,let removeTeams)):
            phrases=[.add:("Requested review from","requesting review from",users.map(\.login)+teams.map(\.slug)),.remove:("Removed the review request for","removing the review request for",removeUsers.map(\.login)+removeTeams.map(\.slug))]
        default:return nil
        }
        let done=applied.compactMap { phrases[$0] }.map { "\($0.done) \(quoted($0.names))" }.joined(separator:" and "),failing=failed.compactMap { phrases[$0] }.map { "\($0.doing) \(quoted($0.names))" }.joined(separator:" and ")
        guard !done.isEmpty,!failing.isEmpty else { return nil }
        return "\(done); \(failing) \(outcome)\(detail.map { " (\($0))" } ?? "")."
    }
    public func providerIDs(_ response:GitHubResponse) -> [String] {
        guard let object=try? JSONSerialization.jsonObject(with:response.data) else { return [] }
        func ids(_ value:Any) -> [String] {
            if let d=value as? [String:Any] { return d.flatMap { key,value in (key == "id" || key == "node_id") ? [(value as? String) ?? String(describing:value)] : ids(value) } }
            if let list=value as? [Any] { return list.flatMap(ids) };return []
        }
        return ids(object)
    }
    /// Revision-independent intents use ONE light query each way; everything else uses the
    /// complete detail/review/thread reader.
    public func read(_ command:PRWriteCommand,operation:PRWriteOperation?,client:GitHubHTTPClient,credential:GitHubCredential) async throws -> PRWriteTruth {
        switch command.intent {
        case .metadata(.labelChanges),.metadata(.assigneeChanges):return try await GitHubPRLabelReader(client:client,credential:credential).read(command,operation:operation)
        case let intent where intent.isRevisionIndependent:return try await GitHubPRReviewAdministrationReader(client:client,credential:credential).read(command,operation:operation)
        default:return try await GitHubPRWriteReader(client:client,credential:credential).read(command,operation:operation)
        }
    }
}
