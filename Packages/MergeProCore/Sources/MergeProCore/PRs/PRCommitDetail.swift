import Foundation

/// A frozen commit and its changes relative to its first parent, or the empty tree for a root.
/// Commit inspection is independent of the canonical PR comparison and cannot supply PR writes.
public struct PRCommitDetail:Sendable {
    public let sha:String
    public let message:String
    public let authorName:String?
    public let authorLogin:String?
    public let authoredAt:Date?
    public let committerName:String?
    public let committedAt:Date?
    public let parents:[String]
    public let webURL:URL?
    public let files:[DiffFile]
    public let nextPage:Int?
    public let complete:Bool
    /// Git's SHA-1 empty tree. Root files are additions and never request LEFT content.
    public static let emptyTreeSHA="4b825dc642cb6eb9a060e54bf8d69288fbee4904"
    public var document:DiffDocument {
        .init(baseSHA:parents.first ?? Self.emptyTreeSHA,headSHA:sha,files:files,expectedFiles:files.count+(complete ? 0 : 1),comparison:.snapshot)
    }
}

private struct CommitDetailPayload:Decodable {
    struct Person:Decodable { let name:String?;let date:String? }
    struct Login:Decodable { let login:String? }
    struct Commit:Decodable { let message:String;let author:Person?;let committer:Person? }
    struct Parent:Decodable { let sha:String }
    struct File:Decodable {
        let filename:String;let previous_filename:String?;let status:String;let patch:String?;let additions:Int;let deletions:Int;let sha:String?
        func value(root:Bool) -> DiffFile {
            .init(path:filename,previousPath:previous_filename,status:root ? .added : .init(rawValue:status) ?? .changed,patch:patch,additions:additions,deletions:deletions,sha:sha)
        }
    }
    let sha:String;let commit:Commit;let author:Login?;let parents:[Parent];let html_url:URL?;let files:[File]
}

extension GitHubPRDetailFetcher {
    public func commitDetail(repository:String,sha:String,token:String) async throws -> PRCommitDetail {
        try await commitDetailPage(repository:repository,sha:sha,page:1,token:token)
    }
    public func moreCommitDetail(repository:String,snapshot:PRCommitDetail,token:String) async throws -> PRCommitDetail {
        guard let page=snapshot.nextPage else { return snapshot }
        let next=try await commitDetailPage(repository:repository,sha:snapshot.sha,page:page,token:token)
        guard next.parents == snapshot.parents,next.message == snapshot.message else { throw PRDetailFailure.revisionChanged }
        let files=snapshot.files+next.files
        guard Set(files.map(\.path)).count == files.count,files.reduce(0,{ $0+($1.patch?.utf8.count ?? 0) }) <= 12_000_000 else { throw PRDetailFailure.oversized }
        return .init(sha:snapshot.sha,message:snapshot.message,authorName:snapshot.authorName,authorLogin:snapshot.authorLogin,authoredAt:snapshot.authoredAt,committerName:snapshot.committerName,committedAt:snapshot.committedAt,parents:snapshot.parents,webURL:snapshot.webURL,files:files,nextPage:next.nextPage,complete:next.complete)
    }
    private func commitDetailPage(repository:String,sha:String,page:Int,token:String) async throws -> PRCommitDetail {
        guard Self.immutableOID(sha),page > 0,page <= 30 else { throw PRDetailFailure.invalidPath }
        let parts=repository.split(separator:"/",omittingEmptySubsequences:false)
        guard parts.count == 2,parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) } }) else { throw PRDetailFailure.invalidPath }
        try Task.checkCancellation()
        let url=client.origin.appendingPathComponent("repos").appendingPathComponent(repository).appendingPathComponent("commits").appendingPathComponent(sha).appending(queryItems:[.init(name:"per_page",value:"100"),.init(name:"page",value:String(page))])
        let response=try await client.get(url,token:token)
        try Task.checkCancellation()
        guard response.status != 304,response.data.count <= 8_000_000 else { throw PRDetailFailure.oversized }
        let value=try JSONDecoder().decode(CommitDetailPayload.self,from:response.data)
        guard value.sha == sha else { throw PRDetailFailure.revisionChanged }
        guard value.parents.allSatisfy({ Self.immutableOID($0.sha) }),value.files.count <= 100,
              value.files.allSatisfy({ Self.validPath($0.filename) && ($0.previous_filename.map(Self.validPath) ?? true) }) else { throw PRDetailFailure.unavailable }
        let files=value.files.map { $0.value(root:value.parents.isEmpty) }
        guard Set(files.map(\.path)).count == files.count,files.reduce(0,{ $0+($1.patch?.utf8.count ?? 0) }) <= 12_000_000 else { throw PRDetailFailure.oversized }
        // Links are hints only. Construct every continuation at the trusted origin with the same OID.
        let hasMore=GitHubPagination.hasNext(response.header("Link"))
        // GitHub caps commit inventories at 3,000 files; a full final page cannot prove completeness.
        let complete = !hasMore && !(page == 30 && files.count == 100)
        let web=value.html_url.flatMap { url in url.scheme == "https" && url.host == "github.com" && url.user == nil && url.password == nil ? url : nil }
        return .init(sha:sha,message:value.commit.message,authorName:value.commit.author?.name,authorLogin:value.author?.login,authoredAt:value.commit.author?.date.flatMap(GitHubDate.parse),committerName:value.commit.committer?.name,committedAt:value.commit.committer?.date.flatMap(GitHubDate.parse),parents:value.parents.map(\.sha),webURL:web,files:files,nextPage:hasMore && page < 30 ? page+1 : nil,complete:complete)
    }
}

extension PRDetailService {
    public func commitDetail(_ pr:PullRequest,sha:String) async throws -> PRCommitDetail {
        try await read(pr) { ctx in try await ctx.fetcher.commitDetail(repository:ctx.metadata.repositoryName,sha:sha,token:ctx.token) }
    }
    public func moreCommitDetail(_ pr:PullRequest,snapshot:PRCommitDetail) async throws -> PRCommitDetail {
        try await read(pr) { ctx in try await ctx.fetcher.moreCommitDetail(repository:ctx.metadata.repositoryName,snapshot:snapshot,token:ctx.token) }
    }
}
