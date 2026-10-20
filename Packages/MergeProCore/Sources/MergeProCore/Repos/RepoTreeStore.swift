import Foundation

public struct RepoTreePersistence: Codable, Equatable, Sendable {
    public var expanded: Set<RepoTreeNodeID> = []
    public var selection: RepoTreeNodeID?
    public var scrollAnchor: RepoTreeNodeID?
    public init() {}
}
public struct RepoTreeStore: Sendable {
    public private(set) var roots: [RepoTreeNode] = []
    public var expanded: Set<RepoTreeNodeID> = []
    public var selection: RepoTreeNodeID?
    public var scrollAnchor: RepoTreeNodeID?
    public var search = ""
    public var owners:[RepoCatalogOwner]=[]
    public init(entries:[RepoCatalogEntry],state:RepoTreePersistence = .init(),owners:[RepoCatalogOwner]=[]) {
        self.owners=owners;expanded=state.expanded;selection=state.selection;scrollAnchor=state.scrollAnchor;refresh(entries)
    }
    public var allNodes:[RepoTreeNode] { func flatten(_ nodes:[RepoTreeNode]) -> [RepoTreeNode] { nodes.flatMap { [$0]+flatten($0.children) } };return flatten(roots) }
    public var persistence:RepoTreePersistence { var result=RepoTreePersistence();result.expanded=expanded;result.selection=selection;result.scrollAnchor=scrollAnchor;return result }
    public mutating func refresh(_ entries:[RepoCatalogEntry]) {
        let grouped=Dictionary(grouping:entries,by:{ $0.key.account })
        roots=Set(grouped.keys).union(owners.map(\.account)).sorted { ($0.host+$0.accountID)<($1.host+$1.accountID) }.map { account in
            let repos=grouped[account] ?? []
            let groupedOwners=Dictionary(grouping:repos,by:\.owner)
            let knownOwners=owners.filter { $0.account==account }
            return RepoTreeNode(id:RepoTreeNodeID(host:account.host,accountID:account.accountID,ownerID:""),title:repos.first?.accountLogin ?? knownOwners.first?.accountLogin ?? account.accountID,children:Set(groupedOwners.keys).union(knownOwners.map(\.name)).sorted().map { owner in
                RepoTreeNode(id:RepoTreeNodeID(host:account.host,accountID:account.accountID,ownerID:knownOwners.first(where:{ $0.name==owner })?.ownerID ?? groupedOwners[owner]?.first?.ownerID ?? owner),title:owner,children:(groupedOwners[owner] ?? []).sorted { $0.shortName<$1.shortName }.map { Self.leaf($0) })
            })
        }
        let pinned=entries.filter(\.pinned)
        if !pinned.isEmpty { roots.insert(RepoTreeNode(id:RepoTreeNodeID(accountID:"",ownerID:"",group:"pins"),title:"Pinned",children:pinned.map { Self.leaf($0,group:"pins") }),at:0) }
        let valid=Set(allNodes.map(\.id));expanded.formIntersection(valid)
        if let selection,!valid.contains(selection) { self.selection=allNodes.first { $0.id.accountID == selection.accountID && $0.id.ownerID == selection.ownerID && $0.repository == nil }?.id }
        if let scrollAnchor,!valid.contains(scrollAnchor) { self.scrollAnchor=nil }
    }
    private static func leaf(_ repo:RepoCatalogEntry,group:String = "catalog") -> RepoTreeNode {
        RepoTreeNode(id:RepoTreeNodeID(host:repo.key.account.host,accountID:repo.key.account.accountID,repositoryID:repo.key.repositoryID,ownerID:repo.ownerID ?? repo.owner,group:group),title:repo.shortName,repository:repo)
    }
    public var visibleRoots:[RepoTreeNode] {
        guard !search.isEmpty else { return roots }
        func retain(_ node:RepoTreeNode) -> RepoTreeNode? {
            if let repo=node.repository { return (repo.repository.name+" "+repo.accountLogin).localizedCaseInsensitiveContains(search) ? node : nil }
            var result=node;result.children=node.children.compactMap(retain);return result.children.isEmpty ? nil : result
        }
        return roots.compactMap(retain)
    }
    public var effectiveExpansion:Set<RepoTreeNodeID> {
        guard !search.isEmpty else { return expanded }
        func ancestors(_ nodes:[RepoTreeNode]) -> [RepoTreeNodeID] { nodes.flatMap { $0.children.isEmpty ? [] : [$0.id]+ancestors($0.children) } }
        return expanded.union(ancestors(visibleRoots))
    }
}

public struct RepoCodePersistence:Codable,Equatable,Sendable {
    public var refName:String?
    public var selection:String?
    public var expanded:Set<String>
    public var scrollAnchor:String?
    public init(refName:String?=nil,selection:String?=nil,expanded:Set<String>=[],scrollAnchor:String?=nil) { self.refName=refName;self.selection=selection;self.expanded=expanded;self.scrollAnchor=scrollAnchor }
}
