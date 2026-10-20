import Foundation

public enum MergeOutcome:Equatable,Codable,Sendable {
    case pending(operationID:String),queued,merged(commitSHA:String),failed(reason:String)
    case autoMergeEnabled,autoMergeDisabled,queueRemoved,branchUpdated(head:String)
}
public struct MergeTarget:Codable,Equatable,Sendable {
    public let key:ProviderKey
    public let repository:String
    public let number:Int
    public let head:String
    public init(_ pr:PullRequest) throws {
        guard let m=pr.metadata,m.number>0 else { throw PRWriteFailure.unavailable }
        key=pr.key;repository=m.repositoryName;number=m.number;head=pr.headRevision.rawValue
    }
    public var gitHubNodeID:String { key.objectID.hasPrefix("pull-request:") ? String(key.objectID.dropFirst("pull-request:".count)) : key.objectID }
}
public struct MergeInspection:Sendable {
    public var pr:PullRequest
    public var evidence:MergeEvidence
    public var stack:PRStack?
    public var mergeCommitSHA:String?
    public var headParents:[String]=[]
    /// Provider's enabled auto-merge options. Read for reconciliation; never persisted.
    public var autoMergeRequest:MergeAutoMergeRequest?
    /// Only parent of the oldest PR commit, when the read commit chain is complete, linear and ends at head.
    public var linearBase:String?
    public init(pr:PullRequest,evidence:MergeEvidence,stack:PRStack?=nil,mergeCommitSHA:String?=nil) { self.pr=pr;self.evidence=evidence;self.stack=stack;self.mergeCommitSHA=mergeCommitSHA }
}
/// GitHub `autoMergeRequest { enabledAt mergeMethod commitHeadline commitBody }`.
public struct MergeAutoMergeRequest:Sendable,Equatable {
    public var method:MergeMethod?
    public var commitHeadline:String?
    public var commitBody:String?
    public var enabledAt:Date?
    public init(method:MergeMethod?,commitHeadline:String?=nil,commitBody:String?=nil,enabledAt:Date?=nil) { self.method=method;self.commitHeadline=commitHeadline;self.commitBody=commitBody;self.enabledAt=enabledAt }
    /// Method must match; text is compared only for fields the command overrides (nil follows GitHub's default).
    /// GitHub reports a blank headline/body as null, so nil and "" (after normalization) are equal.
    public func matches(_ command:MergeCommand) -> Bool {
        func normalized(_ value:String?) -> String { var v=(value ?? "").replacingOccurrences(of:"\r\n",with:"\n");while let last=v.last,last.isWhitespace { v.removeLast() };return v }
        return method?.rawValue == command.method && (command.title == nil || normalized(commitHeadline) == normalized(command.title)) && (command.message == nil || normalized(commitBody) == normalized(command.message))
    }
}
/// A verified inferred parent is a continuation constraint, never permission to restack.
public struct InferredMergeDependency: Codable, Equatable, Sendable {
    public let parent: ProviderKey
    public let parentHead: String
    public let parentBranch: String
    public let parentWasMerged: Bool
    public let providerURL: URL
    public init(parent:ProviderKey,parentHead:String,parentBranch:String,parentWasMerged:Bool,providerURL:URL) {
        self.parent=parent;self.parentHead=parentHead;self.parentBranch=parentBranch
        self.parentWasMerged=parentWasMerged;self.providerURL=providerURL
    }
}
/// How `.updateBranch` brings the head up to date with its base.
public enum MergeUpdateMethod:String,Codable,Sendable,CaseIterable { case merge,rebase }
/// A frozen popup choice. The same ledger reserves this and review/metadata/viewed intents.
public struct MergeCommand:Codable,Equatable,Sendable {
    public let pr:ProviderKey
    public let expectedHeadSHA:String
    public let method:String
    public let action:String
    public let title:String?
    public let message:String?
    public let target:MergeTarget
    public let affected:[MergeTarget]
    public let reviewed:[MergeEvidence]
    public let nativeStackID:String?
    public let topology:String?
    public let topologyRevisions:String?
    public var inferredDependency:InferredMergeDependency?
    /// `MergeUpdateMethod.rawValue` for `.updateBranch`; nil (also legacy) is the nonforce merge update.
    public let updateMethod:String?
    public init(selected:MergeInspection,affected:[MergeInspection],method:MergeMethod,action:MergeAction,title:String?=nil,message:String?=nil,updateMethod:MergeUpdateMethod?=nil) throws {
        self.updateMethod=action == .updateBranch && updateMethod == .rebase ? MergeUpdateMethod.rebase.rawValue : nil
        // Only direct merge and auto-merge accept commit text, and never for rebase. A blank headline is no override.
        let text=method != .rebase && [.direct,.enableAutoMerge].contains(action)
        target=try .init(selected.pr);pr=target.key;expectedHeadSHA=target.head;self.method=method.rawValue;self.action=action.rawValue
        self.title=text ? title.flatMap { $0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? nil : $0 } : nil;self.message=text ? message : nil
        self.affected=try affected.map { try .init($0.pr) };reviewed=affected.map(\.evidence)
        nativeStackID=selected.stack?.kind == .native ? selected.stack?.id : nil;topology=nativeStackID == nil ? nil : selected.stack?.signature
        topologyRevisions=nativeStackID == nil ? nil : selected.stack?.revisionSignature
        guard !self.affected.isEmpty,self.affected.contains(target),Set(self.affected.map(\.key)).count == self.affected.count,self.affected.allSatisfy({ $0.key.repository == pr.repository }) else { throw PRWriteFailure.unavailable }
    }
    public var writeCommand:PRWriteCommand { .init(key:pr,repository:target.repository,number:target.number,revision:.init(head:expectedHeadSHA,origin:reviewed.first(where:{ $0.key == pr })?.base ?? "",target:reviewed.first(where:{ $0.key == pr })?.base ?? ""),intent:.merge(self)) }
    public func validate(_ observations:[MergeInspection]) throws {
        guard let action=MergeAction(rawValue:action),let selected=observations.first(where:{ $0.pr.key == pr }),observations.count == affected.count else { throw PRWriteFailure.unavailable }
        if let nativeStackID {
            guard selected.stack?.id == nativeStackID,selected.stack?.signature == topology else { throw PRWriteFailure.revisionChanged }
            // Only layer-affecting actions are bound to the affected set (prepare uses [selected] otherwise).
            if [.direct,.queue,.removeQueue].contains(action) { guard try selected.stack!.affected(upTo:pr,action:action).map(\.key) == affected.map(\.key) else { throw PRWriteFailure.revisionChanged } }
        } else if selected.stack?.kind == .native { throw PRWriteFailure.revisionChanged }
        for target in affected {
            guard let actual=observations.first(where:{ $0.pr.key == target.key }),let captured=reviewed.first(where:{ $0.key == target.key }),actual.evidence.head == target.head,actual.evidence.base == captured.base else { throw PRWriteFailure.revisionChanged }
            guard Date().timeIntervalSince(actual.evidence.fetchedAt) <= MergePolicy.maximumAge else { throw PRWriteFailure.unavailable }
            if [.direct,.queue].contains(action) {
                let policy=MergePolicy.evaluate(actual.evidence)
                guard policy.eligible,policy.action == action,policy.methods.contains(where:{ $0.rawValue == method }),actual.evidence.sameAdmission(as:captured) else { throw PRWriteFailure.permissionDenied }
            }
        }
        switch action {
        case .enableAutoMerge:guard selected.stack == nil,selected.evidence.canEnableAutoMerge,selected.evidence.open,!selected.evidence.draft,selected.evidence.methods.contains(where:{ $0.rawValue == method }) else { throw PRWriteFailure.permissionDenied }
        case .disableAutoMerge:guard selected.evidence.canDisableAutoMerge,selected.evidence.autoMergeEnabled else { throw PRWriteFailure.permissionDenied }
        case .removeQueue:guard selected.evidence.canRemoveQueue,selected.evidence.queued else { throw PRWriteFailure.permissionDenied }
        case .updateBranch:guard selected.evidence.canUpdateBranch,selected.evidence.open else { throw PRWriteFailure.permissionDenied }
        case .direct,.queue:break
        }
    }
}
