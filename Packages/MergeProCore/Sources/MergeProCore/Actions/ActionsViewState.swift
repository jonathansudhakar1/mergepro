import Foundation
import GRDB
public struct ActionsFilter:Codable,Equatable,Sendable {
    public var query=""
    public var organization=""
    public var repositoryID=""
    /// New selections carry account/host identity; repositoryID remains for legacy saved views.
    public var repositoryKey:RepositoryKey?
    public var workflow=""
    public var branch=""
    public var event=""
    public var actor=""
    public var status=""
    public var environment=""
    public var after:Date?
    public var before:Date?
    public var oldestFirst=false
    public init() {}
    public func matches(repository:Repository) -> Bool {
        (organization.isEmpty || repository.name.split(separator:"/").first.map(String.init)==organization) &&
        (repositoryKey.map { repository.key == $0 } ?? (repositoryID.isEmpty || repository.key.repositoryID==repositoryID))
    }
    public func matches(_ run:WorkflowRun,catalog:ActionsCatalog?=nil) -> Bool {
        // Separate statements keep type-checking fast on every supported compiler.
        guard query.isEmpty || [run.name,run.repository.name,run.branch,run.actor,run.headSHA].contains(where:{ $0.localizedCaseInsensitiveContains(query) }) else { return false }
        guard matches(repository:run.repository) else { return false }
        guard workflow.isEmpty || run.name.localizedCaseInsensitiveContains(workflow) || String(run.workflowID)==workflow else { return false }
        guard branch.isEmpty || run.branch==branch, event.isEmpty || run.event==event else { return false }
        guard actor.isEmpty || run.actor.localizedCaseInsensitiveContains(actor) else { return false }
        guard status.isEmpty || run.status==status || run.conclusion==status else { return false }
        if !environment.isEmpty {
            let deployed=catalog?.deployments.contains(where:{ $0.environment==environment && $0.sha==run.headSHA }) ?? false
            guard deployed else { return false }
        }
        if let after,run.createdAt < after { return false }
        if let before,run.createdAt > before { return false }
        return true
    }
}
public struct ActionsSavedView:Codable,Equatable,Identifiable,Sendable {
    public var id:UUID
    public var name:String
    public var filter:ActionsFilter
    public var notificationRule:Bool
    public init(name:String,filter:ActionsFilter,notificationRule:Bool=false,id:UUID=UUID()) { self.id=id;self.name=name;self.filter=filter;self.notificationRule=notificationRule }
}
public struct ActionsViewState:Codable,Equatable,Sendable {
    public var filter=ActionsFilter()
    public var savedViews:[ActionsSavedView]=[]
    public var pinnedWorkflows:Set<ProviderKey>=[]
    public static func workflowKey(_ id:Int64,repository:RepositoryKey) -> ProviderKey { .init(host:repository.account.host,accountID:repository.account.accountID,repositoryID:repository.repositoryID,objectID:"workflow:\(id)") }
    public init() {}
}
public extension ActionsStore {
    func viewState(_ account:AccountScope) throws -> ActionsViewState {
        try database.database.read { db in try Data.fetchOne(db,sql:"SELECT json FROM actions_view_state WHERE host=? AND accountID=?",arguments:[account.host,account.accountID]).map { try JSONDecoder().decode(ActionsViewState.self,from:$0) } ?? .init() }
    }
    func saveViewState(_ state:ActionsViewState,account:AccountScope) throws {
        try database.database.write { try $0.execute(sql:"INSERT INTO actions_view_state VALUES(?,?,?) ON CONFLICT(host,accountID) DO UPDATE SET json=excluded.json",arguments:[account.host,account.accountID,try JSONEncoder().encode(state)]) }
    }
    func matchingEventKeys(events:[ChangeEvent],repositories:[Repository]) throws -> Set<String> {
        var keys:Set<String>=[]
        for repository in repositories {
            // A rule scoped to another account's repository can never select this account's runs, so it must not silence them.
            let rules=try viewState(repository.key.account).savedViews.filter { $0.notificationRule && ($0.filter.repositoryKey.map { $0.account==repository.key.account } ?? true) }
            let catalog=try catalog(repository.key)
            for event in events where event.object.repository==repository.key && event.locator?.subjectType=="WorkflowRun" {
                guard let run=catalog?.runs.first(where:{ $0.key==event.object }) else { continue }
                if rules.isEmpty || rules.contains(where:{ $0.filter.matches(run,catalog:catalog) }) { keys.insert(event.key) }
            }
        }
        return keys
    }
}

public extension ActionsViewState {
    static func aggregate(_ states:[AccountScope:ActionsViewState]) -> ActionsViewState {
        var result=ActionsViewState()
        if states.count==1 { result.filter=states.values.first!.filter }
        for account in states.keys.sorted(by:{ $0.host+$0.accountID < $1.host+$1.accountID }) {
            result.savedViews += states[account]!.savedViews
            result.pinnedWorkflows.formUnion(states[account]!.pinnedWorkflows)
        }
        return result
    }
    /// A view filtered to one repository belongs to that repository's account; others go to the chosen account.
    static func owner(of filter:ActionsFilter,newViewsAccount:AccountScope?) -> AccountScope? { filter.repositoryKey?.account ?? newViewsAccount }
    /// Aggregate filters stay transient. Views retain their owner; workflow pins carry scoped identity.
    static func distributingEdits(from previous:ActionsViewState,to edited:ActionsViewState,states:[AccountScope:ActionsViewState],newViewsAccount:AccountScope?) -> [AccountScope:ActionsViewState] {
        guard previous != edited else { return states }
        var owners:[UUID:AccountScope]=[:]
        for (account,state) in states { for view in state.savedViews { owners[view.id]=account } }
        var result=states
        for (account,var state) in states {
            if states.count==1,previous.filter != edited.filter { state.filter=edited.filter }
            state.savedViews=edited.savedViews.filter { (owners[$0.id] ?? owner(of:$0.filter,newViewsAccount:newViewsAccount))==account }
            state.pinnedWorkflows=Set(edited.pinnedWorkflows.filter { $0.account==account })
            result[account]=state
        }
        return result
    }
}
