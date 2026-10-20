import Foundation

extension LocalGitService {
    public func checkoutPullRequest(mapping: LocalPRCheckoutMapping, directory: URL, expected: LocalGitSnapshot? = nil) async throws -> LocalGitSnapshot {
        try await transaction(directory: directory) { service in
            let fresh = try await service.readSnapshot(directory: directory); try service.checkExpected(expected, fresh: fresh); try service.requireIdle(fresh)
            guard mapping.repository.account.host.lowercased() == "github.com", mapping.number > 0, [40, 64].contains(mapping.expectedHeadSHA.count), mapping.expectedHeadSHA.allSatisfy(\.isHexDigit) else { throw LocalGitMutationError.repositoryMismatch }
            let names = mapping.repositoryName.split(separator: "/", omittingEmptySubsequences: false)
            guard names.count == 2, names.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw LocalGitMutationError.repositoryMismatch }
            let urls = try await service.validateRemote(mapping.remote, directory: directory)
            guard urls.count == 1, Self.githubRepository(urls[0])?.lowercased() == mapping.repositoryName.lowercased() else { throw LocalGitMutationError.repositoryMismatch }
            try service.authorize(mapping.destination, directory: directory)
            try await service.validateBranch(mapping.branch, directory: directory)
            guard !FileManager.default.fileExists(atPath: mapping.destination.path), !fresh.branches.contains(where: { $0.name == mapping.branch }) else { throw LocalGitMutationError.invalidTarget }
            try await service.preflightHooks(Self.checkoutHooks, directory: directory)
            let ownedRef = "refs/mergepro/pull/\(mapping.number)/\(UUID().uuidString.lowercased())"
            do {
                // Unique owned ref avoids force-updating user branches or existing checkouts.
                _ = try await service.command(["fetch", "--no-tags", "--", mapping.remote, "refs/pull/\(mapping.number)/head:\(ownedRef)"], directory: directory)
                let sha = try await service.resolveCommit(ownedRef, directory: directory)
                guard sha.lowercased() == mapping.expectedHeadSHA.lowercased() else { throw LocalGitMutationError.revisionMismatch }
                _ = try await service.command(["worktree", "add", "-b", mapping.branch, "--", mapping.destination.path, sha], directory: directory)
                _ = try await service.command(["update-ref", "-d", ownedRef, sha], directory: directory)
            } catch {
                // Cancellation must not prevent best-effort cleanup of our unique temporary ref.
                await service.cleanupOwnedRef(ownedRef, directory: directory)
                throw error
            }
            return try await service.readSnapshot(directory: directory)
        }
    }
    func cleanupOwnedRef(_ ref: String, directory: URL) async {
        let runner = runner
        await Task.detached {
            do { try await self.preflightHooks(["reference-transaction"], directory: directory) } catch { return }
            guard let result = try? await runner.runReadOnly(arguments: ["rev-parse", "--verify", "--end-of-options", ref + "^{commit}"], directory: directory), result.exitCode == 0 else { return }
            let sha = String(decoding: result.standardOutput, as: UTF8.self).trimmingCharacters(in: .newlines)
            guard [40, 64].contains(sha.count), sha.allSatisfy(\.isHexDigit) else { return }
            do { _ = try await runner.run(arguments: ["update-ref", "-d", ref, sha], directory: directory) }
            catch { Log.localGit.info("Temporary checkout ref was not removed: \(Log.kind(error), privacy: .public)") }
        }.value
    }
    static func githubRepository(_ remote: String) -> String? {
        var path: String
        if remote.hasPrefix("git@github.com:") { path = String(remote.dropFirst("git@github.com:".count)) }
        else {
            guard let url = URL(string: remote), ["https", "ssh"].contains(url.scheme ?? ""), url.host?.lowercased() == "github.com", url.password == nil, url.query == nil, url.fragment == nil, url.port == nil, url.scheme == "ssh" ? url.user == "git" : url.user == nil else { return nil }
            path = String(url.path.drop(while: { $0 == "/" }))
        }
        if path.hasSuffix(".git") { path = String(path.dropLast(4)) }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return path
    }
}
