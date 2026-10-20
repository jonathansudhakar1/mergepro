import Foundation

public struct GitHubRepoReader: Sendable {
    public let client:GitHubHTTPClient
    public init(client:GitHubHTTPClient) { self.client=client }
    static func repositoryPath(_ name:String) throws -> String {
        let components=name.split(separator:"/",omittingEmptySubsequences:false)
        guard components.count==2,components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) } }) else { throw RepositoryBrowserFailure.invalidPath }
        return "repos/"+name
    }
    public static func immutableSHA(_ sha:String) -> Bool { [40,64].contains(sha.count) && sha.allSatisfy { $0.isHexDigit } }
    /// Browse/compare ref expressions: branch, tag, SHA, `owner:branch` or `main~1`. It accepts every
    /// `BranchService.validName` name. URL construction percent-encodes path characters, so `#` and `%`
    /// stay literal (`%23`, `%25`); traversal, query, control and empty/dot path segments are refused.
    static func refComponent(_ name:String) throws -> String {
        guard !name.isEmpty,!name.contains(".."),!name.contains("?"),!name.contains("\\"),!name.contains(where:{ $0.isWhitespace || $0.isNewline || $0.asciiValue.map { $0<32 || $0==127 } == true }),
              name.split(separator:"/",omittingEmptySubsequences:false).allSatisfy({ !$0.isEmpty && $0 != "." }) else { throw RepositoryBrowserFailure.invalidRef }
        return name
    }
    func response(path:String,query:[URLQueryItem] = [],token:String) async throws -> GitHubResponse {
        var components=URLComponents(url:client.origin.appendingPathComponent(path),resolvingAgainstBaseURL:false)!
        components.queryItems=query.isEmpty ? nil : query
        // URLComponents leaves '+' literal, which GitHub decodes as a space (paths like c++/, emails, branch names).
        components.percentEncodedQuery=components.percentEncodedQuery?.replacingOccurrences(of:"+",with:"%2B")
        guard let url=components.url else { throw RepositoryBrowserFailure.invalidPath }
        let response=try await client.get(url,token:token)
        guard response.data.count <= 16_000_000 else { throw GitHubFailure.invalidResponse };return response
    }
    func object(_ response:GitHubResponse) throws -> [String:Any] {
        guard let value=try JSONSerialization.jsonObject(with:response.data) as? [String:Any] else { throw GitHubFailure.invalidResponse };return value
    }
    func objects(_ response:GitHubResponse) throws -> [[String:Any]] {
        guard let value=try JSONSerialization.jsonObject(with:response.data) as? [[String:Any]] else { throw GitHubFailure.invalidResponse };return value
    }
    static func date(_ text:Any?) -> Date? { guard let text=text as? String else { return nil };return GitHubDate.parse(text) }
    static func safeWebURL(_ value:Any?) -> URL? {
        guard let text=value as? String,let url=URL(string:text),url.scheme == "https",url.host == "github.com",url.user == nil,url.password == nil else { return nil };return url
    }
    func next(_ response:GitHubResponse,page:Int) -> Int? { GitHubPagination.hasNext(response.header("Link")) ? page+1 : nil }
    public func resolve(repository:String,ref:String,token:String) async throws -> ResolvedRepositoryRef {
        let json=try object(await response(path:Self.repositoryPath(repository)+"/commits/"+Self.refComponent(ref),token:token))
        guard let sha=json["sha"] as? String,let commit=json["commit"] as? [String:Any],let tree=commit["tree"] as? [String:Any],let treeSHA=tree["sha"] as? String,Self.immutableSHA(sha),Self.immutableSHA(treeSHA) else { throw GitHubFailure.invalidResponse }
        return ResolvedRepositoryRef(name:ref,commitSHA:sha,treeSHA:treeSHA)
    }
    public func tree(repository:String,sha:String,token:String) async throws -> GitTreePage {
        guard Self.immutableSHA(sha) else { throw RepositoryBrowserFailure.invalidRef }
        let json=try object(await response(path:Self.repositoryPath(repository)+"/git/trees/"+sha,token:token))
        guard let entries=json["tree"] as? [[String:Any]],let truncated=json["truncated"] as? Bool else { throw GitHubFailure.invalidResponse }
        let values=try entries.map { item -> GitTreeEntry in
            guard let path=item["path"] as? String,Self.validFilePath(path),!path.contains("/"),let mode=item["mode"] as? String,let type=item["type"] as? String,let sha=item["sha"] as? String else { throw GitHubFailure.invalidResponse }
            return GitTreeEntry(path:path,mode:mode,type:type,sha:sha,size:item["size"] as? Int)
        }
        return GitTreePage(entries:values,truncated:truncated)
    }
    public static func validFilePath(_ path:String) -> Bool { !path.isEmpty && !path.hasPrefix("/") && !path.contains("\0") && path.split(separator:"/",omittingEmptySubsequences:false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." } }
    public func blob(repository:String,sha:String,token:String) async throws -> Data {
        guard Self.immutableSHA(sha) else { throw RepositoryBrowserFailure.invalidRef }
        let json=try object(await response(path:Self.repositoryPath(repository)+"/git/blobs/"+sha,token:token))
        guard json["encoding"] as? String == "base64",let content=json["content"] as? String,let data=Data(base64Encoded:content,options:.ignoreUnknownCharacters),data.count<=8_000_000 else { throw GitHubFailure.invalidResponse };return data
    }
    static func commit(_ item:[String:Any]) throws -> RepositoryCommit {
        guard let sha=item["sha"] as? String,let c=item["commit"] as? [String:Any],let message=c["message"] as? String else { throw GitHubFailure.invalidResponse }
        let author=c["author"] as? [String:Any] ?? [:]
        return RepositoryCommit(sha:sha,message:message,author:(item["author"] as? [String:Any])?["login"] as? String ?? author["name"] as? String ?? "Unknown",date:date(author["date"]),webURL:safeWebURL(item["html_url"]))
    }
    public func commits(repository:String,sha:String,path:String? = nil,author:String? = nil,page:Int = 1,token:String) async throws -> RepositoryPage<RepositoryCommit> {
        guard Self.immutableSHA(sha),page>0,path == nil || Self.validFilePath(path!) else { throw RepositoryBrowserFailure.invalidPath }
        var query=[URLQueryItem(name:"sha",value:sha),URLQueryItem(name:"per_page",value:"100"),URLQueryItem(name:"page",value:String(page))]
        if let path,!path.isEmpty { query.append(URLQueryItem(name:"path",value:path)) };if let author,!author.isEmpty { query.append(URLQueryItem(name:"author",value:author)) }
        let response=try await response(path:Self.repositoryPath(repository)+"/commits",query:query,token:token)
        return RepositoryPage(values:try objects(response).map(Self.commit),nextPage:next(response,page:page))
    }
    public func branches(repository:String,page:Int = 1,token:String) async throws -> RepositoryPage<RepositoryBranch> {
        let response=try await response(path:Self.repositoryPath(repository)+"/branches",query:[URLQueryItem(name:"per_page",value:"100"),URLQueryItem(name:"page",value:String(page))],token:token)
        let values=try objects(response).map { item -> RepositoryBranch in
            guard let name=item["name"] as? String,let commit=item["commit"] as? [String:Any],let sha=commit["sha"] as? String,let protected=item["protected"] as? Bool else { throw GitHubFailure.invalidResponse }
            return RepositoryBranch(name:name,sha:sha,protected:protected)
        }
        return RepositoryPage(values:values,nextPage:next(response,page:page))
    }
    public func tags(repository:String,page:Int = 1,token:String) async throws -> RepositoryPage<RepositoryTag> {
        let response=try await response(path:Self.repositoryPath(repository)+"/tags",query:[URLQueryItem(name:"per_page",value:"100"),URLQueryItem(name:"page",value:String(page))],token:token)
        return RepositoryPage(values:try objects(response).map { item in
            guard let name=item["name"] as? String,let commit=item["commit"] as? [String:Any],let sha=commit["sha"] as? String else { throw GitHubFailure.invalidResponse };return RepositoryTag(name:name,sha:sha)
        },nextPage:next(response,page:page))
    }
    public func releases(repository:String,page:Int = 1,token:String) async throws -> RepositoryPage<RepositoryRelease> {
        let response=try await response(path:Self.repositoryPath(repository)+"/releases",query:[URLQueryItem(name:"per_page",value:"100"),URLQueryItem(name:"page",value:String(page))],token:token)
        return RepositoryPage(values:try objects(response).map { item in
            guard let id=item["id"] as? Int,let tag=item["tag_name"] as? String else { throw GitHubFailure.invalidResponse }
            let assets=try (item["assets"] as? [[String:Any]] ?? []).map { asset -> RepositoryReleaseAsset in
                guard let id=asset["id"] as? Int,let name=asset["name"] as? String,let size=asset["size"] as? Int else { throw GitHubFailure.invalidResponse }
                return RepositoryReleaseAsset(id:id,name:name,size:size,downloadURL:Self.safeWebURL(asset["browser_download_url"]))
            }
            return RepositoryRelease(id:id,name:item["name"] as? String ?? tag,tag:tag,body:item["body"] as? String ?? "",draft:item["draft"] as? Bool ?? false,prerelease:item["prerelease"] as? Bool ?? false,publishedAt:Self.date(item["published_at"]),webURL:Self.safeWebURL(item["html_url"]),assets:assets)
        },nextPage:next(response,page:page))
    }
    public func compare(repository:String,base:String,head:String,page:Int = 1,token:String) async throws -> RepositoryComparison {
        let path=try Self.repositoryPath(repository)+"/compare/"+Self.refComponent(base)+"..."+Self.refComponent(head)
        let response=try await response(path:path,query:[URLQueryItem(name:"per_page",value:"100"),URLQueryItem(name:"page",value:String(page))],token:token)
        let json=try object(response)
        guard let status=json["status"] as? String,let ahead=json["ahead_by"] as? Int,let behind=json["behind_by"] as? Int else { throw RepositoryBrowserFailure.missingRefs }
        let files=try (json["files"] as? [[String:Any]] ?? []).map { item -> RepositoryChangedFile in
            guard let path=item["filename"] as? String,let status=item["status"] as? String else { throw GitHubFailure.invalidResponse }
            return RepositoryChangedFile(path:path,status:status,additions:item["additions"] as? Int ?? 0,deletions:item["deletions"] as? Int ?? 0,patch:item["patch"] as? String)
        }
        let commits=try (json["commits"] as? [[String:Any]] ?? []).map(Self.commit)
        return RepositoryComparison(status:status,ahead:ahead,behind:behind,commits:commits,files:files,webURL:Self.safeWebURL(json["html_url"]),incomplete:next(response,page:page) != nil || files.count>=300 || (json["total_commits"] as? Int ?? commits.count)>commits.count)
    }
}
