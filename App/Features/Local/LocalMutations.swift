import Foundation
import MergeProCore

extension LocalWorkspaceModel {
    func prepare(_ kind: LocalCommandKind, folderStore: SecurityScopedFolderStore, runner: any GitRunner, checkout: LocalPRCheckoutRequest?, presetTarget: String? = nil, commitMessage: String? = nil, amend: Bool = false) async {
        guard let directory, !mutating, !loading, !preparingCommand else { return }
        let token = UUID(); preparationID = token; preparingCommand = true
        defer { if preparationID == token { preparingCommand = false } }
        do {
            let sink = operationStateSink
            let snapshot = try await folderStore.withAllAccess { roots in
                try await LocalGitService(runner: runner, authorizedRoots: roots, requiresTerminalForHooks: true, operationStateSink: sink).snapshot(directory: directory)
            }
            guard self.directory == directory, preparationID == token, !Task.isCancelled else { return }
            self.snapshot = snapshot
            var input = LocalCommandInput(directory: directory, kind: kind)
            if kind == .createBranch { input.target = "HEAD" }
            if kind == .pull || kind == .push { input.target = snapshot.status.branch ?? "" }
            if kind == .checkoutPR, let checkout { input.name = "pr-\(checkout.number)" }
            if let presetTarget { if kind == .switchBranch { input.name = presetTarget } else { input.target = presetTarget } }
            if let commitMessage { input.message = commitMessage; input.amend = amend }
            commandPresentation = .init(input: input, snapshot: snapshot)
        } catch { self.error = Self.message(for: error) }
    }

    func commitTemplate(directory: URL, folderStore: SecurityScopedFolderStore, runner: any GitRunner) async -> String? {
        do { return try await folderStore.withAllAccess { roots in try await LocalGitService(runner: runner, authorizedRoots: roots, requiresTerminalForHooks: true).commitTemplate(directory: directory) } }
        catch { self.error = Self.message(for: error); return nil }
    }

    func execute(_ input: LocalCommandInput, expected: LocalGitSnapshot, checkout: LocalPRCheckoutRequest?, folderStore: SecurityScopedFolderStore, runner: any GitRunner, reviewedComparison: LocalGitComparison? = nil) async -> Bool {
        guard !mutating else { return false }
        mutating = true; error = nil; message = nil
        defer { mutating = false }
        do {
            let sink = operationStateSink
            let value = try await folderStore.withAllAccess { roots in
                let service = LocalGitService(runner: runner, authorizedRoots: roots, requiresTerminalForHooks: true, operationStateSink: sink)
                switch input.kind {
                case .commit: return try await service.commit(message: input.message, amend: input.amend, directory: input.directory, expected: expected)
                case .createBranch: return try await service.createBranch(name: input.name, startPoint: input.target.isEmpty ? "HEAD" : input.target, directory: input.directory, expected: expected)
                case .switchBranch: return try await service.switchBranch(name: input.name, directory: input.directory, expected: expected)
                case .deleteBranch: return try await service.deleteBranch(name: input.name, directory: input.directory, expected: expected)
                case .renameBranch: return try await service.renameBranch(oldName: input.target, newName: input.name, directory: input.directory, expected: expected)
                case .fetch: return try await service.fetch(remote: input.remote, directory: input.directory, expected: expected)
                case .pull: return try await service.pull(remote: input.remote, branch: input.target, directory: input.directory, expected: expected)
                case .push: return try await service.push(remote: input.remote, branch: input.target, directory: input.directory, expected: expected)
                case .stash: return try await service.stash(message: input.message, includeUntracked: input.includeUntracked, directory: input.directory, expected: expected)
                case .applyStash: return try await service.applyStash(reference: input.target, dropAfterApply: input.dropStash, directory: input.directory, expected: expected)
                case .dropStash: return try await service.dropStash(reference: input.target, directory: input.directory, expected: expected)
                case .addWorktree:
                    guard let path = input.destination else { throw LocalGitMutationError.invalidTarget }
                    return try await service.addWorktree(path: path, branch: input.name, createBranch: input.createWorktreeBranch, directory: input.directory, expected: expected)
                case .removeWorktree: return try await service.removeWorktree(target: URL(fileURLWithPath: input.target), directory: input.directory, expected: expected)
                case .merge: return try await service.begin(operation: .merge, target: input.target, directory: input.directory, expected: expected, reviewedHead: reviewedComparison?.head, reviewedTarget: reviewedComparison?.target)
                case .rebase: return try await service.begin(operation: .rebase, target: input.target, directory: input.directory, expected: expected, reviewedHead: reviewedComparison?.head, reviewedTarget: reviewedComparison?.target)
                case .cherryPick: return try await service.begin(operation: .cherryPick, target: input.target, directory: input.directory, expected: expected)
                case .checkoutPR:
                    guard let checkout, let destination = input.destination else { throw LocalGitMutationError.invalidTarget }
                    let mapping = LocalPRCheckoutMapping(repository: checkout.repository, repositoryName: checkout.repositoryName, number: checkout.number, expectedHeadSHA: checkout.expectedHeadSHA, remote: input.remote, destination: destination, branch: input.name)
                    return try await service.checkoutPullRequest(mapping: mapping, directory: input.directory, expected: expected)
                }
            }
            if directory == input.directory { snapshot = value; overview = .init(snapshot: value); repository = value.repository; status = value.status }
            if input.kind == .commit { LocalCommitDraftStore().clear(directory: input.directory); if directory == input.directory { commitSuccessToken = UUID() } }
            message = "\(input.kind.title) finished."
            await refresh(folderStore: folderStore, runner: runner)
            if !value.transportWarnings.isEmpty { error = value.transportWarnings.map(\.message).joined(separator: " ") }
            return true
        } catch {
            if Task.isCancelled {
                let recoveryRead = Task { @MainActor in await self.refresh(folderStore: folderStore, runner: runner) }
                await recoveryRead.value
            } else { await refresh(folderStore: folderStore, runner: runner) }
            self.error = Self.message(for: error)
            if case LocalGitError.authorizationRequired(let url) = error { requiredAuthorizationPath = url.path }
            return false
        }
    }

    /// A mutation's own fresh snapshot replaces the displayed state, without re-reading the folder.
    private func apply(_ value: LocalGitSnapshot) {
        snapshot = value; overview = .init(snapshot: value); repository = value.repository; status = value.status
        reconcileSelection(value.status)
    }

    func stageFile(path: String, unstage: Bool, folderStore: SecurityScopedFolderStore, runner: any GitRunner) async {
        await stageFiles(paths: [path], unstage: unstage, folderStore: folderStore, runner: runner)
    }

    func stageFiles(paths: [String], unstage: Bool, folderStore: SecurityScopedFolderStore, runner: any GitRunner) async {
        guard let directory, !paths.isEmpty, !mutating, !loading, !preparingCommand else { return }
        mutating = true; defer { mutating = false }
        do {
            let sink = operationStateSink
            // Staging names exact paths and validates them against the snapshot it reads itself, so no separate read
            // first; the snapshot it returns is current, so only the preview is reloaded rather than the whole folder.
            let value = try await folderStore.withAllAccess { roots in
                let service = LocalGitService(runner: runner, authorizedRoots: roots, requiresTerminalForHooks: true, operationStateSink: sink)
                return try await (unstage ? service.unstage(paths: paths, directory: directory) : service.stage(paths: paths, directory: directory))
            }
            guard self.directory == directory else { return }
            apply(value)
            await loadPreview(folderStore: folderStore, runner: runner)
        } catch { await refresh(folderStore: folderStore, runner: runner); self.error = Self.message(for: error) }
    }

    func loadHunks(staged: Bool, folderStore: SecurityScopedFolderStore, runner: any GitRunner) async {
        guard let directory, let selectedPath else { return }
        let token = UUID(); hunkGeneration = token
        do {
            let value = try await folderStore.withAllAccess { roots in try await LocalGitService(runner: runner, authorizedRoots: roots, requiresTerminalForHooks: true).diff(path: selectedPath, staged: staged, directory: directory) }
            guard self.directory == directory, self.selectedPath == selectedPath, hunkGeneration == token else { return }; fileDiff = value; fileDiffStaged = staged
        } catch { if hunkGeneration == token { self.error = Self.message(for: error) } }
    }

    func stageHunk(_ hunk: LocalDiffHunk, unstage: Bool, folderStore: SecurityScopedFolderStore, runner: any GitRunner) async {
        guard let directory, let diff = fileDiff, !mutating, !loading, !preparingCommand else { return }
        mutating = true; defer { mutating = false }
        do {
            let sink = operationStateSink
            let value = try await folderStore.withAllAccess { roots in
                let service = LocalGitService(runner: runner, authorizedRoots: roots, requiresTerminalForHooks: true, operationStateSink: sink)
                if unstage { return try await service.unstageHunk(patch: hunk.patch, expected: diff.snapshot, directory: directory) }
                return try await service.stageHunk(patch: hunk.patch, expected: diff.snapshot, directory: directory)
            }
            fileDiff = nil
            guard self.directory == directory else { return }
            apply(value)
            await loadPreview(folderStore: folderStore, runner: runner)
            await loadHunks(staged: unstage, folderStore: folderStore, runner: runner)
        } catch { self.error = Self.message(for: error) }
    }

    func prepareRecovery(abort: Bool, folderStore: SecurityScopedFolderStore, runner: any GitRunner) async {
        guard let directory, !mutating, !preparingCommand else { return }
        preparingCommand = true
        let advertisedOperation = operation
        let advertisedStatus = status
        do {
            let fresh = try await folderStore.withAllAccess { roots in try await LocalGitService(runner: runner, authorizedRoots: roots, requiresTerminalForHooks: true).snapshot(directory: directory) }
            preparingCommand = false
            guard self.directory == directory, !Task.isCancelled else { return }
            guard fresh.operation == advertisedOperation, fresh.status == advertisedStatus else { throw LocalGitMutationError.staleSnapshot }
            await recover(abort: abort, expected: fresh, folderStore: folderStore, runner: runner)
        } catch { preparingCommand = false; self.error = Self.message(for: error) }
    }

    func recover(abort: Bool, expected: LocalGitSnapshot, folderStore: SecurityScopedFolderStore, runner: any GitRunner) async {
        guard let directory, !mutating else { return }
        mutating = true; defer { mutating = false }
        do {
            let sink = operationStateSink
            _ = try await folderStore.withAllAccess { roots in
                let service = LocalGitService(runner: runner, authorizedRoots: roots, requiresTerminalForHooks: true, operationStateSink: sink)
                return try await (abort ? service.abortOperation(directory: directory, expected: expected) : service.continueOperation(directory: directory, expected: expected))
            }
            await refresh(folderStore: folderStore, runner: runner)
        } catch { await refresh(folderStore: folderStore, runner: runner); self.error = Self.message(for: error) }
    }
}
