import Foundation

extension LocalGitService {
    public func begin(operation: LocalGitOperation, target: String, directory: URL, expected: LocalGitSnapshot? = nil, reviewedHead: String? = nil, reviewedTarget: String? = nil) async throws -> LocalGitSnapshot {
        try await transaction(directory: directory) { service in
            let fresh = try await service.readSnapshot(directory: directory); try service.checkExpected(expected, fresh: fresh); try service.requireIdle(fresh); try service.requireClean(fresh)
            try await service.preflightHooks(Self.recoveryHooks, directory: directory)
            let commit = try await service.resolveCommit(target, directory: directory)
            if let reviewedHead, fresh.status.head != reviewedHead { throw LocalGitMutationError.staleSnapshot }
            if let reviewedTarget, commit != reviewedTarget { throw LocalGitMutationError.staleSnapshot }
            let admitted = try await service.readSnapshot(directory: directory)
            try service.checkExpected(fresh, fresh: admitted)
            await service.publish(.running(name: operation.rawValue), repository: fresh.repository, directory: directory)
            let args: [String]
            switch operation {
            case .merge: args = ["merge", "--no-edit", "--", commit]
            case .rebase: args = ["rebase", "--", commit]
            case .cherryPick: args = ["cherry-pick", "--", commit]
            }
            let result = try await service.runner.run(arguments: args, directory: directory)
            let after = try await service.readSnapshot(directory: directory)
            if result.exitCode != 0 && after.operation == .idle { try LocalRepositoryReader.check(result, arguments: args) }
            return after
        }
    }
    public func continueOperation(directory: URL, expected: LocalGitSnapshot? = nil) async throws -> LocalGitSnapshot {
        try await transaction(directory: directory) { service in
            let fresh = try await service.readSnapshot(directory: directory); try service.checkExpected(expected, fresh: fresh)
            let operation = try service.activeOperation(fresh)
            try await service.preflightHooks(Self.recoveryHooks, directory: directory)
            guard !fresh.status.entries.contains(where: \.isUnmerged) else { throw LocalGitMutationError.operationInProgress }
            // Rebase/cherry-pick continue may invoke configured editors/signing; preserve that behavior.
            let args = operation == .merge ? ["commit", "--no-edit"] : [operation.rawValue, "--continue"]
            let result = try await service.runner.run(arguments: args, directory: directory)
            let after = try await service.readSnapshot(directory: directory)
            if result.exitCode != 0 { try LocalRepositoryReader.check(result, arguments: args) }
            return after
        }
    }
    public func abortOperation(directory: URL, expected: LocalGitSnapshot? = nil) async throws -> LocalGitSnapshot {
        try await transaction(directory: directory) { service in
            let fresh = try await service.readSnapshot(directory: directory); try service.checkExpected(expected, fresh: fresh)
            let operation = try service.activeOperation(fresh)
            try await service.preflightHooks(Self.recoveryHooks, directory: directory)
            _ = try await service.command([operation.rawValue, "--abort"], directory: directory)
            return try await service.readSnapshot(directory: directory)
        }
    }
    func activeOperation(_ snapshot: LocalGitSnapshot) throws -> LocalGitOperation {
        guard case .conflicts(let name, _) = snapshot.operation, let operation = LocalGitOperation(rawValue: name) else { throw LocalGitMutationError.noOperation }
        return operation
    }
    func recoveryState(repository: LocalRepository, directory: URL, status suppliedStatus: GitStatusSnapshot?) async throws -> GitOperationState {
        let metadata = repository.gitDirectory
        for marker in ["rebase-merge", "rebase-apply", "MERGE_HEAD", "CHERRY_PICK_HEAD", "sequencer/todo"] { try authorize(metadata.appendingPathComponent(marker), directory: directory) }
        let operation: LocalGitOperation?
        if FileManager.default.fileExists(atPath: metadata.appendingPathComponent("rebase-merge").path) || FileManager.default.fileExists(atPath: metadata.appendingPathComponent("rebase-apply").path) { operation = .rebase }
        else if FileManager.default.fileExists(atPath: metadata.appendingPathComponent("MERGE_HEAD").path) { operation = .merge }
        else if FileManager.default.fileExists(atPath: metadata.appendingPathComponent("CHERRY_PICK_HEAD").path) { operation = .cherryPick }
        else if FileManager.default.fileExists(atPath: metadata.appendingPathComponent("sequencer/todo").path) {
            let todo = metadata.appendingPathComponent("sequencer/todo"); try authorize(todo, directory: directory)
            let data = try readRegularFile(todo, directory: directory, maximumBytes: 128 * 1024)
            guard let content = String(data: data, encoding: .utf8) else { throw LocalGitError.malformedOutput }
            if content.hasPrefix("pick ") { operation = .cherryPick } else { operation = nil }
        } else { operation = nil }
        guard let operation else { return .idle }
        let status: GitStatusSnapshot
        if let suppliedStatus { status = suppliedStatus }
        else { status = try await LocalRepositoryReader(runner: runner).status(directory: directory, authorizedRoots: authorizedRoots) }
        return .conflicts(operation: operation.rawValue, paths: status.entries.filter(\.isUnmerged).map(\.path).sorted())
    }
}
