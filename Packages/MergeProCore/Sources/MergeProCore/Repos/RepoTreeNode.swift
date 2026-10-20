import Foundation

public struct RepoCatalogEntry: Identifiable, Equatable, Codable, Sendable {
    public var id: RepositoryKey { key }
    public var key: RepositoryKey { repository.key }
    public let repository: Repository
    public let accountLogin: String
    public var ownerID:String?
    public var pinned: Bool
    public var defaultBranch: String
    public var language: String?
    public var topics: [String]
    public var archived: Bool
    public var fork: Bool
    public var stars: Int
    public var openPRs: Int?
    public var pushedAt: Date?
    public var latestRelease: String?
    public var defaultCI: String?
    public var canPush: Bool
    public init(repository: Repository, accountLogin: String, pinned: Bool = false, defaultBranch: String = "main", language: String? = nil, topics: [String] = [], archived: Bool = false, fork: Bool = false, stars: Int = 0, openPRs: Int? = nil, pushedAt: Date? = nil, latestRelease: String? = nil, defaultCI: String? = nil, canPush: Bool = false,ownerID:String? = nil) {
        self.repository=repository;self.accountLogin=accountLogin;self.ownerID=ownerID;self.pinned=pinned;self.defaultBranch=defaultBranch;self.language=language;self.topics=topics;self.archived=archived;self.fork=fork;self.stars=stars;self.openPRs=openPRs;self.pushedAt=pushedAt;self.latestRelease=latestRelease;self.defaultCI=defaultCI;self.canPush=canPush
    }
    public var owner: String { repository.name.split(separator:"/").first.map(String.init) ?? repository.name }
    public var shortName: String { repository.name.split(separator:"/").last.map(String.init) ?? repository.name }
    public var providerKey: ProviderKey { ProviderKey(host:key.account.host,accountID:key.account.accountID,repositoryID:key.repositoryID,objectID:"repository") }
    public var webURL: URL { URL(string:"https://github.com/")!.appendingPathComponent(repository.name) }
}
public struct RepoTreeNodeID: Hashable, Codable, Sendable {
    public let host: String
    public let accountID: String
    public let repositoryID: String?
    public let ownerID: String
    public let path: String?
    public let group: String
    public init(host: String = "github.com", accountID: String, repositoryID: String? = nil, ownerID: String, path: String? = nil, group: String = "catalog") { self.host=host;self.accountID=accountID;self.repositoryID=repositoryID;self.ownerID=ownerID;self.path=path;self.group=group }
    public var stableString: String { [host,accountID,repositoryID ?? "",ownerID,path ?? "",group].map { Data($0.utf8).base64EncodedString() }.joined(separator:"|") }
}
public struct RepoTreeNode: Identifiable, Equatable, Sendable {
    public let id: RepoTreeNodeID
    public let title: String
    public let repository: RepoCatalogEntry?
    public var children: [RepoTreeNode]
    public var count: Int { repository == nil ? children.reduce(0) { $0+$1.count } : 1 }
    public init(id: RepoTreeNodeID,title:String,repository:RepoCatalogEntry? = nil,children:[RepoTreeNode] = []) { self.id=id;self.title=title;self.repository=repository;self.children=children }
}
public enum RepoCatalogSort: String, CaseIterable, Codable, Sendable { case name, lastPush, openPRs, failingCI, stars }
public struct RepoCatalogFilter: Equatable, Sendable {
    public var search="", owner="", language="", topic=""
    public var visibility: Bool? = nil
    public var archived: Bool? = nil
    public var fork: Bool? = nil
    public var hasOpenPRs=false, pinnedOnly=false
    public var sort: RepoCatalogSort = .name
    public init() {}
    public func apply(_ entries:[RepoCatalogEntry]) -> [RepoCatalogEntry] {
        entries.filter {
            (search.isEmpty || ($0.repository.name+" "+$0.accountLogin+" "+$0.topics.joined(separator:" ")).localizedCaseInsensitiveContains(search)) &&
            (owner.isEmpty || $0.owner == owner) && (language.isEmpty || $0.language == language) && (topic.isEmpty || $0.topics.contains(topic)) &&
            (visibility == nil || $0.repository.isPrivate == visibility) && (archived == nil || $0.archived == archived) && (fork == nil || $0.fork == fork) &&
            (!hasOpenPRs || $0.openPRs == nil || ($0.openPRs ?? 0)>0) && (!pinnedOnly || $0.pinned)
        }.sorted {
            if $0.pinned != $1.pinned { return $0.pinned }
            switch sort {
            case .lastPush: if $0.pushedAt != $1.pushedAt { return ($0.pushedAt ?? .distantPast)>($1.pushedAt ?? .distantPast) }
            case .openPRs: if ($0.openPRs ?? 0) != ($1.openPRs ?? 0) { return ($0.openPRs ?? 0)>($1.openPRs ?? 0) }
            case .stars: if $0.stars != $1.stars { return $0.stars>$1.stars }
            case .failingCI: if (["FAILURE","ERROR"].contains($0.defaultCI?.uppercased() ?? "")) != (["FAILURE","ERROR"].contains($1.defaultCI?.uppercased() ?? "")) { return ["FAILURE","ERROR"].contains($0.defaultCI?.uppercased() ?? "") }
            case .name: break
            }
            if $0.repository.name != $1.repository.name { return $0.repository.name.localizedStandardCompare($1.repository.name) == .orderedAscending }
            return $0.accountLogin<$1.accountLogin
        }
    }
}
public struct RepoNavigationRoute: Equatable, Sendable {
    public let repository: RepositoryKey
    public let ref: String?
    public let path: String?
    public let section: String?
    public let line: Int?
    public init(repository:RepositoryKey,ref:String? = nil,path:String? = nil,section:String? = nil,line:Int? = nil) { self.repository=repository;self.ref=ref;self.path=path;self.section=section;self.line=line }
}
public struct RepoPaletteEntry: Equatable, Sendable, Identifiable {
    public let title: String
    public let route: RepoNavigationRoute
    public let kind: String
    public var id:String { route.repository.account.host+"|"+route.repository.account.accountID+"|"+route.repository.repositoryID+"|"+kind+"|"+(route.ref ?? "")+"|"+(route.path ?? "") }
    public init(title:String,route:RepoNavigationRoute,kind:String) { self.title=title;self.route=route;self.kind=kind }
}

public struct RepoCatalogOwner:Equatable,Sendable {
    public let account:AccountScope
    public let accountLogin:String
    public let name:String
    public let ownerID:String
    public init(account:AccountScope,accountLogin:String,name:String,ownerID:String?=nil) { self.account=account;self.accountLogin=accountLogin;self.name=name;self.ownerID=ownerID ?? name }
}
