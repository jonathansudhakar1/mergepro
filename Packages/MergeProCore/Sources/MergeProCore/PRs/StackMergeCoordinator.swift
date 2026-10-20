import Foundation

public struct PRBatchProgress:Sendable,Equatable {
    public var completed:[ProviderKey]=[]
    public var remaining:[ProviderKey]
    public var stopped:String?
    public var providerURL:URL?
    public init(keys:[ProviderKey]) { remaining=keys }
}
/// Serial feature orchestration, never a second operation owner. Each item uses its captured
/// reviewed command. Pending/queued stops an inferred stack because the next base has not landed.
public enum StackMergeCoordinator {
    /// Capture dependency identity from verified inferred topology for every batch entry.
    /// A generic board/list selection is not assumed to arrive in dependency order.
    public static func captureDependencies(_ commands:[MergeCommand], stacks:[PRStack]) throws -> [MergeCommand] {
        let captured = try commands.map { command -> MergeCommand in
            var command = command
            guard command.nativeStackID == nil,
                  let stack = stacks.first(where:{ $0.kind == .inferred && $0.layers.contains(where:{ $0.key == command.pr }) }) else { return command }
            guard stack.warnings.isEmpty,
                  let index = stack.layers.firstIndex(where:{ $0.key == command.pr }) else { throw PRWriteFailure.unavailable }
            if index > 0 {
                let parent = stack.layers[index-1]
                guard let child = command.reviewed.first(where:{ $0.key == command.pr }),
                      child.branch == parent.metadata?.headBranch,
                      child.base == parent.headRevision.rawValue else { throw PRWriteFailure.revisionChanged }
                command.inferredDependency = .init(parent:parent.key,parentHead:parent.headRevision.rawValue,
                    parentBranch:parent.metadata?.headBranch ?? "",parentWasMerged:parent.state == .merged,
                    providerURL:URL(string:"https://\(command.pr.host)/\(command.target.repository)/pull/\(command.target.number)")!)
            }
            return command
        }
        return try ordered(captured)
    }

    public static func ordered(_ commands:[MergeCommand]) throws -> [MergeCommand] {
        guard Set(commands.map(\.pr)).count == commands.count else { throw PRWriteFailure.unavailable }
        var remaining = commands
        var result: [MergeCommand] = []
        while !remaining.isEmpty {
            guard let index = remaining.firstIndex(where:{ command in
                guard let dependency = command.inferredDependency else { return true }
                return !remaining.contains(where:{ $0.pr == dependency.parent })
            }) else { throw PRWriteFailure.unavailable }
            result.append(remaining.remove(at:index))
        }
        return result
    }

    public static func merge(_ commands:[MergeCommand],perform:@Sendable (MergeCommand) async throws -> PRWriteOperation,progress:@Sendable (PRBatchProgress) async -> Void) async -> PRBatchProgress {
        let orderedCommands: [MergeCommand]
        do { orderedCommands = try ordered(commands) }
        catch {
            var stopped = PRBatchProgress(keys:commands.map(\.pr))
            stopped.stopped = "Captured dependency order is ambiguous; review the stack again."
            await progress(stopped)
            return stopped
        }
        var state = PRBatchProgress(keys:orderedCommands.map(\.pr))
        await progress(state)
        for command in orderedCommands {
            if let dependency = command.inferredDependency {
                // Merging a into main normally does not move feature ref a. Sending the
                // old b→a command would not land b on main. A new base/revision also
                // needs a new reviewed command; this batch never silently retargets it.
                state.stopped = state.completed.contains(dependency.parent) || dependency.parentWasMerged
                    ? "The lower layer landed. This PR still targets reviewed feature branch \(dependency.parentBranch); restack or retarget on GitHub, then review fresh options."
                    : "The inferred parent is not confirmed landed in this batch. Review dependencies and retarget/restack on GitHub before continuing."
                state.providerURL = dependency.providerURL
                await progress(state)
                return state
            }
            do {
                try Task.checkCancellation()
                let result = try await perform(command)
                guard result.state == .confirmed else {
                    state.stopped = result.message ?? "The result is incomplete or differs from the reviewed revision; remaining operations were not sent."
                    await progress(state)
                    return state
                }
                guard case .merged = result.mergeOutcome else {
                    state.stopped = "\(command.target.repository) #\(command.target.number): accepted, queued or waiting; remaining layers were not sent."
                    await progress(state)
                    return state
                }
                state.completed.append(command.pr)
                state.remaining.removeFirst()
                await progress(state)
            } catch {
                state.stopped = error.localizedDescription
                await progress(state)
                return state
            }
        }
        return state
    }
    public static func approve(_ commands:[PRWriteCommand],perform:@Sendable (PRWriteCommand) async throws -> PRWriteOperation,progress:@Sendable (PRBatchProgress) async -> Void) async -> PRBatchProgress {
        var state=PRBatchProgress(keys:commands.map(\.key));await progress(state)
        for command in commands {
            do {
                guard command.intent.decision == .approve else { throw PRWriteFailure.unavailable }
                try Task.checkCancellation();let result=try await perform(command)
                guard result.state == .confirmed else { throw PRWriteFailure.uncertain }
                state.completed.append(command.key);state.remaining.removeFirst();await progress(state)
            } catch { state.stopped=error.localizedDescription;await progress(state);return state }
        }
        return state
    }
}
