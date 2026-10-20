import Foundation

extension LocalGitService {
    public func createBranch(name: String, startPoint: String? = nil, directory: URL, expected: LocalGitSnapshot? = nil) async throws -> LocalGitSnapshot {
        try await transaction(directory: directory) { service in
            let fresh = try await service.readSnapshot(directory: directory); try service.checkExpected(expected, fresh: fresh); try service.requireIdle(fresh)
            try await service.validateBranch(name, directory: directory)
            let start = try await service.resolveCommit(startPoint ?? "HEAD", directory: directory)
            _ = try await service.command(["branch", "--", name, start], directory: directory)
            return try await service.readSnapshot(directory: directory)
        }
    }
    public func switchBranch(name: String, directory: URL, expected: LocalGitSnapshot? = nil) async throws -> LocalGitSnapshot {
        try await transaction(directory: directory) { service in
            let fresh = try await service.readSnapshot(directory: directory); try service.checkExpected(expected, fresh: fresh); try service.requireIdle(fresh); try service.requireClean(fresh)
            try await service.validateBranch(name, directory: directory)
            guard fresh.branches.contains(where: { $0.name == name }) else { throw LocalGitMutationError.invalidTarget }
            try await service.preflightHooks(Self.checkoutHooks, directory: directory)
            _ = try await service.command(["switch", "--no-guess", "--", name], directory: directory)
            return try await service.readSnapshot(directory: directory)
        }
    }
    public func deleteBranch(name: String, directory: URL, expected: LocalGitSnapshot? = nil) async throws -> LocalGitSnapshot {
        try await transaction(directory: directory) { service in
            let fresh = try await service.readSnapshot(directory: directory); try service.checkExpected(expected, fresh: fresh); try service.requireIdle(fresh)
            try await service.validateBranch(name, directory: directory)
            guard !service.isProtected(name), !fresh.branches.contains(where: { $0.name == name && $0.isProtected }) else { throw LocalGitMutationError.protectedBranch(name) }
            guard !fresh.repository.worktrees.contains(where: { $0.branch == name }) else { throw LocalGitMutationError.branchInUse(name) }
            guard fresh.branches.contains(where: { $0.name == name }) else { throw LocalGitMutationError.invalidTarget }
            _ = try await service.command(["branch", "--delete", "--", name], directory: directory)
            return try await service.readSnapshot(directory: directory)
        }
    }
    public func renameBranch(oldName: String, newName: String, directory: URL, expected: LocalGitSnapshot? = nil) async throws -> LocalGitSnapshot {
        try await transaction(directory: directory) { service in
            let fresh = try await service.readSnapshot(directory: directory); try service.checkExpected(expected, fresh: fresh); try service.requireIdle(fresh)
            try await service.validateBranch(oldName, directory: directory); try await service.validateBranch(newName, directory: directory)
            guard !service.isProtected(oldName), !fresh.branches.contains(where: { $0.name == oldName && $0.isProtected }) else { throw LocalGitMutationError.protectedBranch(oldName) }
            guard !service.isProtected(newName), !fresh.branches.contains(where: { $0.name == newName && $0.isProtected }) else { throw LocalGitMutationError.protectedBranch(newName) }
            guard fresh.branches.contains(where: { $0.name == oldName }) else { throw LocalGitMutationError.invalidTarget }
            _ = try await service.command(["branch", "--move", "--", oldName, newName], directory: directory)
            return try await service.readSnapshot(directory: directory)
        }
    }
    func validateBranch(_ name: String, directory: URL) async throws {
        guard !name.isEmpty, !name.hasPrefix("-"), !name.contains("\0"), name != "HEAD" else { throw LocalGitMutationError.invalidReference }
        let result = try await runner.runReadOnly(arguments: ["check-ref-format", "refs/heads/" + name], directory: directory)
        guard result.exitCode == 0 else { throw LocalGitMutationError.invalidReference }
    }
    func resolveCommit(_ ref: String, directory: URL) async throws -> String {
        guard !ref.isEmpty, !ref.hasPrefix("-"), !ref.contains("\0") else { throw LocalGitMutationError.invalidReference }
        let result = try await runner.runReadOnly(arguments: ["rev-parse", "--verify", "--end-of-options", ref + "^{commit}"], directory: directory)
        guard result.exitCode == 0, let text = String(data: result.standardOutput, encoding: .utf8) else { throw LocalGitMutationError.invalidReference }
        let sha = text.trimmingCharacters(in: .newlines)
        guard [40, 64].contains(sha.count), sha.allSatisfy(\.isHexDigit) else { throw LocalGitError.malformedOutput }
        return sha
    }
}
