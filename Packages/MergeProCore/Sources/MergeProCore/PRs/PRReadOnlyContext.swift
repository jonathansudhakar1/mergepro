import Foundation

public struct PROverviewContext:Codable,Sendable {
    public struct Reviewer:Codable,Sendable {
        public let name:String
        /// The reviewer's latest submitted review state (APPROVED, CHANGES_REQUESTED, COMMENTED, DISMISSED…).
        public let state:String?
        public let requested:Bool
        /// GraphQL node ID of that latest review, for dismissal. Nil when no review or unknown.
        public let latestReviewID:String?
        public var latestReviewState:String? { state }
        public init(name:String,state:String?,requested:Bool,latestReviewID:String? = nil) { self.name=name;self.state=state;self.requested=requested;self.latestReviewID=latestReviewID }
    }
    public struct Milestone:Codable,Sendable { public let title:String;public let url:URL?;public let state:String? }
    public struct Issue:Codable,Sendable { public let number:Int;public let title:String;public let url:URL?;public let state:String? }
    public let reviewers:[Reviewer]
    public let reviewersComplete:Bool
    public let milestone:Milestone?
    public let milestoneKnown:Bool
    public let issues:[Issue]
    public let issuesComplete:Bool
}
public struct PRCommitContext:Codable,Sendable,Equatable {
    public let authorName:String?
    public let authorLogin:String?
    public let checksState:String?
}
public struct PRCheckTiming:Codable,Sendable,Equatable {
    public let startedAt:Date?
    public let completedAt:Date?
    public var duration:TimeInterval? {
        guard let startedAt,let completedAt,completedAt >= startedAt else { return nil };return completedAt.timeIntervalSince(startedAt)
    }
}
/// One read-only source, with a generation to reject late responses after retry/cancellation.
public struct PRContextSource:Sendable {
    public enum Phase:String,Sendable { case idle,loading,loaded,partial,failed }
    public private(set) var phase:Phase = .idle
    public private(set) var section:PRDetailSection?
    private var request:UUID?
    public init() {}
    /// True while the visible section is a labeled cache entry (see `section.fetchedAt`).
    public var showingCached:Bool { section?.cached == true }
    @discardableResult public mutating func begin() -> UUID { let id=UUID();request=id;phase = .loading;section=nil;return id }
    /// Revalidation: keeps a cached section visible (labeled by `cached`/`fetchedAt`) while loading.
    /// A failed revalidation keeps that cached section; only a fresh success replaces it.
    @discardableResult public mutating func begin(cached:PRDetailSection?) -> UUID { let id=begin();section=cached.map { $0.cached ? $0 : $0.with(fetchedAt:$0.fetchedAt,cached:true) };return id }
    public mutating func succeed(_ value:PRDetailSection,request:UUID) { guard self.request == request else { return };section=value;phase=value.complete ? .loaded : .partial }
    public mutating func fail(_ error:any Error,request:UUID) { guard self.request == request else { return };if section?.cached != true { section=nil };phase=error is CancellationError ? .idle : .failed }
}
/// Provider viewed marks for the selected viewer at one exact head. `viewed[path]` is true only for
/// VIEWED; UNVIEWED and DISMISSED (changed since viewed) are false. Absent paths are unknown.
public struct PRViewedStates:Codable,Sendable,Equatable {
    public let headSHA:String
    public let viewed:[String:Bool]
    /// Every provider file page was read without errors within bounds; otherwise absence proves nothing.
    public let complete:Bool
    public let fetchedAt:Date
    public init(headSHA:String,viewed:[String:Bool],complete:Bool,fetchedAt:Date) { self.headSHA=headSHA;self.viewed=viewed;self.complete=complete;self.fetchedAt=fetchedAt }
    public func isViewed(_ path:String) -> Bool? { viewed[path] }
    func setting(_ path:String,viewed value:Bool) -> PRViewedStates { var map=viewed;map[path]=value;return .init(headSHA:headSHA,viewed:map,complete:complete,fetchedAt:fetchedAt) }
}

private struct ContextConnection<T:Decodable>:Decodable {
    struct Page:Decodable { let hasNextPage:Bool?;let hasPreviousPage:Bool?;let endCursor:String? }
    let nodes:[T?]?
    let pageInfo:Page?
    var complete:Bool { nodes != nil && pageInfo != nil && pageInfo?.hasNextPage != true && pageInfo?.hasPreviousPage != true && nodes?.contains(where:{$0 == nil}) != true }
}
private struct ContextPayload:Decodable {
    struct Person:Decodable { let login:String?;let name:String?;let slug:String? }
    struct Review:Decodable { let id:String?;let author:Person?;let state:String?;let submittedAt:String? }
    struct ViewedFile:Decodable { let path:String;let viewerViewedState:String? }
    struct Request:Decodable { let requestedReviewer:Person? }
    struct Milestone:Decodable { let title:String;let url:URL?;let state:String? }
    struct Issue:Decodable { let number:Int;let title:String;let url:URL?;let state:String? }
    struct CommitNode:Decodable {
        struct Commit:Decodable {
            struct Author:Decodable { let name:String?;let user:Person? }
            struct Rollup:Decodable { let state:String? }
            let oid:String;let message:String;let url:URL?;let author:Author?;let statusCheckRollup:Rollup?
        }
        let commit:Commit
    }
    let headRefOid:String?
    let milestone:Milestone?
    let reviews:ContextConnection<Review>?
    let reviewRequests:ContextConnection<Request>?
    let closingIssuesReferences:ContextConnection<Issue>?
    let commits:ContextConnection<CommitNode>?
    let files:ContextConnection<ViewedFile>?
}
private struct ContextEnvelope:Decodable {
    struct DataValue:Decodable { struct Repository:Decodable { let pullRequest:ContextPayload? };let repository:Repository? }
    struct Failure:Decodable { let message:String? }
    let data:DataValue?
    let errors:[Failure]?
}
extension GitHubPRDetailFetcher {
    private func contextRead(repository:String,number:Int,sha:String,fields:String,after:String? = nil,token:String) async throws -> (ContextPayload,Bool) {
        try await contextRead(repository:repository,number:number,sha:sha,fields:fields,after:after,token:token,bytes:nil)
    }
    private func contextRead(repository:String,number:Int,sha:String,fields:String,after:String?,token:String,bytes:((Int) -> Void)?) async throws -> (ContextPayload,Bool) {
        let parts=repository.split(separator:"/").map(String.init)
        guard parts.count == 2,number > 0 else { throw PRDetailFailure.invalidPath }
        let cursorDeclaration=after == nil && !fields.contains("$after") ? "" : ", $after:String"
        let query="""
        query PRReadOnlyContext($owner:String!, $repo:String!\(cursorDeclaration)) {
          repository(owner:$owner,name:$repo) { pullRequest(number:\(number)) {
            headRefOid
            \(fields)
          } }
        }
        """
        var variables:[String:String?]=["owner":parts[0],"repo":parts[1]]
        if !cursorDeclaration.isEmpty { variables["after"] = .some(after) }
        let response=try await client.readQuery(query,variables:variables,token:token)
        guard response.data.count <= 8_000_000 else { throw PRDetailFailure.oversized }
        bytes?(response.data.count)
        let envelope=try JSONDecoder().decode(ContextEnvelope.self,from:response.data)
        guard let value=envelope.data?.repository?.pullRequest else { throw PRDetailFailure.unavailable }
        guard value.headRefOid == sha else { throw PRDetailFailure.revisionChanged }
        return (value,envelope.errors?.isEmpty ?? true)
    }
    func overviewContext(repository:String,number:Int,sha:String,token:String) async throws -> PRDetailSection {
        let fields="""
        milestone { title url state }
        reviews: latestReviews(first:100) { nodes { id author { login } state submittedAt } pageInfo { hasPreviousPage hasNextPage } }
        reviewRequests(first:100) { nodes { requestedReviewer { ... on User { login } ... on Bot { login } ... on Mannequin { login } ... on Team { name slug } ... on EnterpriseTeam { name slug } } } pageInfo { hasNextPage } }
        closingIssuesReferences(first:100) { nodes { number title url state } pageInfo { hasNextPage } }
        """
        let (value,noErrors)=try await contextRead(repository:repository,number:number,sha:sha,fields:fields,token:token)
        var states:[String:String]=[:],ids:[String:String]=[:],requested=Set<String>()
        for review in (value.reviews?.nodes ?? []).compactMap({$0}).sorted(by:{ ($0.submittedAt ?? "") < ($1.submittedAt ?? "") }) {
            let name=review.author?.login ?? "Unknown reviewer"
            states[name]=review.state ?? "UNKNOWN";ids[name]=review.id
        }
        for request in (value.reviewRequests?.nodes ?? []).compactMap({$0}) {
            requested.insert(request.requestedReviewer?.login ?? request.requestedReviewer?.slug ?? request.requestedReviewer?.name ?? "Unknown reviewer")
        }
        let reviewers=Set(states.keys).union(requested).sorted().map { PROverviewContext.Reviewer(name:$0,state:states[$0],requested:requested.contains($0),latestReviewID:ids[$0]) }
        let reviewersComplete=noErrors && value.reviews?.complete == true && value.reviewRequests?.complete == true
        let issuesComplete=noErrors && value.closingIssuesReferences?.complete == true
        let context=PROverviewContext(reviewers:reviewers,reviewersComplete:reviewersComplete,milestone:value.milestone.map { .init(title:$0.title,url:$0.url,state:$0.state) },milestoneKnown:noErrors,issues:(value.closingIssuesReferences?.nodes ?? []).compactMap{$0}.map { .init(number:$0.number,title:$0.title,url:$0.url,state:$0.state) },issuesComplete:issuesComplete)
        return .init(events:[],complete:reviewersComplete && issuesComplete && noErrors,overview:context)
    }
    func commitContext(repository:String,number:Int,sha:String,token:String) async throws -> PRDetailSection {
        var events:[PRDetailEvent]=[],after:String?,seen=Set<String>(),complete=true
        for page in 1...10 {
            let (value,noErrors)=try await contextRead(repository:repository,number:number,sha:sha,fields:"commits(first:100,after:$after) { nodes { commit { oid message url author { name user { login } } statusCheckRollup { state } } } pageInfo { hasNextPage endCursor } }",after:after,token:token)
            guard let commits=value.commits else { return .init(events:events,complete:false) }
            complete = complete && noErrors && commits.nodes != nil && commits.nodes?.contains(where:{$0 == nil}) != true
            for node in (commits.nodes ?? []).compactMap({$0}) where seen.insert(node.commit.oid).inserted {
                let c=node.commit
                events.append(.init(id:c.oid,title:"Commit "+String(c.oid.prefix(8)),body:c.message,url:c.url,sha:c.oid,commitContext:.init(authorName:c.author?.name,authorLogin:c.author?.user?.login,checksState:c.statusCheckRollup?.state)))
            }
            if commits.pageInfo?.hasNextPage == false { return .init(events:events,complete:complete) }
            guard page < 10,let next=commits.pageInfo?.endCursor,next != after else { return .init(events:events,complete:false) };after=next
        }
        return .init(events:events,complete:false)
    }
    /// One bounded GraphQL connection: provider viewed marks at exactly `sha` (≤30 pages / 3,000 files, 12 MB).
    func viewedStates(repository:String,number:Int,sha:String,token:String,maxPages:Int = 30) async throws -> PRViewedStates {
        var viewed:[String:Bool]=[:],after:String?,complete=true,total=0
        for page in 1...max(1,min(30,maxPages)) {
            let (value,noErrors)=try await contextRead(repository:repository,number:number,sha:sha,fields:"files(first:100,after:$after) { nodes { path viewerViewedState } pageInfo { hasNextPage endCursor } }",after:after,token:token,bytes:{ total += $0 })
            guard let files=value.files,let nodes=files.nodes else { return .init(headSHA:sha,viewed:viewed,complete:false,fetchedAt:Date()) }
            complete = complete && noErrors && !nodes.contains(where:{$0 == nil})
            for node in nodes.compactMap({$0}) { viewed[node.path]=node.viewerViewedState == "VIEWED" }
            if files.pageInfo?.hasNextPage == false { return .init(headSHA:sha,viewed:viewed,complete:complete,fetchedAt:Date()) }
            guard total <= 12_000_000,page < maxPages,let next=files.pageInfo?.endCursor,next != after else { break };after=next
        }
        return .init(headSHA:sha,viewed:viewed,complete:false,fetchedAt:Date())
    }
}
