import Foundation
import MergeProCore

/// Local workspace records: authorized folder bookmarks and Git operation recovery hints (app-wide settings).
extension SetupStorage {
    func localFolderData() throws -> Data? {
        try stores().0.applicationSetting(.localFolders).map { Data($0.utf8) }
    }
    func saveLocalFolderData(_ data:Data) throws {
        guard data.count<=2*1024*1024,let value=String(data:data,encoding:.utf8) else { throw CocoaError(.coderInvalidValue) }
        try stores().0.setApplicationSetting(value,for:.localFolders)
    }
    private struct LocalRecoveryHint:Codable {
        let repository:LocalRepositoryID
        let worktree:LocalWorktreeID
        let state:GitOperationState
        let updatedAt:Date
    }
    func saveLocalOperationState(repository:LocalRepositoryID,worktree:LocalWorktreeID,state:GitOperationState) throws {
        let database=try stores().0
        var hints=try localRecoveryHints()
        hints.removeAll { $0.repository == repository && $0.worktree == worktree }
        if state != .idle { hints.append(.init(repository:repository,worktree:worktree,state:state,updatedAt:dependencies.clock())) }
        // Recovery hints never supersede the current Git metadata and retain only recent worktrees.
        hints=Array(hints.suffix(128))
        let data=try JSONEncoder().encode(hints)
        guard data.count<=2*1024*1024,let value=String(data:data,encoding:.utf8) else { throw CocoaError(.coderInvalidValue) }
        try database.setApplicationSetting(value,for:.localRecoveryHints)
    }
    func localOperationState(repository:LocalRepositoryID,worktree:LocalWorktreeID) throws -> GitOperationState? {
        try localRecoveryHints().first { $0.repository == repository && $0.worktree == worktree }?.state
    }
    private func localRecoveryHints() throws -> [LocalRecoveryHint] {
        guard let value=try stores().0.applicationSetting(.localRecoveryHints) else { return [] }
        return try JSONDecoder().decode([LocalRecoveryHint].self,from:Data(value.utf8))
    }
}
