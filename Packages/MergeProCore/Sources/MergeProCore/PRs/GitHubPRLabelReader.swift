import Foundation

/// ONE identity-checked GraphQL read for revision-independent intents. It applies the full
/// reader's viewer/PR/number/repository identity checks but never fetches detail, files,
/// threads, comments or rules. Incomplete connections never prove presence or absence.
struct GitHubPRLightQuery {
    let client:GitHubHTTPClient
    let credential:GitHubCredential
    typealias Payload=PRWriteReadPayload
    struct Result { let viewer:Payload.Viewer;let pr:Payload.PullRequestNode;let repository:Payload.Repository;let review:Payload.Review? }
    /// A first-page connection is complete only when the provider returned pageInfo without a next page.
    static func complete<Node>(_ connection:Payload.Connection<Node>?,backward:Bool=false) -> Bool { connection?.complete(backward:backward) == true }
    /// Delta confirmation: every added ID present and every removed ID absent.
    static func applied(add:[String],remove:[String],current:[String]) -> Bool { Set(add).isSubset(of:current) && Set(remove).isDisjoint(with:current) }
    static func users(_ connection:Payload.Connection<Payload.Actor>?) -> [PRUserRef] { (connection?.values ?? []).compactMap { node in node.id.flatMap { id in node.login.map { PRUserRef(id:id,login:$0) } } } }
    static func labels(_ connection:Payload.Connection<Payload.Label>?) -> (refs:[PRLabelRef],colors:[String:String]) {
        let nodes=connection?.values ?? []
        return (nodes.compactMap { node in node.id.flatMap { id in node.name.map { PRLabelRef(id:id,name:$0) } } },Dictionary(nodes.compactMap { node in node.name.flatMap { name in node.color.map { (name,$0) } } },uniquingKeysWith:{ first,_ in first }))
    }
    static func query(_ name:String,declarations:String,pullRequest selection:String,repositorySelection:String,extra:String) -> String {
        """
        query PRWriteLight\(name)(\(declarations)) {
          viewer { id databaseId login }
          node(id:$id) { ... on PullRequest {
            id number state headRefOid baseRefOid viewerDidAuthor
            repository { databaseId nameWithOwner viewerPermission \(repositorySelection) }
            \(selection)
          } }
          \(extra)
          rateLimit { cost remaining resetAt }
        }
        """
    }
    func run(_ name:String,key:ProviderKey,repository:String,number:Int,pullRequest selection:String,repositorySelection:String="",extra:String="",variables:[String:String]=[:]) async throws -> Result {
        try GitHubPRWriteAdapter.validateTarget(key:key,repository:repository,number:number)
        let node=PRWriteCommand.gitHubNodeID(for:key)
        let declarations=(["$id:ID!"]+variables.keys.sorted().map { "$\($0):ID!" }).joined(separator:",")
        let query=Self.query(name,declarations:declarations,pullRequest:selection,repositorySelection:repositorySelection,extra:extra)
        var values:[String:String?]=variables.mapValues { $0 };values["id"]=node
        let response=try await client.readQuery(query,variables:values,token:credential.accessToken)
        let data=try GitHubGraphQLResponse.data(Payload.QueryData.self,from:response)
        guard let viewer=data.viewer,let pr=data.node,let repo=pr.repository,
              viewer.databaseId?.text == key.accountID,viewer.login != nil,
              pr.id == node,pr.number == number,pr.headRefOid != nil,pr.baseRefOid != nil,
              repo.databaseId?.text == key.repositoryID,
              repo.nameWithOwner?.lowercased() == repository.lowercased() else { throw PRWriteFailure.accountChanged }
        return .init(viewer:viewer,pr:pr,repository:repo,review:data.review)
    }
    /// Deny-by-default base truth: only capabilities the light query read are later granted.
    /// The revision carries provider head/base tip; origin is not read and stays empty.
    func truth(_ c:PRWriteCommand,_ result:Result) -> PRWriteTruth {
        PRWriteTruth(key:c.key,revision:.init(head:result.pr.headRefOid ?? "",origin:"",target:result.pr.baseRefOid ?? ""),viewerIsAuthor:result.pr.viewerDidAuthor == true,canReview:false,canComment:false,canUpdate:false,canReopen:false,canLabel:false,isOpen:result.pr.state == "OPEN")
    }
}
/// Light admission/reconciliation for label and assignee deltas: viewer, PR identity,
/// capability, repository and the one affected first-100 connection. More than 100 current
/// values is incomplete, so a reconciled delta stays uncertain rather than guessing.
struct GitHubPRLabelReader {
    let client:GitHubHTTPClient
    let credential:GitHubCredential
    private typealias L=GitHubPRLightQuery
    static let labelSelection="viewerCanLabel labels(first:100) { nodes { id name color } pageInfo { hasNextPage } }"
    static let assigneeSelection="viewerCanAssign assignees(first:100) { nodes { id login } pageInfo { hasNextPage } }"
    static let repositoryOptionsSelection="labels(first:100,orderBy:{field:NAME,direction:ASC}) { nodes { id name color } pageInfo { hasNextPage } } assignableUsers(first:100) { nodes { id login } pageInfo { hasNextPage } }"
    func read(_ c:PRWriteCommand,operation:PRWriteOperation?) async throws -> PRWriteTruth {
        let query=GitHubPRLightQuery(client:client,credential:credential)
        switch c.intent {
        case .metadata(.labelChanges(let add,let remove)):
            let result=try await query.run("Labels",key:c.key,repository:c.repository,number:c.number,pullRequest:Self.labelSelection)
            var truth=query.truth(c,result);let connection=result.pr.labels,labels=L.labels(connection)
            truth.canLabel=result.pr.viewerCanLabel == true;truth.labelRefs=labels.refs;truth.labelColors=labels.colors;truth.labelsComplete=L.complete(connection)
            if operation != nil,truth.labelsComplete,L.applied(add:add.map(\.id),remove:remove.map(\.id),current:labels.refs.map(\.id)) { truth.matchingOperationIDs=[c.gitHubNodeID] }
            return truth
        case .metadata(.assigneeChanges(let add,let remove)):
            let result=try await query.run("Assignees",key:c.key,repository:c.repository,number:c.number,pullRequest:Self.assigneeSelection)
            var truth=query.truth(c,result);let connection=result.pr.assignees
            truth.canAssign=result.pr.viewerCanAssign == true;truth.assigneeRefs=L.users(connection);truth.assigneesComplete=L.complete(connection)
            if operation != nil,truth.assigneesComplete,L.applied(add:add.map(\.id),remove:remove.map(\.id),current:truth.assigneeRefs.map(\.id)) { truth.matchingOperationIDs=[c.gitHubNodeID] }
            return truth
        default:throw PRWriteFailure.unavailable
        }
    }
    /// Picker options in one read: current PR labels/assignees plus the first 100 repository
    /// labels (by name) and assignable users, with explicit completeness.
    func options(_ pr:PullRequest) async throws -> PRMetadataOptions {
        guard let m=pr.metadata else { throw PRWriteFailure.unavailable }
        let query=GitHubPRLightQuery(client:client,credential:credential)
        let result=try await query.run("Options",key:pr.key,repository:m.repositoryName,number:m.number,pullRequest:Self.labelSelection+" "+Self.assigneeSelection,repositorySelection:Self.repositoryOptionsSelection)
        let current=result.pr.labels,catalog=result.repository.labels,assignees=result.pr.assignees,assignable=result.repository.assignableUsers
        let labels=L.labels(current),available=L.labels(catalog)
        return .init(key:pr.key,labels:labels.refs,labelsComplete:L.complete(current),availableLabels:available.refs,availableLabelsComplete:L.complete(catalog),labelColors:available.colors.merging(labels.colors) { _,current in current },assignees:L.users(assignees),assigneesComplete:L.complete(assignees),assignableUsers:L.users(assignable),assignableUsersComplete:L.complete(assignable),canLabel:result.pr.viewerCanLabel == true,canAssign:result.pr.viewerCanAssign == true)
    }
}
