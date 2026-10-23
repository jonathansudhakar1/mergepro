import Foundation

/// Feature collaborator: the existing account session, rate budget and write ledger own admission.
public struct MergeCoordinator:Sendable {
    private let session:GitHubAccountSession
    private let budget:RateBudget
    private let database:DatabaseStore
    private let clientID:String
    private let activeAccount:@Sendable () async throws -> AccountScope?
    private let adapter:any MergeAdapter
    public init(session:GitHubAccountSession,budget:RateBudget,database:DatabaseStore,clientID:String,activeAccount:@escaping @Sendable () async throws -> AccountScope?,adapter:any MergeAdapter=GitHubMergeAdapter()) { self.session=session;self.budget=budget;self.database=database;self.clientID=clientID;self.activeAccount=activeAccount;self.adapter=adapter }
    public func inspect(_ pr:PullRequest) async throws -> MergeInspection {
        guard try await activeAccount() == pr.key.account else { throw PRWriteFailure.accountChanged }
        let ticket=try await session.authenticatedOperation(for:pr.key.account,clientID:clientID)
        let fence=try database.observationFence(for:pr.key)
        do {
            // User-initiated (the merge sheet): interactive, never queued behind background sync.
            var value=try await adapter.inspect(MergeTarget(pr),client:await session.interactiveReadClient(account:ticket.account,budget:budget),credential:ticket.credential)
            guard try await activeAccount() == pr.key.account else { throw PRWriteFailure.accountChanged }
            value.evidence.operationInProgress=try (value.evidence.nativeAffected ?? [pr.key]).contains { try hasActiveIntent($0) }
            let enriched=try enriched(value)
            guard try await session.withCurrentOperation(ticket,body:{ db in
                guard try db.saveObservedPullRequests([enriched],fences:[pr.key:fence]) else { throw CancellationError() }
            }) else { throw PRWriteFailure.accountChanged }
            value.pr=enriched;return value
        } catch { await session.featureFailed(error,operation:ticket);throw error }
    }
    /// Read-only commit-text prefill for the evidence head; nil when unavailable or for another head.
    /// Same account checks as `inspect`, but nothing is persisted and no fence/ledger state changes.
    public func messageDefaults(_ pr:PullRequest) async throws -> MergeMessageDefaults? {
        guard try await activeAccount() == pr.key.account else { throw PRWriteFailure.accountChanged }
        let ticket=try await session.authenticatedOperation(for:pr.key.account,clientID:clientID)
        do {
            let value=try await adapter.messageDefaults(MergeTarget(pr),client:await session.interactiveReadClient(account:ticket.account,budget:budget),credential:ticket.credential)
            guard try await activeAccount() == pr.key.account,try await session.withCurrentOperation(ticket,body:{ _ in }) else { throw PRWriteFailure.accountChanged }
            let head=pr.metadata?.mergeEvidence?.head ?? pr.headRevision.rawValue
            guard let value,value.head == head,value.head == pr.headRevision.rawValue else { return nil }
            return value
        } catch { await session.featureFailed(error,operation:ticket);throw error }
    }
    public func prepare(_ pr:PullRequest,action:MergeAction?=nil) async throws -> [MergeInspection] {
        let selected=try await inspect(pr)
        let action=action ?? MergePolicy.evaluate(selected.evidence).action
        guard let stack=selected.stack else { return [selected] }
        if action == .enableAutoMerge { throw PRWriteFailure.unavailable }
        guard [.direct,.queue,.removeQueue].contains(action) else { return [selected] }
        var values:[MergeInspection]=[]
        for layer in try stack.affected(upTo:pr.key,action:action) { values.append(layer.key == pr.key ? selected : try await inspect(layer)) }
        return values
    }
    private func hasActiveIntent(_ key:ProviderKey) throws -> Bool { try DraftReviewStore(database:database).operations(key).contains { [.prepared,.sending,.uncertain].contains($0.state) } }
    private func enriched(_ inspection:MergeInspection) throws -> PullRequest {
        let pr=inspection.pr
        let cached=try database.pullRequest(for:pr.key)
        var metadata=cached?.metadata ?? pr.metadata
        if let source=pr.metadata { metadata?.baseRevision=source.baseRevision;metadata?.baseBranch=source.baseBranch;metadata?.headBranch=source.headBranch }
        if let source=pr.metadata?.headRepositoryID { metadata?.headRepositoryID=source }
        metadata?.mergeEvidence=inspection.evidence;metadata?.mergeEligible=MergePolicy.evaluate(inspection.evidence).eligible;metadata?.nativeStack=inspection.stack
        metadata?.autoMerge=inspection.evidence.autoMergeEnabled;metadata?.autoMergeKnown=true;metadata?.mergedAt=pr.metadata?.mergedAt
        return .init(key:pr.key,headRevision:pr.headRevision,title:pr.title,state:pr.state,isDraft:pr.isDraft,metadata:metadata)
    }
    public func perform(_ command:MergeCommand) async throws -> PRWriteOperation {
        guard try await activeAccount() == command.pr.account else { throw PRWriteFailure.accountChanged }
        let ticket=try await session.authenticatedOperation(for:command.pr.account,clientID:clientID),store=DraftReviewStore(database:database)
        let operation=PRWriteOperation(command:command.writeCommand);try store.prepare(operation)
        let response: GitHubResponse
        do {
            // Shape validation occurs before any transport work; no fixture can invent bypass.
            _ = try GitHubMergeAdapter.request(operation)
            let writer=await session.preflightWriteClient(account:ticket.account,budget:budget,current:{
                guard try await activeAccount() == command.pr.account,try await session.withCurrentOperation(ticket,body:{ _ in }) else { throw PRWriteFailure.accountChanged }
            }) { reader in
                guard try await activeAccount() == command.pr.account else { throw PRWriteFailure.accountChanged }
                var observations:[MergeInspection]=[]
                for target in command.affected {
                    guard try await activeAccount() == command.pr.account,try await session.withCurrentOperation(ticket,body:{ _ in }) else { throw PRWriteFailure.accountChanged }
                    observations.append(try await adapter.inspect(target,client:reader,credential:ticket.credential))
                }
                try command.validate(observations)
                let request=try GitHubMergeAdapter.request(operation)
                let resource:RateBudget.Resource=request.path == "graphql" ? .graphql : .rest
                try await budget.acquire(account:ticket.account,resource:resource,priority:.interactive,cost:resource == .graphql ? 100 : 1)
                guard try await activeAccount() == command.pr.account,try await session.withCurrentWriteOperation(ticket,body:{ _ in
                    var sending=operation;sending.state = .sending
                    do { try store.update(sending,expectedState:.prepared) } catch let error as PRWriteFailure { throw error } catch { throw PRWriteFailure.persistenceBeforeSend }
                }) else { throw PRWriteFailure.accountChanged }
            }
            response = try await adapter.send(operation, client:writer, credential:ticket.credential)
        } catch {
            await session.featureFailed(error,operation:ticket)
            if let auth=(error as? GitHubGraphQLMutationFailure)?.authenticationFailure { await session.featureFailed(auth,operation:ticket) }
            var saved = try store.operation(operation.id) ?? operation
            guard [.prepared,.sending,.uncertain].contains(saved.state) else { throw error }
            let previous = saved.state
            let definitelyDenied: Bool
            switch error as? GitHubFailure {
            case .invalidAuthentication,.scopeRequired,.organizationRestricted,.resourceDenied,.rateLimited:
                definitelyDenied = true
            default:
                definitelyDenied = (error as? GitHubGraphQLMutationFailure)?.definitelyRejected == true
            }
            saved.state = previous == .prepared || definitelyDenied ? .rejected : .uncertain
            saved.message = error.localizedDescription
            try store.update(saved,expectedState:previous)
            if saved.state == .rejected { throw error }
            return saved
        }

        // From here the mutation returned a receipt. Subsequent parsing, persistence or
        // read errors cannot classify that mutation as a definitive transport denial.
        do {
            var saved = try store.operation(operation.id) ?? operation
            saved.response = response.data
            saved.mergeResponseStatus = response.status
            if [400,422].contains(response.status) {
                saved.state = .rejected
                saved.mergeOutcome = .failed(reason:"GitHub rejected the request (\(response.status)).")
                try store.update(saved,expectedState:.sending)
                return saved
            }
            saved.state = .uncertain
            try store.update(saved,expectedState:.sending)
            if [.direct,.queue].contains(MergeAction(rawValue:command.action)) {
                saved.mergeOperationID = try GitHubMergeAdapter.pendingID(response,command:command)
                if let id = saved.mergeOperationID { saved.mergeOutcome = .pending(operationID:id.uuidString) }
                try store.update(saved,expectedState:.uncertain)
            }
            return try await reconcile(saved.id)
        } catch {
            var saved = try store.operation(operation.id) ?? operation
            guard [.sending,.uncertain].contains(saved.state) else { return saved }
            let previous = saved.state
            saved.state = .uncertain
            saved.message = "Mutation may be active; read-only reconciliation is required. " + error.localizedDescription
            try store.update(saved,expectedState:previous)
            return saved
        }
    }
    /// At most two known-operation reads per invocation. Recovery never resends a mutation.
    public func reconcile(_ id:UUID) async throws -> PRWriteOperation {
        let store = DraftReviewStore(database:database)
        guard var operation = try store.operation(id), case .merge(let command) = operation.command.intent else {
            throw PRWriteFailure.unavailable
        }
        if [.confirmed,.postedOutdated,.rejected].contains(operation.state) {
            try store.recoverReceipts(command.pr)
            return operation
        }
        guard operation.state != .prepared else { return operation }

        // Both crash windows recover locally before any network read. Never interpret a
        // legacy raw receipt without HTTP provenance as a matching 202 rather than 409.
        let previousState = operation.state
        operation.state = .uncertain
        if operation.mergeOperationID == nil, let raw = operation.response,
           let status = operation.mergeResponseStatus, [200,202,409].contains(status) {
            do {
                operation.mergeOperationID = try GitHubMergeAdapter.pendingID(.init(status:status,data:raw), command:command)
            } catch {
                operation.message = "Saved receipt options could not be validated; reading PR state without adopting its operation identity."
            }
        }
        try store.update(operation, expectedState:previousState)
        let ticket = try await session.authenticatedOperation(for:command.pr.account,clientID:clientID)
        // The user waits on this outcome read after merging.
        let reader = await session.interactiveReadClient(account:ticket.account,budget:budget)
        var failure: String?
        var readError: (any Error)?
        var optionMismatch: String?
        if let uuid = operation.mergeOperationID {
            do {
                for _ in 0..<2 {
                    let response = try await adapter.status(uuid,target:command.target,client:reader,credential:ticket.credential)
                    let root = try JSONSerialization.jsonObject(with:response.data) as? [String:Any] ?? [:]
                    let details = root["details"] as? [String:Any] ?? [:]
                    if root["status"] as? String == "failed" {
                        failure = details["message"] as? String ?? "GitHub merge failed."
                        break
                    }
                    if root["status"] as? String != "pending" { break }
                    _ = try GitHubMergeAdapter.pendingID(response,command:command)
                }
            } catch let error as GitHubFailure where error == .resourceDenied {
                operation.message = "Operation result unavailable or expired; reconciling pull request state."
            } catch { readError = error }
        }

        var observations: [MergeInspection] = []
        if readError == nil {
            for target in command.affected {
                do {
                    let observation = try await adapter.inspect(target,client:reader,credential:ticket.credential)
                    guard observation.pr.key == target.key, observation.evidence.key == target.key else { throw PRWriteFailure.unavailable }
                    observations.append(observation)
                } catch {
                    readError = error
                    break
                }
            }
        }
        // Positive observations survive an unreadable later layer. Admission remains held
        // for unresolved work; a read denial is never a mutation rejection.
        let merged = observations.filter { $0.pr.state == .merged }
        operation.mergeConfirmedKeys = (operation.mergeConfirmedKeys ?? []).union(merged.map { $0.pr.key })
        var drift = operation.mergeRevisionDrift ?? []
        for observed in observations where [.direct,.queue].contains(MergeAction(rawValue:command.action)) {
            if let target = command.affected.first(where:{ $0.key == observed.pr.key }),
               observed.pr.headRevision.rawValue != target.head {
                drift.append("Layer #\(target.number) changed from reviewed head \(target.head) to observed head \(observed.pr.headRevision.rawValue).")
            }
            if let captured = command.reviewed.first(where:{ $0.key == observed.pr.key }), observed.evidence.branch != captured.branch {
                drift.append("Layer #\(observed.pr.metadata?.number ?? 0) changed its reviewed base branch.")
            }
            if let topology = command.topologyRevisions, let stack = observed.stack,
               stack.id != command.nativeStackID || stack.revisionSignature != topology {
                drift.append("Native stack membership, order or revisions changed after review.")
            }
        }
        operation.mergeRevisionDrift = Array(Set(drift)).sorted()
        let selected = observations.first { $0.pr.key == command.pr }
        if selected?.pr.state == .merged, let sha = selected?.mergeCommitSHA, !sha.isEmpty {
            operation.mergeSelectedCommit = sha
        }
        let allMerged = operation.mergeConfirmedKeys == Set(command.affected.map(\.key))
        if allMerged, let sha = operation.mergeSelectedCommit, !sha.isEmpty {
            operation.state = drift.isEmpty ? .confirmed : .postedOutdated
            operation.mergeOutcome = .merged(commitSHA:sha)
        } else if let failure {
            operation.state = .rejected
            operation.mergeOutcome = .failed(reason:failure)
        } else if readError == nil, observations.count == command.affected.count,
                  let selected, let action = MergeAction(rawValue:command.action) {
            let outcome: MergeOutcome?
            switch action {
            case .queue: outcome = observations.allSatisfy { $0.evidence.queued } ? .queued : nil
            case .enableAutoMerge:
                // Enabled is not enough: another actor's (or a stale) auto-merge may carry different options.
                outcome = selected.evidence.autoMergeEnabled && selected.autoMergeRequest?.matches(command) == true ? .autoMergeEnabled : nil
                if selected.evidence.autoMergeEnabled && outcome == nil { optionMismatch = "Auto-merge is enabled on GitHub, but its method or commit text differs from this request (or could not be read)." }
            case .disableAutoMerge: outcome = selected.evidence.autoMergeEnabled ? nil : .autoMergeDisabled
            case .removeQueue: outcome = observations.allSatisfy { !$0.evidence.queued } ? .queueRemoved : nil
            case .updateBranch:
                // GitHub updates onto the base tip at EXECUTION time, which may have moved after preflight. The
                // accepted bases are the captured base and the tip read now (this inspection's evidence base).
                let bases = Set([command.reviewed.first(where:{ $0.key == command.pr })?.base ?? "",selected.evidence.base].filter { !$0.isEmpty })
                // Merge update: new head's parents are the captured head and an accepted base. Rebase update: the
                // complete, linear chain now starts on an accepted base. Either can stay uncertain after further pushes.
                let proven = command.updateMethod == MergeUpdateMethod.rebase.rawValue ? selected.linearBase.map(bases.contains) == true : selected.headParents.contains(command.expectedHeadSHA) && !bases.isDisjoint(with:selected.headParents)
                outcome = selected.evidence.head != command.expectedHeadSHA && proven ? .branchUpdated(head:selected.evidence.head) : nil
            case .direct: outcome = nil
            }
            if let outcome {
                operation.state = drift.isEmpty || action == .updateBranch ? .confirmed : .postedOutdated
                operation.mergeOutcome = outcome
            }
        }
        var messages = operation.mergeRevisionDrift ?? []
        if let optionMismatch, operation.state == .uncertain { messages.append(optionMismatch) }
        if let readError { messages.append("Provider read incomplete; the sent operation remains unresolved: " + readError.localizedDescription) }
        if operation.state == .uncertain, !merged.isEmpty { messages.append("Some listed layers are provider-confirmed merged; remaining layers stay reserved.") }
        if !messages.isEmpty { operation.message = messages.joined(separator:" ") }
        let confirmations = try (operation.state == .uncertain ? merged : observations).map(enriched)
        let receipt = operation
        guard try await session.withCurrentOperation(ticket,body:{ _ in
            try store.commitReceipt(receipt,expectedState:.uncertain,confirmations:confirmations)
        }) else { throw PRWriteFailure.accountChanged }
        // Apply validated positive truth before a read-auth failure changes availability.
        if let readError { await session.featureFailed(readError,operation:ticket) }
        return receipt
    }
}
