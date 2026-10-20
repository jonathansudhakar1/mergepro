import Foundation

/// Local tracking policy for an owner, partitioned by the connected account's settings.
public enum RepositoryScopeMode: String, Codable, CaseIterable, Sendable {
    case allAccessible
    case selectedRepositories
}
public struct RepositoryScopeConfiguration: Equatable, Codable, Sendable {
    public static let settingName = "repositoryOwnerScopes"
    public var owners: [String:RepositoryScopeMode]
    public init(owners:[String:RepositoryScopeMode] = [:]) { self.owners = owners }
    public static func owner(of repository:Repository) -> String {
        repository.name.split(separator:"/",maxSplits:1).first.map(String.init) ?? repository.name
    }
    public static func canonicalOwner(_ owner:String) -> String { owner.lowercased() }
    /// Older installations stored only explicit repository keys. Preserve those choices, including none.
    public init(settings:[String:String],repositories:[Repository]) throws {
        if let value = settings[.repositoryOwnerScopes] {
            self = try JSONDecoder().decode(Self.self,from:Data(value.utf8))
        } else {
            owners = Dictionary(repositories.map { (Self.canonicalOwner(Self.owner(of:$0)),.selectedRepositories) },uniquingKeysWith:{ first,_ in first })
            if let value = settings[.organizations] {
                for org in try JSONDecoder().decode([GitHubOrganization].self,from:Data(value.utf8)) {
                    owners[Self.canonicalOwner(org.login)] = .selectedRepositories
                }
            }
        }
    }
    public func mode(for owner:String) -> RepositoryScopeMode { owners[Self.canonicalOwner(owner)] ?? .allAccessible }
    public mutating func set(_ mode:RepositoryScopeMode,for owner:String) { owners[Self.canonicalOwner(owner)] = mode }
}

public enum RepositoryScopeFailure: Error, Equatable, Sendable {
    case accountChanged
    case invalidRepositories
}

/// Bounded presentation only; changing the page or query never changes the saved selection.
public struct RepositoryScopePage: Sendable {
    public static let pageSize = 25
    public let repositories:[Repository]
    public let totalCount:Int
    public let page:Int
    public let pageCount:Int
    public init(repositories:[Repository],query:String,page:Int) {
        let query = query.trimmingCharacters(in:.whitespacesAndNewlines)
        let matching = repositories.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.key.repositoryID < $1.key.repositoryID : order == .orderedAscending
        }
        totalCount = matching.count
        pageCount = max(1,(matching.count + Self.pageSize - 1) / Self.pageSize)
        self.page = min(max(0,page),pageCount-1)
        self.repositories = Array(matching.dropFirst(self.page * Self.pageSize).prefix(Self.pageSize))
    }
}
