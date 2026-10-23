import Foundation

extension PRWriteOperation {
    public static let stoppedWaitingMessage="Stopped waiting; check the pull request on GitHub."
    static let notShownMessage="GitHub doesn't show this change, so it was not applied. Nothing was resent; apply it again if it's still needed."
    static let notShownYetMessage="GitHub doesn't show this change yet; it may still be in flight. Read the provider result again to settle it."
    /// "Stop waiting" (`PRWriteCoordinator.abandonUncertain`) is offered only for an `.uncertain` idempotent delta.
    public var canStopWaiting:Bool { state == .uncertain && command.intent.isIdempotent }
}
public protocol PRWriteAdapter:Sendable {
    func read(_ command:PRWriteCommand,operation:PRWriteOperation?,client:GitHubHTTPClient,credential:GitHubCredential) async throws -> PRWriteTruth
    func send(_ operation:PRWriteOperation,client:GitHubHTTPClient,credential:GitHubCredential) async throws -> GitHubResponse
    func providerIDs(_ response:GitHubResponse) -> [String]
    /// Whether a light write's receipt is a definite success of every part; defaults to the GitHub rules.
    func receiptConfirms(_ operation:PRWriteOperation,response:GitHubResponse) -> Bool
    /// Light picker/administration reads; defaults use the GitHub light readers.
    func metadataOptions(_ actionPR:PullRequest,client:GitHubHTTPClient,credential:GitHubCredential) async throws -> PRMetadataOptions
    func reviewAdministration(_ actionPR:PullRequest,client:GitHubHTTPClient,credential:GitHubCredential) async throws -> PRReviewAdministration
}
extension PRWriteAdapter {
    public func receiptConfirms(_ operation:PRWriteOperation,response:GitHubResponse) -> Bool { GitHubPRWriteAdapter.receiptConfirms(operation,response:response) }
    public func metadataOptions(_ actionPR:PullRequest,client:GitHubHTTPClient,credential:GitHubCredential) async throws -> PRMetadataOptions { try await GitHubPRLabelReader(client:client,credential:credential).options(actionPR) }
    public func reviewAdministration(_ actionPR:PullRequest,client:GitHubHTTPClient,credential:GitHubCredential) async throws -> PRReviewAdministration { try await GitHubPRReviewAdministrationReader(client:client,credential:credential).administration(actionPR) }
}
/// Feature coordinator over the existing session, budget and normalized database boundary.
/// User intent survives cancellation and account changes after dispatch under its captured identity.
public struct PRWriteCoordinator:Sendable {
    private let session:GitHubAccountSession
    private let budget:RateBudget
    private let database:DatabaseStore
    private let clientID:String
    private let activeAccount:@Sendable () async throws -> AccountScope?
    private let adapter:any PRWriteAdapter
    public init(session:GitHubAccountSession,budget:RateBudget,database:DatabaseStore,clientID:String,activeAccount:@escaping @Sendable () async throws -> AccountScope?,adapter:any PRWriteAdapter=GitHubPRWriteAdapter()) { self.session=session;self.budget=budget;self.database=database;self.clientID=clientID;self.activeAccount=activeAccount;self.adapter=adapter }
    public func inspect(_ command:PRWriteCommand) async throws -> PRWriteTruth {
        guard try await activeAccount() == command.key.account else { throw PRWriteFailure.accountChanged }
        let ticket=try await session.authenticatedOperation(for:command.key.account,clientID:clientID)
        do {
            let truth=try await adapter.read(command,operation:nil,client:await session.interactiveReadClient(account:ticket.account,budget:budget),credential:ticket.credential)
            guard try await activeAccount() == command.key.account,try await session.withCurrentOperation(ticket,body:{ _ in }) else { throw PRWriteFailure.accountChanged }
            return truth
        } catch { await session.featureFailed(error,operation:ticket);throw error }
    }
    /// Label/assignee picker node IDs for the selected action account: ONE light read.
    public func metadataOptions(for actionPR:PullRequest) async throws -> PRMetadataOptions {
        try await lightRead(actionPR) { [adapter] client,credential in try await adapter.metadataOptions(actionPR,client:client,credential:credential) }
    }
    /// Reviewer rows (Dismiss / Re-request / Discard evidence), requests and subscription: ONE light read.
    public func reviewAdministration(for actionPR:PullRequest) async throws -> PRReviewAdministration {
        try await lightRead(actionPR) { [adapter] client,credential in try await adapter.reviewAdministration(actionPR,client:client,credential:credential) }
    }
    private func lightRead<Value:Sendable>(_ pr:PullRequest,_ body:@Sendable (GitHubHTTPClient,GitHubCredential) async throws -> Value) async throws -> Value {
        guard try await activeAccount() == pr.key.account else { throw PRWriteFailure.accountChanged }
        let ticket=try await session.authenticatedOperation(for:pr.key.account,clientID:clientID)
        do {
            let value=try await body(await session.interactiveReadClient(account:ticket.account,budget:budget),ticket.credential)
            guard try await activeAccount() == pr.key.account,try await session.withCurrentOperation(ticket,body:{ _ in }) else { throw PRWriteFailure.accountChanged }
            return value
        } catch { await session.featureFailed(error,operation:ticket);throw error }
    }
    public func perform(_ command:PRWriteCommand) async throws -> PRWriteOperation {
        // Empty/contradictory deltas and missing dismissal messages never reserve or read.
        try command.intent.validateShape()
        guard try await activeAccount() == command.key.account else { throw PRWriteFailure.accountChanged }
        let ticket=try await session.authenticatedOperation(for:command.key.account,clientID:clientID)
        let store=DraftReviewStore(database:database)
        var operation=PRWriteOperation(command:command)
        // Reserve before network work. If persistence fails, there is no uncertain provider outcome.
        try store.prepare(operation)
        do {
            // The pre-write read is part of the user's submit: interactive, not queued behind background sync.
            let truth=try await adapter.read(command,operation:nil,client:await session.interactiveReadClient(account:ticket.account,budget:budget),credential:ticket.credential)
            try command.validate(truth:truth)
            // Risk only gates approval; other writes (e.g. a label toggle) skip the account snapshot.
            let risk:Bool
            if command.intent.decision == .approve {
                // Targeted rows: the PR itself and, only when a diff is evaluated, its repository's merged baseline.
                let current=try database.pullRequest(for:command.key)
                let merged=truth.document != nil && current != nil ? try database.pullRequests(repository:command.key.repository,states:[.merged]) : []
                risk=truth.riskFlagged || !(current?.metadata?.riskFlags ?? []).filter { $0 != RiskEvidence.Kind.unviewed.rawValue }.isEmpty || truth.document.map { document in
                    RiskRules.evaluate(files:document.files,viewed:[],usualSize:current.map { RepositorySizeBaseline.calculate(merged,for:$0).usualSize } ?? nil).contains { $0.kind != .unviewed }
                } == true
            } else { risk=false }
            if command.intent.decision == .approve,risk,try database.applicationSetting(.requireAllFilesViewedBeforeApprove) == "true" {
                guard truth.filesComplete,truth.viewed == truth.files else { throw PRWriteFailure.viewedIncomplete }
            }
            operation.beforeIDs=truth.existingObjectIDs;try store.update(operation,expectedState:.prepared)
            // Capture the stored row (including draftGeneration) so a multi-part send's later
            // final admission is the idempotent sending marker, not a stale-state conflict.
            operation=try store.operation(operation.id) ?? operation
            let prepared=operation
            let writer=await session.featureWriteClient(account:ticket.account,budget:budget) {
                guard try await activeAccount() == command.key.account else { throw PRWriteFailure.accountChanged }
                // The final admission is after budget waiting and immediately before base.send.
                guard try await session.withCurrentWriteOperation(ticket,body:{ _ in
                    if command.intent.decision == .approve,risk,try database.applicationSetting(.requireAllFilesViewedBeforeApprove) == "true" {
                        guard truth.filesComplete,truth.viewed == truth.files else { throw PRWriteFailure.viewedIncomplete }
                    }
                    var sent=prepared;sent.state = .sending
                    do { try store.update(sent,expectedState:.prepared) } catch let error as PRWriteFailure where error == .operationInProgress { throw error } catch { throw PRWriteFailure.persistenceBeforeSend }
                }) else { throw PRWriteFailure.accountChanged }
            }
            let response=try await adapter.send(prepared,client:writer,credential:ticket.credential)
            operation=try store.operation(operation.id) ?? operation
            // A user-clicked read may already have moved `.sending` to `.uncertain`; a settled row stays settled.
            let sent=operation.state
            guard [.sending,.uncertain].contains(sent) else { return operation }
            operation.response=response.data;operation.providerIDs=adapter.providerIDs(response)
            if command.intent.isRevisionIndependent,adapter.receiptConfirms(prepared,response:response) {
                // Every part returned a definite success: confirmed from the receipt alone. The refresh read
                // below only updates the cached row; failing or disagreeing, it leaves that to the next poll.
                operation.state = .confirmed;operation.providerIDs=[command.lightTargetID];operation.message=nil
                try store.update(operation,expectedState:sent)
                await refreshLightRow(operation,ticket:ticket)
                return operation
            }
            operation.state = .uncertain;try store.update(operation,expectedState:sent)
            let settled=try await reconcile(operation.id)
            // A complete read that doesn't show an ambiguous light receipt settled it as not applied.
            if settled.state == .rejected,command.intent.isRevisionIndependent { throw PRWriteRejection(kind:.notShown,summary:settled.message ?? PRWriteOperation.notShownMessage) }
            return settled
        } catch {
            await session.featureFailed(error,operation:ticket)
            if let auth=(error as? GitHubGraphQLMutationFailure)?.authenticationFailure { await session.featureFailed(auth,operation:ticket) }
            let partial=(error as? PRWriteRejection).flatMap { $0.kind == .partial ? $0 : nil }
            if let cause=partial?.cause {
                await session.featureFailed(cause,operation:ticket)
                if let auth=(cause as? GitHubGraphQLMutationFailure)?.authenticationFailure { await session.featureFailed(auth,operation:ticket) }
            }
            // A saved sending marker survives a lost response and process death.
            var saved=try store.operation(operation.id) ?? operation
            guard [.prepared,.sending,.uncertain].contains(saved.state) else { if saved.state == .rejected { throw error };return saved }
            let expected=saved.state
            let denied:Bool
            switch error as? GitHubFailure {
            case .invalidAuthentication,.scopeRequired,.organizationRestricted,.resourceDenied,.rateLimited:denied=true
            default:denied=(error as? GitHubGraphQLMutationFailure)?.definitelyRejected == true
            }
            // A saved `.uncertain` state means GitHub already returned a receipt; a later read/auth
            // failure (e.g. reconciliation re-admission) can never prove that write was rejected.
            // A definite partial split of an idempotent delta is terminal: what applied is named, nothing is resent.
            saved.state = partial != nil || saved.state == .prepared || denied && saved.state == .sending ? .rejected : .uncertain
            if let graph=error as? GitHubGraphQLMutationFailure { saved.response=graph.response }
            if let evidence=partial?.response { saved.response=evidence }
            saved.message=error.localizedDescription
            try store.update(saved,expectedState:expected)
            if saved.state == .rejected { throw error }
            return saved
        }
    }
    /// Best-effort cached-row refresh after a receipt-confirmed light write; it never changes the operation.
    /// Only a read that agrees with the delta replaces fields; a dismissal, which the receipt alone proves,
    /// still invalidates cached review and merge evidence.
    private func refreshLightRow(_ operation:PRWriteOperation,ticket:AccountOperation) async {
        let command=operation.command
        var truth:PRWriteTruth?
        do {
            let read=try await adapter.read(command,operation:operation,client:await session.featureClient(account:ticket.account,budget:budget),credential:ticket.credential)
            if command.reconciliation(truth:read) == .confirmed { truth=read }
        } catch {
            await session.featureFailed(error,operation:ticket)
            Log.writes.info("Refresh read after a confirmed light write failed; the cached row keeps its fields: \(Log.kind(error), privacy: .public)")
        }
        let agreed=truth
        do {
            _ = try await session.withCurrentOperation(ticket,body:{ db in
                if let row=try db.pullRequest(for:command.key).flatMap({ Self.lightConfirmation(command.intent,truth:agreed,cached:$0) }) { try db.confirmWrite(row) }
            })
        } catch { Log.storage.error("Cached row refresh after a confirmed light write failed: \(Log.kind(error), privacy: .public)") }
    }
    /// Confirmed light truth applied to the CACHED row. Labels, assignees and requests are not
    /// merge-policy inputs, so merge evidence/eligibility and all other metadata survive; a
    /// dismissal invalidates review and merge evidence. Discard/subscription change no row.
    /// Without a confirming `truth` (a receipt-confirmed write whose refresh read failed or disagreed) only a
    /// dismissal changes the row: its review/merge evidence is stale whatever the read says.
    static func lightConfirmation(_ intent:PRWriteIntent,truth:PRWriteTruth?,cached:PullRequest) -> PullRequest? {
        guard var metadata=cached.metadata else { return nil }
        switch intent {
        case .metadata(.labelChanges):
            guard let truth,truth.labelsComplete else { return nil }
            metadata.labels=truth.labelRefs.map(\.name);metadata.labelColors=truth.labelColors ?? metadata.labelColors
        case .metadata(.assigneeChanges):
            guard let truth,truth.assigneesComplete else { return nil }
            metadata.assignees=truth.assigneeRefs.map(\.login)
        case .metadata(.reviewRequestChanges(let users,let teams,_,_)):
            guard let truth,truth.requestsComplete else { return nil }
            let old=metadata.requests,affected=Set(users.map(\.id)+teams.map(\.id)),viewer=metadata.viewerID
            let fresh=truth.requestedUsers.map { PRReviewRequest(id:$0.id,name:$0.login,kind:.direct,isForViewer:$0.id == viewer,viewerStatus:$0.id == viewer ? .needsReview : .notForViewer) }+truth.requestedTeams.map { PRReviewRequest(id:$0.id,name:$0.slug,kind:.team,isForViewer:false,viewerStatus:.unknown) }
            // Verified team membership/already-reviewed status survives by stable ID; an explicit
            // (re-)request of a viewer-relevant request makes its review status unknown again.
            metadata.requests=fresh.map { request in
                guard let known=old.first(where:{ $0.id == request.id }) else { return request }
                var kept=request;kept.name=known.name;kept.isForViewer=known.isForViewer;kept.viewerStatus=known.viewerStatus
                if affected.contains(request.id),known.isForViewer || known.viewerStatus == .alreadyReviewed { kept.viewerStatus = .unknown;kept.isForViewer=true }
                return kept
            }
            let names=metadata.requests.map(\.name)
            metadata.reviewers=Array(Set(names+(truth.reviewsComplete ? truth.reviews.compactMap(\.authorLogin) : metadata.reviewers))).sorted()
        case .dismissReview:
            metadata.reviewDecision=truth.map(\.reviewDecision) ?? metadata.reviewDecision;metadata.approvalCount=nil;metadata.outstandingChanges=nil;metadata.reviewEvidenceComplete=false
            metadata.mergeEligible=nil;metadata.mergeEvidence=nil
        default:return nil
        }
        return PullRequest(key:cached.key,headRevision:cached.headRevision,title:cached.title,state:cached.state,isDraft:cached.isDraft,metadata:metadata)
    }
    /// Explicit "Stop waiting" for an `.uncertain` idempotent delta (labels, assignees, review requests,
    /// subscription) whose reads stay incomplete, e.g. more than 100 current values. Local only: it neither
    /// reads nor resends. The operation becomes terminal with `PRWriteOperation.stoppedWaitingMessage` and
    /// releases the pull request; resending such a delta later is harmless. Settled rows are returned as is;
    /// any other intent or state throws `.uncertain` and keeps its strict read-only reconciliation.
    public func abandonUncertain(_ id:UUID) throws -> PRWriteOperation {
        let store=DraftReviewStore(database:database)
        guard var operation=try store.operation(id) else { throw PRWriteFailure.unavailable }
        if [.confirmed,.postedOutdated,.rejected].contains(operation.state) { return operation }
        guard operation.canStopWaiting else { throw PRWriteFailure.uncertain }
        operation.state = .rejected;operation.message=PRWriteOperation.stoppedWaitingMessage
        try store.update(operation,expectedState:.uncertain)
        return try store.operation(id) ?? operation
    }
    /// Read-before-retry only. An uncertain creation is never automatically posted again. Light intents settle
    /// on a COMPLETE fresh read once the send is over (`.uncertain`): matched is confirmed and unmatched is
    /// terminal (`.rejected`, "GitHub doesn't show this change"). A `.sending` row may still be in flight in this
    /// process, so its unmatched read only moves it to `.uncertain`. Incomplete reads keep it uncertain.
    public func reconcile(_ id:UUID) async throws -> PRWriteOperation {
        let store=DraftReviewStore(database:database)
        guard var operation=try store.operation(id) else { throw PRWriteFailure.unavailable }
        try store.recoverReceipts(operation.command.key)
        guard [.sending,.uncertain].contains(operation.state) else { return operation }
        let expected=operation.state
        let ticket=try await session.authenticatedOperation(for:operation.command.key.account,clientID:clientID)
        do {
            let truth=try await adapter.read(operation.command,operation:operation,client:await session.interactiveReadClient(account:ticket.account,budget:budget),credential:ticket.credential)
            operation.state=operation.command.reconciliation(truth:truth)
            operation.providerIDs=truth.matchingOperationIDs
            if operation.command.intent.isRevisionIndependent {
                if operation.state != .uncertain { operation.message=nil }
                else if operation.command.lightReadIsDecisive(truth) {
                    if expected == .uncertain { operation.state = .rejected;operation.message=PRWriteOperation.notShownMessage } else { operation.message=PRWriteOperation.notShownYetMessage }
                }
            }
            let result=operation
            guard try await session.withCurrentOperation(ticket,body:{ db in
                var confirmed:PullRequest?
                if [.confirmed,.postedOutdated].contains(result.state),result.command.intent.isRevisionIndependent {
                    // Light reads replace only their own fields on the cached row.
                    confirmed=try db.pullRequest(for:result.command.key).flatMap { Self.lightConfirmation(result.command.intent,truth:truth,cached:$0) }
                } else if [.confirmed,.postedOutdated].contains(result.state),let normalized=truth.normalized {
                    var metadata=normalized.metadata
                    if let old=try db.pullRequest(for:normalized.key)?.metadata {
                        metadata?.descriptionPreview=old.descriptionPreview
                        metadata?.riskFlags=old.riskFlags;metadata?.createdAt=old.createdAt;metadata?.authorID=old.authorID;metadata?.actorType=old.actorType
                        metadata?.checks=old.checks;metadata?.failingRequiredCheck=old.failingRequiredCheck;metadata?.autoMerge=old.autoMerge;metadata?.autoMergeKnown=old.autoMergeKnown
                        metadata?.lastActivityAt=old.lastActivityAt;metadata?.columnChangedAt=old.columnChangedAt;metadata?.comments=old.comments;metadata?.mergeable=old.mergeable
                        metadata?.approvalCount=old.approvalCount;metadata?.outstandingChanges=old.outstandingChanges;metadata?.reviewEvidenceComplete=old.reviewEvidenceComplete
                        // This reader observes request IDs, not team membership/timeline status.
                        let requests=metadata?.requests ?? []
                        metadata?.requests=requests.map { request in
                            guard let known=old.requests.first(where:{ $0.id == request.id }) else { return request }
                            var kept=request;kept.isForViewer=known.isForViewer;kept.viewerStatus=known.viewerStatus;return kept
                        }
                        if !truth.requestsComplete { metadata?.requests=old.requests;metadata?.reviewers=old.reviewers }
                        if !truth.labelsComplete { metadata?.labels=old.labels }
                        if !truth.labelsComplete || metadata?.labelColors == nil { metadata?.labelColors=old.labelColors }
                        if !truth.assigneesComplete { metadata?.assignees=old.assignees }
                        if case .metadata(.reviewers(_,_,let remove)) = result.command.intent,!remove {
                            let requests=metadata?.requests ?? []
                            metadata?.requests=requests.map { request in
                                guard truth.affectedReviewRequestIDs.contains(request.id),request.isForViewer || request.viewerStatus == .alreadyReviewed else { return request }
                                var affected=request;affected.viewerStatus = .unknown;affected.isForViewer=true;return affected
                            }
                        }
                        if result.command.intent.decision != nil {
                            metadata?.approvalCount=nil;metadata?.outstandingChanges=nil;metadata?.reviewEvidenceComplete=false
                        }
                    }
                    // Eligibility is independent and must refresh after every confirmed mutation.
                    metadata?.mergeEligible=nil;metadata?.mergeEvidence=nil
                    confirmed=PullRequest(key:normalized.key,headRevision:normalized.headRevision,title:normalized.title,state:normalized.state,isDraft:normalized.isDraft,metadata:metadata)
                }
                try store.commitReceipt(result,expectedState:expected,normalized:confirmed)
            }) else { throw PRWriteFailure.unavailable }
            return operation
        } catch {
            await session.featureFailed(error,operation:ticket)
            if let current=try store.operation(id),![.sending,.uncertain].contains(current.state) { try store.recoverReceipts(current.command.key);return current }
            operation.state = .uncertain;operation.message=error.localizedDescription;try store.update(operation,expectedState:expected)
            return operation
        }
    }
}
