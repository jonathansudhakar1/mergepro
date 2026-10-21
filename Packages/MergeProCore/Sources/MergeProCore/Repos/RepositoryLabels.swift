import Foundation

/// A provider-confirmed repository label. `openPullRequests` is nil when the count was not read.
public struct RepositoryLabel:Codable,Hashable,Sendable,Identifiable {
    public let id:String
    public let name:String
    /// Six lowercase hex digits without `#`.
    public let color:String
    public let description:String?
    public let isDefault:Bool
    public let openPullRequests:Int?
    public init(id:String,name:String,color:String,description:String?,isDefault:Bool=false,openPullRequests:Int?=nil) { self.id=id;self.name=name;self.color=color;self.description=description;self.isDefault=isDefault;self.openPullRequests=openPullRequests }
    /// Six hex digits, optional leading `#`, returned lowercase without `#`; anything else is not a GitHub label color.
    public static func normalizedColor(_ value:String) -> String? {
        var text=value.trimmingCharacters(in:.whitespacesAndNewlines);if text.hasPrefix("#") { text.removeFirst() }
        guard text.count==6,text.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil };return text.lowercased()
    }
    /// GitHub label names: 1–50 characters after trimming, no line breaks or control characters.
    public static func validName(_ name:String) -> Bool {
        let trimmed=name.trimmingCharacters(in:.whitespacesAndNewlines)
        return (1...50).contains(trimmed.count) && !trimmed.contains(where:{ $0.isNewline || $0.asciiValue.map { $0<32 || $0==127 } == true })
    }
    /// Whether a chip with this fill draws dark text (see `chipText`).
    public static func prefersDarkText(hex:String) -> Bool { chipText(hex:hex)?.isDark ?? false }
    /// WCAG 2 relative luminance of a six-digit sRGB hex color.
    public static func relativeLuminance(hex:String) -> Double? {
        guard let color=normalizedColor(hex),let value=Int(color,radix:16) else { return nil }
        func channel(_ shift:Int) -> Double { linear(Double((value>>shift)&0xff)/255) }
        return 0.2126*channel(16)+0.7152*channel(8)+0.0722*channel(0)
    }
    private static func linear(_ c:Double) -> Double { c<=0.04045 ? c/12.92 : pow((c+0.055)/1.055,2.4) }
    /// The text a label chip draws: `gray` is the sRGB gray level (1 white, 0.08 the chip's soft dark, 0 black).
    public struct ChipText:Equatable,Sendable {
        public let gray:Double
        /// WCAG contrast ratio of this text on the label fill.
        public let contrast:Double
        public var isDark:Bool { gray<0.5 }
    }
    /// The chip's soft dark text level; pure black replaces it only when it falls short of the minimum.
    public static let chipDarkGray=0.08
    /// Text for a chip filled with `hex`, computed against the colours actually drawn. White or the soft dark gray
    /// (whichever contrasts more) when it reaches `minimumContrast`; otherwise the better of white and pure black,
    /// which always reaches at least 4.58:1. Use 7 for Increase Contrast. Nil for an invalid color.
    public static func chipText(hex:String,minimumContrast:Double=4.5) -> ChipText? {
        guard let fill=relativeLuminance(hex:hex) else { return nil }
        func text(_ gray:Double) -> ChipText {
            let level=linear(gray)
            return ChipText(gray:gray,contrast:(max(fill,level)+0.05)/(min(fill,level)+0.05))
        }
        let soft=[text(1),text(chipDarkGray)].filter { $0.contrast>=minimumContrast }.max { $0.contrast<$1.contrast }
        return soft ?? [text(1),text(0)].max { $0.contrast<$1.contrast }!
    }
}
public struct RepositoryLabelCatalog:Codable,Equatable,Sendable {
    public let repositoryNodeID:String
    public let labels:[RepositoryLabel]
    /// From viewerPermission (ADMIN, MAINTAIN, WRITE or TRIAGE); the provider stays the final authority.
    public let canManage:Bool
    /// False when the page/node bound stopped the read; absence of a name is then unknown.
    public let complete:Bool
    public let fetchedAt:Date
    public init(repositoryNodeID:String,labels:[RepositoryLabel],canManage:Bool,complete:Bool,fetchedAt:Date) { self.repositoryNodeID=repositoryNodeID;self.labels=labels;self.canManage=canManage;self.complete=complete;self.fetchedAt=fetchedAt }
    /// GitHub label names are unique case-insensitively.
    public func label(named name:String) -> RepositoryLabel? { let key=name.trimmingCharacters(in:.whitespacesAndNewlines).lowercased();return labels.first { $0.name.lowercased()==key } }
}
public enum RepositoryLabelMutation:Codable,Hashable,Sendable,Identifiable {
    case create(name:String,color:String,description:String?)
    case update(id:String,name:String,color:String,description:String?)
    case delete(id:String,name:String)
    public var id:String { switch self { case .create(let name,_,_):"create|"+name.lowercased();case .update(let id,_,_,_):"update|"+id;case .delete(let id,_):"delete|"+id } }
    public var name:String { switch self { case .create(let name,_,_),.update(_,let name,_,_),.delete(_,let name):name } }
    func identity(repository:RepositoryKey) -> String {
        switch self {
        case .create(let name,_,_):"label-create|"+repository.repositoryID+"|"+name.lowercased()
        case .update(let id,_,_,_):"label-update|"+repository.repositoryID+"|"+id
        case .delete(let id,_):"label-delete|"+repository.repositoryID+"|"+id
        }
    }
    /// Trimmed name/description, normalized color; empty description is absent.
    func normalized() throws -> RepositoryLabelMutation {
        func clean(_ name:String,_ color:String,_ description:String?) throws -> (String,String,String?) {
            let text=description?.trimmingCharacters(in:.whitespacesAndNewlines)
            guard RepositoryLabel.validName(name),let color=RepositoryLabel.normalizedColor(color),(text?.count ?? 0)<=100 else { throw RepositoryLabelFailure.invalidLabel }
            return (name.trimmingCharacters(in:.whitespacesAndNewlines),color,text?.isEmpty == false ? text : nil)
        }
        switch self {
        case .create(let name,let color,let description):let v=try clean(name,color,description);return .create(name:v.0,color:v.1,description:v.2)
        case .update(let id,let name,let color,let description):guard !id.isEmpty else { throw RepositoryLabelFailure.invalidLabel };let v=try clean(name,color,description);return .update(id:id,name:v.0,color:v.1,description:v.2)
        case .delete(let id,let name):guard !id.isEmpty else { throw RepositoryLabelFailure.invalidLabel };return .delete(id:id,name:name)
        }
    }
}
public enum RepositoryLabelFailure:Error,Equatable,Sendable,LocalizedError {
    case invalidLabel,existingLabel,missingLabel
    /// GitHub did not accept the GraphQL label mutation schema and the REST fallback could not be targeted
    /// (the label's current name is unknown or dot-only); nothing was applied. Offer "Edit on GitHub".
    case labelEditingUnavailable
    public var errorDescription:String? {
        switch self {
        case .invalidLabel:"Enter a label name of 1–50 characters, a 6-digit hex color and a description of at most 100 characters."
        case .existingLabel:"A label with this name already exists. Label names are not case-sensitive."
        case .missingLabel:"This label no longer exists on GitHub. Refresh the labels."
        case .labelEditingUnavailable:"GitHub does not allow editing labels from MergePro for this account. Edit the label on GitHub."
        }
    }
}

extension RepositoryBrowserService {
    private static let labelSegmentCharacters=CharacterSet(charactersIn:"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    /// A label name as ONE percent-encoded REST path segment. Only RFC 3986 unreserved ASCII stays literal, so
    /// `/`, space, `:`, `#`, `?`, `%`, `+` and non-ASCII are encoded. A dot-only name has no safe segment
    /// (a peer may normalize `%2E%2E` into another resource), so it is nil.
    static func labelPathSegment(_ name:String) -> String? {
        guard !name.isEmpty,!name.allSatisfy({ $0 == "." }) else { return nil }
        return name.addingPercentEncoding(withAllowedCharacters:labelSegmentCharacters)
    }
    static let labelPageLimit=30
    static let labelNodeLimit=3_000
    /// Bounded label catalog: 30 pages of 100 nodes. Identity is checked against the repository ID.
    static func fetchLabels(_ reader:GitHubRepoReader,repository:RepoCatalogEntry,token:String) async throws -> RepositoryLabelCatalog {
        let query="""
        query RepositoryLabels($owner:String!,$name:String!,$after:String) {
          repository(owner:$owner,name:$name) {
            id databaseId viewerPermission
            labels(first:100,after:$after,orderBy:{field:NAME,direction:ASC}) {
              nodes { id name color description isDefault pullRequests(states:[OPEN]) { totalCount } }
              pageInfo { hasNextPage endCursor }
            }
          }
        }
        """
        var labels:[RepositoryLabel]=[],after:String?=nil,nodeID="",permission:String?=nil,complete=false
        for _ in 0..<labelPageLimit {
            let response=try await reader.client.readQuery(query,variables:["owner":repository.owner,"name":repository.shortName,"after":after],token:token)
            let envelope=try reader.object(response)
            guard let node=(envelope["data"] as? [String:Any])?["repository"] as? [String:Any] else { throw GitHubFailure.resourceDenied }
            guard envelope["errors"] == nil,let id=node["id"] as? String,let connection=node["labels"] as? [String:Any],let nodes=connection["nodes"] as? [[String:Any]],let page=connection["pageInfo"] as? [String:Any] else { throw GitHubFailure.invalidResponse }
            guard (node["databaseId"] as? Int).map(String.init)==repository.key.repositoryID else { throw RepositoryBrowserFailure.permissionDenied }
            nodeID=id;permission=node["viewerPermission"] as? String
            for item in nodes {
                guard let id=item["id"] as? String,let name=item["name"] as? String,let color=item["color"] as? String else { throw GitHubFailure.invalidResponse }
                let description=(item["description"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                labels.append(RepositoryLabel(id:id,name:name,color:RepositoryLabel.normalizedColor(color) ?? color.lowercased(),description:description,isDefault:item["isDefault"] as? Bool ?? false,openPullRequests:(item["pullRequests"] as? [String:Any])?["totalCount"] as? Int))
            }
            guard page["hasNextPage"] as? Bool == true else { complete=true;break }
            guard let cursor=page["endCursor"] as? String,labels.count<labelNodeLimit else { break };after=cursor
        }
        return RepositoryLabelCatalog(repositoryNodeID:nodeID,labels:Array(labels.prefix(labelNodeLimit)),canManage:["ADMIN","MAINTAIN","WRITE","TRIAGE"].contains(permission ?? ""),complete:complete,fetchedAt:Date())
    }
    /// Fresh REST identity and label-management admission (triage or higher).
    static func requireLabelManagement(_ reader:GitHubRepoReader,repository:RepoCatalogEntry,token:String) async throws {
        let info=try reader.object(await reader.response(path:GitHubRepoReader.repositoryPath(repository.repository.name),token:token))
        let permissions=info["permissions"] as? [String:Any] ?? [:]
        guard (info["id"] as? Int).map(String.init)==repository.key.repositoryID,["admin","maintain","push","triage"].contains(where:{ permissions[$0] as? Bool == true }),info["archived"] as? Bool != true,info["disabled"] as? Bool != true else { throw RepositoryBrowserFailure.permissionDenied }
    }
    static func admit(_ mutation:RepositoryLabelMutation,in catalog:RepositoryLabelCatalog) throws {
        guard catalog.canManage else { throw RepositoryBrowserFailure.permissionDenied }
        switch mutation {
        case .create(let name,_,_):guard catalog.label(named:name) == nil else { throw RepositoryLabelFailure.existingLabel }
        case .update(let id,let name,_,_):
            if catalog.complete,!catalog.labels.contains(where:{ $0.id==id }) { throw RepositoryLabelFailure.missingLabel }
            if let other=catalog.label(named:name),other.id != id { throw RepositoryLabelFailure.existingLabel }
        case .delete(let id,_):if catalog.complete,!catalog.labels.contains(where:{ $0.id==id }) { throw RepositoryLabelFailure.missingLabel }
        }
    }
    /// A static schema rejection means label mutations are unavailable to this account/API version.
    static func labelPayload(_ response:GitHubResponse,field:String) throws -> [String:Any] {
        do { return try graphQLPayload(response,field:field) }
        catch let failure as GitHubGraphQLMutationFailure where failure.definitelyRejected && failure.types.allSatisfy({ schemaFailureCodes.contains($0) }) { throw RepositoryLabelFailure.labelEditingUnavailable }
    }
    static func graphLabel(_ value:Any?,openPullRequests:Int?) throws -> RepositoryLabel {
        guard let item=value as? [String:Any],let id=item["id"] as? String,let name=item["name"] as? String,let color=item["color"] as? String else { throw GitHubFailure.invalidResponse }
        return RepositoryLabel(id:id,name:name,color:RepositoryLabel.normalizedColor(color) ?? color.lowercased(),description:(item["description"] as? String).flatMap { $0.isEmpty ? nil : $0 },isDefault:item["isDefault"] as? Bool ?? item["default"] as? Bool ?? false,openPullRequests:openPullRequests)
    }

    /// REST receipts carry the GraphQL node ID as `node_id`; a brand-new label has no open PRs.
    /// An unparseable success receipt still means applied, so it yields nil rather than an error.
    static func restLabel(_ response:GitHubResponse) -> RepositoryLabel? {
        guard let item=try? JSONSerialization.jsonObject(with:response.data) as? [String:Any],let id=item["node_id"] as? String,let name=item["name"] as? String,let color=item["color"] as? String else { return nil }
        return RepositoryLabel(id:id,name:name,color:RepositoryLabel.normalizedColor(color) ?? color.lowercased(),description:(item["description"] as? String).flatMap { $0.isEmpty ? nil : $0 },isDefault:item["default"] as? Bool ?? false,openPullRequests:0)
    }
    public func labels(_ repository:RepoCatalogEntry) async throws -> RepositoryLabelCatalog {
        try await read(repository.key.account) { reader,ticket in
            let catalog=try await Self.fetchLabels(reader,repository:repository,token:ticket.credential.accessToken)
            try await self.cache(catalog,key:"labels|"+repository.key.repositoryID,ticket:ticket);return catalog
        }
    }
    public func cachedLabels(_ repository:RepoCatalogEntry) async throws -> RepositoryLabelCatalog? {
        try await read(repository.key.account) { _,ticket in try RepositoryBrowserPersistence(database:self.database).cached("labels|"+repository.key.repositoryID,account:ticket.account,as:RepositoryLabelCatalog.self) }
    }
    /// Create uses REST; update/delete use GraphQL node IDs first, so names like `area/ui` stay out of paths.
    /// Each preflight re-reads permission and the complete catalog; uncertain receipts are never resent.
    /// If GitHub DEFINITELY rejects the GraphQL label mutation schema (e.g. a preview header is required),
    /// nothing was applied and `mutate` recorded the identity as rejected; only then the SAME ledger identity
    /// retries over REST by the label's current, percent-encoded name. Any other GraphQL failure, including a
    /// lost or ambiguous response, never falls back, so a possibly applied write is never sent twice.
    public func apply(_ mutation:RepositoryLabelMutation,to repository:RepoCatalogEntry) async throws -> RepositoryLabel? {
        let mutation=try mutation.normalized()
        let identity=mutation.identity(repository:repository.key),intent=try JSONEncoder.stable.encode(mutation)
        let root=try GitHubRepoReader.repositoryPath(repository.repository.name),key="labels|"+repository.key.repositoryID
        let admitted:@Sendable (GitHubRepoReader,AccountOperation) async throws -> RepositoryLabelCatalog={ reader,ticket in
            try await Self.requireLabelManagement(reader,repository:repository,token:ticket.credential.accessToken)
            let catalog=try await Self.fetchLabels(reader,repository:repository,token:ticket.credential.accessToken)
            try await self.cache(catalog,key:key,ticket:ticket)
            try Self.admit(mutation,in:catalog);return catalog
        }
        let preflight:@Sendable (GitHubRepoReader,AccountOperation) async throws -> Void={ _ = try await admitted($0,$1) }
        /// REST fallback target: the label's current name from the catalog the rejected attempt just cached;
        /// its own preflight re-proves that this node still has that name before anything is sent.
        func restFallback(id:String,method:String,body:Data?,acceptedStatuses:Set<Int>=[],validate:(@Sendable (GitHubResponse) throws -> Void)?=nil) async throws -> GitHubResponse {
            guard let current=try await cachedLabels(repository)?.labels.first(where:{ $0.id==id })?.name,let segment=Self.labelPathSegment(current) else { throw RepositoryLabelFailure.labelEditingUnavailable }
            return try await mutate(account:repository.key.account,identity:identity,path:root+"/labels/"+segment,method:method,body:body,intent:intent,acceptedStatuses:acceptedStatuses,percentEncodedPath:true,validate:validate) { reader,ticket in
                guard try await admitted(reader,ticket).labels.first(where:{ $0.id==id })?.name==current else { throw RepositoryLabelFailure.missingLabel }
            }
        }
        let result:RepositoryLabel?
        switch mutation {
        case .create(let name,let color,let description):
            let body=try JSONSerialization.data(withJSONObject:["name":name,"color":color,"description":description ?? ""],options:.sortedKeys)
            let response=try await mutate(account:repository.key.account,identity:identity,path:root+"/labels",method:"POST",body:body,intent:intent,acceptedStatuses:[422],validate:{ response in
                // 422 is a provider validation refusal: nothing was created.
                if response.status == 422 { throw String(decoding:response.data,as:UTF8.self).contains("already_exists") ? RepositoryLabelFailure.existingLabel : RepositoryLabelFailure.invalidLabel }
            },preflight:preflight)
            result=Self.restLabel(response)
        case .update(let id,let name,let color,let description):
            let body=try Self.graphQLMutationBody("UpdateLabel",input:"UpdateLabelInput",field:"updateLabel",selection:"label { id name color description isDefault }",variables:["id":id,"name":name,"color":color,"description":description ?? ""])
            do {
                let response=try await mutate(account:repository.key.account,identity:identity,path:"graphql",method:"POST",body:body,intent:intent,validate:{ _ = try Self.graphLabel(Self.labelPayload($0,field:"updateLabel")["label"],openPullRequests:nil) },preflight:preflight)
                result=try Self.graphLabel(Self.labelPayload(response,field:"updateLabel")["label"],openPullRequests:nil)
            } catch RepositoryLabelFailure.labelEditingUnavailable {
                let rest=try JSONSerialization.data(withJSONObject:["new_name":name,"color":color,"description":description ?? ""],options:.sortedKeys)
                let response=try await restFallback(id:id,method:"PATCH",body:rest,acceptedStatuses:[422],validate:{ response in
                    // 422 is a provider validation refusal (e.g. the new name exists): nothing was changed.
                    if response.status == 422 { throw String(decoding:response.data,as:UTF8.self).contains("already_exists") ? RepositoryLabelFailure.existingLabel : RepositoryLabelFailure.invalidLabel }
                })
                // Like the GraphQL receipt, an updated label's open-PR count is not part of the receipt.
                result=Self.restLabel(response).map { RepositoryLabel(id:$0.id,name:$0.name,color:$0.color,description:$0.description,isDefault:$0.isDefault,openPullRequests:nil) }
            }
        case .delete(let id,_):
            let body=try Self.graphQLMutationBody("DeleteLabel",input:"DeleteLabelInput",field:"deleteLabel",selection:"clientMutationId",variables:["id":id])
            do { _ = try await mutate(account:repository.key.account,identity:identity,path:"graphql",method:"POST",body:body,intent:intent,validate:{ _ = try Self.labelPayload($0,field:"deleteLabel") },preflight:preflight) }
            catch RepositoryLabelFailure.labelEditingUnavailable { _ = try await restFallback(id:id,method:"DELETE",body:nil) }
            result=nil
        }
        await patchLabelCache(repository,mutation:mutation,label:result)
        return result
    }
    /// Applies a confirmed receipt to the cached catalog; a failure only leaves the cache stale.
    private func patchLabelCache(_ repository:RepoCatalogEntry,mutation:RepositoryLabelMutation,label:RepositoryLabel?) async {
        let key="labels|"+repository.key.repositoryID
        do { _ = try await read(repository.key.account) { _,ticket in
            guard let catalog=try RepositoryBrowserPersistence(database:self.database).cached(key,account:ticket.account,as:RepositoryLabelCatalog.self) else { return }
            var labels=catalog.labels
            switch mutation {
            case .create:if let label { labels.removeAll { $0.name.lowercased()==label.name.lowercased() };labels.append(label) }
            case .update(let id,_,_,_):if let label,let index=labels.firstIndex(where:{ $0.id==id }) { labels[index]=RepositoryLabel(id:label.id,name:label.name,color:label.color,description:label.description,isDefault:label.isDefault,openPullRequests:labels[index].openPullRequests) }
            case .delete(let id,_):labels.removeAll { $0.id==id }
            }
            labels.sort { $0.name.lowercased() < $1.name.lowercased() }
            try await self.cache(RepositoryLabelCatalog(repositoryNodeID:catalog.repositoryNodeID,labels:labels,canManage:catalog.canManage,complete:catalog.complete,fetchedAt:catalog.fetchedAt),key:key,ticket:ticket)
        } } catch { Log.storage.info("Repository label cache left stale after a confirmed change: \(Log.kind(error), privacy: .public)") }
    }
    public func pendingLabelMutations(_ repository:RepoCatalogEntry) async throws -> [RepositoryLabelMutation] {
        let live=inFlightWrites
        return try await read(repository.key.account) { _,ticket in
            try Self.ledgerRows(self.database,account:ticket.account,repositoryID:repository.key.repositoryID,excluding:live).compactMap { row in
                guard row.identity.hasPrefix("label-"),let mutation=try? JSONDecoder().decode(RepositoryLabelMutation.self,from:row.json),mutation.identity(repository:repository.key)==row.identity else { return nil };return mutation
            }
        }
    }
    /// A fresh catalog settles a pending write; it only reads and never resends. Outdated writes settle too
    /// (they never throw forever): with a COMPLETE catalog an update of a label that no longer exists is
    /// `.notApplied`, and a create whose name now exists is `.applied` whatever its color, because the name
    /// exists and the user's intent is satisfied. A create is matched first by its receipt's `node_id` when the
    /// ledger holds one. Absence in an incomplete catalog proves nothing and keeps the write pending.
    public func reconcileLabel(_ mutation:RepositoryLabelMutation,in repository:RepoCatalogEntry) async throws -> RepositoryBranchReconciliation {
        let mutation=try mutation.normalized()
        let identity=mutation.identity(repository:repository.key),intent=try JSONEncoder.stable.encode(mutation)
        guard !inFlightWrites.contains(identity) else { throw RepositoryBrowserFailure.unknownWriteOutcome }
        return try await read(repository.key.account) { reader,ticket in
            let catalog=try await Self.fetchLabels(reader,repository:repository,token:ticket.credential.accessToken)
            let result:RepositoryBranchReconciliation
            switch mutation {
            case .create(let name,_,_):
                // A provider receipt (REST `node_id`) proves the create applied, even if it was renamed or deleted since.
                let receipt=try Self.ledgerIntent(self.database,identity:identity,account:ticket.account).flatMap { try? JSONSerialization.jsonObject(with:$0) as? [String:Any] }?["node_id"] as? String
                if receipt != nil || catalog.label(named:name) != nil { result = .applied }
                else { guard catalog.complete else { throw RepositoryBrowserFailure.unknownWriteOutcome };result = .notApplied }
            case .update(let id,let name,let color,let description):
                // A complete catalog without this node: the label no longer exists, so the update cannot have stuck.
                guard let current=catalog.labels.first(where:{ $0.id==id }) else { guard catalog.complete else { throw RepositoryBrowserFailure.unknownWriteOutcome };result = .notApplied;break }
                result = current.name==name && current.color==color && (current.description ?? "")==(description ?? "") ? .applied : .notApplied
            case .delete(let id,_):
                if catalog.labels.contains(where:{ $0.id==id }) { result = .notApplied } else { guard catalog.complete else { throw RepositoryBrowserFailure.unknownWriteOutcome };result = .applied }
            }
            try await self.cache(catalog,key:"labels|"+repository.key.repositoryID,ticket:ticket)
            guard try await self.session.withCurrentOperation(ticket,body:{ db in try RepositoryBrowserPersistence(database:db).record(identity,account:ticket.account,state:result == .applied ? "applied" : "rejected",data:intent) }) else { throw CancellationError() }
            return result
        }
    }
}
