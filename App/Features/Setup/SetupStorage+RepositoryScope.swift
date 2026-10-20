import MergeProCore

extension SetupStorage {
    func repositoryScope(_ mode:RepositoryScopeMode,owner:String,account:AccountScope) throws {
        try stores().0.setRepositoryScope(mode,owner:owner,account:account,expectedActiveAccount:account)
    }
    func repositorySelection(_ keys:Set<RepositoryKey>,enabled:Bool,owner:String,account:AccountScope) throws {
        try stores().0.setRepositorySelection(keys,enabled:enabled,owner:owner,account:account,expectedActiveAccount:account)
    }
}
