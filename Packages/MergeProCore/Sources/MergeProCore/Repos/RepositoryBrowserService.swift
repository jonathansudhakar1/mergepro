import Foundation
import GRDB

/// Account-scoped browser. Credential values never leave Core and every read result is fenced.
public actor RepositoryBrowserService: GitTreeProvider {
    let session:GitHubAccountSession
    let budget:RateBudget
    let database:DatabaseStore
    let clientID:String
    let activeAccount:@Sendable () async throws -> AccountScope?
    /// Ledger identities dispatching in this process; a `prepared` row here is live, not stranded.
    var inFlightWrites:Set<String>=[]
    /// Most pages any one list walk reads (100 items each): a provider that keeps advertising `next` can
    /// never hold a walk open forever. A capped walk is incomplete, never proof of absence.
    static let pageLimit=100
    public init(session:GitHubAccountSession,budget:RateBudget,database:DatabaseStore,clientID:String,activeAccount:@escaping @Sendable () async throws -> AccountScope?) {
        self.session=session;self.budget=budget;self.database=database;self.clientID=clientID;self.activeAccount=activeAccount
    }
    func persistence() throws -> RepositoryBrowserPersistence { try RepositoryBrowserPersistence(database:database) }
    func read<T:Sendable>(_ account:AccountScope,body:@Sendable (GitHubRepoReader,AccountOperation) async throws -> T) async throws -> T {
        guard account.host == "github.com" else { throw RepositoryBrowserFailure.permissionDenied }
        let ticket=try await session.authenticatedOperation(for:account,clientID:clientID)
        do {
            let result=try await body(GitHubRepoReader(client:await session.interactiveReadClient(account:account,budget:budget)),ticket)
            try Task.checkCancellation()
            guard try await session.withCurrentOperation(ticket,body:{ _ in }) else { throw CancellationError() };return result
        } catch { await session.featureFailed(error,operation:ticket);throw error }
    }
    func cache<T:Encodable & Sendable>(_ value:T,key:String,ticket:AccountOperation) async throws {
        guard try await session.withCurrentOperation(ticket,body:{ db in try RepositoryBrowserPersistence(database:db).cache(value,key:key,account:ticket.account) }) else { throw CancellationError() }
        // A palette source changed: that repository's palette rows are decoded again on the next read.
        if let separator=key.firstIndex(of:"|"),Self.paletteSources.contains(String(key[..<separator])) {
            paletteVersions[RepositoryKey(account:ticket.account,repositoryID:String(key[key.index(after:separator)...])),default:0] += 1
        }
    }
    public private(set) var catalogProblems:[AccountScope:String] = [:]
    public func cachedCatalog() async throws -> [RepoCatalogEntry] { try await cachedCatalogs().flatMap(\.entries) }
    /// Each available account's cached catalog with the session generation it was read under.
    private func cachedCatalogs() async throws -> [(generation:UUID,entries:[RepoCatalogEntry])] {
        let store=try persistence()
        var result:[(generation:UUID,entries:[RepoCatalogEntry])]=[]
        for account in try database.accounts() {
            do {
                let ticket=try await session.authenticatedOperation(for:account.scope,clientID:clientID)
                let cached=try store.cached("catalog",account:account.scope,as:[RepoCatalogEntry].self) ?? database.repositories(account:account.scope).map { RepoCatalogEntry(repository:$0,accountLogin:account.login) }
                let pins=try database.pins(account:account.scope)
                guard try await session.withCurrentOperation(ticket,body:{ _ in }) else { continue }
                result.append((ticket.generation,cached.map { item in var value=item;value.pinned=pins.contains(item.providerKey);return value }))
            } catch { catalogProblems[account.scope]=String(describing:error) }
        }
        return result
    }
    /// Cache keys (before `|`) whose contents feed the palette.
    private static let paletteSources:Set<String>=["branches","tags","releases","files"]
    /// Bumped by every palette-source cache write, per repository.
    private var paletteVersions:[RepositoryKey:Int]=[:]
    private struct PaletteRows { let version:Int;let generation:UUID;let pinned:Bool;let name:String;let rows:[RepoPaletteEntry] }
    /// Decoded palette rows per repository, valid for one cache version, account session and pin state.
    private var paletteRows:[RepositoryKey:PaletteRows]=[:]
    /// Palette-source decodes performed (each reads a repository's branch, tag, release and file caches).
    private(set) var paletteDecodes=0

    public func catalog() async throws -> [RepoCatalogEntry] {
        var result:[RepoCatalogEntry]=[]
        catalogProblems=[:]
        for account in try database.accounts() {
            do {
            let values=try await read(account.scope) { reader,ticket in
                var values:[RepoCatalogEntry]=[];var page=1
                let pins=try self.database.pins(account:account.scope)
                for _ in 0..<Self.pageLimit {
                    let response=try await reader.response(path:"user/repos",query:[URLQueryItem(name:"per_page",value:"100"),URLQueryItem(name:"page",value:String(page)),URLQueryItem(name:"affiliation",value:"owner,collaborator,organization_member")],token:ticket.credential.accessToken)
                    for item in try reader.objects(response) {
                        guard let id=item["id"] as? Int,let name=item["full_name"] as? String,let isPrivate=item["private"] as? Bool else { throw GitHubFailure.invalidResponse }
                        let repository=Repository(key:RepositoryKey(account:account.scope,repositoryID:String(id)),name:name,isPrivate:isPrivate,capabilities:[.readPullRequests,.readWorkflows])
                        let key=ProviderKey(host:account.scope.host,accountID:account.scope.accountID,repositoryID:String(id),objectID:"repository")
                        values.append(RepoCatalogEntry(repository:repository,accountLogin:account.login,pinned:pins.contains(key),defaultBranch:item["default_branch"] as? String ?? "main",language:item["language"] as? String,topics:item["topics"] as? [String] ?? [],archived:item["archived"] as? Bool ?? false,fork:item["fork"] as? Bool ?? false,stars:item["stargazers_count"] as? Int ?? 0,pushedAt:GitHubRepoReader.date(item["pushed_at"]),canPush:(item["permissions"] as? [String:Any])?["push"] as? Bool ?? false,ownerID:((item["owner"] as? [String:Any])?["id"] as? Int).map(String.init)))
                    }
                    guard let next=reader.next(response,page:page) else { break };page=next
                }
                let savedValues=values
                guard try await self.session.withCurrentOperation(ticket,body:{ db in
                    for value in savedValues { try db.saveRepository(value.repository) }
                    try RepositoryBrowserPersistence(database:db).cache(savedValues,key:"catalog",account:ticket.account)
                }) else { throw CancellationError() }
                return values
            }
            result += values
            } catch { catalogProblems[account.scope]=String(describing:error);result += (try? await cachedCatalog().filter { $0.key.account==account.scope }) ?? [] }
        }
        return result
    }
    /// One budgeted GraphQL read enriches a visible row with exact PR count and default checks.
    public func overview(_ repository:RepoCatalogEntry) async throws -> RepoCatalogEntry {
        try await read(repository.key.account) { reader,ticket in
            let query="""
            query RepositoryOverview($owner:String!,$name:String!) {
              repository(owner:$owner,name:$name) {
                pullRequests(states:OPEN) { totalCount }
                latestRelease { name tagName }
                defaultBranchRef { target { ... on Commit { statusCheckRollup { state } } } }
              }
            }
            """
            let response=try await reader.client.readQuery(query,variables:["owner":repository.owner,"name":repository.shortName],token:ticket.credential.accessToken)
            let envelope=try reader.object(response)
            guard envelope["errors"] == nil,let data=envelope["data"] as? [String:Any],let node=data["repository"] as? [String:Any],let pulls=node["pullRequests"] as? [String:Any],let count=pulls["totalCount"] as? Int else { throw GitHubFailure.invalidResponse }
            var value=repository;value.openPRs=count
            let release=node["latestRelease"] as? [String:Any];value.latestRelease=release?["name"] as? String ?? release?["tagName"] as? String
            let target=(node["defaultBranchRef"] as? [String:Any])?["target"] as? [String:Any]
            value.defaultCI=(target?["statusCheckRollup"] as? [String:Any])?["state"] as? String
            return value
        }
    }
    public func treeState() async throws -> RepoTreePersistence {
        let store=try persistence();var result=RepoTreePersistence()
        for account in try database.accounts() {
            guard let ticket=try? await session.authenticatedOperation(for:account.scope,clientID:clientID) else { continue }
            let state=try store.state(account.scope)
            guard try await session.withCurrentOperation(ticket,body:{ _ in }) else { continue }
            result.expanded.formUnion(state.expanded);if result.selection == nil { result.selection=state.selection };if result.scrollAnchor == nil { result.scrollAnchor=state.scrollAnchor }
        }
        return result
    }
    public func saveTreeState(_ state:RepoTreePersistence) async throws {
        for account in try database.accounts() {
            let ticket=try await session.authenticatedOperation(for:account.scope,clientID:clientID)
            var scoped=state;scoped.expanded=Set(state.expanded.filter { $0.accountID == account.scope.accountID && $0.host == account.scope.host || $0.group == "pins" })
            if scoped.selection?.accountID != account.scope.accountID { scoped.selection=nil };if scoped.scrollAnchor?.accountID != account.scope.accountID { scoped.scrollAnchor=nil }
            let saved=scoped
            guard try await session.withCurrentOperation(ticket,body:{ db in try RepositoryBrowserPersistence(database:db).saveState(saved,account:account.scope) }) else { throw CancellationError() }
        }
    }
    public func setPinned(_ repository:RepoCatalogEntry,pinned:Bool) async throws {
        let ticket=try await session.authenticatedOperation(for:repository.key.account,clientID:clientID)
        guard try await session.withCurrentOperation(ticket,body:{ db in try db.setPinned(repository.providerKey,pinned:pinned) }) else { throw CancellationError() }
    }
    public func resolve(repository:RepoCatalogEntry,ref:String) async throws -> ResolvedRepositoryRef {
        try await read(repository.key.account) { reader,ticket in try await reader.resolve(repository:repository.repository.name,ref:ref,token:ticket.credential.accessToken) }
    }
    public func children(repository:RepoCatalogEntry,ref:ResolvedRepositoryRef,treeSHA:String) async throws -> GitTreePage {
        let key="tree|\(repository.key.repositoryID)|\(ref.commitSHA)|\(treeSHA)"
        return try await read(repository.key.account) { reader,ticket in
            if let value=try RepositoryBrowserPersistence(database:self.database).cached(key,account:ticket.account,as:GitTreePage.self),!value.truncated { return value }
            let value=try await reader.tree(repository:repository.repository.name,sha:treeSHA,token:ticket.credential.accessToken)
            try await self.cache(value,key:key,ticket:ticket);return value
        }
    }
    public func blob(repository:RepoCatalogEntry,ref:ResolvedRepositoryRef,entry:GitTreeEntry) async throws -> Data {
        guard entry.kind == .file || entry.kind == .symlink else { throw RepositoryBrowserFailure.invalidPath }
        let key="blob|\(repository.key.repositoryID)|\(ref.commitSHA)|\(entry.sha)"
        return try await read(repository.key.account) { reader,ticket in
            if let value=try RepositoryBrowserPersistence(database:self.database).cached(key,account:ticket.account,as:Data.self) { return value }
            let value=try await reader.blob(repository:repository.repository.name,sha:entry.sha,token:ticket.credential.accessToken)
            try await self.cache(value,key:key,ticket:ticket);return value
        }
    }
    public func commits(repository:RepoCatalogEntry,ref:ResolvedRepositoryRef,path:String? = nil,author:String? = nil,page:Int = 1) async throws -> RepositoryPage<RepositoryCommit> {
        try await read(repository.key.account) { reader,ticket in try await reader.commits(repository:repository.repository.name,sha:ref.commitSHA,path:path,author:author,page:page,token:ticket.credential.accessToken) }
    }
    public func branches(repository:RepoCatalogEntry,page:Int = 1) async throws -> RepositoryPage<RepositoryBranch> {
        try await read(repository.key.account) { reader,ticket in
            let result=try await reader.branches(repository:repository.repository.name,page:page,token:ticket.credential.accessToken)
            if page==1 { try await self.cache(result.values,key:"branches|"+repository.key.repositoryID,ticket:ticket) };return result
        }
    }
    public func tags(repository:RepoCatalogEntry,page:Int = 1) async throws -> RepositoryPage<RepositoryTag> {
        try await read(repository.key.account) { reader,ticket in
            let result=try await reader.tags(repository:repository.repository.name,page:page,token:ticket.credential.accessToken)
            if page==1 { try await self.cache(result.values,key:"tags|"+repository.key.repositoryID,ticket:ticket) };return result
        }
    }
    public func releases(repository:RepoCatalogEntry,page:Int = 1) async throws -> RepositoryPage<RepositoryRelease> {
        try await read(repository.key.account) { reader,ticket in
            let result=try await reader.releases(repository:repository.repository.name,page:page,token:ticket.credential.accessToken)
            if page==1 { try await self.cache(result.values,key:"releases|"+repository.key.repositoryID,ticket:ticket) };return result
        }
    }
    public func compare(repository:RepoCatalogEntry,base:String,head:String,page:Int = 1) async throws -> RepositoryComparison {
        try await read(repository.key.account) { reader,ticket in try await reader.compare(repository:repository.repository.name,base:base,head:head,page:page,token:ticket.credential.accessToken) }
    }
    public func download(repository:RepoCatalogEntry,asset:RepositoryReleaseAsset,directory:URL) async throws -> URL {
        let data=try await read(repository.key.account) { reader,ticket in try await RepositoryAssetDownload.download(client:reader.client,repository:repository.repository.name,asset:asset,token:ticket.credential.accessToken) }
        try Task.checkCancellation();return try RepositoryAssetDownload.save(data,name:asset.name,directory:directory)
    }
    public static func permalink(repository:RepoCatalogEntry,ref:ResolvedRepositoryRef,path:String,line:Int? = nil,blame:Bool = false) -> URL {
        let base=repository.webURL.appendingPathComponent(blame ? "blame" : "blob").appendingPathComponent(ref.commitSHA).appendingPathComponent(path)
        guard let line,line>0 else { return base };var parts=URLComponents(url:base,resolvingAgainstBaseURL:false)!;parts.fragment="L\(line)";return parts.url!
    }
    /// Repository rows plus each repository's cached branches, tags, releases and (when pinned) files. A
    /// repository's cached sources are decoded again only after one of them was rewritten, its pin changed, or
    /// its account session changed; otherwise its previous rows are reused.
    public func paletteEntries() async throws -> [RepoPaletteEntry] {
        let store=try persistence();var result:[RepoPaletteEntry]=[],listed=Set<RepositoryKey>()
        for (generation,repositories) in try await cachedCatalogs() {
            for repository in repositories {
                let route=RepoNavigationRoute(repository:repository.key);listed.insert(repository.key)
                result.append(RepoPaletteEntry(title:repository.repository.name+" · "+repository.accountLogin,route:route,kind:"repository"))
                let version=paletteVersions[repository.key] ?? 0
                if let saved=paletteRows[repository.key],saved.version == version,saved.generation == generation,saved.pinned == repository.pinned,saved.name == repository.repository.name {
                    result += saved.rows;continue
                }
                paletteDecodes += 1
                var rows:[RepoPaletteEntry]=[]
                for branch in try store.cached("branches|"+repository.key.repositoryID,account:repository.key.account,as:[RepositoryBranch].self) ?? [] { rows.append(RepoPaletteEntry(title:repository.repository.name+" / "+branch.name,route:RepoNavigationRoute(repository:repository.key,ref:branch.name),kind:"branch")) }
                for tag in try store.cached("tags|"+repository.key.repositoryID,account:repository.key.account,as:[RepositoryTag].self) ?? [] { rows.append(RepoPaletteEntry(title:repository.repository.name+" / "+tag.name,route:RepoNavigationRoute(repository:repository.key,ref:tag.sha),kind:"tag")) }
                for release in try store.cached("releases|"+repository.key.repositoryID,account:repository.key.account,as:[RepositoryRelease].self) ?? [] { rows.append(RepoPaletteEntry(title:repository.repository.name+" / "+release.name,route:RepoNavigationRoute(repository:repository.key,ref:release.tag,section:"releases"),kind:"release")) }
                if repository.pinned { rows += try store.cached("files|"+repository.key.repositoryID,account:repository.key.account,as:[RepoPaletteEntryStorage].self)?.map { $0.entry(repository:repository.key) } ?? [] }
                paletteRows[repository.key]=PaletteRows(version:version,generation:generation,pinned:repository.pinned,name:repository.repository.name,rows:rows)
                result += rows
            }
        }
        // Rows of repositories no longer listed (removed or unavailable accounts) are never kept.
        paletteRows=paletteRows.filter { listed.contains($0.key) }
        return result
    }
    public func indexFiles(repository:RepoCatalogEntry,ref:ResolvedRepositoryRef,maxTrees:Int = 20) async throws {
        guard repository.pinned,maxTrees>0 else { return }
        var pending=[("",ref.treeSHA)],entries:[RepoPaletteEntryStorage]=[],visited=Set<String>();var count=0
        while !pending.isEmpty,count<min(maxTrees,100) {
            let (path,sha)=pending.removeFirst();guard visited.insert(sha+"|"+path).inserted else { continue };count+=1
            let page=try await children(repository:repository,ref:ref,treeSHA:sha)
            for item in page.entries {
                let full=path.isEmpty ? item.path : path+"/"+item.path
                if item.kind == .directory { pending.append((full,item.sha)) }
                else { entries.append(RepoPaletteEntryStorage(title:repository.repository.name+" / "+full,ref:ref.commitSHA,path:full)) }
            }
        }
        let indexed=entries
        _ = try await read(repository.key.account) { _,ticket in try await self.cache(indexed,key:"files|"+repository.key.repositoryID,ticket:ticket) }
    }
}
private struct RepoPaletteEntryStorage:Codable,Sendable {
    let title:String;let ref:String;let path:String
    func entry(repository:RepositoryKey) -> RepoPaletteEntry { RepoPaletteEntry(title:title,route:RepoNavigationRoute(repository:repository,ref:ref,path:path),kind:"file") }
}

extension RepositoryBrowserService {
    private func current(_ ticket:AccountOperation) async throws {
        guard try await activeAccount() == ticket.account,try await session.withCurrentWriteOperation(ticket,body:{ _ in }) else { throw RepositoryBrowserFailure.permissionDenied }
    }
    /// `intent` is the durable ledger payload (defaults to the body) so reconciliation can rebuild the
    /// captured command. `validate` inspects a provider receipt; a provider-proven rejection it throws
    /// is recorded as rejected, anything else after dispatch stays an explicit unknown.
    /// `percentEncodedPath` sends `path` verbatim (see `mutate(_:percentEncodedPath:…)`) instead of through
    /// `GitHubHTTPClient.mutate`, whose `appendingPathComponent` would encode `%` a second time.
    func mutate(account:AccountScope,identity:String,path:String,method:String,body:Data?,intent:Data?=nil,acceptedStatuses:Set<Int>=[],percentEncodedPath:Bool=false,validate:(@Sendable (GitHubResponse) throws -> Void)?=nil,preflight:@escaping @Sendable (GitHubRepoReader,AccountOperation) async throws -> Void) async throws -> GitHubResponse {
        guard try await activeAccount()==account else { throw RepositoryBrowserFailure.permissionDenied }
        guard !inFlightWrites.contains(identity) else { throw RepositoryBrowserFailure.unknownWriteOutcome }
        inFlightWrites.insert(identity);defer { inFlightWrites.remove(identity) }
        let ticket=try await session.authenticatedOperation(for:account,clientID:clientID)
        let store=try persistence(),ledger=intent ?? body ?? Data()
        if let state=try store.operationState(identity,account:account),["prepared","sending","unknown"].contains(state) { throw RepositoryBrowserFailure.unknownWriteOutcome }
        try await current(ticket)
        try store.record(identity,account:account,state:"prepared",data:ledger)
        do {
            let writer=await session.preflightWriteClient(account:account,budget:budget,current:{ try await self.current(ticket) },beforeSend:{ client in
                try await preflight(GitHubRepoReader(client:client),ticket)
                guard try await self.activeAccount()==account,try await self.session.withCurrentWriteOperation(ticket,body:{ db in
                    let store=try RepositoryBrowserPersistence(database:db)
                    // A locally released intent must never be dispatched afterwards.
                    guard try store.operationState(identity,account:account)=="prepared" else { throw RepositoryBrowserFailure.unknownWriteOutcome }
                    try store.record(identity,account:account,state:"sending",data:ledger)
                }) else { throw RepositoryBrowserFailure.permissionDenied }
            })
            let response=percentEncodedPath ? try await Self.mutate(writer,percentEncodedPath:path,method:method,body:body,token:ticket.credential.accessToken,acceptedStatuses:acceptedStatuses) : try await writer.mutate(path:path,method:method,body:body,token:ticket.credential.accessToken,acceptedStatuses:acceptedStatuses)
            try validate?(response)
            // A positive response belongs to captured intent even if the active account changes.
            try store.record(identity,account:account,state:"applied",data:response.data)
            return response
        } catch {
            await session.featureFailed(error,operation:ticket)
            if let auth=(error as? GitHubGraphQLMutationFailure)?.authenticationFailure { await session.featureFailed(auth,operation:ticket) }
            let dispatched=try store.operationState(identity,account:account)=="sending"
            let rejected=Self.definitelyRejected(error)
            try store.record(identity,account:account,state:dispatched && !rejected ? "unknown" : "rejected",data:ledger)
            if dispatched && !rejected { throw RepositoryBrowserFailure.unknownWriteOutcome };throw error
        }
    }
    /// The `GitHubHTTPClient.mutate` contract (no redirect or retry, same headers, origin and status rules) for a
    /// relative path whose segments are ALREADY percent-encoded, e.g. `repos/o/r/labels/area%2Fui`. The URL is
    /// built with `percentEncodedPath`, never `appendingPathComponent`. Only unreserved ASCII, `%` escapes and `/`
    /// are admitted, so a raw `?`/`#` cannot occur while `%3F` is fine; empty or (decoded) dot segments are refused.
    static func mutate(_ client:GitHubHTTPClient,percentEncodedPath path:String,method:String,body:Data?,token:String,acceptedStatuses:Set<Int>=[]) async throws -> GitHubResponse {
        func safe(_ segment:Substring) -> Bool { guard let decoded=segment.removingPercentEncoding else { return false };return !decoded.isEmpty && decoded != "." && decoded != ".." }
        guard !token.isEmpty,["POST","PATCH","PUT","DELETE"].contains(method),path.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-._~%/".contains($0)) }),path.split(separator:"/",omittingEmptySubsequences:false).allSatisfy(safe) else { throw GitHubFailure.unsafeURL }
        var components=URLComponents(url:client.origin,resolvingAgainstBaseURL:false)
        components?.percentEncodedPath=(client.origin.path.hasSuffix("/") ? client.origin.path : client.origin.path+"/")+path
        guard let url=components?.url,client.isSafeAPIURL(url) else { throw GitHubFailure.unsafeURL }
        var request=URLRequest(url:url);request.httpMethod=method;request.httpBody=body
        request.setValue("Bearer "+token,forHTTPHeaderField:"Authorization")
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.setValue("application/vnd.github+json",forHTTPHeaderField:"Accept")
        request.setValue(GitHubHTTPClient.apiVersion,forHTTPHeaderField:"X-GitHub-Api-Version")
        let response=try await client.transport.send(request)
        if let actual=response.responseURL { guard client.isSafeAPIURL(actual),actual == url else { throw GitHubFailure.unsafeURL } }
        if response.status == 401 { throw GitHubFailure.invalidAuthentication }
        // Even cancellation after dispatch must retain positively returned provider evidence.
        if !acceptedStatuses.contains(response.status) { try GitHubHTTPClient.validate(response,now:Date()) }
        return response
    }
    /// Only provider-proven refusals release a dispatched write; transport loss and 5xx stay unknown.
    static func definitelyRejected(_ error:any Error) -> Bool {
        switch error {
        case let failure as GitHubFailure:
            switch failure { case .invalidAuthentication,.scopeRequired,.organizationRestricted,.resourceDenied,.rateLimited:return true;default:return false }
        case let failure as GitHubGraphQLMutationFailure:return failure.definitelyRejected
        case is RepositoryLabelFailure:return true
        default:return false
        }
    }
    /// GraphQL mutation receipts return HTTP 200 with `errors`. Static schema failures never execute
    /// and allowlisted denials without data are rejections; any other error keeps effects uncertain.
    static func graphQLPayload(_ response:GitHubResponse,field:String) throws -> [String:Any] {
        guard response.data.count <= 8_000_000,let envelope=try JSONSerialization.jsonObject(with:response.data) as? [String:Any] else { throw GitHubFailure.invalidResponse }
        let data=envelope["data"] as? [String:Any]
        if let errors=envelope["errors"] as? [[String:Any]],!errors.isEmpty {
            let types=errors.map { ($0["type"] as? String) ?? (($0["extensions"] as? [String:Any])?["code"] as? String) ?? "UNKNOWN" }
            let noEffects=data == nil || data!.values.allSatisfy { $0 is NSNull }
            let known:Set<String>=["FORBIDDEN","UNAUTHORIZED","UNAUTHENTICATED","NOT_FOUND","UNPROCESSABLE","GRAPHQL_VALIDATION_FAILED","BAD_USER_INPUT"]
            throw GitHubGraphQLMutationFailure(response:response.data,types:types,messages:errors.map { $0["message"] as? String ?? "GraphQL mutation failed" },definitelyRejected:noEffects && types.allSatisfy { known.contains($0) || schemaFailureCodes.contains($0) })
        }
        guard let payload=data?[field] as? [String:Any] else { throw GitHubFailure.invalidResponse };return payload
    }
    /// GraphQL static-validation codes: the operation was never executed by the provider.
    static let schemaFailureCodes:Set<String>=["undefinedField","undefinedType","undefinedArgument","argumentNotAccepted","variableRequiresValidType","missingRequiredInputObjectAttribute","inputObjectFieldNotDefined"]
    static func graphQLMutationBody(_ operation:String,input:String,field:String,selection:String,variables:[String:Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject:["query":"mutation \(operation)($input:\(input)!) { \(field)(input:$input) { \(selection) } }","variables":["input":variables]],options:.sortedKeys)
    }
    static func requirePush(_ reader:GitHubRepoReader,name:String,expectedID:String,token:String) async throws {
        _ = try await pushInfo(reader,name:name,expectedID:expectedID,token:token)
    }
    /// Fresh repository identity and push admission; returns the provider repository object.
    static func pushInfo(_ reader:GitHubRepoReader,name:String,expectedID:String,token:String) async throws -> [String:Any] {
        let response=try await reader.response(path:GitHubRepoReader.repositoryPath(name),token:token)
        let info=try reader.object(response)
        guard (info["id"] as? Int).map(String.init) == expectedID,(info["permissions"] as? [String:Any])?["push"] as? Bool == true,info["archived"] as? Bool != true,info["disabled"] as? Bool != true else { throw RepositoryBrowserFailure.permissionDenied }
        return info
    }
    public func createBranch(repository:RepoCatalogEntry,name:String,from ref:ResolvedRepositoryRef) async throws {
        guard BranchService.validName(name),GitHubRepoReader.immutableSHA(ref.commitSHA) else { throw RepositoryBrowserFailure.invalidRef }
        let identity="branch-create|"+repository.key.repositoryID+"|"+name
        let data=try JSONSerialization.data(withJSONObject:["ref":"refs/heads/"+name,"sha":ref.commitSHA])
        _ = try await mutate(account:repository.key.account,identity:identity,path:GitHubRepoReader.repositoryPath(repository.repository.name)+"/git/refs",method:"POST",body:data) { reader,ticket in
            try await Self.requirePush(reader,name:repository.repository.name,expectedID:repository.key.repositoryID,token:ticket.credential.accessToken)
            // A courtesy check (GitHub refuses an existing ref anyway), so a capped walk just stops checking.
            var page=1
            for _ in 0..<Self.pageLimit {
                let branches=try await reader.branches(repository:repository.repository.name,page:page,token:ticket.credential.accessToken)
                guard !branches.values.contains(where:{ $0.name==name }) else { throw RepositoryBrowserFailure.existingBranch }
                guard let next=branches.nextPage else { break };page=next
            }
            _ = try await reader.resolve(repository:repository.repository.name,ref:ref.commitSHA,token:ticket.credential.accessToken)
        }
    }
    public func deleteBranch(repository:RepoCatalogEntry,branch:RepositoryBranch) async throws {
        try BranchService.validateDeletion(branch,defaultBranch:repository.defaultBranch)
        let identity="branch-delete|"+repository.key.repositoryID+"|"+branch.name+"|"+branch.sha
        _ = try await mutate(account:repository.key.account,identity:identity,path:GitHubRepoReader.repositoryPath(repository.repository.name)+"/git/refs/heads/"+branch.name,method:"DELETE",body:nil) { reader,ticket in
            try await Self.requirePush(reader,name:repository.repository.name,expectedID:repository.key.repositoryID,token:ticket.credential.accessToken)
            let info=try reader.object(await reader.response(path:GitHubRepoReader.repositoryPath(repository.repository.name),token:ticket.credential.accessToken))
            guard (info["id"] as? Int).map(String.init)==repository.key.repositoryID else { throw RepositoryBrowserFailure.permissionDenied }
            let response=try reader.object(await reader.response(path:GitHubRepoReader.repositoryPath(repository.repository.name)+"/branches/"+branch.name,token:ticket.credential.accessToken))
            guard let name=response["name"] as? String,let sha=(response["commit"] as? [String:Any])?["sha"] as? String,let protected=response["protected"] as? Bool,sha==branch.sha else { throw RepositoryBrowserFailure.invalidRef }
            try BranchService.validateDeletion(RepositoryBranch(name:name,sha:sha,protected:protected),defaultBranch:info["default_branch"] as? String ?? repository.defaultBranch)
            // GitHub closes open PRs whose head or base branch is deleted; unknown users refuse like known ones.
            let users=try await Self.openBranchUsers(reader,repository:repository,branch:name,excluding:0,token:ticket.credential.accessToken)
            guard users.isEmpty else { throw RepositoryPRActionFailure.branchInUse(pullRequests:users) }
        }
    }
    static func existing(_ command:CreatePRCommand,reader:GitHubRepoReader,token:String) async throws -> Data? {
        let response=try await reader.response(path:GitHubRepoReader.repositoryPath(command.repositoryName)+"/pulls",query:[URLQueryItem(name:"state",value:"open"),URLQueryItem(name:"head",value:command.qualifiedHead),URLQueryItem(name:"base",value:command.base),URLQueryItem(name:"per_page",value:"100")],token:token)
        let values=try reader.objects(response)
        guard let first=values.first else { return nil };return try JSONSerialization.data(withJSONObject:first)
    }
    func savePR(_ data:Data,command:CreatePRCommand,existing:Bool,ticket:AccountOperation) async throws -> CreatedRepositoryPR {
        guard let value=try JSONSerialization.jsonObject(with:data) as? [String:Any],let number=value["number"] as? Int,let id=value["node_id"] as? String,!id.isEmpty,let head=value["head"] as? [String:Any],let sha=head["sha"] as? String,let web=GitHubRepoReader.safeWebURL(value["html_url"]) else { throw GitHubFailure.invalidResponse }
        // The inventory's canonical object ID, so a created/linked PR and its later inventory row are one row.
        let key=ProviderKey(host:command.repository.host,accountID:command.repository.accountID,repositoryID:command.repository.repositoryID,objectID:"pull-request:"+id)
        var metadata=PRMetadata(number:number,webURL:web,repositoryName:command.repositoryName)
        metadata.headBranch=head["ref"] as? String ?? command.headBranch;metadata.baseBranch=command.base;metadata.baseRevision=(value["base"] as? [String:Any])?["sha"] as? String ?? "";metadata.headRepositoryID=((head["repo"] as? [String:Any])?["id"] as? Int).map(String.init)
        metadata.authorLogin=(value["user"] as? [String:Any])?["login"] as? String;metadata.authorID=(value["user"] as? [String:Any])?["node_id"] as? String;metadata.actorType=(value["user"] as? [String:Any])?["type"] as? String
        metadata.createdAt=GitHubRepoReader.date(value["created_at"]);metadata.updatedAt=GitHubRepoReader.date(value["updated_at"]);metadata.fetchedAt=Date();metadata.partial=true;metadata.mergedAt=GitHubRepoReader.date(value["merged_at"]);metadata.descriptionPreview=value["body"] as? String
        let state:PullRequest.State=metadata.mergedAt != nil ? .merged : value["state"] as? String == "closed" ? .closed : .open
        let pr=PullRequest(key:key,headRevision:RevisionID(sha),title:value["title"] as? String ?? command.title,state:state,isDraft:value["draft"] as? Bool ?? command.draft,metadata:metadata)
        guard try await session.withCurrentOperation(ticket,body:{ db in try db.savePullRequests([pr]) }) else { throw CancellationError() }
        return CreatedRepositoryPR(key:key,number:number,existing:existing)
    }
    /// An uncertain creation is reconciled by head/base; it is never blindly repeated.
    public func createPR(_ command:CreatePRCommand) async throws -> CreatedRepositoryPR {
        try command.validate()
        guard try await activeAccount()==command.repository.account else { throw RepositoryBrowserFailure.permissionDenied }
        let ticket=try await session.authenticatedOperation(for:command.repository.account,clientID:clientID)
        let reader=GitHubRepoReader(client:await session.interactiveReadClient(account:ticket.account,budget:budget))
        let identity="pr-create|"+command.repository.repositoryID+"|"+command.qualifiedHead+"|"+command.base
        do {
            let targetInfo=try reader.object(await reader.response(path:GitHubRepoReader.repositoryPath(command.repositoryName),token:ticket.credential.accessToken))
            guard (targetInfo["id"] as? Int).map(String.init)==command.repository.repositoryID else { throw RepositoryBrowserFailure.permissionDenied }
            var expectedHeadID=command.repository.repositoryID
            if let fork=command.headRepository {
                let forkInfo=try reader.object(await reader.response(path:GitHubRepoReader.repositoryPath(fork),token:ticket.credential.accessToken))
                guard let forkID=forkInfo["id"] as? Int,((forkInfo["source"] as? [String:Any])?["id"] as? Int).map(String.init)==command.repository.repositoryID || ((forkInfo["parent"] as? [String:Any])?["id"] as? Int).map(String.init)==command.repository.repositoryID else { throw RepositoryBrowserFailure.permissionDenied }
                expectedHeadID=String(forkID)
            }
            let capturedHeadID=expectedHeadID
            if let data=try await Self.existing(command,reader:reader,token:ticket.credential.accessToken) {
                try persistence().record(identity,account:ticket.account,state:"applied",data:data)
                return try await savePR(data,command:command,existing:true,ticket:ticket)
            }
            let body=try JSONSerialization.data(withJSONObject:["head":command.head,"base":command.base,"title":command.title,"body":command.body,"draft":command.draft,"head_repo":command.headRepository?.split(separator:"/").last.map(String.init) ?? command.repositoryName.split(separator:"/").last.map(String.init)!])
            let response=try await mutate(account:ticket.account,identity:identity,path:GitHubRepoReader.repositoryPath(command.repositoryName)+"/pulls",method:"POST",body:body) { reader,ticket in
                let target=try reader.object(await reader.response(path:GitHubRepoReader.repositoryPath(command.repositoryName),token:ticket.credential.accessToken))
                guard (target["id"] as? Int).map(String.init)==command.repository.repositoryID else { throw RepositoryBrowserFailure.permissionDenied }
                try await Self.requirePush(reader,name:command.headRepository ?? command.repositoryName,expectedID:capturedHeadID,token:ticket.credential.accessToken)
                _ = try await reader.resolve(repository:command.repositoryName,ref:command.base,token:ticket.credential.accessToken)
                _ = try await reader.resolve(repository:command.headRepository ?? command.repositoryName,ref:command.headBranch,token:ticket.credential.accessToken)
                guard try await Self.existing(command,reader:reader,token:ticket.credential.accessToken)==nil else { throw RepositoryBrowserFailure.unknownWriteOutcome }
            }
            let created=try await savePR(response.data,command:command,existing:false,ticket:ticket)
            guard !command.reviewers.isEmpty else { return created }
            do {
                let body=try JSONSerialization.data(withJSONObject:["reviewers":command.reviewers])
                _ = try await mutate(account:ticket.account,identity:identity+"|reviewers",path:GitHubRepoReader.repositoryPath(command.repositoryName)+"/pulls/\(created.number)/requested_reviewers",method:"POST",body:body) { reader,ticket in
                    _ = try await reader.response(path:GitHubRepoReader.repositoryPath(command.repositoryName)+"/pulls/\(created.number)",token:ticket.credential.accessToken)
                }
            } catch { return CreatedRepositoryPR(key:created.key,number:created.number,existing:false,reviewersPending:true) }
            return created
        } catch {
            await session.featureFailed(error,operation:ticket)
            let malformedReceipt=(error as? GitHubFailure) == .invalidResponse && (try? persistence().operationState(identity,account:ticket.account)) == "applied"
            if error as? RepositoryBrowserFailure == .unknownWriteOutcome || malformedReceipt {
                if malformedReceipt { try persistence().record(identity,account:ticket.account,state:"unknown",data:JSONEncoder.stable.encode(command)) }
                if let data=try await Self.existing(command,reader:reader,token:ticket.credential.accessToken) {
                    try persistence().record(identity,account:ticket.account,state:"applied",data:data)
                    return try await savePR(data,command:command,existing:true,ticket:ticket)
                }
                throw RepositoryBrowserFailure.unknownWriteOutcome
            }
            throw error
        }
    }
}

extension RepositoryBrowserService {
    public func commitChecks(repository:RepoCatalogEntry,sha:String) async throws -> String {
        guard GitHubRepoReader.immutableSHA(sha) else { throw RepositoryBrowserFailure.invalidRef }
        return try await read(repository.key.account) { reader,ticket in
            let query="""
            query RepositoryCommitChecks($owner:String!,$name:String!,$sha:String!) {
              repository(owner:$owner,name:$name) { object(expression:$sha) { ... on Commit { statusCheckRollup { state } } } }
            }
            """
            let response=try await reader.client.readQuery(query,variables:["owner":repository.owner,"name":repository.shortName,"sha":sha],token:ticket.credential.accessToken)
            let data=try reader.object(response)["data"] as? [String:Any]
            let object=(data?["repository"] as? [String:Any])?["object"] as? [String:Any]
            return (object?["statusCheckRollup"] as? [String:Any])?["state"] as? String ?? "No checks"
        }
    }
    public func commitDiff(repository:RepoCatalogEntry,sha:String) async throws -> [RepositoryChangedFile] {
        guard GitHubRepoReader.immutableSHA(sha) else { throw RepositoryBrowserFailure.invalidRef }
        return try await read(repository.key.account) { reader,ticket in
            let response=try await reader.response(path:GitHubRepoReader.repositoryPath(repository.repository.name)+"/commits/"+sha,token:ticket.credential.accessToken)
            let files=try reader.object(response)["files"] as? [[String:Any]] ?? []
            return try files.map { item in
                guard let path=item["filename"] as? String,let status=item["status"] as? String else { throw GitHubFailure.invalidResponse }
                return RepositoryChangedFile(path:path,status:status,additions:item["additions"] as? Int ?? 0,deletions:item["deletions"] as? Int ?? 0,patch:item["patch"] as? String)
            }
        }
    }
    public func linkedPRs(repository:RepoCatalogEntry,sha:String) async throws -> [CreatedRepositoryPR] {
        guard GitHubRepoReader.immutableSHA(sha) else { throw RepositoryBrowserFailure.invalidRef }
        return try await read(repository.key.account) { reader,ticket in
            let response=try await reader.response(path:GitHubRepoReader.repositoryPath(repository.repository.name)+"/commits/"+sha+"/pulls",token:ticket.credential.accessToken)
            var results:[CreatedRepositoryPR]=[]
            for item in try reader.objects(response) {
                let command=CreatePRCommand(repository:repository.providerKey,repositoryName:repository.repository.name,head:(item["head"] as? [String:Any])?["ref"] as? String ?? "",base:(item["base"] as? [String:Any])?["ref"] as? String ?? "",title:item["title"] as? String ?? "",body:"",draft:false,reviewers:[])
                results.append(try await self.savePR(JSONSerialization.data(withJSONObject:item),command:command,existing:true,ticket:ticket))
            }
            return results
        }
    }
}

extension RepositoryBrowserService {
    public func pendingBranchMutations(repository:RepoCatalogEntry) async throws -> [RepositoryBranchMutation] {
        let live=inFlightWrites
        return try await read(repository.key.account) { _,ticket in
            let rows=try Self.ledgerRows(self.database,account:ticket.account,repositoryID:repository.key.repositoryID,excluding:live)
            return rows.compactMap { row in
                let identity=row.identity
                let createPrefix="branch-create|"+repository.key.repositoryID+"|"
                let deletePrefix="branch-delete|"+repository.key.repositoryID+"|"
                if identity.hasPrefix(createPrefix) {
                    let data=row.json
                    guard let json=try? JSONSerialization.jsonObject(with:data) as? [String:Any],let sha=json["sha"] as? String else { return nil }
                    return .create(name:String(identity.dropFirst(createPrefix.count)),sha:sha)
                }
                if identity.hasPrefix(deletePrefix) {
                    let suffix=String(identity.dropFirst(deletePrefix.count));guard let separator=suffix.lastIndex(of:"|") else { return nil }
                    return .delete(name:String(suffix[..<separator]),sha:String(suffix[suffix.index(after:separator)...]))
                }
                return nil
            }
        }
    }
    /// A complete, fresh branch catalog proves application or non-application before a new confirmation.
    public func reconcileBranch(repository:RepoCatalogEntry,mutation:RepositoryBranchMutation) async throws -> RepositoryBranchReconciliation {
        guard !inFlightWrites.contains(mutation.identity(repository:repository.key)) else { throw RepositoryBrowserFailure.unknownWriteOutcome }
        return try await read(repository.key.account) { reader,ticket in
            try await Self.requirePush(reader,name:repository.repository.name,expectedID:repository.key.repositoryID,token:ticket.credential.accessToken)
            var values:[RepositoryBranch]=[],page=1,complete=false
            for _ in 0..<Self.pageLimit {
                let result=try await reader.branches(repository:repository.repository.name,page:page,token:ticket.credential.accessToken);values += result.values
                guard let next=result.nextPage else { complete=true;break };page=next
            }
            // Only a complete catalog proves application or non-application.
            guard complete else { throw RepositoryBrowserFailure.unknownWriteOutcome }
            let current=values.first { $0.name==mutation.name }
            let result:RepositoryBranchReconciliation
            switch mutation {
            case .create: if let current { guard current.sha==mutation.sha else { throw RepositoryBrowserFailure.existingBranch };result = .applied } else { result = .notApplied }
            case .delete: if let current { guard current.sha==mutation.sha else { throw RepositoryBrowserFailure.invalidRef };result = .notApplied } else { result = .applied }
            }
            guard try await self.session.withCurrentOperation(ticket,body:{ db in try RepositoryBrowserPersistence(database:db).record(mutation.identity(repository:repository.key),account:ticket.account,state:result == .applied ? "applied" : "rejected",data:Data()) }) else { throw CancellationError() }
            return result
        }
    }
}

/// An unresolved repository write. `prepared` was never dispatched (a crash or failure before the
/// durable `sending` marker) and can be released locally; `sending`/`unknown` need a provider read.
public struct RepositoryPendingWrite:Equatable,Sendable,Identifiable {
    public enum State:String,Sendable { case prepared,sending,unknown }
    public let identity:String
    public let state:State
    public var id:String { identity }
    public var unsent:Bool { state == .prepared }
    /// Ledger family such as `branch-create`, `label-update` or `pr-revert`.
    public var kind:String { identity.split(separator:"|",omittingEmptySubsequences:false).first.map(String.init) ?? "" }
    public init(identity:String,state:State) { self.identity=identity;self.state=state }
}
extension RepositoryBrowserService {
    struct LedgerRow:Sendable { let identity:String;let state:String;let json:Data }
    /// Unresolved rows whose identity is `kind|<repositoryID>|…`, minus writes live in this process.
    static func ledgerRows(_ database:DatabaseStore,account:AccountScope,repositoryID:String,excluding live:Set<String>) throws -> [LedgerRow] {
        try database.database.read { db in
            try Row.fetchAll(db,sql:"SELECT identity,state,json FROM repo_browser_operations WHERE account_host=? AND account_id=? AND state IN ('prepared','sending','unknown') ORDER BY identity",arguments:[account.host,account.accountID]).compactMap { row in
                let identity:String=row["identity"]
                let parts=identity.split(separator:"|",omittingEmptySubsequences:false)
                guard parts.count>=3,parts[1]==repositoryID,!live.contains(identity) else { return nil }
                return LedgerRow(identity:identity,state:row["state"],json:row["json"])
            }
        }
    }
    static func ledgerIntent(_ database:DatabaseStore,identity:String,account:AccountScope) throws -> Data? {
        try database.database.read { try Data.fetchOne($0,sql:"SELECT json FROM repo_browser_operations WHERE account_host=? AND account_id=? AND identity=?",arguments:[account.host,account.accountID,identity]) }
    }
    public func pendingWrites(repository:RepoCatalogEntry) async throws -> [RepositoryPendingWrite] {
        let live=inFlightWrites
        return try await read(repository.key.account) { _,ticket in
            try Self.ledgerRows(self.database,account:ticket.account,repositoryID:repository.key.repositoryID,excluding:live).compactMap { row in RepositoryPendingWrite.State(rawValue:row.state).map { RepositoryPendingWrite(identity:row.identity,state:$0) } }
        }
    }
    /// Mirrors the PR write ledger's `rejectUnsent`: only a never-dispatched intent is released.
    /// Its captured payload is retained; a later command is a new explicit user action.
    public func releaseUnsentWrite(repository:RepoCatalogEntry,identity:String) async throws {
        let parts=identity.split(separator:"|",omittingEmptySubsequences:false)
        guard parts.count>=3,parts[1]==Substring(repository.key.repositoryID) else { throw RepositoryBrowserFailure.permissionDenied }
        guard !inFlightWrites.contains(identity) else { throw RepositoryBrowserFailure.unknownWriteOutcome }
        let ticket=try await session.authenticatedOperation(for:repository.key.account,clientID:clientID)
        guard try await session.withCurrentOperation(ticket,body:{ db in
            let store=try RepositoryBrowserPersistence(database:db)
            guard try store.operationState(identity,account:ticket.account)=="prepared" else { throw RepositoryBrowserFailure.unknownWriteOutcome }
            try store.record(identity,account:ticket.account,state:"rejected",data:Self.ledgerIntent(db,identity:identity,account:ticket.account) ?? Data())
        }) else { throw CancellationError() }
    }
}

extension RepositoryBrowserService {
    public func codeState(repository:RepositoryKey) async throws -> RepoCodePersistence {
        try await read(repository.account) { _,_ in try RepositoryBrowserPersistence(database:self.database).codeState(repository) }
    }
    public func saveCodeState(_ state:RepoCodePersistence,repository:RepositoryKey) async throws {
        let ticket=try await session.authenticatedOperation(for:repository.account,clientID:clientID)
        guard try await session.withCurrentOperation(ticket,body:{ db in try RepositoryBrowserPersistence(database:db).saveCodeState(state,repository:repository) }) else { throw CancellationError() }
    }
}

extension RepositoryBrowserService {
    public func catalogOwners() async throws -> [RepoCatalogOwner] {
        var result:[RepoCatalogOwner]=[]
        for account in try database.accounts() {
            do {
                result += try await read(account.scope) { _,_ in
                    let organizations=try self.database.setting(.organizations,account:account.scope).flatMap { try? JSONDecoder().decode([GitHubOrganization].self,from:Data($0.utf8)) } ?? []
                    return [RepoCatalogOwner(account:account.scope,accountLogin:account.login,name:account.login,ownerID:account.scope.accountID)]+organizations.map { RepoCatalogOwner(account:account.scope,accountLogin:account.login,name:$0.login,ownerID:$0.id) }
                }
            } catch { catalogProblems[account.scope]=String(describing:error) }
        }
        return result
    }
}
