import Foundation

public struct Draft: Equatable, Codable, Sendable {
    public let id: UUID
    public let key: ProviderKey
    public let revision: RevisionID
    public let body: String
    public init(id: UUID = UUID(), key: ProviderKey, revision: RevisionID, body: String) {
        self.id = id; self.key = key; self.revision = revision; self.body = body
    }
}

public struct LocalSnapshot: Equatable, Sendable {
    public let account: Account?
    public let repositories: [Repository]
    public let trackedRepositories: Set<RepositoryKey>
    public let pins: Set<ProviderKey>
    public let settings: [String: String]
    public let pullRequests: [PullRequest]
    public let drafts: [Draft]

    public init(account: Account?, repositories: [Repository], trackedRepositories: Set<RepositoryKey>,
                pins: Set<ProviderKey>, settings: [String: String], pullRequests: [PullRequest], drafts: [Draft]) {
        self.account = account
        self.repositories = repositories
        self.trackedRepositories = trackedRepositories
        self.pins = pins
        self.settings = settings
        self.pullRequests = pullRequests
        self.drafts = drafts
    }
}

public enum StorageError: Error, Equatable, Sendable {
    case accountMissing(AccountScope)
    case revisionConflict
    case invalidCacheBudget
    case payloadExceedsBudget
    case draftIdentityConflict
}
