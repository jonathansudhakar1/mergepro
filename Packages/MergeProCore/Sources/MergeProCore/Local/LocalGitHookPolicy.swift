import Foundation

extension LocalGitService {
    /// The signed app enables this until its selected Git can execute hooks reliably. Testing an
    /// executable bit with access(X_OK) is insufficient: sandbox denial can make Git skip a hook.
    func preflightHooks(_ names: [String], directory: URL) async throws {
        guard requiresTerminalForHooks else { return }
        let path = try await text(["rev-parse", "--path-format=absolute", "--git-path", "hooks"], directory: directory)
        let hooks = URL(fileURLWithPath: path)
        try authorize(hooks, directory: directory)
        for name in names {
            let hook = hooks.appendingPathComponent(name)
            try authorize(hook, directory: directory)
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: hook.path)
                let bits = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
                if bits & 0o111 != 0 { throw LocalGitMutationError.unsupportedHooks }
            } catch let failure as CocoaError where failure.code == .fileReadNoSuchFile {
                continue
            } catch let failure as LocalGitMutationError { throw failure }
            catch { throw LocalGitError.authorizationRequired(hook) }
        }
    }
    /// All service-owned mutating commands pass here, including ref-only operations. Read-only
    /// inspection stays usable when the signed app needs Terminal for a configured write hook.
    func preflightCommandHooks(_ arguments: [String], directory: URL) async throws {
        guard requiresTerminalForHooks, let index = arguments.firstIndex(where: { !$0.hasPrefix("-") }) else { return }
        let verb = arguments[index], rest = arguments.dropFirst(index + 1)
        let hooks: [String]
        switch verb {
        case "add", "restore", "rm", "apply": hooks = Self.indexHooks
        case "commit": hooks = Self.commitHooks + ["post-rewrite", "reference-transaction"]
        case "branch", "fetch", "update-ref": hooks = ["reference-transaction"]
        case "switch", "worktree": hooks = Self.checkoutHooks + ["reference-transaction"]
        case "pull", "merge", "rebase", "cherry-pick": hooks = Self.recoveryHooks
        case "push": hooks = ["pre-push", "reference-transaction"]
        case "stash":
            if rest.first == "list" { return }
            hooks = Self.indexHooks + ["reference-transaction"]
        default: return
        }
        try await preflightHooks(hooks, directory: directory)
    }
    static let commitHooks = ["pre-commit", "prepare-commit-msg", "commit-msg", "post-commit"]
    static let indexHooks = ["post-index-change"]
    static let checkoutHooks = ["post-checkout", "post-index-change"]
    static let recoveryHooks = commitHooks + ["pre-merge-commit", "post-merge", "pre-rebase", "post-rewrite", "post-checkout", "post-index-change", "reference-transaction"]
}
