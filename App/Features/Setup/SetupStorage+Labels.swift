import SwiftUI
import MergeProCore

/// Label reads and writes. PR label deltas go through the PR write coordinator (active action
/// account only); repository label mutations go through the repository browser service.
extension SetupStorage {
    /// The repository as `key.account` sees it. Label reads/writes never borrow another account's identity.
    /// Targeted lookups (the accounts table and one repository row), never the account's cached PRs.
    func labelRepository(_ key:RepositoryKey) throws -> RepoCatalogEntry {
        let database=try stores().0
        guard let account=try database.accounts().first(where:{ $0.scope == key.account }),
              let repository=try database.repository(key) else { throw RepositoryBrowserFailure.permissionDenied }
        return RepoCatalogEntry(repository:repository,accountLogin:account.login)
    }
    func cachedRepositoryLabels(_ key:RepositoryKey) async throws -> RepositoryLabelCatalog? { try await repositoryBrowserService().cachedLabels(labelRepository(key)) }
    func repositoryLabels(_ key:RepositoryKey) async throws -> RepositoryLabelCatalog { try await repositoryBrowserService().labels(labelRepository(key)) }
    /// One explicit repository label mutation; an unconfirmed receipt throws `unknownWriteOutcome` and is never resent.
    func applyRepositoryLabel(_ mutation:RepositoryLabelMutation,in key:RepositoryKey) async throws -> RepositoryLabel? { try await repositoryBrowserService().apply(mutation,to:labelRepository(key)) }
    func reconcileRepositoryLabel(_ mutation:RepositoryLabelMutation,in key:RepositoryKey) async throws -> RepositoryBranchReconciliation { try await repositoryBrowserService().reconcileLabel(mutation,in:labelRepository(key)) }
    /// Picker options (current labels, first 100 repository labels, colors, permission) for the action-account PR: ONE light read.
    func labelOptions(_ actionPR:PullRequest) async throws -> PRMetadataOptions { try await writeCoordinator().metadataOptions(for:actionPR) }
    /// Label deltas for this PR whose provider outcome is not yet known; Apply stays disabled while any exist.
    func unresolvedLabelWrites(_ key:ProviderKey) throws -> [PRWriteOperation] {
        try writeOperations(key).filter { operation in
            guard [.prepared,.sending,.uncertain].contains(operation.state),case .metadata(.labelChanges)=operation.command.intent else { return false }
            return true
        }
    }
}
