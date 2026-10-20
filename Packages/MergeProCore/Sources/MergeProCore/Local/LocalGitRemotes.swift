import Foundation

public struct LocalGitRemote: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public let name: String
    /// Sanitized display only; commands use the existing remote name, never this string.
    public let fetchURL: String?
    public let pushURL: String?
}
extension LocalGitService {
    public func remotes(directory: URL) async throws -> [LocalGitRemote] {
        try await transaction(directory: directory) { service in
            let names = try await service.text(["remote"], directory: directory).split(separator: "\n").map(String.init)
            var result: [LocalGitRemote] = []
            for name in names {
                let fetch = try await service.text(["remote", "get-url", "--", name], directory: directory)
                let push = try await service.text(["remote", "get-url", "--push", "--", name], directory: directory)
                result.append(.init(name: name, fetchURL: Self.displayRemoteURL(fetch), pushURL: Self.displayRemoteURL(push)))
            }
            return result
        }
    }
    public func fetch(remote: String, directory: URL, expected: LocalGitSnapshot? = nil) async throws -> LocalGitSnapshot {
        try await transaction(directory: directory) { service in
            let fresh = try await service.readSnapshot(directory: directory); try service.checkExpected(expected, fresh: fresh); try service.requireIdle(fresh)
            let warnings = try await Self.plaintextTransportWarnings(remote: remote, urls: service.validateRemote(remote, directory: directory))
            _ = try await service.command(["fetch", "--", remote], directory: directory)
            var snapshot = try await service.readSnapshot(directory: directory); snapshot.transportWarnings = warnings
            return snapshot
        }
    }
    public func pull(remote: String, branch: String, directory: URL, expected: LocalGitSnapshot? = nil) async throws -> LocalGitSnapshot {
        try await transaction(directory: directory) { service in
            let fresh = try await service.readSnapshot(directory: directory); try service.checkExpected(expected, fresh: fresh); try service.requireIdle(fresh); try service.requireClean(fresh)
            try await service.validateBranch(branch, directory: directory)
            guard fresh.status.branch == branch else { throw LocalGitMutationError.invalidTarget }
            let warnings = try await Self.plaintextTransportWarnings(remote: remote, urls: service.validateRemote(remote, directory: directory))
            try await service.preflightHooks(Self.recoveryHooks, directory: directory)
            _ = try await service.command(["pull", "--ff-only", "--", remote, "refs/heads/" + branch], directory: directory)
            var snapshot = try await service.readSnapshot(directory: directory); snapshot.transportWarnings = warnings
            return snapshot
        }
    }
    public func push(remote: String, branch: String, directory: URL, expected: LocalGitSnapshot? = nil) async throws -> LocalGitSnapshot {
        try await transaction(directory: directory) { service in
            let fresh = try await service.readSnapshot(directory: directory); try service.checkExpected(expected, fresh: fresh); try service.requireIdle(fresh)
            try await service.validateBranch(branch, directory: directory)
            guard fresh.branches.contains(where: { $0.name == branch }) else { throw LocalGitMutationError.invalidTarget }
            try await service.validateRemote(remote, push: true, directory: directory)
            try await service.preflightHooks(["pre-push"], directory: directory)
            // Disable configured mirror/all pushes; an explicit non-forced refspec selects one branch.
            _ = try await service.command(["push", "--no-force", "--no-mirror", "--", remote, "refs/heads/\(branch):refs/heads/\(branch)"], directory: directory)
            return try await service.readSnapshot(directory: directory)
        }
    }
    @discardableResult func validateRemote(_ name: String, push: Bool = false, directory: URL) async throws -> [String] {
        guard !name.isEmpty, !name.hasPrefix("-"), !name.contains("\0"), !name.contains(":"), !name.contains("/") else { throw LocalGitMutationError.invalidRemote }
        let names = try await text(["remote"], directory: directory).split(separator: "\n").map(String.init)
        guard names.contains(name) else { throw LocalGitMutationError.invalidRemote }
        let urls = try await text(["remote", "get-url"] + (push ? ["--push"] : []) + ["--all", "--", name], directory: directory).split(separator: "\n").map(String.init)
        guard !urls.isEmpty else { throw LocalGitMutationError.invalidRemote }
        for value in urls {
            if push, !Self.isEncryptedPushURL(value) { throw LocalGitMutationError.unsupportedPushRemote }
            if let url = URL(string: value), let scheme = url.scheme {
                if scheme == "file" { try authorize(url, directory: directory) }
                else if ["https", "http", "ssh", "git"].contains(scheme) {
                    guard url.password == nil, scheme == "ssh" || url.user == nil else { throw LocalGitMutationError.invalidRemote }
                } else { throw LocalGitMutationError.invalidRemote }
            } else if Self.hasSCPShape(value) {
                // Existing scp-style SSH remotes; arbitrary custom remote-helper transports need Terminal.
                guard Self.isSCPRemote(value) else { throw LocalGitMutationError.invalidRemote }
            } else {
                let target = value.hasPrefix("/") ? URL(fileURLWithPath: value) : directory.appendingPathComponent(value)
                try authorize(target, directory: directory)
            }
        }
        return urls
    }
    /// Git treats a value as scp-style only when its first ':' precedes any '/'; otherwise it is a local path.
    static func hasSCPShape(_ value: String) -> Bool {
        guard let colon = value.firstIndex(of: ":") else { return false }
        return value.firstIndex(of: "/").map { colon < $0 } ?? true
    }
    static func isSCPRemote(_ value: String) -> Bool { hasSCPShape(value) && !value.hasPrefix("-") && !value.contains("\n") && !value.contains("::") }
    /// Pushes leave the machine only over encrypted transports: https, ssh or scp-style [user@]host:path. Plaintext
    /// http and git://, file and local paths, and remote helpers such as ext:: are refused.
    static func isEncryptedPushURL(_ value: String) -> Bool {
        if let scheme = URL(string: value)?.scheme { return scheme == "https" || scheme == "ssh" }
        return isSCPRemote(value)
    }
    /// Fetching over http or git:// stays allowed, but its result explicitly carries a warning for the caller to show.
    static func plaintextTransportWarnings(remote: String, urls: [String]) -> [LocalGitTransportWarning] {
        Set(urls.compactMap { URL(string: $0)?.scheme }.filter { $0 == "http" || $0 == "git" }).sorted().map { .init(remote: remote, scheme: $0) }
    }
    static func displayRemoteURL(_ value: String) -> String? {
        if var parts = URLComponents(string: value), parts.scheme != nil {
            parts.user = nil; parts.password = nil; parts.query = nil; parts.fragment = nil
            return parts.string
        }
        if let at = value.firstIndex(of: "@"), value[at...].contains(":") { return String(value[value.index(after: at)...]) }
        return value.contains("\n") ? nil : value
    }
}
