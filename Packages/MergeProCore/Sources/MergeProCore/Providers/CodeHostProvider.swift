import Foundation

/// Discovery boundary. Later features add dedicated protocols for reads and writes.
public protocol CodeHostProvider: Sendable {
    var account: AccountScope { get }
    func repositories() async throws -> [Repository]
    func capabilities(for repository: RepositoryKey) async throws -> ProviderCapabilities
}

public enum ProviderError: Error, Equatable, Sendable {
    case unauthenticated(AccountScope)
    case restrictedOrganization(account: AccountScope, organization: String)
    case forbidden(ProviderKey)
    case rateLimited(account: AccountScope, retryAfter: Date?)
    case incompleteData(ProviderKey)
    case uncertainWriteOutcome(object: ProviderKey, operationID: String)
}
