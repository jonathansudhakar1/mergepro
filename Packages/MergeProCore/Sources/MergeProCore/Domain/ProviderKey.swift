import Foundation

public struct AccountScope: Hashable, Codable, Sendable {
    public let host: String
    public let accountID: String
    public init(host: String, accountID: String) { self.host = host; self.accountID = accountID }
}

public struct RepositoryKey: Hashable, Codable, Sendable {
    public let account: AccountScope
    public let repositoryID: String
    public init(account: AccountScope, repositoryID: String) {
        self.account = account; self.repositoryID = repositoryID
    }
}

public struct ProviderKey: Hashable, Codable, Sendable {
    public let host: String
    public let accountID: String
    public let repositoryID: String
    public let objectID: String
    public init(host: String, accountID: String, repositoryID: String, objectID: String) {
        self.host = host; self.accountID = accountID
        self.repositoryID = repositoryID; self.objectID = objectID
    }
    public var account: AccountScope { AccountScope(host: host, accountID: accountID) }
    public var repository: RepositoryKey { RepositoryKey(account: account, repositoryID: repositoryID) }
}

/// An immutable provider revision, such as a commit SHA or workflow run attempt.
public struct RevisionID: Hashable, Codable, Sendable {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}
