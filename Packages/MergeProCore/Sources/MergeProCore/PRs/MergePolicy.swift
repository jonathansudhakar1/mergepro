import Foundation

public enum MergeMethod:String,Codable,Sendable,CaseIterable { case merge,squash,rebase }
public enum MergeAction:String,Codable,Sendable { case direct="direct_merge",queue="merge_queue",enableAutoMerge,disableAutoMerge,removeQueue,updateBranch }
public enum MergeRequirementState:String,Codable,Sendable { case satisfied,pending,unknown }
public struct MergeRequirement:Codable,Sendable,Equatable {
    public let name:String
    public let state:MergeRequirementState
    public init(name:String,state:MergeRequirementState) { self.name=name;self.state=state }
}
public struct MergeCheckRequirement:Sendable,Equatable { public let context:String;public let appID:Int?;public init(context:String,appID:Int?) { self.context=context;self.appID=appID } }
public struct MergeCheck:Sendable,Equatable {
    public enum Kind:Sendable { case check,status }
    public let context:String;public let appID:Int?;public let sha:String;public let state:String;public let kind:Kind
    public init(context:String,appID:Int?,sha:String,state:String,kind:Kind) { self.context=context;self.appID=appID;self.sha=sha;self.state=state;self.kind=kind }
}
/// Account-scoped configured, non-bypass evidence. Nil never means permission or no protection.
public struct MergeEvidence:Codable,Sendable,Equatable {
    public let key:ProviderKey
    public let head:String
    public let base:String
    public let branch:String
    public var fetchedAt:Date
    public var open=false,draft=true,behind=false,operationInProgress=false
    public var conflictFree:Bool?,actorAllowed:Bool?,tokenCanWrite:Bool?
    public var rulesComplete=false,asyncSupported=false,queueRequired=false,autoMergeEnabled=false,queued=false
    public var canEnableAutoMerge=false,canDisableAutoMerge=false,canUpdateBranch=false,canRemoveQueue=false
    public var methods:[MergeMethod]=[]
    public var queueMethod:MergeMethod?
    public var requirements:[MergeRequirement]=[]
    public var optionalFailures:[String]=[]
    public var limitations:[String]=[]
    public var nativeAdmission:MergeRequirement?
    /// Missing on legacy proof that did not retain lower-layer unknownness.
    public var nativeAdmissionVersion:Int?
    public var nativeAffected:[ProviderKey]?
    public var ruleIdentity:String=""
    /// Human-readable reason per removed `MergeMethod.rawValue`; first trimming site wins.
    /// Optional for decoding compatibility. Presentation only: never an admission fact.
    public var methodReasons:[String:String]?
    public init(key:ProviderKey,head:String,base:String,branch:String,fetchedAt:Date) { self.key=key;self.head=head;self.base=base;self.branch=branch;self.fetchedAt=fetchedAt }
    /// Freshness alone changes on a read; all admission-relevant evidence must otherwise agree.
    /// Method reasons only explain `methods` (still compared), e.g. a renamed ruleset.
    public func sameAdmission(as other:Self) -> Bool { var a=self,b=other;a.fetchedAt = .distantPast;b.fetchedAt = .distantPast;a.operationInProgress=false;b.operationInProgress=false;a.methodReasons=nil;b.methodReasons=nil;return a == b }
    /// Removes methods, recording the first reason for each method still present.
    mutating func removeMethods(because reason:String,where remove:(MergeMethod) -> Bool) {
        var reasons=methodReasons ?? [:]
        for method in methods where remove(method) && reasons[method.rawValue] == nil { reasons[method.rawValue]=reason }
        methods.removeAll(where:remove);methodReasons=reasons
    }
}
public struct MergeEligibility:Sendable,Equatable {
    /// Submit evidence: fresh (within `MergePolicy.maximumAge`) and satisfying every requirement.
    public let eligible:Bool
    public let action:MergeAction
    public let methods:[MergeMethod]
    public let reasons:[String]
    /// Known blockers only: facts from the row, or from evidence still within `MergePolicy.maximumAge`, that reading
    /// GitHub again would not clear (not open, draft, conflicts, not permitted, an operation pending reconciliation,
    /// already queued or auto-merging). Stale, missing or incomplete evidence is never a blocker.
    public var blockers:[String]=[]
    /// When merge evidence for the current head was last read for this account; nil when it never was.
    public var verifiedAt:Date?
    /// The read at `verifiedAt` found every requirement satisfied. GitHub may have changed since.
    public var verifiedReady=false
    public var label:String { action == .queue ? "Add to merge queue" : "Merge" }
    /// Every Merge entry point opens the merge sheet unless a known blocker exists. Stale or unknown evidence
    /// never blocks opening it: the sheet reads GitHub again and refuses to submit without fresh, eligible evidence.
    public var opensMergeSheet:Bool { blockers.isEmpty }
}
/// Whether the inventory alone says a pull request is ready to merge. See `MergePolicy.inventoryReadiness`.
public enum InventoryMergeReadiness:String,Sendable { case ready,notReady,unknown }
/// A batch merge after skipping rows with known blockers; the remaining rows are verified in the sheet.
public struct MergeBatchPlan:Sendable,Equatable {
    public struct Skip:Sendable,Equatable,Identifiable {
        public let pr:PullRequest
        public let reason:String
        public var id:ProviderKey { pr.key }
        public init(pr:PullRequest,reason:String) { self.pr=pr;self.reason=reason }
    }
    public var ready:[PullRequest]=[]
    public var skipped:[Skip]=[]
    public init(ready:[PullRequest]=[],skipped:[Skip]=[]) { self.ready=ready;self.skipped=skipped }
}
/// One row of the method picker, in GitHub's merge/squash/rebase order.
public struct MergeMethodOption:Sendable,Equatable,Identifiable {
    public let method:MergeMethod
    public let enabled:Bool
    public let reason:String?
    public init(method:MergeMethod,enabled:Bool,reason:String?) { self.method=method;self.enabled=enabled;self.reason=reason }
    public var id:MergeMethod { method }
    public var label:String { switch method { case .merge:"Create a merge commit";case .squash:"Squash and merge";case .rebase:"Rebase and merge" } }
}
public enum MergePolicy {
    /// Every method in GitHub's order, enabled exactly as `evaluate`/`MergeCommand.validate` would accept it.
    public static func methodOptions(_ evidence:MergeEvidence?,action:MergeAction) -> [MergeMethodOption] {
        func all(_ reason:String) -> [MergeMethodOption] { MergeMethod.allCases.map { .init(method:$0,enabled:false,reason:reason) } }
        guard let e=evidence else { return all("Merge evidence has not been read for the active account.") }
        switch action {
        case .disableAutoMerge,.removeQueue,.updateBranch:return all("Not used by this action.")
        case .queue,.direct where e.queueRequired:
            guard let queue=e.queueMethod else { return all("Merge queue method is unknown.") }
            return MergeMethod.allCases.map { .init(method:$0,enabled:$0 == queue,reason:$0 == queue ? nil : "Merge queue uses \(queue.rawValue)") }
        case .direct,.enableAutoMerge:
            return MergeMethod.allCases.map { m in e.methods.contains(m) ? .init(method:m,enabled:true,reason:nil) : .init(method:m,enabled:false,reason:e.methodReasons?[m.rawValue] ?? "Not verified as allowed for this pull request.") }
        }
    }
    public static func becameReady(previous:PullRequest?,current:PullRequest,now:Date=Date()) -> Bool {
        guard let before=previous?.metadata?.mergeEvidence,let after=current.metadata?.mergeEvidence,before.key == after.key else { return false }
        // A readiness transition starts from authoritative blocked evidence. Learning
        // previously missing lower-layer facts is not a newly-ready provider event.
        return requirementState(before,now:before.fetchedAt) == .pending && evaluate(after,now:now).eligible
    }
    /// Preserve evidence knowledge when composing native affected-layer admission.
    /// The shared policy still decides eligibility; this distinguishes missing proof
    /// from a verified blocker without turning reason strings into another policy.
    static func requirementState(_ evidence:MergeEvidence,now:Date=Date()) -> MergeRequirementState {
        guard evidence.rulesComplete, evidence.actorAllowed != nil,
              evidence.tokenCanWrite != nil, evidence.conflictFree != nil,
              evidence.nativeAdmission?.state != .unknown,
              evidence.nativeAdmission == nil || evidence.nativeAdmissionVersion == 1,
              !evidence.requirements.contains(where:{ $0.state == .unknown }),
              evidence.limitations.isEmpty, evidence.asyncSupported,
              !evidence.queueRequired || evidence.queueMethod != nil,
              now.timeIntervalSince(evidence.fetchedAt) <= maximumAge,
              evidence.fetchedAt <= now.addingTimeInterval(5) else { return .unknown }
        return evaluate(evidence,now:now).eligible ? .satisfied : .pending
    }
    public static let maximumAge:TimeInterval=60
    private static let staleReason="Merge evidence is stale; refresh."
    private static let notOpen="Pull request is not open.",draft="Pull request is draft.",conflicts="Merge conflicts."
    static func isFresh(_ evidence:MergeEvidence,now:Date) -> Bool { now.timeIntervalSince(evidence.fetchedAt) <= maximumAge && evidence.fetchedAt <= now.addingTimeInterval(5) }
    /// Blockers the row itself proves, whatever the age of its merge evidence.
    static func rowBlockers(_ pr:PullRequest) -> [String] {
        var result:[String]=[]
        if pr.state != .open { result.append(notOpen) }
        if pr.isDraft { result.append(draft) }
        if pr.metadata?.mergeable?.uppercased() == "CONFLICTING" { result.append(conflicts) }
        return result
    }
    public static func evaluate(pr:PullRequest,now:Date=Date()) -> MergeEligibility {
        let row=rowBlockers(pr)
        func adding(_ value:MergeEligibility) -> MergeEligibility {
            var result=value;var seen=Set<String>();result.blockers=(row+value.blockers).filter { seen.insert($0).inserted };return result
        }
        guard let e=pr.metadata?.mergeEvidence,e.key == pr.key,e.head == pr.headRevision.rawValue,e.open == (pr.state == .open),e.draft == pr.isDraft else { return adding(evaluate(nil,now:now)) }
        if pr.metadata?.nativeStack != nil && e.nativeAdmission == nil {
            let evidence=evaluate(e,now:now)
            return adding(.init(eligible:false,action:e.queueRequired ? .queue : .direct,methods:[],reasons:["Native affected-layer admission has not been verified."],blockers:evidence.blockers,verifiedAt:e.fetchedAt))
        }
        return adding(evaluate(e,now:now))
    }
    /// Row facts only, without merge evidence: for a row the action account has not read (another account's row).
    public static func unverified(_ pr:PullRequest) -> MergeEligibility {
        var result=evaluate(nil);result.blockers=rowBlockers(pr);return result
    }
    public static func evaluate(_ evidence:MergeEvidence?,now:Date=Date()) -> MergeEligibility {
        guard let e=evidence else { return .init(eligible:false,action:.direct,methods:[],reasons:["Merge evidence has not been read for the active account."]) }
        var reasons=e.limitations
        if e.nativeAdmission != nil && e.nativeAdmissionVersion != 1 {
            reasons.append("Native affected-layer proof must be refreshed.")
        }
        if let native=e.nativeAdmission,native.state != .satisfied { reasons.append(native.name+": "+native.state.rawValue) }
        let fresh=isFresh(e,now:now)
        if !fresh { reasons.append(staleReason) }
        if !e.open { reasons.append(notOpen) };if e.draft { reasons.append(draft) }
        if e.operationInProgress { reasons.append("An action is pending reconciliation.") }
        if e.conflictFree != true { reasons.append(e.conflictFree == false ? conflicts : "Mergeability is unknown.") }
        if e.actorAllowed != true { reasons.append(e.actorAllowed == false ? "The active account is not permitted." : "Actor restrictions or membership are unknown.") }
        if e.tokenCanWrite != true { reasons.append("Contents write capability is unavailable.") }
        if !e.rulesComplete { reasons.append("Configured protection and applicable rule evidence is incomplete.") }
        if !e.asyncSupported { reasons.append("Async merge is unavailable on this host.") }
        reasons += e.requirements.filter { $0.state != .satisfied }.map { "\($0.name): \($0.state.rawValue)" }
        let methods=e.queueRequired ? e.queueMethod.map { [$0] } ?? [] : e.methods
        if methods.isEmpty { reasons.append("No verified allowed merge method.") }
        if e.queued { reasons.append("Already in merge queue.") }
        if e.autoMergeEnabled { reasons.append("Auto-merge is enabled; waiting for GitHub. Disable it before choosing a new merge intent.") }
        // Only fresh evidence proves a blocker; an older read is unknown now and the sheet reads again.
        var blockers:[String]=[]
        if fresh {
            if !e.open { blockers.append(notOpen) };if e.draft { blockers.append(draft) }
            if e.operationInProgress { blockers.append("An action is pending reconciliation.") }
            if e.conflictFree == false { blockers.append(conflicts) }
            if e.actorAllowed == false { blockers.append("The active account is not permitted.") }
            if e.tokenCanWrite == false { blockers.append("Contents write capability is unavailable.") }
            if e.queued { blockers.append("Already in merge queue.") }
            if e.autoMergeEnabled { blockers.append("Auto-merge is enabled; disable it before choosing a new merge intent.") }
        }
        return .init(eligible:reasons.isEmpty,action:e.queueRequired ? .queue : .direct,methods:methods,reasons:reasons,
                     blockers:blockers,verifiedAt:e.fetchedAt,verifiedReady:reasons.allSatisfy { $0 == staleReason })
    }
    /// The built-in "Ready to merge" rule, from inventory facts that a poll refreshes and that don't expire with
    /// 60-second merge evidence: open, not draft, approved (GitHub's APPROVED decision, or the complete
    /// no-required-review fallback the board's Approved column uses), the head's check rollup SUCCESS, no failing
    /// required check, and GitHub reports MERGEABLE (no conflicts). A known contrary fact is `.notReady`; a missing
    /// fact (no check rollup, UNKNOWN mergeability, no review decision) is `.unknown`, never assumed ready.
    /// Readiness here never authorizes a merge: the merge sheet verifies fresh evidence before submitting.
    public static func inventoryReadiness(_ pr:PullRequest) -> InventoryMergeReadiness {
        guard pr.state == .open,!pr.isDraft,let m=pr.metadata else { return pr.state != .open || pr.isDraft ? .notReady : .unknown }
        let review=m.reviewDecision?.uppercased(),checks=m.checks?.uppercased(),mergeable=m.mergeable?.uppercased()
        if review == "CHANGES_REQUESTED" || review == "REVIEW_REQUIRED" || m.failingRequiredCheck == true || mergeable == "CONFLICTING" { return .notReady }
        if let checks,checks != "SUCCESS" { return .notReady }
        let approved=BoardProjection.column(for:pr,showDrafts:true) == .approved
        return approved && checks == "SUCCESS" && mergeable == "MERGEABLE" ? .ready : .unknown
    }
    /// Batch merge skips rows with known blockers (each listed with its first blocker) instead of refusing the batch.
    public static func batchPlan(_ rows:[PullRequest],eligibility:(PullRequest) -> MergeEligibility) -> MergeBatchPlan {
        var plan=MergeBatchPlan()
        for pr in rows {
            let value=eligibility(pr)
            if let blocker=value.blockers.first { plan.skipped.append(.init(pr:pr,reason:blocker)) } else { plan.ready.append(pr) }
        }
        return plan
    }
    public static func checkState(_ requirement:MergeCheckRequirement,checks:[MergeCheck],head:String,testMerge:String?) -> MergeRequirementState {
        let sha=testMerge.flatMap { test in checks.contains(where:{ $0.sha == test }) ? test : nil } ?? head
        let named=checks.filter { $0.sha == sha && $0.context == requirement.context }
        let bound=named.filter { requirement.appID == nil || requirement.appID == -1 || $0.appID == requirement.appID }
        guard !bound.isEmpty else { return .pending }
        let matching=bound+named.filter { $0.kind == .status && !bound.contains($0) }
        return matching.allSatisfy { $0.kind == .check ? ["SUCCESS","NEUTRAL","SKIPPED"].contains($0.state.uppercased()) : $0.state.uppercased() == "SUCCESS" } ? .satisfied : .pending
    }
}
