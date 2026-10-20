import Foundation

public enum PRDetailFailure: Error, Equatable, Sendable { case revisionChanged, unavailable, oversized, invalidPath }
/// Description-only provider result. It contains no diff origin or validated file inventory.
public struct PRDescriptionSnapshot:Sendable {
    public let body:String
    public let headSHA:String
    public let fetchedAt:Date
    public let cached:Bool
    public init(body:String,headSHA:String,fetchedAt:Date,cached:Bool) {
        self.body=body;self.headSHA=headSHA;self.fetchedAt=fetchedAt;self.cached=cached
    }
}
public struct PRDetailSnapshot: Codable, Sendable {
    public let body: String
    /// Immutable LEFT content identity (merge base), not the current target-branch tip.
    public let baseSHA: String
    public let headSHA: String
    public let files: [DiffFile]
    public let expectedFiles: Int
    /// Current target-branch tip used to validate the paginated diff origin.
    public let baseBranchSHA: String
    public let nextPage: Int?
    /// Served from the local detail cache without contacting the provider in this call.
    public let cached: Bool
    /// When the provider last confirmed this file inventory for `headSHA`. Nil means unknown age.
    public let fetchedAt: Date?
    /// When `body` was read from the provider. Nil means the description is unknown, not empty.
    public let bodyFetchedAt: Date?
    public var document: DiffDocument { .init(baseSHA:baseSHA,headSHA:headSHA,files:files,expectedFiles:expectedFiles) }
    /// The provider inventory has more files than are loaded (paged, capped or byte-bounded).
    public var isPartial: Bool { document.missingFileCount > 0 }
    /// Loaded files without a renderable patch (binary, oversized or provider-truncated).
    public var unavailablePatchCount: Int { files.reduce(0) { $0 + ($1.patchState == .available ? 0 : 1) } }
    public init(body:String,baseSHA:String,headSHA:String,files:[DiffFile],expectedFiles:Int,baseBranchSHA:String? = nil,nextPage:Int? = nil,cached:Bool = false,fetchedAt:Date? = nil,bodyFetchedAt:Date? = nil) {
        self.body=body;self.baseSHA=baseSHA;self.headSHA=headSHA;self.files=files;self.expectedFiles=expectedFiles
        self.baseBranchSHA=baseBranchSHA ?? baseSHA;self.nextPage=nextPage;self.cached=cached;self.fetchedAt=fetchedAt;self.bodyFetchedAt=bodyFetchedAt
    }
    func with(body:String,baseBranchSHA:String? = nil,cached:Bool,fetchedAt:Date?,bodyFetchedAt:Date?) -> PRDetailSnapshot {
        .init(body:body,baseSHA:baseSHA,headSHA:headSHA,files:files,expectedFiles:expectedFiles,baseBranchSHA:baseBranchSHA ?? self.baseBranchSHA,nextPage:nextPage,cached:cached,fetchedAt:fetchedAt,bodyFetchedAt:bodyFetchedAt)
    }
}
/// Provider review coordinates retain the reviewed head, distinct from LEFT content identity.
public struct PRProviderCommentLocation:Codable,Sendable,Equatable {
    public let reviewedHeadSHA:String
    public let path:String
    public let side:String
    public let startLine:Int
    public let endLine:Int
}
/// Raw provider coordinates: nullable fields stay nullable, and originals never become current.
public struct PRCommentCoordinates:Codable,Sendable,Equatable {
    public struct Location:Codable,Sendable,Equatable {
        public let reviewedHeadSHA:String?
        public let startLine:Int?
        public let endLine:Int?
        public let side:String?
        public let startSide:String?
    }
    public let path:String?
    public let current:Location
    public let original:Location
    public var mappedCurrent:PRProviderCommentLocation? {
        guard let path,let sha=current.reviewedHeadSHA,let end=current.endLine,end > 0,
              let side=current.side,DiffSide(rawValue:side) != nil,
              current.startSide == nil || current.startSide == side else { return nil }
        let start=current.startLine ?? end
        guard start > 0,start <= end else { return nil }
        return .init(reviewedHeadSHA:sha,path:path,side:side,startLine:start,endLine:end)
    }
}
public struct PRDetailEvent: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let title: String
    public let body: String
    public let url: URL?
    public let sha: String?
    public let anchor: ReviewAnchor?
    public let providerComment:PRProviderCommentLocation?
    public let commentCoordinates:PRCommentCoordinates?
    public let commitContext:PRCommitContext?
    public let checkTiming:PRCheckTiming?
    public func renderingAnchor(in document:DiffDocument) -> ReviewAnchor? {
        if let anchor { return anchor.commitSHA == document.headSHA ? anchor : nil }
        guard document.comparison == .pullRequest,let location=providerComment,location.reviewedHeadSHA == document.headSHA,let side=DiffSide(rawValue:location.side),let file=document.files.first(where:{ $0.path == location.path }) else { return nil }
        return try? document.anchor(file:file,side:side,start:location.startLine,end:location.endLine)
    }
    public init(id:String,title:String,body:String,url:URL?,sha:String? = nil,anchor:ReviewAnchor? = nil,providerComment:PRProviderCommentLocation? = nil,commentCoordinates:PRCommentCoordinates? = nil,commitContext:PRCommitContext? = nil,checkTiming:PRCheckTiming? = nil) { self.id=id;self.title=title;self.body=body;self.url=url;self.sha=sha;self.anchor=anchor;self.providerComment=providerComment;self.commentCoordinates=commentCoordinates;self.commitContext=commitContext;self.checkTiming=checkTiming }
}
public struct PRDetailSection: Codable, Sendable {
    public let events: [PRDetailEvent]
    public let complete: Bool
    public let overview:PROverviewContext?
    /// When the provider returned (or confirmed, via 304) this section. Nil means unknown age.
    public let fetchedAt:Date?
    /// Served from the local detail cache without contacting the provider in this call.
    public let cached:Bool
    public init(events:[PRDetailEvent],complete:Bool,overview:PROverviewContext? = nil,fetchedAt:Date? = nil,cached:Bool = false) { self.events=events;self.complete=complete;self.overview=overview;self.fetchedAt=fetchedAt;self.cached=cached }
    func with(fetchedAt:Date?,cached:Bool) -> PRDetailSection { .init(events:events,complete:complete,overview:overview,fetchedAt:fetchedAt,cached:cached) }
}
/// Conditional REST page retained by the detail cache. A 304 reuses exactly these parsed values.
struct PRConditionalPage:Codable,Sendable,Equatable {
    let etag:String?
    let lastModified:String?
    let events:[PRDetailEvent]
    let entries:Int
    let complete:Bool
    var conditional:Bool { etag != nil || lastModified != nil }
}
/// `pulls/N` fields used by detail loads, plus its validators for conditional revalidation.
struct PRPullRecord:Codable,Sendable,Equatable {
    let head:String
    let base:String
    let body:String
    let changedFiles:Int
    let etag:String?
    let lastModified:String?
}
/// Validators for one loaded `pulls/N/files` page. `count` locates its slice in the cached inventory.
struct PRFilesPage:Codable,Sendable,Equatable {
    let page:Int
    let etag:String?
    let lastModified:String?
    let count:Int
}
public enum PRDetailTab: String, CaseIterable, Sendable { case overview="Overview",conversation="Conversation",files="Files",commits="Commits",checks="Checks",deployments="Deployments" }
/// Read-only REST adapter. Every page goes through the caller's authenticated budgeted client.
public struct GitHubPRDetailFetcher: Sendable {
    public let client: GitHubHTTPClient
    public init(client:GitHubHTTPClient) { self.client=client }
    private struct Overview: Decodable { struct Ref:Decodable { let sha:String };let body:String?;let head:Ref;let base:Ref;let changed_files:Int }
    private struct File:Decodable { let filename:String;let previous_filename:String?;let status:String;let patch:String?;let additions:Int;let deletions:Int;let sha:String?
        var value:DiffFile { .init(path:filename,previousPath:previous_filename,status:.init(rawValue:status) ?? .changed,patch:patch,additions:additions,deletions:deletions,sha:sha) }
    }
    private func root(_ repository:String) throws -> URL {
        let parts=repository.split(separator:"/",omittingEmptySubsequences:false)
        guard parts.count == 2,parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) } }) else { throw PRDetailFailure.invalidPath }
        return client.origin.appendingPathComponent("repos").appendingPathComponent(repository)
    }
    private func read(_ url:URL,token:String,etag:String? = nil,lastModified:String? = nil) async throws -> GitHubResponse {
        let response=try await client.get(url,token:token,etag:etag,lastModified:lastModified)
        guard response.data.count <= 8_000_000 else { throw PRDetailFailure.oversized }
        // A 304 is only meaningful for a request that supplied a validator with a retained body.
        guard response.status != 304 || etag != nil || lastModified != nil else { throw GitHubFailure.invalidResponse }
        return response
    }
    /// Conditional `pulls/N`. A 304 returns the retained record unchanged.
    func pull(repository:String,number:Int,cached:PRPullRecord?,token:String) async throws -> (value:PRPullRecord,notModified:Bool) {
        guard number > 0 else { throw PRDetailFailure.invalidPath }
        let response=try await read(try root(repository).appendingPathComponent("pulls/\(number)"),token:token,etag:cached?.etag,lastModified:cached?.lastModified)
        if response.status == 304,let cached { return (cached,true) }
        let value=try JSONDecoder().decode(Overview.self,from:response.data)
        guard Self.validRevision(value.head.sha),Self.validRevision(value.base.sha) else { throw PRDetailFailure.unavailable }
        return (.init(head:value.head.sha,base:value.base.sha,body:value.body ?? "",changedFiles:value.changed_files,etag:response.header("ETag"),lastModified:response.header("Last-Modified")),false)
    }
    /// Conditional `pulls/N/files` page. A 304 returns the retained slice for that page.
    func filesPage(repository:String,number:Int,page:Int,cached:(tag:PRFilesPage,files:[DiffFile])?,token:String) async throws -> (files:[DiffFile],tag:PRFilesPage,notModified:Bool) {
        guard number > 0,page > 0,page <= 30 else { throw PRDetailFailure.invalidPath }
        let usable=cached?.tag.page == page ? cached : nil
        let url=try root(repository).appendingPathComponent("pulls/\(number)/files").appending(queryItems:[.init(name:"per_page",value:"100"),.init(name:"page",value:String(page))])
        let response=try await read(url,token:token,etag:usable?.tag.etag,lastModified:usable?.tag.lastModified)
        if response.status == 304,let usable { return (usable.files,usable.tag,true) }
        let values=try JSONDecoder().decode([File].self,from:response.data).map(\.value)
        return (values,.init(page:page,etag:response.header("ETag"),lastModified:response.header("Last-Modified"),count:values.count),false)
    }
    public func detail(repository:String,number:Int,headSHA:String,token:String,maxPages:Int = 1) async throws -> PRDetailSnapshot {
        guard number > 0 else { throw PRDetailFailure.invalidPath }
        let url=try root(repository).appendingPathComponent("pulls/\(number)")
        let before=try JSONDecoder().decode(Overview.self,from:await read(url,token:token).data)
        guard before.head.sha == headSHA else { throw PRDetailFailure.revisionChanged }
        var files:[DiffFile]=[];var accumulatedBytes=0
        // GitHub caps this endpoint at 3,000 files. Missing count remains explicit.
        var continuation:Int?
        for page in 1...max(1,min(30,maxPages)) {
            try Task.checkCancellation()
            let response=try await read(url.appendingPathComponent("files").appending(queryItems:[.init(name:"per_page",value:"100"),.init(name:"page",value:String(page))]),token:token)
            accumulatedBytes += response.data.count
            if accumulatedBytes > 12_000_000 { break }
            let values=try JSONDecoder().decode([File].self,from:response.data)
            files += values.map(\.value)
            continuation=values.count == 100 && page < 30 && files.count < before.changed_files ? page+1 : nil
            if values.count < 100 { break }
        }
        let after=try JSONDecoder().decode(Overview.self,from:await read(url,token:token).data)
        guard after.head.sha == headSHA,after.base.sha == before.base.sha else { throw PRDetailFailure.revisionChanged }
        let mergeBase=try await mergeBase(repository:repository,base:before.base.sha,head:headSHA,token:token)
        return .init(body:after.body ?? "",baseSHA:mergeBase,headSHA:headSHA,files:files,expectedFiles:after.changed_files,baseBranchSHA:after.base.sha,nextPage:continuation)
    }
    func mergeBase(repository:String,base:String,head:String,token:String) async throws -> String {
        guard Self.validRevision(base),Self.validRevision(head) else { throw PRDetailFailure.invalidPath }
        struct Comparison:Decodable { struct Commit:Decodable { let sha:String };let merge_base_commit:Commit }
        let url=try root(repository).appendingPathComponent("compare/\(base)...\(head)")
        let sha=try JSONDecoder().decode(Comparison.self,from:await read(url,token:token).data).merge_base_commit.sha
        guard Self.validRevision(sha) else { throw PRDetailFailure.unavailable };return sha
    }
    public func more(repository:String,number:Int,snapshot:PRDetailSnapshot,token:String) async throws -> PRDetailSnapshot {
        guard let page=snapshot.nextPage,page > 1,page <= 30 else { return snapshot }
        let url=try root(repository).appendingPathComponent("pulls/\(number)")
        let before=try JSONDecoder().decode(Overview.self,from:await read(url,token:token).data)
        guard before.head.sha == snapshot.headSHA,before.base.sha == snapshot.baseBranchSHA else { throw PRDetailFailure.revisionChanged }
        let response=try await read(url.appendingPathComponent("files").appending(queryItems:[.init(name:"per_page",value:"100"),.init(name:"page",value:String(page))]),token:token)
        let values=try JSONDecoder().decode([File].self,from:response.data)
        let after=try JSONDecoder().decode(Overview.self,from:await read(url,token:token).data)
        guard after.head.sha == snapshot.headSHA,after.base.sha == snapshot.baseBranchSHA else { throw PRDetailFailure.revisionChanged }
        let origin=try await mergeBase(repository:repository,base:after.base.sha,head:after.head.sha,token:token)
        guard origin == snapshot.baseSHA else { throw PRDetailFailure.revisionChanged }
        let files=snapshot.files+values.map(\.value)
        guard Set(files.map(\.path)).count == files.count,files.reduce(0,{ $0+($1.patch?.utf8.count ?? 0) }) <= 12_000_000 else { throw PRDetailFailure.oversized }
        return .init(body:after.body ?? "",baseSHA:origin,headSHA:snapshot.headSHA,files:files,expectedFiles:after.changed_files,baseBranchSHA:after.base.sha,nextPage:values.count == 100 && page < 30 && files.count < after.changed_files ? page+1 : nil)
    }
    public func blob(repository:String,path:String,sha:String,token:String) async throws -> Data {
        guard Self.validPath(path),Self.immutableOID(sha) else { throw PRDetailFailure.invalidPath }
        let url=try root(repository).appendingPathComponent("contents").appendingPathComponent(path).appending(queryItems:[.init(name:"ref",value:sha)])
        struct Blob:Decodable { let encoding:String?;let content:String?;let size:Int?;let type:String }
        let value=try JSONDecoder().decode(Blob.self,from:await read(url,token:token).data)
        guard value.type == "file",value.encoding == "base64",let content=value.content,let data=Data(base64Encoded:content,options:.ignoreUnknownCharacters),data.count <= 2_000_000 else { throw PRDetailFailure.oversized }
        return data
    }
    public static func validPath(_ path:String) -> Bool { !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") && !path.utf8.contains(0) && !path.split(separator:"/",omittingEmptySubsequences:false).contains(where:{ $0 == ".." || $0 == "." || $0.isEmpty }) }
    public static func validRevision(_ sha:String) -> Bool { !sha.isEmpty && sha.count <= 128 && sha.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } }
    public static func immutableOID(_ value:String) -> Bool { value.count == 40 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    private func resolvedRevision(repository:String,requested:String,token:String) async throws -> String {
        guard Self.validPath(requested),requested.count <= 128,requested.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_./".contains($0)) }) else { throw PRDetailFailure.invalidPath }
        if Self.immutableOID(requested) { return requested }
        struct Commit:Decodable { let sha:String }
        let sha=try JSONDecoder().decode(Commit.self,from:await read(root(repository).appendingPathComponent("commits").appendingPathComponent(requested),token:token).data).sha
        guard Self.immutableOID(sha) else { throw PRDetailFailure.unavailable };return sha
    }
    public func compare(repository:String,base:String,head:String,token:String) async throws -> DiffDocument {
        let resolvedBase=try await resolvedRevision(repository:repository,requested:base,token:token)
        let resolvedHead=try await resolvedRevision(repository:repository,requested:head,token:token)
        struct Compare:Decodable { struct Commit:Decodable { let sha:String };let files:[File]?;let merge_base_commit:Commit }
        let url=try root(repository).appendingPathComponent("compare/\(resolvedBase)...\(resolvedHead)")
        let result=try JSONDecoder().decode(Compare.self,from:await read(url,token:token).data)
        guard Self.immutableOID(result.merge_base_commit.sha) else { throw PRDetailFailure.unavailable }
        let files=result.files?.map(\.value) ?? []
        return .init(baseSHA:result.merge_base_commit.sha,headSHA:resolvedHead,files:files,expectedFiles:files.count >= 300 ? files.count+1 : files.count,requestedBase:base,requestedHead:head,resolvedBaseSHA:resolvedBase,comparison:.threeDot)
    }
    public func snapshotInterdiff(repository:String,old:String,new:String,token:String) async throws -> DiffDocument {
        let oldOID=try await resolvedRevision(repository:repository,requested:old,token:token)
        let newOID=try await resolvedRevision(repository:repository,requested:new,token:token)
        let forward=try await compare(repository:repository,base:oldOID,head:newOID,token:token)
        let reverse=try await compare(repository:repository,base:newOID,head:oldOID,token:token)
        return try SnapshotInterdiff.candidates(forward:forward,reverse:reverse,requestedOld:old,requestedNew:new)
    }
    public func section(repository:String,number:Int,sha:String,tab:PRDetailTab,token:String) async throws -> PRDetailSection {
        guard number > 0,Self.validRevision(sha) else { throw PRDetailFailure.invalidPath }
        _ = try root(repository)
        if tab == .overview { return try await overviewContext(repository:repository,number:number,sha:sha,token:token) }
        if tab == .commits { return try await commitContext(repository:repository,number:number,sha:sha,token:token) }
        return try await pagedSection(repository:repository,number:number,sha:sha,tab:tab,token:token,cached:[:]).section
    }
    /// Conversation and checks pages are conditional: a page answered 304 reuses its retained parsed
    /// events (including nested check annotations) and is not re-expanded.
    func pagedSection(repository:String,number:Int,sha:String,tab:PRDetailTab,token:String,cached:[String:PRConditionalPage]) async throws -> (section:PRDetailSection,pages:[String:PRConditionalPage]) {
        guard number > 0,Self.validRevision(sha) else { throw PRDetailFailure.invalidPath }
        let root=try root(repository)
        let paths:[String]
        switch tab {
        case .conversation: paths=["issues/\(number)/timeline","pulls/\(number)/comments"]
        case .commits: paths=["pulls/\(number)/commits"]
        case .checks: paths=["commits/\(sha)/check-runs","commits/\(sha)/statuses"]
        case .deployments: paths=["deployments"]
        default:return (.init(events:[],complete:true),[:])
        }
        let conditional=tab == .conversation || tab == .checks
        var events:[PRDetailEvent]=[];var complete=true;var pages:[String:PRConditionalPage]=[:]
        for path in paths {
            for page in 1...10 {
                var query=[URLQueryItem(name:"per_page",value:"100"),.init(name:"page",value:String(page))]
                if tab == .deployments { query.append(.init(name:"sha",value:sha)) }
                let url=root.appendingPathComponent(path).appending(queryItems:query)
                let prior=conditional ? cached[url.absoluteString].flatMap { $0.conditional ? $0 : nil } : nil
                let response=try await read(url,token:token,etag:prior?.etag,lastModified:prior?.lastModified)
                let record:PRConditionalPage
                if response.status == 304,let prior { record=prior }
                else { record=try await parsePage(response,path:path,page:page,root:root,sha:sha,tab:tab,token:token) }
                if conditional { pages[url.absoluteString]=record }
                events += record.events
                if !record.complete { complete=false }
                if record.entries < 100 { break };if page == 10 { complete=false }
            }
        }
        return (.init(events:events,complete:complete),pages)
    }
    private func parsePage(_ response:GitHubResponse,path:String,page:Int,root:URL,sha:String,tab:PRDetailTab,token:String) async throws -> PRConditionalPage {
        let json=try JSONSerialization.jsonObject(with:response.data)
        guard let entries=(json as? [[String:Any]]) ?? (json as? [String:Any])?["check_runs"] as? [[String:Any]] else { throw GitHubFailure.invalidResponse }
        var events:[PRDetailEvent]=[];var complete=true
        for (index,item) in entries.enumerated() {
            let user=(item["user"] as? [String:Any])?["login"] as? String ?? (item["actor"] as? [String:Any])?["login"] as? String
            let commit=item["commit"] as? [String:Any]
            let title=[item["event"] as? String,item["name"] as? String,item["environment"] as? String,item["state"] as? String,item["conclusion"] as? String,item["status"] as? String,user].compactMap { $0 }.joined(separator:" · ")
            var coordinates:PRCommentCoordinates?
            if path.hasSuffix("/comments") {
                coordinates = .init(path:item["path"] as? String,
                    current:.init(reviewedHeadSHA:item["commit_id"] as? String,startLine:item["start_line"] as? Int,endLine:item["line"] as? Int,side:item["side"] as? String,startSide:item["start_side"] as? String),
                    original:.init(reviewedHeadSHA:item["original_commit_id"] as? String,startLine:item["original_start_line"] as? Int,endLine:item["original_line"] as? Int,side:item["side"] as? String,startSide:item["start_side"] as? String))
            }
            if tab == .checks,path.hasSuffix("check-runs"),let id=item["id"] as? Int,
               let output=item["output"] as? [String:Any],(output["annotations_count"] as? Int ?? 0) > 0 {
                for annotationPage in 1...10 {
                    let response=try await read(root.appendingPathComponent("check-runs/\(id)/annotations").appending(queryItems:[.init(name:"per_page",value:"100"),.init(name:"page",value:String(annotationPage))]),token:token)
                    let annotations=try JSONSerialization.jsonObject(with:response.data) as? [[String:Any]] ?? []
                    for (annotationIndex,annotation) in annotations.enumerated() {
                        guard let path=annotation["path"] as? String,let start=annotation["start_line"] as? Int,let end=annotation["end_line"] as? Int,start > 0,end >= start else { continue }
                        events.append(.init(id:"annotation:\(id):\(annotationPage):\(annotationIndex)",title:annotation["title"] as? String ?? annotation["annotation_level"] as? String ?? "Check annotation",body:annotation["message"] as? String ?? "",url:(annotation["blob_href"] as? String).flatMap(URL.init(string:)),anchor:.init(commitSHA:sha,path:path,side:"RIGHT",startLine:start,endLine:end)))
                    }
                    if annotations.count < 100 { break };if annotationPage == 10 { complete=false }
                }
            }
            if tab == .deployments,let id=item["id"] as? Int {
                let response=try await read(root.appendingPathComponent("deployments/\(id)/statuses").appending(queryItems:[.init(name:"per_page",value:"100")]),token:token)
                let statuses=try JSONSerialization.jsonObject(with:response.data) as? [[String:Any]] ?? []
                if let latest=statuses.first {
                    let preview=(latest["environment_url"] as? String).flatMap(URL.init(string:))
                    events.append(.init(id:"deployment:\(id)",title:title+" · "+(latest["state"] as? String ?? "Unknown"),body:latest["description"] as? String ?? "",url:preview))
                    continue
                }
            }
            let web=(item["html_url"] as? String) ?? (item["details_url"] as? String) ?? (item["target_url"] as? String)
            events.append(.init(id:path+":"+String(page)+":"+String(index),title:title.isEmpty ? "Commit" : title,body:item["body"] as? String ?? commit?["message"] as? String ?? item["description"] as? String ?? "",url:web.flatMap(URL.init(string:)),sha:item["sha"] as? String,providerComment:coordinates?.mappedCurrent,commentCoordinates:coordinates,checkTiming:tab == .checks ? .init(startedAt:(item["started_at"] as? String).flatMap(GitHubDate.parse),completedAt:(item["completed_at"] as? String).flatMap(GitHubDate.parse)) : nil))
        }
        return .init(etag:response.header("ETag"),lastModified:response.header("Last-Modified"),events:events,entries:entries.count,complete:complete)
    }
}
