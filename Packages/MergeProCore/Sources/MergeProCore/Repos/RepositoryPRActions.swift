import Foundation

public struct RepositoryRevertResult:Equatable,Sendable {
    /// Canonical inventory key (`pull-request:<node ID>`) of the revert pull request.
    public let key:ProviderKey
    public let number:Int
    public let webURL:URL
    /// True when a fresh read found the revert PR (already open, or a reconciled lost receipt).
    public let existing:Bool
    public init(key:ProviderKey,number:Int,webURL:URL,existing:Bool) { self.key=key;self.number=number;self.webURL=webURL;self.existing=existing }
}
public enum RepositoryPRActionFailure:Error,Equatable,Sendable,LocalizedError {
    case notMerged,stillOpen,crossRepositoryHead,headMoved
    /// Other OPEN pull requests use the branch as head or as base (stacked); GitHub would close or retarget them.
    case branchInUse(pullRequests:[Int])
    /// The open-PR reads were incomplete, so the branch's other users are unknown and nothing was deleted.
    case branchUsageUnknown
    public var errorDescription:String? {
        switch self {
        case .branchInUse(let numbers):"Branch is still used by open PR\(numbers.count == 1 ? "" : "s") \(numbers.map { "#\($0)" }.joined(separator:", ")). It was not deleted."
        case .branchUsageUnknown:"MergePro couldn't confirm that no other open pull request uses this branch. It was not deleted."
        case .notMerged:"Only merged pull requests can be reverted."
        case .stillOpen:"The pull request is open. Its branch can only be deleted or restored after it is merged or closed."
        case .crossRepositoryHead:"The head branch is not in this repository, so it can't be changed here."
        case .headMoved:"The branch has new commits since the pull request closed. It was not deleted."
        }
    }
}
/// Captured revert intent: reconciliation finds the provider result by base, title or GitHub's branch name.
struct RevertIntent:Codable,Sendable {
    let number:Int
    let nodeID:String
    let title:String
    let base:String
    let attemptedAt:Date
}

extension RepositoryBrowserService {
    static func rawNodeID(_ value:String) -> String { value.hasPrefix("pull-request:") ? String(value.dropFirst("pull-request:".count)) : value }
    static func pullRequestObject(_ reader:GitHubRepoReader,repository:RepoCatalogEntry,number:Int,token:String) async throws -> [String:Any] {
        try reader.object(await reader.response(path:GitHubRepoReader.repositoryPath(repository.repository.name)+"/pulls/\(number)",token:token))
    }
    /// Fresh provider proof that this exact PR is merged; returns its base branch.
    static func requireMerged(_ value:[String:Any],nodeID:String) throws -> String {
        guard value["node_id"] as? String==nodeID else { throw RepositoryBrowserFailure.permissionDenied }
        guard value["merged"] as? Bool == true || value["merged_at"] is String else { throw RepositoryPRActionFailure.notMerged }
        guard let base=(value["base"] as? [String:Any])?["ref"] as? String else { throw GitHubFailure.invalidResponse };return base
    }
    /// A revert PR targets the original base from this repository and has the requested title or GitHub's
    /// `revert-<number>-` head branch. Without `since` only open PRs are read; with it, PRs created since
    /// the attempt (any state, newest first) until an older one proves the window was read completely.
    static func findRevert(_ reader:GitHubRepoReader,repository:RepoCatalogEntry,intent:RevertIntent,token:String,since:Date?) async throws -> (match:[String:Any]?,complete:Bool) {
        let path=try GitHubRepoReader.repositoryPath(repository.repository.name)+"/pulls"
        let earliest=since?.addingTimeInterval(-300)
        func matches(_ item:[String:Any]) -> Bool {
            // Historical closed/merged reverts do not prove a new attempt succeeded.
            if let earliest { guard let created=GitHubRepoReader.date(item["created_at"]),created >= earliest else { return false } }
            let head=item["head"] as? [String:Any] ?? [:]
            return item["number"] as? Int != intent.number && ((head["repo"] as? [String:Any])?["id"] as? Int).map(String.init)==repository.key.repositoryID && (item["base"] as? [String:Any])?["ref"] as? String==intent.base && (item["title"] as? String==intent.title || (head["ref"] as? String)?.hasPrefix("revert-\(intent.number)-") == true)
        }
        var page=1
        while page<=10 {
            var query=[URLQueryItem(name:"base",value:intent.base),URLQueryItem(name:"per_page",value:"100"),URLQueryItem(name:"page",value:String(page))]
            query += since == nil ? [URLQueryItem(name:"state",value:"open")] : [URLQueryItem(name:"state",value:"all"),URLQueryItem(name:"sort",value:"created"),URLQueryItem(name:"direction",value:"desc")]
            let response=try await reader.response(path:path,query:query,token:token)
            let items=try reader.objects(response)
            if let match=items.first(where:matches) { return (match,true) }
            if let earliest,let oldest=items.last.flatMap({ GitHubRepoReader.date($0["created_at"]) }),oldest<earliest { return (nil,true) }
            guard let next=reader.next(response,page:page) else { return (nil,true) };page=next
        }
        return (nil,false)
    }
    static func revertNode(_ response:GitHubResponse) throws -> [String:Any] {
        guard let node=try graphQLPayload(response,field:"revertPullRequest")["revertPullRequest"] as? [String:Any],let id=node["id"] as? String,!id.isEmpty,node["number"] is Int,GitHubRepoReader.safeWebURL(node["url"]) != nil else { throw GitHubFailure.invalidResponse };return node
    }
    private func saveRevert(_ node:[String:Any],repository:RepoCatalogEntry,ticket:AccountOperation) async throws -> RepositoryRevertResult {
        guard let id=node["id"] as? String,let number=node["number"] as? Int,let url=GitHubRepoReader.safeWebURL(node["url"]) else { throw GitHubFailure.invalidResponse }
        let key=ProviderKey(host:repository.key.account.host,accountID:repository.key.account.accountID,repositoryID:repository.key.repositoryID,objectID:"pull-request:"+id)
        var metadata=PRMetadata(number:number,webURL:url,repositoryName:repository.repository.name)
        metadata.headBranch=node["headRefName"] as? String ?? "";metadata.baseBranch=node["baseRefName"] as? String ?? "";metadata.baseRevision=node["baseRefOid"] as? String ?? ""
        // GitHub creates the revert branch in the base repository.
        metadata.headRepositoryID=repository.key.repositoryID;metadata.fetchedAt=Date();metadata.partial=true
        let state:PullRequest.State=node["state"] as? String == "MERGED" ? .merged : node["state"] as? String == "CLOSED" ? .closed : .open
        let pr=PullRequest(key:key,headRevision:RevisionID(node["headRefOid"] as? String ?? ""),title:node["title"] as? String ?? "",state:state,isDraft:node["isDraft"] as? Bool ?? false,metadata:metadata)
        guard try await session.withCurrentOperation(ticket,body:{ db in try db.savePullRequests([pr]) }) else { throw CancellationError() }
        return RepositoryRevertResult(key:key,number:number,webURL:url,existing:false)
    }
    /// Records a provider-observed revert as applied and stores it like a created PR.
    private func adoptRevert(_ item:[String:Any],repository:RepoCatalogEntry,identity:String,ticket:AccountOperation) async throws -> RepositoryRevertResult {
        let data=try JSONSerialization.data(withJSONObject:item)
        guard let url=GitHubRepoReader.safeWebURL(item["html_url"]) else { throw GitHubFailure.invalidResponse }
        let command=CreatePRCommand(repository:repository.providerKey,repositoryName:repository.repository.name,head:(item["head"] as? [String:Any])?["ref"] as? String ?? "",base:(item["base"] as? [String:Any])?["ref"] as? String ?? "",title:item["title"] as? String ?? "",body:"",draft:item["draft"] as? Bool ?? false,reviewers:[])
        guard try await session.withCurrentOperation(ticket,body:{ db in try RepositoryBrowserPersistence(database:db).record(identity,account:ticket.account,state:"applied",data:data) }) else { throw CancellationError() }
        let saved=try await savePR(data,command:command,existing:true,ticket:ticket)
        return RepositoryRevertResult(key:saved.key,number:saved.number,webURL:url,existing:true)
    }

    /// GraphQL `revertPullRequest` for a merged PR, through the repository ledger. An already-open revert is
    /// returned without a mutation; a lost receipt is reconciled by a fresh read and never resent.
    public func revertPullRequest(repository:RepoCatalogEntry,pullRequestNodeID:String,number:Int,title:String,body:String,draft:Bool) async throws -> RepositoryRevertResult {
        let nodeID=Self.rawNodeID(pullRequestNodeID),title=title.trimmingCharacters(in:.whitespacesAndNewlines)
        guard repository.key.account.host == "github.com",number>0,!nodeID.isEmpty,!title.isEmpty,title.count<=256,body.utf8.count<=65536 else { throw RepositoryBrowserFailure.invalidRef }
        _ = try GitHubRepoReader.repositoryPath(repository.repository.name)
        guard try await activeAccount()==repository.key.account else { throw RepositoryBrowserFailure.permissionDenied }
        let identity="pr-revert|"+repository.key.repositoryID+"|\(number)"
        let ticket=try await session.authenticatedOperation(for:repository.key.account,clientID:clientID)
        let reader=GitHubRepoReader(client:await session.interactiveReadClient(account:ticket.account,budget:budget)),token=ticket.credential.accessToken
        var captured:RevertIntent?
        do {
            let base=try Self.requireMerged(await Self.pullRequestObject(reader,repository:repository,number:number,token:token),nodeID:nodeID)
            let intent=RevertIntent(number:number,nodeID:nodeID,title:title,base:base,attemptedAt:Date());captured=intent
            if let found=try await Self.findRevert(reader,repository:repository,intent:intent,token:token,since:nil).match { return try await adoptRevert(found,repository:repository,identity:identity,ticket:ticket) }
            let request=try Self.graphQLMutationBody("RevertPullRequest",input:"RevertPullRequestInput",field:"revertPullRequest",selection:"revertPullRequest { id number url title isDraft state headRefName headRefOid baseRefName baseRefOid }",variables:["pullRequestId":nodeID,"title":title,"body":body,"draft":draft])
            let response=try await mutate(account:ticket.account,identity:identity,path:"graphql",method:"POST",body:request,intent:JSONEncoder().encode(intent),validate:{ _ = try Self.revertNode($0) }) { reader,ticket in
                let token=ticket.credential.accessToken
                try await Self.requirePush(reader,name:repository.repository.name,expectedID:repository.key.repositoryID,token:token)
                _ = try Self.requireMerged(await Self.pullRequestObject(reader,repository:repository,number:number,token:token),nodeID:nodeID)
                guard try await Self.findRevert(reader,repository:repository,intent:intent,token:token,since:nil).match == nil else { throw RepositoryBrowserFailure.unknownWriteOutcome }
            }
            return try await saveRevert(Self.revertNode(response),repository:repository,ticket:ticket)
        } catch {
            await session.featureFailed(error,operation:ticket)
            let malformedReceipt=(error as? GitHubFailure) == .invalidResponse && (try? persistence().operationState(identity,account:ticket.account)) == "applied"
            guard error as? RepositoryBrowserFailure == .unknownWriteOutcome || malformedReceipt else { throw error }
            if malformedReceipt,let captured { try persistence().record(identity,account:ticket.account,state:"unknown",data:JSONEncoder().encode(captured)) }
            // The durable intent (not this call's inputs) defines what is reconciled.
            guard let intent=(try Self.ledgerIntent(database,identity:identity,account:ticket.account)).flatMap({ try? JSONDecoder().decode(RevertIntent.self,from:$0) }) ?? captured else { throw RepositoryBrowserFailure.unknownWriteOutcome }
            if let found=try await Self.findRevert(reader,repository:repository,intent:intent,token:token,since:intent.attemptedAt).match { return try await adoptRevert(found,repository:repository,identity:identity,ticket:ticket) }
            throw RepositoryBrowserFailure.unknownWriteOutcome
        }
    }
    /// Read-only reconciliation of a pending revert: found → applied; a complete window without it → notApplied.
    public func reconcileRevert(repository:RepoCatalogEntry,number:Int) async throws -> RepositoryBranchReconciliation {
        let identity="pr-revert|"+repository.key.repositoryID+"|\(number)"
        guard !inFlightWrites.contains(identity) else { throw RepositoryBrowserFailure.unknownWriteOutcome }
        return try await read(repository.key.account) { reader,ticket in
            let store=try RepositoryBrowserPersistence(database:self.database)
            if try store.operationState(identity,account:ticket.account) == "applied" { return .applied }
            guard let data=try Self.ledgerIntent(self.database,identity:identity,account:ticket.account),let intent=try? JSONDecoder().decode(RevertIntent.self,from:data) else { throw RepositoryBrowserFailure.invalidRef }
            let found=try await Self.findRevert(reader,repository:repository,intent:intent,token:ticket.credential.accessToken,since:intent.attemptedAt)
            if let match=found.match { _ = try await self.adoptRevert(match,repository:repository,identity:identity,ticket:ticket);return .applied }
            guard found.complete else { throw RepositoryBrowserFailure.unknownWriteOutcome }
            guard try await self.session.withCurrentOperation(ticket,body:{ db in try RepositoryBrowserPersistence(database:db).record(identity,account:ticket.account,state:"rejected",data:data) }) else { throw CancellationError() }
            return .notApplied
        }
    }

    /// Local admission for head-branch cleanup: a merged/closed PR whose head is in this repository.
    static func headTarget(_ repository:RepoCatalogEntry,pr:PullRequest) throws -> (name:String,sha:String,number:Int) {
        guard pr.key.repository==repository.key,let metadata=pr.metadata else { throw RepositoryBrowserFailure.permissionDenied }
        guard pr.state != .open else { throw RepositoryPRActionFailure.stillOpen }
        guard metadata.headRepositoryID==repository.key.repositoryID else { throw RepositoryPRActionFailure.crossRepositoryHead }
        guard metadata.number>0,BranchService.validName(metadata.headBranch),GitHubRepoReader.immutableSHA(pr.headRevision.rawValue) else { throw RepositoryBrowserFailure.invalidRef }
        return (metadata.headBranch,pr.headRevision.rawValue.lowercased(),metadata.number)
    }
    /// Fresh provider proof: same PR, closed, same-repository head at the captured ref and SHA.
    static func verifyClosedHead(_ reader:GitHubRepoReader,repository:RepoCatalogEntry,pr:PullRequest,target:(name:String,sha:String,number:Int),token:String) async throws {
        let value=try await pullRequestObject(reader,repository:repository,number:target.number,token:token)
        let head=value["head"] as? [String:Any] ?? [:]
        guard value["node_id"] as? String==rawNodeID(pr.key.objectID) else { throw RepositoryBrowserFailure.permissionDenied }
        guard value["state"] as? String == "closed" else { throw RepositoryPRActionFailure.stillOpen }
        guard ((head["repo"] as? [String:Any])?["id"] as? Int).map(String.init)==repository.key.repositoryID else { throw RepositoryPRActionFailure.crossRepositoryHead }
        guard head["ref"] as? String==target.name,(head["sha"] as? String)?.lowercased()==target.sha else { throw RepositoryBrowserFailure.invalidRef }
    }
    /// One branch read; a 404 after an identity check is an absent branch.
    static func branch(_ reader:GitHubRepoReader,repository:RepoCatalogEntry,name:String,token:String) async throws -> RepositoryBranch? {
        let response:GitHubResponse
        do { response=try await reader.response(path:GitHubRepoReader.repositoryPath(repository.repository.name)+"/branches/"+GitHubRepoReader.refComponent(name),token:token) }
        catch let failure as GitHubFailure where failure == .resourceDenied { return nil }
        let value=try reader.object(response)
        guard value["name"] as? String==name,let sha=(value["commit"] as? [String:Any])?["sha"] as? String,let protected=value["protected"] as? Bool else { throw GitHubFailure.invalidResponse }
        return RepositoryBranch(name:name,sha:sha,protected:protected)
    }
    /// Current head branch of a merged/closed same-repository PR; nil when it no longer exists.
    public func headBranch(repository:RepoCatalogEntry,pr:PullRequest) async throws -> RepositoryBranch? {
        let target=try Self.headTarget(repository,pr:pr)
        return try await read(repository.key.account) { reader,ticket in
            let info=try reader.object(await reader.response(path:GitHubRepoReader.repositoryPath(repository.repository.name),token:ticket.credential.accessToken))
            guard (info["id"] as? Int).map(String.init)==repository.key.repositoryID else { throw RepositoryBrowserFailure.permissionDenied }
            return try await Self.branch(reader,repository:repository,name:target.name,token:ticket.credential.accessToken)
        }
    }
    /// Open pull requests other than `number` whose head is `owner:branch` or whose base is `branch` (a stacked
    /// child). Bounded to 10 pages per filter; an unfinished read throws `branchUsageUnknown`, never "unused".
    static func openBranchUsers(_ reader:GitHubRepoReader,repository:RepoCatalogEntry,branch:String,excluding number:Int,token:String) async throws -> [Int] {
        let path=try GitHubRepoReader.repositoryPath(repository.repository.name)+"/pulls"
        var users:Set<Int>=[]
        // Query values go through URLQueryItem (`&`, `=`, `#` encoded) and the reader's `+` → %2B fix.
        for filter in [URLQueryItem(name:"head",value:repository.owner+":"+branch),URLQueryItem(name:"base",value:branch)] {
            var page=1,complete=false
            while page<=10 {
                let response=try await reader.response(path:path,query:[URLQueryItem(name:"state",value:"open"),filter,URLQueryItem(name:"per_page",value:"100"),URLQueryItem(name:"page",value:String(page))],token:token)
                for item in try reader.objects(response) {
                    guard let found=item["number"] as? Int else { throw RepositoryPRActionFailure.branchUsageUnknown }
                    if found != number { users.insert(found) }
                }
                guard let next=reader.next(response,page:page) else { complete=true;break };page=next
            }
            guard complete else { throw RepositoryPRActionFailure.branchUsageUnknown }
        }
        return users.sorted()
    }
    /// Deletes the head branch only while it still points at the PR head and no other open PR uses it as head
    /// or base (GitHub would close those PRs); shares the branch-delete ledger. Every condition is a preflight
    /// READ: Git ref DELETE takes no expected-SHA, so a push or a new PR between preflight and DELETE is a
    /// check-then-act gap this API cannot close.
    public func deleteHeadBranch(repository:RepoCatalogEntry,pr:PullRequest) async throws {
        let target=try Self.headTarget(repository,pr:pr)
        let mutation=RepositoryBranchMutation.delete(name:target.name,sha:target.sha)
        _ = try await mutate(account:repository.key.account,identity:mutation.identity(repository:repository.key),path:GitHubRepoReader.repositoryPath(repository.repository.name)+"/git/refs/heads/"+target.name,method:"DELETE",body:nil) { reader,ticket in
            let token=ticket.credential.accessToken
            let info=try await Self.pushInfo(reader,name:repository.repository.name,expectedID:repository.key.repositoryID,token:token)
            try await Self.verifyClosedHead(reader,repository:repository,pr:pr,target:target,token:token)
            guard let current=try await Self.branch(reader,repository:repository,name:target.name,token:token) else { throw GitHubFailure.resourceDenied }
            guard current.sha.lowercased()==target.sha else { throw RepositoryPRActionFailure.headMoved }
            try BranchService.validateDeletion(current,defaultBranch:info["default_branch"] as? String ?? repository.defaultBranch)
            // A failed or incomplete read throws: unknown users means the branch is not deleted.
            let users=try await Self.openBranchUsers(reader,repository:repository,branch:target.name,excluding:target.number,token:token)
            guard users.isEmpty else { throw RepositoryPRActionFailure.branchInUse(pullRequests:users) }
        }
    }
    /// Recreates the deleted head branch at the PR's head SHA; shares the branch-create ledger.
    public func restoreHeadBranch(repository:RepoCatalogEntry,pr:PullRequest) async throws {
        let target=try Self.headTarget(repository,pr:pr)
        let mutation=RepositoryBranchMutation.create(name:target.name,sha:target.sha)
        let body=try JSONSerialization.data(withJSONObject:["ref":"refs/heads/"+target.name,"sha":target.sha])
        _ = try await mutate(account:repository.key.account,identity:mutation.identity(repository:repository.key),path:GitHubRepoReader.repositoryPath(repository.repository.name)+"/git/refs",method:"POST",body:body) { reader,ticket in
            let token=ticket.credential.accessToken
            try await Self.requirePush(reader,name:repository.repository.name,expectedID:repository.key.repositoryID,token:token)
            try await Self.verifyClosedHead(reader,repository:repository,pr:pr,target:target,token:token)
            guard try await Self.branch(reader,repository:repository,name:target.name,token:token) == nil else { throw RepositoryBrowserFailure.existingBranch }
            guard try await reader.resolve(repository:repository.repository.name,ref:target.sha,token:token).commitSHA.lowercased()==target.sha else { throw RepositoryBrowserFailure.invalidRef }
        }
    }
}
