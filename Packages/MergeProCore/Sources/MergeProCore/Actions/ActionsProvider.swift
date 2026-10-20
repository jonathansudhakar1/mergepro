import Foundation

public protocol ActionsProvider: Sendable {
    func runs(repository:Repository) async throws -> [WorkflowRun]
    func run(repository:Repository,id:Int64,attempt:Int?) async throws -> WorkflowRun
    func workflows(repository:Repository) async throws -> [ActionsWorkflow]
    func jobs(run:WorkflowRun) async throws -> [ActionsJob]
    func artifacts(run:WorkflowRun) async throws -> [ActionsArtifact]
}
public struct ActionsPollResult:Sendable {
    public let runs:[WorkflowRun]
    /// Conditional validators to persist (run keys only, never bodies).
    public let responses:[PollResponseCache]
}
public struct GitHubActionsProvider: ActionsProvider {
    public let client:GitHubHTTPClient
    private let credential:GitHubCredential
    public init(client:GitHubHTTPClient,credential:GitHubCredential) { self.client=client;self.credential=credential }
    func base(_ repository:Repository) throws -> String {
        let parts=repository.name.split(separator:"/",omittingEmptySubsequences:false)
        guard repository.key.account.host == "github.com",parts.count == 2,parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("?") && !$0.contains("#") && !$0.contains("%") }) else { throw GitHubFailure.unsafeURL }
        return "repos/"+repository.name
    }
    func get(_ path:String,query:[URLQueryItem]=[]) async throws -> GitHubResponse {
        var components=URLComponents(url:client.origin.appendingPathComponent(path),resolvingAgainstBaseURL:false)!
        if !query.isEmpty { components.queryItems=query }
        return try await client.get(components.url!,token:credential.accessToken)
    }
    func object(_ path:String,query:[URLQueryItem]=[]) async throws -> [String:Any] {
        let data=try await get(path,query:query).data
        guard let value=try JSONSerialization.jsonObject(with:data) as? [String:Any] else { throw GitHubFailure.invalidResponse };return value
    }
    func pages(_ repository:Repository,_ suffix:String,key:String?=nil,query:[URLQueryItem]=[]) async throws -> [[String:Any]] {
        var components=URLComponents(url:client.origin.appendingPathComponent(try base(repository)+suffix),resolvingAgainstBaseURL:false)!
        components.queryItems=query + [.init(name:"per_page",value:"100")]
        var next:URL?=components.url;var visited:Set<URL>=[];var result:[[String:Any]]=[]
        while let url=next {
            try Task.checkCancellation();guard visited.insert(url).inserted,visited.count <= 200,client.isSafeAPIURL(url),GitHubHTTPClient.samePaginatedPath(url,as:components.url!,repositoryID:repository.key.repositoryID) else { throw GitHubFailure.unsafeURL }
            let response=try await client.get(url,token:credential.accessToken)
            let json=try JSONSerialization.jsonObject(with:response.data)
            let array=key.flatMap { (json as? [String:Any])?[$0] as? [[String:Any]] } ?? (key == nil ? json as? [[String:Any]] : nil)
            guard let array else { throw GitHubFailure.invalidResponse };result += array
            next=try GitHubPagination.next(response.header("Link"),client:client,requested:components.url!,repositoryID:repository.key.repositoryID)
        }
        return result
    }
    public func runs(repository:Repository) async throws -> [WorkflowRun] {
        try await pages(repository,"/actions/runs",key:"workflow_runs").map { try decodeRun($0,repository:repository) }
    }
    public func recentRuns(repository:Repository) async throws -> [WorkflowRun] {
        let object=try await object(base(repository)+"/actions/runs",query:[.init(name:"per_page",value:"100")])
        guard let values=object["workflow_runs"] as? [[String:Any]] else { throw GitHubFailure.invalidResponse }
        return try values.map { try decodeRun($0,repository:repository) }
    }
    /// Bounded status windows plus known active IDs avoid restarting unbounded history on every poll.
    public func pollRuns(repository:Repository,cached:[WorkflowRun],deadline:ContinuousClock.Instant) async throws -> [WorkflowRun] {
        try await pollRuns(repository:repository,cached:cached,deadline:deadline,validators:[:]).runs
    }
    /// Conditional poll: every list/run read revalidates its stored ETag/Last-Modified. A 304 (free against
    /// GitHub's primary limit) is rebuilt from the cached observations named by the stored run keys; if
    /// any is missing the read repeats unconditionally. Bodies are never stored, only run keys.
    /// The newest-runs list is read first: when it is unchanged, no run in it changed (status, attempt or a new
    /// run would change it), so the status windows and the listed active runs need no reads and a quiet
    /// repository costs one 304. Otherwise the poll fans out to the status windows (when older runs exist) and
    /// to cached active attempts.
    public func pollRuns(repository:Repository,cached:[WorkflowRun],deadline:ContinuousClock.Instant,validators:[String:PollResponseCache]) async throws -> ActionsPollResult {
        let base=try base(repository)+"/actions/runs"
        func hasHeadroom() -> Bool { ContinuousClock.now.duration(to:deadline) > .seconds(3) }
        let observed=Dictionary(cached.filter { $0.repository.key == repository.key }.map { ($0.key.objectID,$0) },uniquingKeysWith:{ a,b in a.updatedAt>b.updatedAt ? a:b })
        var responses:[PollResponseCache]=[]
        func read(_ path:String,query:[URLQueryItem]=[],single:Bool=false) async throws -> (runs:[WorkflowRun],unchanged:Bool) {
            var components=URLComponents(url:client.origin.appendingPathComponent(path),resolvingAgainstBaseURL:false)!
            if !query.isEmpty { components.queryItems=query }
            guard let url=components.url else { throw GitHubFailure.unsafeURL }
            let stored=validators[url.absoluteString]
            let reusable=stored.flatMap { entry -> [WorkflowRun]? in
                guard entry.etag != nil || entry.lastModified != nil,let keys=try? JSONDecoder().decode([String].self,from:entry.body) else { return nil }
                let runs=keys.compactMap { observed[$0] }
                return runs.count == keys.count ? runs : nil
            }
            let response=try await client.get(url,token:credential.accessToken,etag:reusable == nil ? nil : stored?.etag,lastModified:reusable == nil ? nil : stored?.lastModified)
            if response.status == 304 { guard let reusable else { throw GitHubFailure.invalidResponse };return (reusable,true) }
            guard let object=try JSONSerialization.jsonObject(with:response.data) as? [String:Any] else { throw GitHubFailure.invalidResponse }
            let values:[WorkflowRun]
            if single { values=[try decodeRun(object,repository:repository)] }
            else { guard let rows=object["workflow_runs"] as? [[String:Any]] else { throw GitHubFailure.invalidResponse };values=try rows.map { try decodeRun($0,repository:repository) } }
            if response.header("ETag") != nil || response.header("Last-Modified") != nil {
                responses.append(PollResponseCache(url:url,etag:response.header("ETag"),body:try JSONEncoder().encode(values.map(\.key.objectID)),lastModified:response.header("Last-Modified")))
            }
            return (values,false)
        }
        try Task.checkCancellation()
        let latest=try await read(base,query:[.init(name:"per_page",value:"100")])
        var values:[WorkflowRun]=latest.runs
        let listed=Set(latest.runs.map(\.runID))
        // A list shorter than a page already holds every run of the repository: no window can add an active run.
        if !latest.unchanged, latest.runs.count >= 100 {
            for status in ["in_progress","queued","waiting","pending","requested"] {
                guard hasHeadroom() else { break }
                try Task.checkCancellation()
                values += try await read(base,query:[.init(name:"status",value:status),.init(name:"per_page",value:"100")]).runs
            }
        }
        var known:Set<Int64>=Set(values.map(\.runID))
        // Old attempts that were active also need a final immutable-attempt observation after a rerun. An unchanged
        // list already shows the runs it holds; only active runs older than it are read individually then.
        for run in cached.filter({ $0.isActive && (!latest.unchanged || !listed.contains($0.runID)) }).sorted(by:{ $0.updatedAt<$1.updatedAt }).prefix(20) {
            guard hasHeadroom() else { break }
            guard run.runID>0,run.attempt>0 else { throw GitHubFailure.unsafeURL }
            let attempt:[WorkflowRun]
            do { attempt=try await read(base+"/\(run.runID)/attempts/\(run.attempt)",single:true).runs }
            catch GitHubFailure.resourceDenied {
                // Deleted since it was cached (404; the repository's run lists above were readable).
                // A terminal observation leaves the active set, so a dead run neither shows as running
                // forever nor costs a request every poll or starves live runs of this bound.
                values.append(Self.deleted(run));continue
            }
            guard attempt.count == 1,attempt[0].runID == run.runID,attempt[0].attempt == run.attempt else { throw GitHubFailure.invalidResponse }
            values += attempt
            if hasHeadroom(),known.insert(run.runID).inserted {
                let latest=try await read(base+"/\(run.runID)",single:true).runs
                guard latest.count == 1,latest[0].runID == run.runID else { throw GitHubFailure.invalidResponse }
                values += latest
            }
        }
        let runs=Dictionary(values.map { ($0.key,$0) },uniquingKeysWith:{ before,after in before.updatedAt>after.updatedAt ? before:after }).values.sorted { $0.createdAt>$1.createdAt }
        return ActionsPollResult(runs:runs,responses:responses)
    }
    /// Conclusion recorded for a cached run GitHub no longer returns.
    public static let deletedConclusion="deleted"
    static func deleted(_ run:WorkflowRun) -> WorkflowRun {
        .init(repository:run.repository,runID:run.runID,workflowID:run.workflowID,attempt:run.attempt,name:run.name,branch:run.branch,headSHA:run.headSHA,event:run.event,actor:run.actor,status:"completed",conclusion:deletedConclusion,createdAt:run.createdAt,updatedAt:max(Date(),run.updatedAt),startedAt:run.startedAt,webURL:run.webURL,pullRequestNumbers:run.pullRequestNumbers)
    }
    public func run(repository:Repository,id:Int64,attempt:Int?=nil) async throws -> WorkflowRun {
        guard id>0,attempt.map({ $0>0 }) ?? true else { throw GitHubFailure.unsafeURL }
        let path=try base(repository)+"/actions/runs/\(id)"+(attempt.map { "/attempts/\($0)" } ?? "")
        let value=try decodeRun(await object(path),repository:repository)
        guard value.runID==id,attempt.map({ value.attempt==$0 }) ?? true else { throw GitHubFailure.invalidResponse };return value
    }
    public func workflows(repository:Repository) async throws -> [ActionsWorkflow] {
        try await pages(repository,"/actions/workflows",key:"workflows").map { object in
            .init(id:try int(object,"id"),name:try string(object,"name"),path:try string(object,"path"),state:try string(object,"state"),webURL:webURL(object["html_url"]))
        }
    }
    public func dispatchCapabilities(repository:Repository,workflows:[ActionsWorkflow]) async throws -> [ActionsWorkflow] {
        let metadata=try await object(base(repository))
        guard let ref=metadata["default_branch"] as? String else { return workflows }
        let commit=try await object(base(repository)+"/commits/"+ref)
        let sha=try string(commit,"sha")
        var result:[ActionsWorkflow]=[]
        for workflow in workflows {
            let manual:Bool?
            do { _=try await schemaAtRevision(repository:repository,workflow:workflow,ref:ref,sha:sha);manual=true }
            catch ActionsFailure.noManualTrigger { manual=false }
            catch GitHubFailure.resourceDenied { manual=nil }
            result.append(.init(id:workflow.id,name:workflow.name,path:workflow.path,state:workflow.state,webURL:workflow.webURL,manualTrigger:manual))
        }
        return result
    }
    public func jobs(run:WorkflowRun) async throws -> [ActionsJob] {
        try await pages(run.repository,"/actions/runs/\(run.runID)/attempts/\(run.attempt)/jobs",key:"jobs").map { object in
            let steps=try (object["steps"] as? [[String:Any]] ?? []).map { step in ActionsStep(number:Int(try int(step,"number")),name:try string(step,"name"),status:try string(step,"status"),conclusion:step["conclusion"] as? String,startedAt:date(step["started_at"]),completedAt:date(step["completed_at"])) }
            let check=(object["check_run_url"] as? String).flatMap(URL.init(string:)).flatMap { client.isSafeAPIURL($0) ? Int64($0.lastPathComponent) : nil }
            return .init(id:try int(object,"id"),name:try string(object,"name"),status:try string(object,"status"),conclusion:object["conclusion"] as? String,startedAt:date(object["started_at"]),completedAt:date(object["completed_at"]),steps:steps,checkRunID:check,webURL:webURL(object["html_url"]))
        }
    }
    public func artifacts(run:WorkflowRun) async throws -> [ActionsArtifact] {
        try await pages(run.repository,"/actions/runs/\(run.runID)/artifacts",key:"artifacts").map {
            .init(id:try int($0,"id"),name:try string($0,"name"),size:($0["size_in_bytes"] as? NSNumber)?.int64Value ?? 0,expired:$0["expired"] as? Bool ?? true,expiresAt:date($0["expires_at"]))
        }
    }
    public func annotations(repository:Repository,job:ActionsJob) async throws -> [ActionsAnnotation] {
        guard let id=job.checkRunID else { return [] }
        return try await pages(repository,"/check-runs/\(id)/annotations").map { .init(path:try string($0,"path"),startLine:Int(try int($0,"start_line")),endLine:Int(try int($0,"end_line")),level:try string($0,"annotation_level"),message:try string($0,"message"),title:$0["title"] as? String) }
    }
    public func environments(repository:Repository) async throws -> [ActionsEnvironment] {
        try await pages(repository,"/environments",key:"environments").map { .init(id:try int($0,"id"),name:try string($0,"name"),canApprove:false,production:Self.productionName(try string($0,"name"))) }
    }
    public func pendingDeployments(run:WorkflowRun) async throws -> [ActionsEnvironment] {
        try await pages(run.repository,"/actions/runs/\(run.runID)/pending_deployments").map {
            guard let environment=$0["environment"] as? [String:Any] else { throw GitHubFailure.invalidResponse }
            let name=try string(environment,"name")
            return .init(id:try int(environment,"id"),name:name,canApprove:$0["current_user_can_approve"] as? Bool ?? false,production:Self.productionName(name))
        }
    }
    public func deployments(repository:Repository) async throws -> [ActionsDeployment] {
        let objects=try await pages(repository,"/deployments")
        var seen:Set<String>=[];var result:[ActionsDeployment]=[]
        for object in objects {
            let environment=try string(object,"environment")
            guard seen.insert(environment).inserted else { continue }
            let id=try int(object,"id")
            let statuses=try await pages(repository,"/deployments/\(id)/statuses")
            result.append(.init(id:id,environment:environment,ref:try string(object,"ref"),sha:try string(object,"sha"),production:object["production_environment"] as? Bool ?? false,state:statuses.first?["state"] as? String ?? "unknown",webURL:webURL(statuses.first?["environment_url"])))
        }
        return result
    }
    public func refs(repository:Repository) async throws -> [String] {
        let branches=try await pages(repository,"/branches").map { try string($0,"name") }
        let tags=try await pages(repository,"/tags").map { try string($0,"name") }
        return Array(Set(branches+tags)).sorted()
    }
    public func schema(repository:Repository,workflow:ActionsWorkflow,ref:String) async throws -> WorkflowInputSchema {
        guard !ref.isEmpty,workflow.path.hasPrefix(".github/workflows/"),!workflow.path.split(separator:"/").contains("..") else { throw GitHubFailure.unsafeURL }
        let commit=try await object(base(repository)+"/commits/"+ref)
        let sha=try string(commit,"sha")
        return try await schemaAtRevision(repository:repository,workflow:workflow,ref:ref,sha:sha)
    }
    private func schemaAtRevision(repository:Repository,workflow:ActionsWorkflow,ref:String,sha:String) async throws -> WorkflowInputSchema {
        guard workflow.path.hasPrefix(".github/workflows/"),!workflow.path.split(separator:"/").contains("..") else { throw GitHubFailure.unsafeURL }
        let file=try await object(base(repository)+"/contents/"+workflow.path,query:[.init(name:"ref",value:sha)])
        guard file["encoding"] as? String == "base64",let content=file["content"] as? String,let data=Data(base64Encoded:content,options:.ignoreUnknownCharacters),let yaml=String(data:data,encoding:.utf8) else { throw GitHubFailure.invalidResponse }
        return try .parse(yaml:yaml,workflowID:workflow.id,ref:ref,revision:sha)
    }
    public func canWrite(repository:Repository) async throws -> Bool {
        let info=try await object(base(repository));guard String(try int(info,"id"))==repository.key.repositoryID else { throw GitHubFailure.invalidResponse }
        let permissions=info["permissions"] as? [String:Bool] ?? [:]
        return permissions["push"] == true || permissions["admin"] == true || permissions["maintain"] == true
    }
    /// A download redirect is read exactly once with the authenticated budgeted API transport.
    /// Signed storage URLs are then read by an isolated, credential-free transport.
    func download(_ path:String,maxBytes:Int=256*1024*1024) async throws -> Data? {
        let url=client.origin.appendingPathComponent(path)
        guard client.isSafeAPIURL(url) else { throw GitHubFailure.unsafeURL }
        var request=URLRequest(url:url);request.setValue("Bearer "+credential.accessToken,forHTTPHeaderField:"Authorization");request.setValue(GitHubHTTPClient.apiVersion,forHTTPHeaderField:"X-GitHub-Api-Version")
        let response=try await client.transport.send(request)
        if let actual=response.responseURL,actual != url { throw GitHubFailure.unsafeURL }
        if [404,410].contains(response.status) { return nil }
        if response.status==200 { guard response.data.count <= maxBytes else { throw ActionsFailure.tooLarge };return response.data }
        if response.status != 302 { try GitHubHTTPClient.validate(response,now:Date());throw GitHubFailure.invalidResponse }
        guard let location=response.header("Location"),let signedURL=URL(string:location),Self.safeDownloadURL(signedURL) else { throw GitHubFailure.unsafeURL }
        let transport=URLSessionGitHubTransport()
        let raw=try await transport.send(URLRequest(url:signedURL))
        guard raw.responseURL==signedURL else { throw GitHubFailure.unsafeURL }
        if [403,404,410].contains(raw.status) { return nil }
        guard raw.status==200,raw.data.count<=maxBytes else { throw raw.data.count>maxBytes ? ActionsFailure.tooLarge:ActionsFailure.unavailable };return raw.data
    }
    public func log(repository:Repository,jobID:Int64) async throws -> ActionsLogAvailability {
        guard jobID>0 else { throw GitHubFailure.unsafeURL }
        guard let data=try await download(base(repository)+"/actions/jobs/\(jobID)/logs",maxBytes:32*1024*1024) else { return .unavailable }
        return .available(String(decoding:data,as:UTF8.self))
    }
    public func artifact(repository:Repository,artifact:ActionsArtifact) async throws -> Data {
        guard !artifact.expired,artifact.size<=256*1024*1024,artifact.expiresAt.map({ $0>Date() }) ?? true else { throw ActionsFailure.expiredArtifact }
        guard let data=try await download(base(repository)+"/actions/artifacts/\(artifact.id)/zip") else { throw ActionsFailure.expiredArtifact };return data
    }
    public static func safeDownloadURL(_ url:URL) -> Bool {
        guard url.scheme=="https",url.user==nil,url.password==nil,(url.port ?? 443)==443,let host=url.host?.lowercased() else { return false }
        return host.hasSuffix(".blob.core.windows.net") || host.hasSuffix(".githubusercontent.com") || host.hasSuffix(".s3.amazonaws.com")
    }
    public static func productionName(_ name:String) -> Bool { ["prod","production"].contains(name.lowercased()) || name.lowercased().hasPrefix("production-") }
    private func decodeRun(_ o:[String:Any],repository:Repository) throws -> WorkflowRun {
        if let scope=o["repository"] as? [String:Any],let id=scope["id"] as? NSNumber,String(id.int64Value) != repository.key.repositoryID { throw GitHubFailure.invalidResponse }
        guard let created=date(o["created_at"]),let updated=date(o["updated_at"]) else { throw GitHubFailure.invalidResponse }
        return .init(repository:repository,runID:try int(o,"id"),workflowID:try int(o,"workflow_id"),attempt:Int(o["run_attempt"] as? Int ?? 1),name:o["name"] as? String ?? "Workflow",branch:o["head_branch"] as? String ?? "",headSHA:try string(o,"head_sha"),event:try string(o,"event"),actor:(o["actor"] as? [String:Any])?["login"] as? String ?? "",status:try string(o,"status"),conclusion:o["conclusion"] as? String,createdAt:created,updatedAt:updated,startedAt:date(o["run_started_at"]),webURL:webURL(o["html_url"]),pullRequestNumbers:(o["pull_requests"] as? [[String:Any]] ?? []).compactMap { $0["number"] as? Int })
    }
    private func int(_ object:[String:Any],_ key:String) throws -> Int64 { guard let n=object[key] as? NSNumber,n.int64Value>0 else { throw GitHubFailure.invalidResponse };return n.int64Value }
    private func string(_ object:[String:Any],_ key:String) throws -> String { guard let s=object[key] as? String else { throw GitHubFailure.invalidResponse };return s }
    /// Step timestamps can carry fractional seconds ("…:40.000-07:00"); `GitHubDate` accepts both forms.
    private func date(_ value:Any?) -> Date? {
        guard let s=value as? String else { return nil }
        return GitHubDate.parse(s)
    }
    private func webURL(_ value:Any?) -> URL? { guard let s=value as? String,let u=URL(string:s),u.scheme=="https",u.host=="github.com",u.user==nil,u.password==nil else { return nil };return u }
}
